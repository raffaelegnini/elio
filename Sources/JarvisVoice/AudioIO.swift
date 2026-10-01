import AVFoundation
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
    public private(set) var inputFormat: AVAudioFormat?

    public init() {}

    public func start() throws {
        let input = engine.inputNode

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)

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
