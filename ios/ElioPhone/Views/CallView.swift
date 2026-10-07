import SwiftUI

/// In-app call screen: big orb, mute, speaker, hang up.
struct CallView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let calls = model.calls
        VStack(spacing: 18) {
            Spacer(minLength: 20)
            Text(calls.active?.title ?? "Elio").font(.largeTitle.bold()).foregroundStyle(Theme.text)
            Text(subtitle).font(.subheadline).foregroundStyle(Theme.text2)
            OrbView(orb: model.orb, level: { model.voiceIn.level })
                .frame(maxWidth: .infinity)
                .frame(height: 320)
            Text(model.voiceIn.partial.isEmpty ? (model.feed.last(where: { $0.kind == .elio })?.text ?? "") : model.voiceIn.partial)
                .font(.callout).foregroundStyle(Theme.text2)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .padding(.horizontal, 28)
                .frame(minHeight: 80, alignment: .top)
            Spacer()
            HStack(spacing: 36) {
                CallButton(symbol: calls.muted ? "mic.slash.fill" : "mic.fill", label: calls.muted ? "Riattiva microfono" : "Muto", on: calls.muted) {
                    calls.setMuted(!calls.muted)
                }
                CallButton(symbol: "phone.down.fill", label: "Chiudi", on: false, tint: Theme.danger, size: 76) {
                    calls.end()
                }
                CallButton(symbol: calls.speaker ? "speaker.wave.3.fill" : "speaker.fill", label: calls.speaker ? "Vivavoce attivo" : "Vivavoce", on: calls.speaker) {
                    calls.setSpeaker(!calls.speaker)
                }
            }
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
    }

    private var subtitle: String {
        guard let call = model.calls.active else { return "Chiamata terminata" }
        if !call.live { return call.incoming ? "In arrivo…" : "Chiamo…" }
        if let reason = call.reason, !reason.isEmpty { return reason }
        return model.stateLabel.prefix(1).uppercased() + model.stateLabel.dropFirst()
    }
}

struct CallButton: View {
    let symbol: String
    let label: String
    let on: Bool
    var tint: Color? = nil
    var size: CGFloat = 64
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint != nil ? .white : (on ? Theme.accentInk : Theme.text))
                .frame(width: size, height: size)
                .background(Circle().fill(tint ?? (on ? Theme.accent : Theme.fill2)))
        }
        .accessibilityLabel(label)
    }
}
