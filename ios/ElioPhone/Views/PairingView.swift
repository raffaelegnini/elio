import SwiftUI
import UIKit
import Vision
import VisionKit

/// First launch: paste the link from the Mac (Impostazioni di Elio → Telefono) or scan its QR code.
struct PairingView: View {
    @Environment(AppModel.self) private var model
    @State private var link = ""
    @State private var error = ""
    @State private var scanning = false
    @State private var advanced = false
    @State private var host = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image("Logo")
                    .resizable().scaledToFit().frame(height: 52)
                    .padding(.top, 60)
                    .accessibilityHidden(true)
                Text("Elio").font(.largeTitle.bold()).foregroundStyle(Theme.text)
                Text("Questo telefono non è ancora associato.\nSul Mac apri Impostazioni di Elio, poi **Telefono**: inquadra il codice QR oppure copia il link e incollalo qui.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.text2)

                if DataScannerViewController.isSupported {
                    Button { scanning = true } label: {
                        Label("Inquadra il codice QR", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PillButtonStyle(kind: .go, small: false))
                    .padding(.top, 8)
                }

                TextField("Link di associazione", text: $link, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
                    .foregroundStyle(Theme.text)
                    .onSubmit(submit)

                if advanced {
                    TextField("Indirizzo del Mac (es. mac.local:8443)", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
                    Text("Solo se il Mac non è su Tailscale. Il token verrà inviato a questo indirizzo: usalo solo se è il tuo.")
                        .font(.footnote).foregroundStyle(Theme.warn)
                }

                HStack(spacing: 10) {
                    Button {
                        if let s = UIPasteboard.general.string { link = s; submit() }
                    } label: {
                        Label("Incolla", systemImage: "doc.on.clipboard").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PillButtonStyle(kind: .neutral, small: false))
                    Button(action: submit) {
                        Text("Associa").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PillButtonStyle(kind: .go, small: false))
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if !error.isEmpty {
                    Text(error).font(.footnote).foregroundStyle(Theme.danger).multilineTextAlignment(.center)
                }

                Button(advanced ? "Usa un indirizzo Tailscale" : "Altro server (avanzato)") {
                    advanced.toggle()
                    error = ""
                }
                .font(.footnote)
                .foregroundStyle(Theme.text3)
                .padding(.top, 12)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.bg)
        .sheet(isPresented: $scanning) {
            QRScannerView { payload in
                scanning = false
                if let p = Pairing.parse(payload) {
                    model.requestPairing(p)
                } else {
                    error = "Il codice non è un link di associazione di Elio (serve un indirizzo .ts.net)."
                }
            }
            .ignoresSafeArea()
        }
    }

    private func submit() {
        error = ""
        let p = advanced
            ? Pairing.parse(link, fallbackHost: host.isEmpty ? nil : Pairing.cleanHost(host), allowAnyHost: true)
            : Pairing.parse(link)
        if let p { model.requestPairing(p) }
        else { error = advanced ? "Link non valido." : "Link non valido: deve essere un indirizzo https://….ts.net con #pair=." }
    }
}

/// VisionKit's live scanner, looking for one QR code.
struct QRScannerView: UIViewControllerRepresentable {
    let onFound: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                           qualityLevel: .balanced,
                                           recognizesMultipleItems: false,
                                           isHighFrameRateTrackingEnabled: false,
                                           isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onFound: (String) -> Void
        private var done = false
        init(onFound: @escaping (String) -> Void) { self.onFound = onFound }

        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let code) = item, let payload = code.payloadStringValue, !done {
                    done = true
                    scanner.stopScanning()
                    onFound(payload)
                    return
                }
            }
        }
    }
}
