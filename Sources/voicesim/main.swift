import Accelerate
import AVFoundation
setvbuf(stdout, nil, _IONBF, 0)
import ElioCore
import ElioVoice

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

// SPEAKER=1: cosine similarity matrix of the given files (speaker verification check).
if ProcessInfo.processInfo.environment["SPEAKER"] == "1" {
    guard let sid = SpeakerID() else { print("model missing"); exit(1) }
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    func load16k(_ path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buf)
        let conv = AVAudioConverter(from: file.processingFormat, to: target)!
        let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(file.length) * 16000 / file.processingFormat.sampleRate) + 1024)!
        var done = false
        _ = conv.convert(to: out, error: nil) { _, st in if done { st.pointee = .endOfStream; return nil }; done = true; st.pointee = .haveData; return buf }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }
    let files = Array(CommandLine.arguments.dropFirst())
    let start = Date()
    let embs = try files.map { try sid.embedding(load16k($0))! }
    print(String(format: "%d embeddings in %.0f ms", embs.count, Date().timeIntervalSince(start) * 1000))
    let names = files.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
    print("        " + names.map { $0.padding(toLength: 8, withPad: " ", startingAt: 0) }.joined())
    for (i, a) in embs.enumerated() {
        print(names[i].padding(toLength: 8, withPad: " ", startingAt: 0) + embs.map { String(format: "%6.2f  ", vDSP.dot(a, $0)) }.joined())
    }
    exit(0)
}

// CONTINUOUS=1: one long-lived transcriber fed with everything (the app's new mode).
if ProcessInfo.processInfo.environment["CONTINUOUS"] == "1" {
    let start = Date()
    WakeWord.configure(name: "Elio", aliases: ["helio"])
    let ct = ContinuousTranscriber(locale: Locale(identifier: "it_IT"), contextWords: ["Elio"])
    try await ct.start(inputFormat: mono)
    let vad = InputPipeline()
    var ends: [Task<Void, Never>] = []
    vad.onEvent = { event in
        if case .speechStart = event { ct.resetSegment() }
        if case .speechEnd = event {
            let t0 = Date()
            ends.append(Task.detached {
                let text = await ct.finalizeSegment()
                let wake = WakeWord.strip(text)
                print(String(format: "%5.1fs end→text %.2fs '%@' wake: %@", Date().timeIntervalSince(start),
                             Date().timeIntervalSince(t0), text, wake.map { "YES → '\($0)'" } ?? "no"))
            })
        }
    }
    var j = 0
    while j < signal.count {
        let n = min(4410, signal.count - j)
        let b = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(n))!
        signal.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress! + j, count: n) }
        b.frameLength = AVAudioFrameCount(n)
        ct.feed(b)
        vad.process(b, levelDb: AudioIO.levelDb(b))
        j += n
        try await Task.sleep(for: .milliseconds(100))
    }
    for e in ends { await e.value }
    await ct.stop()
    exit(0)
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
