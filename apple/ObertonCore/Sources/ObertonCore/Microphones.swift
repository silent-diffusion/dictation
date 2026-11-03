import AVFoundation
import Foundation
#if os(macOS)
import CoreAudio
#endif

/// The microphones to choose from (Settings › Microphone, `AppSettings.microphoneName`), by name as on Windows. On the
/// Mac: every Core Audio device with an input, set on the audio engine's input unit. On iPhone and iPad: the audio
/// session's inputs, chosen as its preferred input. A name that is no longer there falls back to the system default.
public enum Microphones {
    /// Every input device's name, in the system's order.
    public static var names: [String] {
        #if os(macOS)
        inputDevices().map(\.name)
        #else
        AVAudioSession.sharedInstance().availableInputs?.map(\.portName) ?? []
        #endif
    }

    /// The system's default input, for display.
    public static var defaultName: String? {
        #if os(macOS)
        AVCaptureDevice.default(for: .audio)?.localizedName
        #else
        AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName
        #endif
    }

    /// Make this engine record from the named microphone (nil: the system default). Before the engine starts.
    static func use(_ name: String?, on engine: AVAudioEngine) {
        #if os(macOS)
        // The engine is reused, so the default is set again too when no microphone (or a missing one) is chosen.
        guard let unit = engine.inputNode.audioUnit,
              var id = name.flatMap({ n in inputDevices().first { $0.name == n }?.id }) ?? defaultInputDevice() else { return }
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        #else
        let session = AVAudioSession.sharedInstance()
        let port = name.flatMap { n in session.availableInputs?.first { $0.portName == n } }
        try? session.setPreferredInput(port)
        #endif
    }

    #if os(macOS)
    private static func inputDevices() -> [(id: AudioDeviceID, name: String)] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannels(id) > 0, let name = deviceName(id) else { return nil }
            return (id, name)
        }
    }

    private static func defaultInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func deviceName(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }
    #endif
}

/// The INPUT LEVEL meter on Settings › Microphone: its own microphone, open while the page is (as Windows' AudioPage),
/// never while a dictation records.
public final class MicrophoneMeter: @unchecked Sendable {
    private let engine = AVAudioEngine()
    /// Called on the main queue with the level, 0…1.
    public var onLevel: ((Float) -> Void)?

    public init() {}

    /// Start metering the named microphone (nil: the system default). Throws a message for the page's hint.
    public func start(microphone: String?) throws {
        stop()
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        #endif
        Microphones.use(microphone, on: engine)
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw UserFacingError("No microphone was found.") }
        node.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let (rms, _) = LiveTranscriber.rms(buffer) else { return }
            let level = LiveTranscriber.meterLevel(rms: rms), cb = self?.onLevel
            DispatchQueue.main.async { cb?(level) }
        }
        engine.prepare()
        do { try engine.start() } catch {
            node.removeTap(onBus: 0)
            throw UserFacingError("The microphone couldn't be started (\(error.localizedDescription)).")
        }
    }

    public func stop() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        #if os(iOS)
        if !LiveTranscriber.audioSessionHeld { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        #endif
    }

    deinit { stop() }
}
