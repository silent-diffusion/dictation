#if os(macOS)
import AVFoundation
import CoreAudio
import Foundation
import ObertonCore

/// Everything this Mac plays, as 16 kHz mono Float32 samples (Core Audio process tap).
/// A global tap (all processes, nothing excluded) feeds a private aggregate device whose IO proc converts each
/// buffer with AVAudioConverter. Needs "System Audio Recording" permission (NSAudioCaptureUsageDescription).
final class SystemAudioCapture {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "Oberton.SystemAudioCapture", qos: .userInitiated)
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    init() {}

    deinit { stop() }

    /// Starts capturing; `onSamples` is called on a background queue with 16 kHz mono float samples (-1...1),
    /// continuously, including silence (zeros), roughly every 10–100 ms.
    func start(onSamples: @escaping ([Float]) -> Void) throws {
        stop()
        do {
            try setUp(onSamples: onSamples)
        } catch {
            stop()
            throw error
        }
    }

    /// Tears down the IO proc, aggregate device and tap. Safe to call more than once.
    func stop() {
        if aggregateID != kAudioObjectUnknown, let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func setUp(onSamples: @escaping ([Float]) -> Void) throws {
        // 1. A private stereo tap of every process's output, left audible.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Oberton Extended Notes"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr, tap != kAudioObjectUnknown else {
            throw UserFacingError("Oberton couldn't capture the computer's audio. Allow Oberton under System Settings › "
                                  + "Privacy & Security › Screen & System Audio Recording, then try again. (\(tapStatus))")
        }
        tapID = tap

        // 2. The tap's stream format (usually Float32 stereo at the output device's rate).
        var asbd = AudioStreamBasicDescription()
        try check(Self.get(tap, kAudioTapPropertyFormat, &asbd), "read the computer audio format")
        guard let tapFormat = AVAudioFormat(streamDescription: &asbd),
              let converter = AVAudioConverter(from: tapFormat, to: outputFormat) else {
            Log.warn("Computer audio: can't convert \(Int(asbd.mSampleRate)) Hz, \(asbd.mChannelsPerFrame) ch")
            throw UserFacingError(Self.failed)
        }
        converter.downmix = true

        // 3. A private aggregate device clocked by the default output device, containing the tap.
        var outputDevice = AudioObjectID(kAudioObjectUnknown)
        try check(Self.get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice,
                           &outputDevice), "find the output device")
        var outputUID: CFString = "" as CFString
        try check(Self.get(outputDevice, kAudioDevicePropertyDeviceUID, &outputUID), "read the output device")
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Oberton System Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID as String,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID as String]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "set up audio capture")
        aggregateID = device

        // 4. The IO proc: wrap the tap's buffer, resample to 16 kHz mono, hand the samples on.
        let output = outputFormat
        let ratio = output.sampleRate / tapFormat.sampleRate
        var proc: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { _, inputData, _, _, _ in
            guard let input = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: inputData, deallocator: nil),
                  input.frameLength > 0,
                  let out = AVAudioPCMBuffer(pcmFormat: output,
                                             frameCapacity: AVAudioFrameCount(Double(input.frameLength) * ratio) + 32)
            else { return }
            var fed = false
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if fed { inputStatus.pointee = .noDataNow; return nil }
                fed = true
                inputStatus.pointee = .haveData
                return input
            }
            guard status != .error, out.frameLength > 0, let channel = out.floatChannelData?[0] else { return }
            onSamples(Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength))))
        }, "set up audio capture")
        procID = proc

        // 5. Go.
        try check(AudioDeviceStart(device, proc), "start capturing the computer's audio")
        let float = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        Log.info("Computer audio: \(Int(asbd.mSampleRate)) Hz, \(asbd.mChannelsPerFrame) ch, \(asbd.mBitsPerChannel)-bit \(float ? "IeeeFloat" : "Pcm")")
    }

    /// Windows' one sentence for a capture that can't start (LoopbackCapture.Start); the step and the error go to the log.
    static let failed = "Couldn't listen to the computer's audio. Check that a sound output device is enabled."

    private func check(_ status: OSStatus, _ action: String) throws {
        guard status != noErr else { return }
        Log.warn("Computer audio: couldn't \(action) (Core Audio error \(status))")
        throw UserFacingError(Self.failed)
    }

    /// Reads a global-scope property of a fixed-size type.
    private static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> OSStatus {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
    }
}
#endif
