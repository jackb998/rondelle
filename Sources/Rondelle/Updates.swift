import AppKit

/// See Sources/UpdateCheck/main.swift: the same protocol, on the side of the app.
@objc(UpdateCheckService) protocol UpdateCheckService {
    func latestVersion(reply: @escaping (_ tag: String?, _ problem: String?) -> Void)
}

/// Looks for a newer release through the UpdateCheck service: the app itself keeps no network access.
/// Nothing is downloaded or installed here. With an ad-hoc signature there is no way to prove who built an
/// update, so a new version is only announced and the user downloads it from its GitHub page.
@MainActor
enum Updates {
    static let repository = "jackb998/rondelle"
    private static let serviceName = "io.github.jackb998.rondelle.updatecheck"
    private static let lastCheckKey = "lastUpdateCheck"
    private static let interval: TimeInterval = 24 * 60 * 60

    /// The newer version found, as tagged on GitHub.
    private(set) static var available: String?
    static var onChange: (() -> Void)?
    private static var checking = false
    private static var timer: Timer?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// 1.2.3 without the v, for showing.
    static var availableName: String? { available.map { $0.hasPrefix("v") ? String($0.dropFirst()) : $0 } }

    /// The numbers of a version, as ASCII digits without leading zeros (so that no size overflows): ["1", "2", "3"] for
    /// v1.2.3. A tag from GitHub must be v and two to four numbers, as in UpdateCheck; the app's own version has no v.
    nonisolated static func parts(_ version: String, tag: Bool = true) -> [String]? {
        var bytes = Array(version.utf8)
        guard bytes.count <= 64 else { return nil }
        if tag {
            guard bytes.first == UInt8(ascii: "v") else { return nil }
            bytes.removeFirst()
        }
        let numbers = bytes.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
        guard (tag ? 2...4 : 1...4).contains(numbers.count),
              numbers.allSatisfy({ !$0.isEmpty && $0.allSatisfy { (0x30...0x39).contains($0) } }) else { return nil }
        return numbers.map { number in
            let digits = number.drop { $0 == 0x30 }
            return digits.isEmpty ? "0" : String(decoding: digits, as: UTF8.self)
        }
    }

    nonisolated static func isNewer(_ tag: String, than current: String) -> Bool {
        guard let a = parts(tag), let b = parts(current, tag: false) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : "0", y = i < b.count ? b[i] : "0"
            // Same digits only, no leading zeros: the longer is larger, and at equal length the order of the text is.
            if x != y { return x.count != y.count ? x.count > y.count : x > y }
        }
        return false
    }

    /// One minute after launch, then every hour: asks GitHub at most once a day (Settings → Privacy can turn it off).
    static func startAutomaticChecks() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { checkIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { checkIfDue() }
        }
    }

    private static func checkIfDue() {
        guard Settings.checkUpdates else { return }
        if let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date,
           abs(last.timeIntervalSinceNow) < interval { return }
        check { _, _ in }
    }

    /// `done` gets the latest tag, or the service's problem: "none", "failed".
    static func check(done: @escaping (String?, String?) -> Void) {
        guard !checking else { return done(nil, "failed") }
        checking = true
        let connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: UpdateCheckService.self)
        var over = false
        let finish = { (tag: String?, problem: String?) in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard !over else { return }
                    over = true
                    checking = false
                    connection.invalidate()
                    if let tag, parts(tag) != nil {
                        UserDefaults.standard.set(Date(), forKey: lastCheckKey)
                        let newer = isNewer(tag, than: currentVersion)
                        available = newer ? tag : nil
                        onChange?()
                        done(tag, nil)
                    } else {
                        if problem == "none" { UserDefaults.standard.set(Date(), forKey: lastCheckKey) }
                        done(nil, problem ?? "failed")
                    }
                }
            }
        }
        connection.resume()
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in finish(nil, "failed") } as? UpdateCheckService
        guard let proxy else { return finish(nil, "failed") }
        proxy.latestVersion { tag, problem in finish(tag, problem) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { finish(nil, "failed") }
    }

    /// Menu → Cerca aggiornamenti…
    static func checkAndTell() {
        check { tag, problem in
            let alert = NSAlert()
            if tag != nil, available != nil {
                return offerDownload()
            } else if tag != nil {
                alert.messageText = L("Hai già l'ultima versione (%@)", currentVersion)
            } else if problem == "none" {
                alert.messageText = L("Nessuna versione pubblicata su GitHub per ora")
            } else if problem == "busy" {
                alert.messageText = L("GitHub sta limitando le richieste")
                alert.informativeText = L("Riprova fra un'ora.")
            } else {
                alert.messageText = L("Impossibile cercare aggiornamenti")
                alert.informativeText = L("Controlla la connessione e riprova più tardi.")
            }
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    /// Menu → Scarica la versione…: the page is made from the checked tag, not from anything the answer points to.
    static func offerDownload() {
        guard let tag = available, let name = availableName, parts(tag) != nil else { return }
        let alert = NSAlert()
        alert.messageText = L("È disponibile Rondelle %@", name)
        alert.informativeText = L("Stai usando la versione %@. Si apre la pagina di GitHub da cui scaricarla.", currentVersion)
        alert.addButton(withTitle: L("Apri la pagina"))
        alert.addButton(withTitle: L("Più tardi"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "https://github.com/\(repository)/releases/tag/\(tag)") {
            NSWorkspace.shared.open(url)
        }
    }

    #if UPDATE_TEST
    /// Tests/updates/run.sh, inside the sandbox of a real bundle. Prints what happened and exits.
    static func selfTest() {
        // The app must not reach the network by itself: only the service can.
        let url = URL(string: "https://\(repositoryHost)/zen")!
        URLSession(configuration: .ephemeral).dataTask(with: url) { _, response, error in
            print("RETE-APP \(error == nil && response != nil ? "raggiunta" : "bloccata")")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    check { tag, problem in
                        print("SERVIZIO \(tag ?? "nessuno") \(problem ?? "-")")
                        print("DISPONIBILE \(available ?? "nessuno")")
                        exit(0)
                    }
                }
            }
        }.resume()
    }
    private static let repositoryHost = "api.github.com"
    #endif
}
