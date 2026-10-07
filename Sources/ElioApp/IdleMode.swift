import AppKit
import CoreGraphics
import ElioCore
import ElioVoice
import IOKit.pwr_mgt
import Observation

/// Rest mode ("modalità riposo"): the user is away but Elio keeps working. The Mac doesn't go to sleep
/// (background agents, monitors, the phone keep going), the screen goes off or very dim, the app's
/// animations stop, Elio doesn't talk aloud (events go to the phone and are kept for a one-line summary on
/// return) and only urgent things outside the quiet hours wake it up. Any keyboard/mouse input, an unlock,
/// "Elio…" or the switch brings it back.
@MainActor
@Observable
final class IdleMode {
    private(set) var active = false
    private(set) var since: Date?
    private(set) var config = ElioConfig.load()

    @ObservationIgnored private weak var loop: VoiceLoop?
    @ObservationIgnored private weak var app: AppDelegate?
    @ObservationIgnored private var assertion: IOPMAssertionID = 0
    @ObservationIgnored private var savedBrightness: Float?
    @ObservationIgnored private var dimmed = false
    /// The mic was turned off for rest mode (idleListen off): turned back on when leaving.
    @ObservationIgnored private var mutedByRest = false
    @ObservationIgnored private var held: [IdleSummary.Event] = []
    @ObservationIgnored private var poll: Timer?
    @ObservationIgnored private var pendingEnter: Task<Void, Never>?
    @ObservationIgnored private var rescreen: Task<Void, Never>?
    /// The "Elio a riposo" page phase: the screen goes off when it ends.
    @ObservationIgnored private var restPage: Task<Void, Never>?
    /// When Elio last woke the screen itself: that's not the user coming back.
    @ObservationIgnored private var selfWake = Date.distantPast
    /// Left rest mode without touching the Mac (from the phone, by voice): the idle timer starts over from here.
    @ObservationIgnored private var lastExit = Date.distantPast
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    func attach(_ loop: VoiceLoop, app: AppDelegate) {
        self.loop = loop
        self.app = app
        loop.onRestEvent = { [weak self] msg in self?.restEvent(msg) ?? false }
        loop.onRestCommand = { [weak self] text in self?.restCommand(text) ?? false }
        loop.onIdleRequest = { [weak self] on in
            // From a voice command or the phone: leave a moment for Elio's spoken reply before the screen goes off.
            // Woken from afar, nobody may be at the Mac to hear the summary: it's only shown.
            if on { self?.enter(after: 4) } else { self?.exit(speakSummary: false) }
        }
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.active, Date().timeIntervalSince(self.selfWake) > 20 else { return }
                self.checkActivity()
            }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.active == true { self?.exit(speakSummary: true) } }
        })
        schedulePoll()
    }

    /// Settings saved (from the window or by voice).
    func apply(_ config: ElioConfig) {
        self.config = config
        schedulePoll()
    }

    func toggle() {
        if active { exit(speakSummary: true) } else { enter() }
    }

    /// "Riposo automatico" from the menus: saved to the config like the Settings window would.
    func setAuto(_ on: Bool) {
        var cfg = ElioConfig.load()
        cfg.idleAuto = on
        cfg.save()
        apply(cfg)
    }

    // MARK: Entering / leaving

    func enter(after delay: TimeInterval = 0) {
        guard !active else { return }
        pendingEnter?.cancel()
        guard delay > 0 else { start(); return }
        pendingEnter = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.start()
        }
    }

    private func start() {
        pendingEnter = nil
        guard !active, let loop else { return }
        active = true
        since = Date()
        held = []
        loop.resting = true
        // Background work goes on: no idle sleep while at rest (the display may sleep). With the lid closed on
        // battery macOS sleeps anyway (clamshell needs power and an external display).
        if assertion == 0 {
            IOPMAssertionCreateWithName("PreventUserIdleSystemSleep" as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Elio: modalità riposo (lavoro in background)" as CFString, &assertion)
        }
        if !config.idleListen, !loop.muted {
            mutedByRest = true
            loop.setMuted(true, persist: false)
        }
        app?.setResting(true)
        let minutes = min(max(config.restScreenMinutes, 0), 30)
        if minutes > 0 {
            // First the rest page (sleeping orb, time, what's running), then the screen goes off/dim.
            RestScreen.shared.show(loop: loop, held: { [weak self] in self?.held.count ?? 0 })
            restPage = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Double(minutes) * 60))
                guard !Task.isCancelled, let self, self.active else { return }
                RestScreen.shared.hide()
                self.selfWake = Date()
                self.applyScreen()
            }
        } else {
            applyScreen()
        }
        schedulePoll()
    }

    /// `speakSummary`: say what happened while away (only if something did; otherwise it's just shown).
    /// Returns whether something was said.
    @discardableResult
    func exit(speakSummary: Bool) -> Bool {
        pendingEnter?.cancel()
        pendingEnter = nil
        guard active, let loop else { return false }
        active = false
        since = nil
        lastExit = Date()
        rescreen?.cancel()
        restPage?.cancel(); restPage = nil
        RestScreen.shared.hide()
        restoreScreen()
        // Back by voice, from the phone or a switch: the display slept on its own and nothing woke it (a key or
        // the mouse would have). Light it up; if the Mac locks on display sleep, the lock screen shows.
        var wake: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("Elio: fine del riposo" as CFString, kIOPMUserActiveLocal, &wake)
        if assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
        if mutedByRest { loop.setMuted(false, persist: false) }
        mutedByRest = false
        loop.resting = false
        app?.setResting(false)
        let line = IdleSummary.line(held, addressAs: config.addressAs)
        if let line { loop.announce(line, speak: speakSummary) }
        held = []
        schedulePoll()
        return line != nil && speakSummary
    }

    /// Quitting: never leave the screen dimmed or the assertion behind.
    func shutdown() {
        guard active else { return }
        restPage?.cancel()
        RestScreen.shared.hide()
        restoreScreen()
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
        if mutedByRest { loop?.setMuted(false, persist: false) }
    }

    // MARK: Events and commands while at rest

    private func restEvent(_ msg: ServerMessage) -> Bool {
        // The briefing starts on the first unlock: the user is back, even if this event beat the unlock notice here.
        if msg.kind == "briefStart" || msg.kind == "recapStart", Self.inputIdle < 15 {
            exit(speakSummary: false)
            return true
        }
        switch IdlePolicy.decide(msg, config: config) {
        case .ignore:
            return false
        case .wake:
            // Said aloud now: not repeated in the summary.
            wakeScreen()
            return true
        case .hold:
            if let kind = msg.kind {
                let text = msg.text ?? ""
                // A confirmation can be announced more than once (reminders): count it once.
                if !(kind == "confirm" && held.contains { $0.kind == kind && $0.text == text }) {
                    held.append(IdleSummary.Event(kind: kind, text: text))
                }
            }
            return false
        }
    }

    private static let backPhrases = #"^(eccomi|sono tornat[oa]|sono qui|ci sono|rieccomi|bentornat[oa]|svegliati|esci dal riposo)\b"#

    private func restCommand(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let justBack = !t.isEmpty && t.range(of: Self.backPhrases, options: .regularExpression) != nil
        // "Elio, sono tornato" is just the return: the summary is the answer. Anything else goes on and the
        // summary stays on screen, so it doesn't talk over the reply — or, for "Elio" alone and the hotkey,
        // over the request the user is about to make.
        let spoke = exit(speakSummary: justBack)
        if justBack, !spoke { loop?.announce("Bentornato, \(config.addressAs).") }
        return justBack
    }

    // MARK: Activity

    private func schedulePoll() {
        poll?.invalidate()
        // Cheap (one call into the window server): every 2 s at rest to come back quickly, 10 s otherwise.
        let every: TimeInterval = active ? 2 : 10
        guard active || config.idleAuto else { poll = nil; return }
        let timer = Timer(timeInterval: every, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkActivity() }
        }
        timer.tolerance = every / 2
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    private static var inputIdle: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private func checkActivity() {
        let idle = Self.inputIdle
        if active {
            guard let since else { return }
            // Input after entering (the click or key that turned it on has a moment of grace), not Elio's own wake.
            let reference = max(since.addingTimeInterval(5), selfWake.addingTimeInterval(3))
            if idle < Date().timeIntervalSince(reference) { exit(speakSummary: true) }
            return
        }
        guard config.idleAuto, pendingEnter == nil, let loop else { return }
        let limit = TimeInterval(min(max(config.idleMinutes, 5), 120) * 60)
        let quietFor = min(idle, Date().timeIntervalSince(loop.lastInteraction), Date().timeIntervalSince(lastExit))
        guard quietFor >= limit, loop.state == .listening || loop.state == .muted || loop.state == .idle,
              loop.confirmations.isEmpty, !loop.routineMode, !Self.appKeepsDisplayOn() else { return }
        start()
    }

    /// A regular app (video player, a call in the browser, a presentation) holds the display on: the user is
    /// watching, not away. Command-line `caffeinate` doesn't count: people leave it running for other reasons.
    private static func appKeepsDisplayOn() -> Bool {
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dict) == kIOReturnSuccess,
              let byPid = dict?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        for (pid, list) in byPid where pid.int32Value != me {
            guard list.contains(where: { ($0["AssertType"] as? String) == "PreventUserIdleDisplaySleep" }),
                  let app = NSRunningApplication(processIdentifier: pid.int32Value), app.activationPolicy == .regular else { continue }
            return true
        }
        return false
    }

    // MARK: Screen

    private func applyScreen() {
        if config.idleScreen == "dim", Brightness.available, let current = Brightness.get() {
            savedBrightness = savedBrightness ?? current
            Brightness.set(0.02)
            dimmed = true
        } else {
            // "off", or no way to dim this display (external monitor, API missing): the display sleeps.
            Self.sleepDisplays()
        }
    }

    private func restoreScreen() {
        if dimmed, let level = savedBrightness { Brightness.set(level) }
        dimmed = false
        savedBrightness = nil
    }

    /// Urgent event: light the screen up so the message can be read, then back to rest after a while.
    private func wakeScreen() {
        selfWake = Date()
        if dimmed, let level = savedBrightness {
            Brightness.set(level)
            dimmed = false
        } else {
            var id: IOPMAssertionID = 0
            IOPMAssertionDeclareUserActivity("Elio: avviso urgente" as CFString, kIOPMUserActiveLocal, &id)
        }
        rescreen?.cancel()
        rescreen = Task { [weak self] in
            try? await Task.sleep(for: .seconds(90))
            guard !Task.isCancelled, let self, self.active else { return }
            self.selfWake = Date()
            self.applyScreen()
        }
    }

    /// `pmset displaysleepnow` needs no admin rights; it only sleeps the displays (the Mac stays awake).
    private static func sleepDisplays() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        try? p.run()
    }
}

/// Brightness of the built-in display. There's no public API for it: DisplayServices (private, used by the
/// brightness keys' own tools) is loaded at run time, and everything falls back to "display off" without it.
enum Brightness {
    private typealias Getter = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias Setter = @convention(c) (UInt32, Float) -> Int32

    private static let symbols: (Getter, Setter)? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let g = dlsym(h, "DisplayServicesGetBrightness"), let s = dlsym(h, "DisplayServicesSetBrightness") else { return nil }
        return (unsafeBitCast(g, to: Getter.self), unsafeBitCast(s, to: Setter.self))
    }()

    private static var display: CGDirectDisplayID {
        // The built-in panel if there is one (lid open), else the main display (which DisplayServices may refuse).
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var n: UInt32 = 0
        CGGetOnlineDisplayList(8, &ids, &n)
        return ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
    }

    static var available: Bool { symbols != nil && get() != nil }

    static func get() -> Float? {
        guard let (get, _) = symbols else { return nil }
        var value: Float = -1
        return get(display, &value) == 0 && value >= 0 ? value : nil
    }

    static func set(_ value: Float) {
        guard let (_, set) = symbols else { return }
        _ = set(display, max(0, min(1, value)))
    }
}
