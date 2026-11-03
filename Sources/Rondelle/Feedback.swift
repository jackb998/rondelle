import AppKit
import SwiftUI

/// The other side of the FeedbackSend service, which has the network: this app hasn't.
@objc(FeedbackSendService) protocol FeedbackSendService {
    func send(kind: String, message: String, email: String, app: String, system: String, reply: @escaping (String) -> Void)
}

@MainActor
enum Feedback {
    private static let serviceName = "io.github.jackb998.rondelle.feedbacksend"
    static let maxMessage = 5_000
    static let maxMessageBytes = 20_000   // as in FeedbackSend: one letter with thousands of accents is one character

    static func fits(_ message: String) -> Bool { message.count <= maxMessage && message.utf8.count <= maxMessageBytes }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "0") (\(info?["CFBundleVersion"] as? String ?? "0"))"
    }

    static var systemVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// The answer is "ok", "invalid", "quota", "busy", "refused" or "failed", always once, on the main thread.
    static func send(kind: String, message: String, email: String, includeVersions: Bool, done: @escaping (String) -> Void) {
        let connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: FeedbackSendService.self)
        var over = false
        let finish = { (result: String) in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard !over else { return }
                    over = true
                    connection.invalidate()
                    done(result)
                }
            }
        }
        connection.resume()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in finish("failed") }) as? FeedbackSendService else { return finish("failed") }
        proxy.send(kind: kind, message: message, email: email, app: includeVersions ? appVersion : "", system: includeVersions ? systemVersion : "") { finish($0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 35) { finish("failed") }
    }

    static func isValidEmail(_ text: String) -> Bool {
        text.isEmpty || text.utf8.count <= 254 && !text.contains(where: \.isNewline) && text.range(of: #"^[^\s@<>"]{1,64}@[^\s@<>"]{1,185}\.[^\s@<>".]{2,}$"#, options: .regularExpression) != nil
    }

    static func problem(for result: String) -> String {
        switch result {
        case "invalid": return L("Controlla il messaggio e l'email: qualcosa non è valido.")
        case "quota": return L("Il modulo ha raggiunto il limite di messaggi di questo mese. Riprova il mese prossimo.")
        case "busy": return L("Troppi invii in poco tempo. Riprova tra un minuto.")
        case "refused": return L("Il servizio del modulo ha rifiutato il messaggio. Riprova più tardi.")
        default: return L("Messaggio non inviato. Controlla la connessione e riprova: il testo resta qui.")
        }
    }
}

/// The contact form: a small window of the app, so the answer shows here and what was written stays here if it fails.
@MainActor
enum FeedbackWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let new = NSWindow(contentViewController: NSHostingController(rootView: FeedbackView { window?.close() }))
            new.title = L("Scrivici")
            new.styleMask = [.titled, .closable]
            new.rondelleStyle()
            new.isReleasedWhenClosed = false
            new.center()
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: new, queue: .main) { _ in
                MainActor.assumeIsolated { window = nil }
            }
            window = new
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    #if DEBUG
    static func preview() -> some View { FeedbackView {} }
    #endif
}

private struct FeedbackView: View {
    let close: () -> Void
    @State private var kind = "problema"
    @State private var message = ""
    @State private var email = ""
    @State private var includeVersions = false
    @State private var sending = false
    @State private var sent = false
    @State private var problem: String?

    private var trimmed: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool {
        !sending && !trimmed.isEmpty && Feedback.fits(trimmed) && Feedback.isValidEmail(email.trimmingCharacters(in: .whitespaces))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RondelleHeader(symbol: "envelope.fill", title: L("Scrivici"))
                .padding(.bottom, 4)
            if sent {
                Label(L("Messaggio inviato. Grazie!"), systemImage: "checkmark.circle.fill").font(.headline)
                Text(L("Il servizio del modulo filtra lo spam da solo: se chiedevi una risposta e non arriva, riscrivi."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(L("Chiudi"), action: close).keyboardShortcut(.defaultAction).rondelleProminentButton()
                }
            } else {
                form
            }
        }
        .padding(18)
        .frame(width: 460)
    }

    private var form: some View {
        Group {
            Picker(L("Di cosa si tratta?"), selection: $kind) {
                Text(L("Problema")).tag("problema")
                Text(L("Idea")).tag("idea")
                Text(L("Altro")).tag("altro")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            ZStack(alignment: .topLeading) {
                TextEditor(text: $message)
                    .font(.body)
                    .frame(height: 150)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                if message.isEmpty {
                    Text(L("Cosa è successo, o cosa vorresti?"))
                        .foregroundStyle(.secondary).padding(.horizontal, 9).padding(.vertical, 5).allowsHitTesting(false)
                }
            }
            if !Feedback.fits(trimmed) {
                Text(L("Massimo %@ caratteri.", Feedback.maxMessage)).font(.caption).foregroundStyle(.red)
            }
            TextField(L("La tua email, se vuoi una risposta (facoltativa)"), text: $email)
                .textFieldStyle(.roundedBorder)
            Toggle(isOn: $includeVersions) {
                Text(L("Includi le versioni: Rondelle %@, macOS %@", Feedback.appVersion, Feedback.systemVersion))
            }
            Text(L("Parte solo ciò che vedi qui, nessun file. Il messaggio passa da Formdall, con server in Germania, e non resta sul Mac."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if sending { ProgressView().controlSize(.small) }
                Spacer()
                Button(L("Annulla"), action: close).keyboardShortcut(.cancelAction).rondelleButton()
                Button(L("Invia"), action: send).keyboardShortcut(.defaultAction).disabled(!canSend).rondelleProminentButton()
            }
        }
    }

    private func send() {
        guard canSend else { return }
        sending = true
        problem = nil
        Feedback.send(kind: kind, message: trimmed, email: email.trimmingCharacters(in: .whitespaces), includeVersions: includeVersions) { result in
            sending = false
            if result == "ok" { sent = true } else { problem = Feedback.problem(for: result) }
        }
    }
}
