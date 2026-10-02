import AVFoundation
import CoreAudio
import Foundation

/// Separate engines for mic and speaker, so each can follow its own device:
/// with AirPods, Elio listens on the Mac's mic while the AirPods keep high-quality output.
/// Voice processing (AEC) stays off: on macOS it delivers a 7-channel stream the recognizer
/// can't use. Echo is handled by VoiceLoop (half-duplex + high barge-in margin) instead.
public final class AudioIO: @unchecked Sendable {
    public let engine = AVAudioEngine()          // output
    private let inputEngine = AVAudioEngine()    // mic
    public let player = AVAudioPlayerNode()
    public let playbackFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 22050,
                                              channels: 1, interleaved: false)!
    /// Called on the audio thread with each mic buffer and its level in dBFS.
    public var onInput: ((AVAudioPCMBuffer, Float) -> Void)?
    /// Called after the audio route changed (AirPods connected/removed) and the input restarted.
    public var onRouteChange: ((AVAudioFormat?) -> Void)?
    public private(set) var inputFormat: AVAudioFormat?
    /// When output goes to Bluetooth (AirPods), capture from the Mac's built-in mic:
    /// using the AirPods mic switches them to the hands-free profile (16–24 kHz, robotic sound).
    public var preferBuiltInMicWithBluetooth = true
    /// Echo cancellation on the mic when Elio plays through the speakers: macOS removes what the
    /// speakers emit (measured: Elio's voice drops from +12 dB to below room noise), so anything the
    /// mic still hears while Elio talks is the user. Not used with headphones (no echo there).
    public var echoCancellation = false
    public private(set) var aecActive = false
    private var observers: [NSObjectProtocol] = []

    public init() {}

    public func start() throws {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        engine.prepare()
        try engine.start()
        player.play()
        try startInput()

        // Device changes (AirPods in/out) stop the engines: rebuild them on the new devices.
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: inputEngine, queue: .main
        ) { [weak self] _ in self?.routeChanged(output: false) })
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.routeChanged(output: true) })
    }

    // Restarting an input with echo cancellation itself posts configuration-change notifications:
    // reacting to those restarted the mic every 100 ms forever (Elio went deaf). Changes are
    // coalesced, our own restart's echo is ignored, and bursts are slowed down.
    private var lastRestart = Date.distantPast
    private var pendingRestart: DispatchWorkItem?
    private var outputChanged = false
    private var restartsInWindow: [Date] = []

    private func routeChanged(output: Bool) {
        if Date().timeIntervalSince(lastRestart) < 1.5 { return }  // caused by our own restart
        outputChanged = outputChanged || output
        pendingRestart?.cancel()
        restartsInWindow = restartsInWindow.filter { Date().timeIntervalSince($0) < 30 }
        let delay = restartsInWindow.count >= 3 ? 5.0 : 0.5
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restartsInWindow.append(Date())
            if self.outputChanged {
                self.outputChanged = false
                self.engine.stop()
                self.engine.connect(self.player, to: self.engine.mainMixerNode, format: self.playbackFormat)
                try? self.engine.start()
                self.player.play()
            }
            // The output device decides which mic to use.
            self.restartInput()
            self.lastRestart = Date()
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func restartInput() {
        lastRestart = Date()
        inputEngine.inputNode.removeTap(onBus: 0)
        inputEngine.stop()
        inputEngine.reset()
        do {
            try startInput()
            onRouteChange?(inputFormat)
        } catch {
            NSLog("Elio audio restart failed: \(error)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, !self.inputEngine.isRunning else { return }
                try? self.startInput()
                self.onRouteChange?(self.inputFormat)
            }
        }
    }

    private func startInput() throws {
        let input = inputEngine.inputNode
        let useAEC = echoCancellation && !AudioDevices.defaultOutputIsHeadphones()
        if input.isVoiceProcessingEnabled != useAEC { try input.setVoiceProcessingEnabled(useAEC) }
        aecActive = useAEC
        if useAEC {
            // Don't lower other apps' audio while Elio listens all day.
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        }
        if !useAEC, let unit = input.audioUnit {
            let wanted: AudioDeviceID? = preferBuiltInMicWithBluetooth && AudioDevices.defaultOutputIsBluetooth()
                ? AudioDevices.builtInMicrophone() : AudioDevices.defaultInput()
            if var id = wanted {
                let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                                  &id, UInt32(MemoryLayout<AudioDeviceID>.size))
                if status != noErr { NSLog("Elio: cannot select input device (\(status))") }
            }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                       channels: 1, interleaved: false) else { throw VoiceError.audioFormat }
        inputFormat = mono
        // format: nil = whatever the node really delivers. Passing a format read right after switching
        // device (AirPods out → built-in mic) can be stale (48 vs 44.1 kHz): AVAudioEngine then throws an
        // Objective-C exception and the app aborts.
        input.removeTap(onBus: 0)
        var monoCache = mono
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            if monoCache.sampleRate != buffer.format.sampleRate,
               let m = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
                                     channels: 1, interleaved: false) {
                monoCache = m
            }
            guard let m = Self.firstChannel(of: buffer, as: monoCache) else { return }
            self?.onInput?(m, Self.levelDb(m))
        }
        inputEngine.prepare()
        try inputEngine.start()
    }

    /// Mute: the mic is really released (no orange indicator), output keeps working.
    /// Re-applies echo cancellation / device choice (settings changed, AEC auto-disabled).
    public func reconfigureInput() {
        restartInput()
    }

    public func setInputEnabled(_ on: Bool) throws {
        if on {
            guard !inputEngine.isRunning else { return }
            try startInput()
        } else {
            inputEngine.inputNode.removeTap(onBus: 0)
            inputEngine.stop()
        }
    }

    public func stop() {
        inputEngine.inputNode.removeTap(onBus: 0)
        inputEngine.stop()
        player.stop()
        engine.stop()
    }

    public var outputDeviceName: String { AudioDevices.name(of: AudioDevices.defaultOutput() ?? 0) }

    public var inputDeviceName: String {
        guard let unit = inputEngine.inputNode.audioUnit else { return "?" }
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size) == noErr
        else { return "?" }
        return AudioDevices.name(of: id)
    }

    /// Mic arrays expose several channels; channel 0 is the usable voice signal.
    static func firstChannel(of buffer: AVAudioPCMBuffer, as mono: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let src = buffer.floatChannelData,
              let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength),
              let dst = out.floatChannelData else { return nil }
        dst[0].update(from: src[0], count: Int(buffer.frameLength))
        out.frameLength = buffer.frameLength
        return out
    }

    public static func levelDb(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return -100 }
        let samples = data[0]
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        return 20 * log10(max(rms, 1e-7))
    }
}

/// Converts PCM buffers between formats (mic → analyzer, synthesizer → player).
final class BufferConverter {
    private var converter: AVAudioConverter
    let output: AVAudioFormat

    init?(from input: AVAudioFormat, to output: AVAudioFormat) {
        guard let c = AVAudioConverter(from: input, to: output) else { return nil }
        converter = c
        self.output = output
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        // The mic may change rate under us (device switch): follow the buffers, not the initial guess.
        if buffer.format.sampleRate != converter.inputFormat.sampleRate
            || buffer.format.channelCount != converter.inputFormat.channelCount {
            guard let c = AVAudioConverter(from: buffer.format, to: output) else { return nil }
            converter = c
        }
        let ratio = output.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status == .error || out.frameLength == 0 ? nil : out
    }
}

public enum AudioDevices {
    private static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ value: inout T) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }

    static func name(of id: AudioDeviceID) -> String {
        var name: Unmanaged<CFString>?
        guard property(id, kAudioObjectPropertyName, &name), let name else { return "?" }
        return name.takeRetainedValue() as String
    }

    static func transport(of id: AudioDeviceID) -> UInt32 {
        var t: UInt32 = 0
        _ = property(id, kAudioDevicePropertyTransportType, &t)
        return t
    }

    static func defaultOutput() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        return property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &id) ? id : nil
    }

    static func defaultInput() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        return property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, &id) ? id : nil
    }

    public static func defaultOutputIsBluetooth() -> Bool {
        guard let id = defaultOutput() else { return false }
        let t = transport(of: id)
        return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
    }

    /// Headphones of any kind: no speaker echo reaches the mic, so plain speech can interrupt Elio.
    public static func defaultOutputIsHeadphones() -> Bool {
        if defaultOutputIsBluetooth() { return true }
        guard let id = defaultOutput() else { return false }
        var source: UInt32 = 0
        guard property(id, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput, &source) else { return false }
        return source == 0x6864_706E  // 'hdpn'
    }

    static func builtInMicrophone() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.first { id in
            guard transport(of: id) == kAudioDeviceTransportTypeBuiltIn else { return false }
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: kAudioDevicePropertyScopeInput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr && streamSize > 0
        }
    }
}
