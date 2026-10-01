import AVFoundation
import Foundation

/// One AVAudioEngine for both mic and speaker. Voice processing (echo cancellation)
/// needs input and output on the same engine, otherwise Jarvis hears itself and
/// barge-in triggers on its own voice.
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
        try input.setVoiceProcessingEnabled(true)
        // Voice processing ducks all other Mac audio by default; Jarvis listens all day, so don't.
        input.voiceProcessingOtherAudioDuckingConfiguration =
            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)

        let format = input.outputFormat(forBus: 0)
        inputFormat = format
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.onInput?(buffer, Self.levelDb(buffer))
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

    static func levelDb(_ buffer: AVAudioPCMBuffer) -> Float {
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
