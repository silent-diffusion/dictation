#if os(macOS)
import AVFoundation
import CoreAudio
import Foundation
import ObertonCore

/// What this Mac plays on its default output device, as 16 kHz mono Float32 samples (Core Audio process tap), as
/// Windows' WASAPI loopback of the default render device. A tap of every process's audio bound for that device's first
/// stream feeds a private aggregate device whose IO proc converts each buffer with AVAudioConverter. Needs "System Audio
/// Recording" permission (NSAudioCaptureUsageDescription).
final class SystemAudioCapture {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    /// The output device tapped, and the listener that says when it goes away.
    private var outputID = AudioObjectID(kAudioObjectUnknown)
    private var aliveListener: AudioObjectPropertyListenerBlock?
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
        if outputID != kAudioObjectUnknown, let aliveListener {
            var address = Self.address(kAudioDevicePropertyDeviceIsAlive)
            AudioObjectRemovePropertyListenerBlock(outputID, &address, queue, aliveListener)
        }
        aliveListener = nil
        outputID = AudioObjectID(kAudioObjectUnknown)
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
        // 0. The default output device (Windows' default render device for multimedia, which loopback records).
        var outputDevice = AudioObjectID(kAudioObjectUnknown)
        try check(Self.get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                           &outputDevice), "find the output device")
        var outputUID: CFString = "" as CFString
        try check(Self.get(outputDevice, kAudioDevicePropertyDeviceUID, &outputUID), "read the output device")

        // 1. A private tap of what every process sends to that device's first stream, left audible. A device that
        // won't be tapped on its own falls back to everything the Mac plays (the tap as it was before).
        func tapDescription(device: Bool) -> CATapDescription {
            let d = device ? CATapDescription(excludingProcesses: [], deviceUID: outputUID as String, stream: 0)
                : CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            d.uuid = UUID()
            d.name = "Oberton Extended Notes"
            d.isPrivate = true
            d.muteBehavior = .unmuted
            return d
        }
        var description = tapDescription(device: true)
        var tap = AudioObjectID(kAudioObjectUnknown)
        var tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        if tapStatus != noErr || tap == kAudioObjectUnknown {
            Log.warn("Computer audio: couldn't tap the output device alone (Core Audio error \(tapStatus)); tapping all of the Mac's audio")
            description = tapDescription(device: false)
            tap = AudioObjectID(kAudioObjectUnknown)
            tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        }
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
        // The device going away (headphones unplugged, a USB device gone) ends the capture: Windows' RecordingStopped
        // with an exception logs it as an error. The session goes on, its clock filling the gap with silence.
        outputID = outputDevice
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            var alive: UInt32 = 1
            guard Self.get(self.outputID, kAudioDevicePropertyDeviceIsAlive, &alive) != noErr || alive == 0 else { return }
            Log.error("Computer audio capture stopped: the output device \(outputUID as String) is gone")
        }
        var aliveAddress = Self.address(kAudioDevicePropertyDeviceIsAlive)
        if AudioObjectAddPropertyListenerBlock(outputDevice, &aliveAddress, queue, listener) == noErr { aliveListener = listener }
        // The format as it is: Core Audio has no WAVEFORMATEXTENSIBLE wrapper, which Windows' mix format reports as
        // "Extensible".
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

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    /// Reads a global-scope property of a fixed-size type.
    private static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> OSStatus {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
    }
}
#endif
