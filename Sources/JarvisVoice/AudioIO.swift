import AVFoundation
import CoreAudio
import Foundation

/// One AVAudioEngine for mic and speaker. Voice processing (AEC) is deliberately off:
/// on macOS it delivers a 7-channel stream the recognizer can't use and it also
/// cancels other system audio. Echo is handled by VoiceLoop (half-duplex + high
/// barge-in margin) instead.
public final class AudioIO: @unchecked Sendable {
    public let engine = AVAudioEngine()
    public let player = AVAudioPlayerNode()
    public let playbackFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 22050,
                                              channels: 1, interleaved: false)!
    /// Called on the audio thread with each mic buffer and its level in dBFS.
    public var onInput: ((AVAudioPCMBuffer, Float) -> Void)?
    /// Called after the audio route changed (AirPods connected/removed) and the engine restarted.
    public var onRouteChange: ((AVAudioFormat?) -> Void)?
    public private(set) var inputFormat: AVAudioFormat?
    private var configObserver: NSObjectProtocol?

    public init() {}

    public func start() throws {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        try startInput()

        // AirPods connecting makes them the default mic: the engine stops itself and
        // must be rebuilt with the new device format, or Jarvis goes deaf.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.restart()
        }
    }

    private func restart() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        do {
            try startInput()
            onRouteChange?(inputFormat)
        } catch {
            NSLog("Jarvis audio restart failed: \(error)")
            // The new device may not be ready yet: retry once shortly after.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, !self.engine.isRunning else { return }
                try? self.startInput()
                self.onRouteChange?(self.inputFormat)
            }
        }
    }

    private func startInput() throws {
        let input = engine.inputNode

        let format = input.outputFormat(forBus: 0)
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                       channels: 1, interleaved: false) else { throw VoiceError.audioFormat }
        inputFormat = mono
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let m = Self.firstChannel(of: buffer, as: mono) else { return }
            self?.onInput?(m, Self.levelDb(m))
        }
        engine.prepare()
        try engine.start()
        player.play()
    }

    public var inputDeviceName: String {
        AVCaptureDeviceNameProvider.defaultInputName()
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
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
    private let converter: AVAudioConverter
    let output: AVAudioFormat

    init?(from input: AVAudioFormat, to output: AVAudioFormat) {
        guard let c = AVAudioConverter(from: input, to: output) else { return nil }
        converter = c
        self.output = output
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
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

enum AVCaptureDeviceNameProvider {
    static func defaultInputName() -> String {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr
        else { return "?" }
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioObjectPropertyName
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name) == noErr, let name
        else { return "?" }
        return name.takeRetainedValue() as String
    }
}
