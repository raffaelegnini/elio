import AVFoundation

/// One place for the audio session. Always .playAndRecord with .defaultToSpeaker: replies come out of the
/// loudspeaker even while the mic is open (the PWA on iOS sent them to the earpiece).
enum AudioRoute {
    private static var session: AVAudioSession { .sharedInstance() }

    /// Assistant mode: talk, listen, play messages. A2DP keeps AirPods in high quality for playback.
    static func configureAssistant() {
        try? session.setCategory(.playAndRecord, mode: .default,
                                 options: [.defaultToSpeaker, .allowBluetoothA2DP, .duckOthers])
    }

    /// Call mode: voice-chat processing (echo cancellation) so Elio's voice isn't heard back as the user.
    static func configureCall() {
        try? session.setCategory(.playAndRecord, mode: .voiceChat,
                                 options: [.defaultToSpeaker, .allowBluetoothHFP])
    }

    static func activate() {
        try? session.setActive(true)
    }

    static func deactivate() {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Speaker on/off during a call (off = receiver or the connected headset).
    static func setSpeaker(_ on: Bool) {
        try? session.overrideOutputAudioPort(on ? .speaker : .none)
    }
}
