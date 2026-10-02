import Accelerate
import AVFoundation
import CSpeaker
import ElioCore
import Foundation

/// "Is this the owner talking?" — on-device speaker verification.
/// 16 kHz audio → Kaldi-style 80-bin log-mel filterbank → WeSpeaker ResNet34 (ONNX) → 256-d embedding,
/// compared by cosine similarity with the voiceprint recorded at enrollment. Nothing leaves the Mac.
public final class SpeakerID: @unchecked Sendable {
    public static let sampleRate = 16_000.0
    public static var modelURL: URL { ElioPaths.support.appendingPathComponent("models/speaker.onnx") }
    public static var voiceprintURL: URL { ElioPaths.support.appendingPathComponent("voiceprint.json") }

    private let handle: UnsafeMutableRawPointer
    private let lock = NSLock()
    private let fbank = Fbank()
    public private(set) var voiceprint: [Float]?

    public init?() {
        var error = [CChar](repeating: 0, count: 512)
        guard let h = spk_create(Self.modelURL.path, &error, Int32(error.count)) else {
            VoiceLog.write("speaker model unavailable: \(String(cString: error))")
            return nil
        }
        handle = h
        voiceprint = (try? Data(contentsOf: Self.voiceprintURL)).flatMap { try? JSONDecoder().decode([Float].self, from: $0) }
    }

    deinit { spk_free(handle) }

    public var isEnrolled: Bool { voiceprint != nil }

    /// L2-normalised embedding of 16 kHz mono samples (nil if too short: < 0.5 s).
    public func embedding(_ samples: [Float]) -> [Float]? {
        guard samples.count >= Int(Self.sampleRate / 2) else { return nil }
        let (feats, frames) = fbank.compute(samples)
        guard frames > 0 else { return nil }
        var out = [Float](repeating: 0, count: 512)
        let n = lock.withLock { feats.withUnsafeBufferPointer { spk_embed(handle, $0.baseAddress, Int32(frames), 80, &out, 512) } }
        guard n > 0 else { return nil }
        return Self.normalized(Array(out.prefix(Int(n))))
    }

    /// Cosine similarity with the enrolled voice (−1…1), nil if not enrolled or audio too short.
    public func score(_ samples: [Float]) -> Float? {
        guard let print = voiceprint, let e = embedding(samples), e.count == print.count else { return nil }
        return vDSP.dot(e, print)
    }

    /// Best score over 1.5 s windows: an utterance that is mostly Elio's echo with the owner's
    /// answer at the end ("…posso procedere? — Non lo scrivere") still counts as the owner.
    public func bestWindowScore(_ samples: [Float]) -> Float? {
        let win = Int(Self.sampleRate * 1.5), hop = Int(Self.sampleRate * 0.5)
        guard samples.count > win else { return score(samples) }
        var best: Float?
        var start = max(0, samples.count - win)
        var windows = 0
        // From the end backwards: the user's words usually come last; cap the work.
        while start >= 0, windows < 16 {
            if let s = score(Array(samples[start..<(start + win)])) { best = max(best ?? -1, s) }
            if start == 0 { break }
            start = max(0, start - hop)
            windows += 1
        }
        if let whole = score(samples) { best = max(best ?? -1, whole) }
        return best
    }

    /// Enrollment: average of several clips of the owner speaking.
    @discardableResult
    public func enroll(_ clips: [[Float]]) -> Bool {
        let embeddings = clips.compactMap(embedding)
        guard embeddings.count >= 2 else { return false }
        var mean = [Float](repeating: 0, count: embeddings[0].count)
        for e in embeddings { mean = vDSP.add(mean, e) }
        let print = Self.normalized(mean)
        guard let data = try? JSONEncoder().encode(print) else { return false }
        try? data.write(to: Self.voiceprintURL, options: .atomic)
        voiceprint = print
        return true
    }

    public func forget() {
        try? FileManager.default.removeItem(at: Self.voiceprintURL)
        voiceprint = nil
    }

    static func normalized(_ v: [Float]) -> [Float] {
        let norm = sqrt(vDSP.sumOfSquares(v))
        return norm > 0 ? vDSP.divide(v, norm) : v
    }
}

/// Kaldi-compatible fbank as used by WeSpeaker: 25 ms Hamming frames every 10 ms, DC removal,
/// pre-emphasis 0.97, 512-point power spectrum, 80 triangular mel bins (20 Hz – 8 kHz), log,
/// then per-utterance mean normalisation. Input is scaled to the int16 range like Kaldi's.
final class Fbank {
    let frameLength = 400, frameShift = 160, fftSize = 512, bins = 80
    private let window: [Float]
    private let melBank: [[(Int, Float)]]
    private let fftSetup: FFTSetup

    init() {
        window = (0..<400).map { 0.54 - 0.46 * cos(2 * .pi * Float($0) / Float(400 - 1)) }
        fftSetup = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2))!
        // Mel filterbank over the 257 FFT bins.
        let mel = { (f: Float) in 1127 * log(1 + f / 700) }
        let low = mel(20), high = mel(8000)
        let step = (high - low) / Float(80 + 1)
        let binHz = Float(16000) / Float(512)
        melBank = (0..<80).map { m in
            let left = low + Float(m) * step, center = left + step, right = center + step
            return (0..<257).compactMap { k in
                let f = mel(Float(k) * binHz)
                guard f > left, f < right else { return nil }
                let w = f <= center ? (f - left) / (center - left) : (right - f) / (right - center)
                return (k, w)
            }
        }
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    /// Returns row-major [frames × 80] features and the frame count.
    func compute(_ samples: [Float]) -> ([Float], Int) {
        let frames = samples.count < frameLength ? 0 : 1 + (samples.count - frameLength) / frameShift
        guard frames > 0 else { return ([], 0) }
        var out = [Float](repeating: 0, count: frames * bins)
        var frame = [Float](repeating: 0, count: fftSize)
        var real = [Float](repeating: 0, count: fftSize / 2), imag = [Float](repeating: 0, count: fftSize / 2)
        var power = [Float](repeating: 0, count: fftSize / 2 + 1)
        for t in 0..<frames {
            let start = t * frameShift
            var x = samples[start..<(start + frameLength)].map { $0 * 32768 }
            let mean = vDSP.mean(x)
            x = vDSP.add(-mean, x)
            for i in stride(from: frameLength - 1, to: 0, by: -1) { x[i] -= 0.97 * x[i - 1] }
            x[0] -= 0.97 * x[0]
            x = vDSP.multiply(x, window)
            for i in 0..<fftSize { frame[i] = i < frameLength ? x[i] : 0 }
            frame.withUnsafeBufferPointer { fp in
                real.withUnsafeMutableBufferPointer { rp in
                    imag.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2))
                        }
                        vDSP_fft_zrip(fftSetup, &split, 1, 9, FFTDirection(FFT_FORWARD))
                        // zrip packs DC in real[0] and Nyquist in imag[0]; values are scaled by 2.
                        power[0] = (rp[0] / 2) * (rp[0] / 2)
                        power[fftSize / 2] = (ip[0] / 2) * (ip[0] / 2)
                        for k in 1..<(fftSize / 2) {
                            let re = rp[k] / 2, im = ip[k] / 2
                            power[k] = re * re + im * im
                        }
                    }
                }
            }
            for m in 0..<bins {
                var e: Float = 0
                for (k, w) in melBank[m] { e += power[k] * w }
                out[t * bins + m] = log(max(e, 1.1920929e-7))
            }
        }
        // Cepstral mean normalisation per utterance.
        for m in 0..<bins {
            var sum: Float = 0
            for t in 0..<frames { sum += out[t * bins + m] }
            let mean = sum / Float(frames)
            for t in 0..<frames { out[t * bins + m] -= mean }
        }
        return (out, frames)
    }
}

/// Collects the mic signal at 16 kHz for speaker verification (last ~30 s).
public final class VoiceTap: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: BufferConverter?
    private var inputFormat: AVAudioFormat?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: SpeakerID.sampleRate, channels: 1, interleaved: false)!
    /// Total samples ever appended (positions are stable across trimming).
    private var total = 0

    public init() {}

    public func feed(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            if inputFormat != buffer.format {
                inputFormat = buffer.format
                converter = BufferConverter(from: buffer.format, to: target)
            }
            guard let out = converter?.convert(buffer), let data = out.floatChannelData else { return }
            samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
            total += Int(out.frameLength)
            // Trim in 5 s chunks: removing from the front of a 30 s array on every buffer
            // (~40 times a second) moved megabytes of memory continuously.
            let keep = Int(SpeakerID.sampleRate * 30)
            if samples.count > keep + Int(SpeakerID.sampleRate * 5) { samples.removeFirst(samples.count - keep) }
        }
    }

    /// Current position, to mark the start of an utterance.
    public var position: Int { lock.withLock { total } }

    /// Samples from `start` (a past `position`, minus a little lead-in) to now.
    public func samples(since start: Int, lead: Double = 0.3) -> [Float] {
        lock.withLock {
            let from = max(start - Int(lead * SpeakerID.sampleRate), total - samples.count)
            return Array(samples[(from - (total - samples.count))...])
        }
    }
}
