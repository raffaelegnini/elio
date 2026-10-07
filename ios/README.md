# Elio per iPhone (app nativa)

App SwiftUI che sostituisce la PWA (`web/index.html`) sul telefono: stessa conversazione con il Mac
(WebSocket `/ws` e gli stessi endpoint HTTP su `https://<mac>.ts.net`), più quello che una web app non può
fare: trascrizione sul telefono, notifiche native, chiamate CallKit con squillo anche a schermo bloccato.

- iOS 18 o successivo, Xcode 26, Swift 6 (isolamento predefinito `MainActor`).
- Bundle id `it.dnafactory.elio.phone` (si cambia in *Signing & Capabilities*; l'app invia al Mac quello vero).

## Struttura

```
ios/
  ElioPhone.xcodeproj         progetto (cartelle sincronizzate: i file nuovi entrano da soli)
  Config/Info.plist           permessi, URL scheme elio://, background modes (audio, voip, remote-notification)
  Config/ElioPhone.entitlements  aps-environment + Time Sensitive Notifications
  ElioPhone/
    App/        ElioPhoneApp, AppDelegate, AppModel (logica della conversazione, come lo script della PWA)
    Core/       ElioClient (socket + HTTP), Pairing (+ Keychain), Models (JSON di Protocol.swift), Theme
    Voice/      VoiceIn (microfono, Speech on-device, fallback `stt`), CaptureTap (thread audio),
                VoiceOut (TTS frase per frase), MessagePlayer (Messaggi), AudioRoute (sessione audio)
    Calls/      CallManager (CallKit + PushKit)
    Push/       PushManager (permessi, token APNs, api/apns/register)
    Features/   InboxModel, TodoModel, WorkflowModel
    Views/      una vista per scheda + orb, chiamata, impostazioni, associazione
  ElioPhoneTests/  test (Swift Testing) della validazione dell'associazione
```

## Prima installazione

1. Apri `ios/ElioPhone.xcodeproj` in Xcode.
2. Target **ElioPhone** → *Signing & Capabilities* → **Team**: scegli il tuo team (Apple Developer Program).
   Lascia la firma automatica: Xcode crea App ID e profilo. Se il bundle id è già preso, cambialo
   (es. `it.tuonome.elio.phone`).
3. Le capability sono già negli entitlements; verifica che in *Signing & Capabilities* compaiano
   **Push Notifications**, **Background Modes** (Audio, Voice over IP, Remote notifications) e
   **Time Sensitive Notifications**. Se Xcode segnala che il profilo non le include, premi "+ Capability"
   e aggiungile: Xcode aggiorna l'App ID nel portale.
4. Collega l'iPhone, selezionalo come destinazione e premi Run. La prima volta: sull'iPhone
   *Impostazioni → Generali → VPN e gestione dispositivi* per fidarti dello sviluppatore, e attiva la
   *Modalità sviluppatore* se richiesta.

## Notifiche e chiamate: chiave APNs

Il Mac invia le notifiche e le chiamate direttamente ad Apple (APNs), quindi serve una chiave:

1. [developer.apple.com](https://developer.apple.com/account/resources/authkeys/list) → *Certificates,
   Identifiers & Profiles* → **Keys** → "+" → nome "Elio APNs", spunta **Apple Push Notifications service
   (APNs)** → Continue → Register → **Download** (file `AuthKey_XXXXXXXXXX.p8`, scaricabile una volta sola).
2. Annota il **Key ID** (10 caratteri) e il **Team ID** (in alto a destra nel portale, o in *Membership*).
3. Sul Mac: Elio → **Impostazioni → Telefono** → sezione APNs: incolla/scegli il file `.p8`, Key ID,
   Team ID e il bundle id dell'app.
4. Sull'iPhone apri Elio: consenti le notifiche; l'app registra da sola i token sul Mac
   (`api/apns/register`, a ogni avvio). In *Impostazioni → Notifiche* dell'app trovi lo stato e
   "Invia una prova".

L'ambiente APNs (sandbox o production) è letto dal profilo di provisioning incluso nell'app:
build da Xcode → `sandbox`, TestFlight/App Store → `production`. Lo vedi in fondo alle Impostazioni dell'app.
Una chiave `.p8` vale per entrambi.

## Associazione

Sul Mac: Impostazioni di Elio → **Telefono** → "Pubblica e copia link". Sul telefono: inquadra il codice QR
oppure incolla il link `https://<mac>.ts.net/#pair=…`. L'app chiede sempre conferma mostrando l'indirizzo,
accetta da link e QR solo indirizzi Tailscale (`*.ts.net`) e non sostituisce mai un'associazione esistente
(prima si dissocia dalle Impostazioni). Host e token stanno nel Portachiavi.

Link supportati: `elio://messages`, `elio://todo`, `elio://workflow`, `elio://call`,
`elio://pair?link=<link del Mac>`.

## TestFlight

1. In Xcode: destinazione *Any iOS Device* → **Product → Archive**.
2. Organizer → **Distribute App → App Store Connect → Upload** (la prima volta crea l'app in
   App Store Connect con lo stesso bundle id).
3. In App Store Connect → TestFlight aggiungi te stesso come tester interno e installa da TestFlight.
   Le build TestFlight usano APNs `production`: l'app lo comunica al Mac da sola.

## Verifica senza iPhone

```sh
xcodebuild -project ios/ElioPhone.xcodeproj -scheme ElioPhone -destination 'generic/platform=iOS Simulator' build
xcodebuild -project ios/ElioPhone.xcodeproj -scheme ElioPhone -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

Nelle build Debug l'argomento di avvio `-ElioDemo` riempie conversazione e messaggi di esempio (solo per
screenshot). Nel Simulatore CallKit e PushKit non squillano: "Chiama Elio" apre la chiamata dentro l'app.

## Note di comportamento

- **Voce in uscita**: sessione audio `.playAndRecord` con `.defaultToSpeaker`, quindi le risposte escono
  dall'altoparlante anche col microfono aperto (il bug della PWA su iOS). Prima frase in streaming
  (`tts/ticket` + `tts/stream`), le successive scaricate mentre la precedente suona.
- **Voce in entrata**: Speech framework in italiano, on-device quando il modello è presente; senza permesso
  di riconoscimento vocale l'audio va al Mac (`stt`). L'ascolto continuo manda `ambient`: il Mac risponde
  solo se dici "Elio" (o se aspetta una tua risposta).
- **Chiamate**: ogni VoIP push viene riportata subito a CallKit (obbligatorio). Se non rispondi entro 45 s
  la chiamata si chiude e l'app avvisa il Mac (`api/call/end`). Rispondi → `api/call/answer`, rifiuti →
  `api/call/decline`. In chiamata niente parola d'attivazione, cancellazione dell'eco, e puoi interrompere
  Elio parlando.
- Tempi e errori audio finiscono nel log del Mac (`~/Library/Logs/Elio/phone.log`, righe `[ios]`).
