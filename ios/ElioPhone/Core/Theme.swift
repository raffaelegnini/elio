import SwiftUI

/// The PWA's palette.
enum Theme {
    static let bg = Color(hex: 0x0E0E10)
    static let bg2 = Color(hex: 0x18181B)
    static let bg3 = Color(hex: 0x222226)
    static let fill = Color.white.opacity(0.06)
    static let fill2 = Color.white.opacity(0.10)
    static let text = Color(hex: 0xF7F5F0)
    static let text2 = Color(red: 235 / 255, green: 233 / 255, blue: 228 / 255).opacity(0.62)
    static let text3 = Color(red: 235 / 255, green: 233 / 255, blue: 228 / 255).opacity(0.38)
    static let accent = Color(hex: 0xFFD360)
    static let accentInk = Color(hex: 0x1C1606)
    static let accentSoft = Color(hex: 0xFFD360).opacity(0.14)
    static let warn = Color(hex: 0xFF9F43)
    static let danger = Color(hex: 0xFF6B61)
    static let dangerSoft = Color(hex: 0xFF6B61).opacity(0.12)
    static let ok = Color(hex: 0x4ADE80)

    static func tint(_ orb: AppModel.Orb) -> Color {
        switch orb {
        case .listening: Color(hex: 0xFFD360)
        case .thinking: Color(hex: 0xFF9F43)
        case .speaking: Color(hex: 0xF5C13F)
        case .hearing: Color(hex: 0xFFE38A)
        case .offline: Color(hex: 0x4A4843)
        }
    }

    static func status(_ s: String) -> Color {
        switch s {
        case "done": ok
        case "failed": danger
        case "cancelled": text3
        case "waitingConfirmation", "paused": warn
        default: accent
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// "adesso", "5 min fa", "ieri 18:30"…: the PWA's relative times.
enum RelTime {
    static func string(_ date: Date?, now: Date = Date()) -> String {
        guard let d = date else { return "" }
        let s = now.timeIntervalSince(d)
        if s < 60 { return "adesso" }
        if s < 3600 { return "\(Int(s / 60)) min fa" }
        let cal = Calendar.current
        let hm = d.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "it_IT")))
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: now)).day ?? 0
        if days == 0 { return s < 3 * 3600 ? "\(Int(s / 3600)) h fa" : "oggi \(hm)" }
        if days == 1 { return "ieri \(hm)" }
        if days < 7 { return d.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "it_IT"))) + " " + hm }
        return d.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "it_IT")))
    }

    static func clock(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        return "\(Int(t) / 60):" + String(format: "%02d", Int(t) % 60)
    }
}
