import AVFoundation
import CallKit
import Observation
import PushKit
import UIKit

/// Calls with Elio through CallKit: the phone rings like a real call (lock screen too) when the Mac sends a
/// VoIP push, and "Chiama Elio" starts an outgoing call, so iOS handles audio routing, the lock screen and the
/// Dynamic Island. Once audio is live the app runs "call mode" (see AppModel).
@Observable
final class CallManager: NSObject {
    struct Call: Equatable {
        let uuid: UUID
        /// The Mac's call id (incoming calls only).
        let callId: String?
        let title: String
        let text: String
        let reason: String?
        let incoming: Bool
        var answered = false
        var live = false
        /// Without CallKit (Simulator, or the system refused): audio handled by the app alone.
        var inAppOnly = false
    }

    private(set) var active: Call?
    private(set) var muted = false
    private(set) var speaker = true
    private(set) var voipToken: String?

    @ObservationIgnored var onVoipToken: ((String) -> Void)?
    /// Audio is ready: start call mode.
    @ObservationIgnored var onCallLive: ((Call) -> Void)?
    @ObservationIgnored var onCallEnded: (() -> Void)?
    @ObservationIgnored var onMuteChanged: ((Bool) -> Void)?
    /// POSTs api/call/<action> {"id"} to the Mac.
    @ObservationIgnored var notifyMac: ((String, String) -> Void)?
    /// Diagnostics to the Mac's phone.log (a VoIP push that doesn't ring leaves no other trace).
    @ObservationIgnored var onLog: ((String) -> Void)?

    @ObservationIgnored private let provider: CXProvider
    @ObservationIgnored private let controller = CXCallController()
    @ObservationIgnored private let registry = PKPushRegistry(queue: .main)
    @ObservationIgnored private var ringTimeout: Task<Void, Never>?

    /// The Mac can't stop the ringing: an unanswered call ends here after this long.
    private static let ringSeconds: Double = 45

    override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        config.includesCallsInRecents = false
        config.iconTemplateImageData = UIImage(systemName: "sun.max.fill",
                                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 40))?.pngData()
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
        // Must exist from launch: a VoIP push may be what launched the app.
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
    }

    // MARK: Outgoing

    func startOutgoing() {
        guard active == nil else { return }
        let call = Call(uuid: UUID(), callId: nil, title: "Elio", text: "", reason: nil, incoming: false)
        active = call
        let action = CXStartCallAction(call: call.uuid, handle: CXHandle(type: .generic, value: "Elio"))
        action.isVideo = false
        AudioRoute.configureCall()
        Task {
            do {
                try await controller.request(CXTransaction(action: action))
                let update = CXCallUpdate()
                update.localizedCallerName = "Elio"
                update.remoteHandle = CXHandle(type: .generic, value: "Elio")
                provider.reportCall(with: call.uuid, updated: update)
                // CallKit normally activates the audio session within a moment; if it never does
                // (Simulator, a stuck audio daemon), go live anyway rather than ringing forever.
                try? await Task.sleep(for: .seconds(3))
                if let now = active, now.uuid == call.uuid, !now.live {
                    AudioRoute.activate()
                    goLive()
                }
            } catch {
                // No CallKit here (Simulator): run the call inside the app.
                guard active?.uuid == call.uuid else { return }
                active?.inAppOnly = true
                AudioRoute.configureCall()
                AudioRoute.activate()
                goLive()
            }
        }
    }

    // MARK: Controls

    func end() {
        guard let call = active else { return }
        if call.inAppOnly { finish(call, reason: nil); return }
        let action = CXEndCallAction(call: call.uuid)
        Task {
            do { try await controller.request(CXTransaction(action: action)) }
            catch { finish(call, reason: nil) }
        }
    }

    func setMuted(_ on: Bool) {
        guard let call = active else { return }
        if call.inAppOnly { applyMute(on); return }
        let action = CXSetMutedCallAction(call: call.uuid, muted: on)
        Task {
            do { try await controller.request(CXTransaction(action: action)) }
            catch { applyMute(on) }
        }
    }

    func setSpeaker(_ on: Bool) {
        speaker = on
        AudioRoute.setSpeaker(on)
    }

    private func applyMute(_ on: Bool) {
        muted = on
        onMuteChanged?(on)
    }

    private func goLive() {
        guard var call = active else { return }
        call.live = true
        active = call
        AudioRoute.setSpeaker(speaker)
        onCallLive?(call)
    }

    /// Clears the call and tells the Mac how it ended.
    private func finish(_ call: Call, reason: CXCallEndedReason?) {
        guard active?.uuid == call.uuid else { return }
        ringTimeout?.cancel()
        if let id = call.callId {
            notifyMac?(call.incoming && !call.answered && reason != .unanswered ? "decline" : "end", id)
        }
        if let reason, !call.inAppOnly { provider.reportCall(with: call.uuid, endedAt: nil, reason: reason) }
        active = nil
        muted = false
        speaker = true
        onCallEnded?()
    }

    // MARK: Incoming

    /// Reports the call to CallKit right away: iOS kills an app that gets a VoIP push without doing so.
    private func reportIncoming(callId: String?, title: String, text: String, reason: String?) {
        let uuid = UUID()
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: "Elio")
        update.localizedCallerName = title
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        // Already in a call, not paired, or not a call payload: still report (it's mandatory), then end it.
        let acceptable = active == nil && callId != nil && Pairing.load() != nil
        onLog?("voip push: call=\(callId != nil) active=\(active != nil) paired=\(Pairing.load() != nil) → \(acceptable ? "ring" : "report+end")")
        if acceptable {
            active = Call(uuid: uuid, callId: callId, title: title, text: text, reason: reason, incoming: true)
        }
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if !acceptable {
                    self.provider.reportCall(with: uuid, endedAt: nil, reason: .failed)
                    return
                }
                if let error {
                    self.onLog?("callkit refused the incoming call: \((error as NSError).domain) \((error as NSError).code) \(error.localizedDescription)")
                    // Do Not Disturb or a blocked caller: nothing rings.
                    if self.active?.uuid == uuid { self.active = nil }
                    return
                }
                self.onLog?("ringing")
                self.armRingTimeout(uuid)
            }
        }
    }

    private func armRingTimeout(_ uuid: UUID) {
        ringTimeout?.cancel()
        ringTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.ringSeconds))
            guard !Task.isCancelled, let self, let call = self.active, call.uuid == uuid, !call.answered else { return }
            self.finish(call, reason: .unanswered)
        }
    }
}

// MARK: - PushKit

extension CallManager: PKPushRegistryDelegate {
    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        let hex = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        voipToken = hex
        onVoipToken?(hex)
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        voipToken = nil
    }

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
                      for type: PKPushType, completion: @escaping () -> Void) {
        let d = payload.dictionaryPayload
        let isCall = (d["type"] as? String) == "call"
        reportIncoming(callId: isCall ? d["id"] as? String : nil,
                       title: (d["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Elio",
                       text: d["text"] as? String ?? "",
                       reason: d["reason"] as? String)
        completion()
    }
}

// MARK: - CallKit

extension CallManager: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        if let call = active { finish(call, reason: nil) }
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        // Configure now; CallKit activates the session and calls didActivate.
        AudioRoute.configureCall()
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        action.fulfill()
        provider.reportOutgoingCall(with: action.callUUID, connectedAt: Date())
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard var call = active, call.uuid == action.callUUID else { action.fail(); return }
        ringTimeout?.cancel()
        call.answered = true
        active = call
        AudioRoute.configureCall()
        if let id = call.callId { notifyMac?("answer", id) }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        if let call = active, call.uuid == action.callUUID { finish(call, reason: nil) }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        applyMute(action.isMuted)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        guard let call = active, call.answered || !call.incoming else { return }
        goLive()
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {}
}
