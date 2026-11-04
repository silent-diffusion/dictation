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
    public static func use(_ name: String?, on engine: AVAudioEngine) {
        #if os(macOS)
        // The engine is reused, so the default is set again too when no microphone (or a missing one) is chosen.
        guard let unit = engine.inputNode.audioUnit, var id = device(named: name) ?? defaultInputDevice() else { return }
        // Only a real change: each one sends the engine a device-change notice on a queue of its own.
        var current = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        if AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &current, &size) == noErr,
           current == id { return }
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        #else
        let session = AVAudioSession.sharedInstance()
        let port = name.flatMap { n in session.availableInputs?.first { $0.portName.caseInsensitiveCompare(n) == .orderedSame } }
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty, port == nil { logMissing(name) }
        try? session.setPreferredInput(port)
        #endif
    }

    /// Windows' MicCapture: "Microphone '{name}' not found; using the default device.", once per name in a row.
    nonisolated(unsafe) private static var lastMissing: String?
    private static func logMissing(_ name: String) {
        guard lastMissing != name else { return }
        lastMissing = name
        CoreLog.warn("Microphone '\(name)' not found; using the default device.")
    }

    #if os(macOS)
    /// The named microphone, matched in any case as Windows does (`ProductName.Equals(…, OrdinalIgnoreCase)`); nil for
    /// none chosen, or one that isn't there any more (logged, and the default is used).
    private static func device(named name: String?) -> AudioDeviceID? {
        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if let id = inputDevices().first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.id {
            lastMissing = nil
            return id
        }
        logMissing(name)
        return nil
    }
    #endif

    /// Tap the microphone (bus 0 of the input node, in its own format). The input device may have changed its format a
    /// moment ago (a Bluetooth headset switching to its microphone mode, or another engine opening it at another rate)
    /// with the engine not caught up yet: a tap then raises an Objective-C exception, which ends the app. So this waits
    /// up to a second for the engine to catch up, and reports a failure as an error.
    public static func tap(_ node: AVAudioInputNode, bufferSize: AVAudioFrameCount,
                           block: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        func pending() -> Bool { node.inputFormat(forBus: 0).sampleRate != node.outputFormat(forBus: 0).sampleRate }
        for _ in 0..<20 where pending() { Thread.sleep(forTimeInterval: 0.05) }
        node.removeTap(onBus: 0)
        let busy = node.inputFormat(forBus: 0).sampleRate > 0
            ? UserFacingError("The microphone is still switching over. Try again in a moment.")
            : UserFacingError("The microphone isn't giving any sound. Check that Oberton may use it (Privacy & Security › Microphone), or pick another one in Settings › Microphone.")
        #if compiler(>=6.4)
        if #available(macOS 27, iOS 27, *) {
            do { try node.__installTap(onBus: 0, bufferSize: bufferSize, format: nil, error: (), block: block) } catch { throw busy }
            return
        }
        #endif
        guard !pending() else { throw busy }
        node.installTap(onBus: 0, bufferSize: bufferSize, format: nil, block: block)
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
/// never while a dictation records. On the main actor.
public final class MicrophoneMeter: @unchecked Sendable {
    /// One engine for every meter, kept for good. The page makes a new meter each time it opens or the microphone
    /// changes; an engine freed just after it was stopped or given another device crashes when Core Audio's
    /// device-change notice for it arrives a moment later (AVAudioIOUnit::IOUnitPropertyListener).
    nonisolated(unsafe) private static let engine = AVAudioEngine()
    /// The meter using the engine now: an older one going away late leaves it running.
    nonisolated(unsafe) private static var owner: ObjectIdentifier?
    private var engine: AVAudioEngine { Self.engine }
    /// Called on the main queue with the level, 0…1.
    public var onLevel: ((Float) -> Void)?

    public init() {}

    /// Start metering the named microphone (nil: the system default). Throws a message for the page's hint.
    public func start(microphone: String?) throws {
        Self.owner = ObjectIdentifier(self)
        halt()
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        #endif
        Microphones.use(microphone, on: engine)
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw UserFacingError(LiveTranscriber.noMicrophone) }
        try Microphones.tap(node, bufferSize: 2048) { [weak self] buffer, _ in
            guard let (rms, _) = LiveTranscriber.rms(buffer) else { return }
            // Windows' MicCapture scale, the one a dictation's own level uses too: min(1, √rms · 1.8).
            let level = min(1, rms.squareRoot() * 1.8), cb = self?.onLevel
            DispatchQueue.main.async { cb?(level) }
        }
        engine.prepare()
        do { try engine.start() } catch {
            node.removeTap(onBus: 0)
            CoreLog.warn("The microphone meter couldn't start: \(error.localizedDescription)")
            throw UserFacingError(LiveTranscriber.micWontOpen)
        }
    }


    public func stop() {
        guard Self.owner == ObjectIdentifier(self) else { return }
        Self.owner = nil
        halt()
    }

    private func halt() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        #if os(iOS)
        if !LiveTranscriber.audioSessionHeld { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        #endif
    }

    deinit { stop() }
}
