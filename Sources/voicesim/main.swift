import AVFoundation
setvbuf(stdout, nil, _IONBF, 0)
import JarvisCore
import JarvisVoice

// voicesim: runs WAV files through the app's real input pipeline (VAD → STT → wake word)
// with simulated room noise, without a microphone.
//   voicesim a.wav b.wav …   (16-bit or float WAV, any rate; resampled to 44.1k mono)

let rate = 44100.0
let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
let noiseDb: Float = Float(ProcessInfo.processInfo.environment["NOISE_DB"] ?? "-58") ?? -58

func load(_ path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buf)
    let conv = AVAudioConverter(from: file.processingFormat, to: mono)!
    let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(Double(file.length) * rate / file.processingFormat.sampleRate) + 4096)!
    var done = false
    _ = conv.convert(to: out, error: nil) { _, status in
        if done { status.pointee = .endOfStream; return nil }
        done = true; status.pointee = .haveData; return buf
    }
    return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
}

func noise(_ seconds: Double) -> [Float] {
    let amp = pow(10, noiseDb / 20) * 1.7
    return (0..<Int(seconds * rate)).map { _ in Float.random(in: -amp...amp) }
}

var signal = noise(2)
for path in CommandLine.arguments.dropFirst() {
    signal += try load(path).map { $0 + Float.random(in: -0.002...0.002) }
    signal += noise(2.5)
}

let pipeline = InputPipeline()
var transcriber: UtteranceTranscriber?
var pendingEnds: [Task<Void, Never>] = []

pipeline.onEvent = { event in
    switch event {
    case .speechStart:
        let t = UtteranceTranscriber(locale: Locale(identifier: "it_IT"))
        transcriber = t
        let sem = DispatchSemaphore(value: 0)
        Task.detached { try? await t.begin(inputFormat: mono); pipeline.attach(t); sem.signal() }
        sem.wait()
        print("▶ speechStart")
    case .speechEnd:
        guard let t = transcriber else { return }
        transcriber = nil
        pipeline.detach()
        pendingEnds.append(Task.detached {
            let start = Date()
            let text = await t.finish()
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let wake = WakeWord.strip(text)
            print("■ speechEnd → '\(text)' (finalize \(ms)ms) wake: \(wake.map { "YES → '\($0)'" } ?? "no")")
        })
    }
}

let chunk = 4410
var i = 0
while i < signal.count {
    let n = min(chunk, signal.count - i)
    let b = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(n))!
    signal.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress! + i, count: n) }
    b.frameLength = AVAudioFrameCount(n)
    pipeline.process(b, levelDb: AudioIO.levelDb(b))
    i += n
    try await Task.sleep(for: .milliseconds(20))  // ~5x real time
}
for t in pendingEnds { await t.value }
