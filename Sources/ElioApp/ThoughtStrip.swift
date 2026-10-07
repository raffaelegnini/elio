import ElioCore
import ElioVoice
import SwiftUI

/// "What Elio is doing / thinking", live: the phase with a running timer, the action under way, the latest
/// reasoning (dim, fading upwards) and the steps already done with outcome and duration.
struct ThoughtStrip: View {
    let loop: VoiceLoop
    @Environment(\.animationsLive) private var animationsLive

    /// Visible while a reply is being worked on, and while it's spoken (the steps stay readable).
    static func visible(_ loop: VoiceLoop) -> Bool {
        loop.phase != nil || (loop.state == .speaking && !steps(loop).isEmpty)
    }

    static func steps(_ loop: VoiceLoop) -> [VoiceLoop.ActivityStep] {
        guard let start = loop.turnStarted else { return [] }
        return loop.activityTrail.filter { $0.started >= start.addingTimeInterval(-1) }
    }

    var body: some View {
        let busy = loop.phase != nil
        // A tenth-of-a-second clock only while working: nothing ticks when idle.
        TimelineView(.animation(minimumInterval: 1 / 12, paused: !busy || !animationsLive)) { ctx in
            content(now: ctx.date)
        }
    }

    private func content(now: Date) -> some View {
        let tint = Theme.tint(loop.state)
        let steps = Self.steps(loop)
        let done = steps.filter { !$0.running }.suffix(5)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                PhaseGlyph(phase: loop.phase, tint: tint, t: now.timeIntervalSinceReferenceDate)
                Text((VoiceLoop.phaseLabel(loop.phase) ?? "Fatto") + (loop.phase != nil ? "…" : ""))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                if loop.phase != nil {
                    Text(Self.seconds(now.timeIntervalSince(loop.phaseStarted)))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(tint)
                }
                Spacer()
                if let start = loop.turnStarted {
                    Text("totale " + Self.seconds(now.timeIntervalSince(start)))
                        .font(Theme.mono).foregroundStyle(Theme.dim)
                }
            }

            if let line = loop.currentActivity {
                HStack(spacing: 8) {
                    Image(systemName: Capability.of(tool: steps.last(where: \.running)?.tool ?? "").icon)
                        .font(.system(size: 11)).foregroundStyle(tint).frame(width: 16)
                    Text(line).font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer(minLength: 0)
                    ProgressView().controlSize(.mini)
                }
                .transition(.opacity)
            }

            if !loop.thinkingText.isEmpty, loop.phase != nil {
                Text(loop.thinkingText)
                    .font(.system(size: 11.5).italic()).foregroundStyle(Theme.dim)
                    .lineLimit(3, reservesSpace: false)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .bottomLeading)
                    .mask(LinearGradient(colors: [.black.opacity(0.15), .black], startPoint: .top, endPoint: .center))
            }

            if !done.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(done)) { step in
                        HStack(spacing: 7) {
                            Image(systemName: step.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.system(size: 10)).foregroundStyle(step.ok ? Color.green.opacity(0.8) : Color(hex: "#FF6B61"))
                            Text(step.text).font(.system(size: 11.5)).foregroundStyle(Theme.text.opacity(0.75)).lineLimit(1)
                            if let o = step.outcome {
                                Text("· " + o).font(.system(size: 11)).foregroundStyle(step.ok ? Theme.dim : Color(hex: "#FF6B61"))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if let ms = step.ms {
                                Text(Self.seconds(Double(ms) / 1000)).font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Theme.dim.opacity(0.8))
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(width: 600, alignment: .leading)
        .animation(.easeOut(duration: 0.2), value: loop.currentActivity)
        .animation(.easeOut(duration: 0.2), value: steps.count)
    }

    /// "3,2 s" (Italian decimal comma), "1 min 05 s" past a minute.
    static func seconds(_ s: Double) -> String {
        let s = max(0, s)
        if s >= 60 { return String(format: "%d min %02d s", Int(s) / 60, Int(s) % 60) }
        return String(format: "%.1f s", s).replacingOccurrences(of: ".", with: ",")
    }
}

/// Small animated mark of the phase: dots orbiting while thinking, a spinning arc while using tools,
/// a pulse while answering.
private struct PhaseGlyph: View {
    let phase: String?
    let tint: Color
    let t: Double

    var body: some View {
        ZStack {
            Circle().strokeBorder(tint.opacity(0.25), lineWidth: 1)
            switch phase {
            case "penso", "capisco":
                ForEach(0..<3, id: \.self) { k in
                    let a = t * 3.2 + Double(k) * 2 * .pi / 3
                    Circle().fill(tint.opacity(0.5 + 0.5 * Double(2 - k) / 2)).frame(width: 3, height: 3)
                        .offset(x: cos(a) * 5, y: sin(a) * 5)
                }
            case "strumenti":
                Circle().trim(from: 0, to: 0.3).stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.radians(t * 6)).padding(1)
            case "rispondo":
                Circle().fill(tint).frame(width: 5 + 2 * sin(t * 6), height: 5 + 2 * sin(t * 6))
            default:
                Image(systemName: "checkmark").font(.system(size: 7, weight: .bold)).foregroundStyle(tint)
            }
        }
        .frame(width: 16, height: 16)
    }
}
