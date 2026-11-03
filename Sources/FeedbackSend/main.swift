import Foundation

// Sends one message written in Settings to Rondelle's contact form, when the person presses «Invia». A separate process
// (an XPC service in Contents/XPCServices): it has the network and no access to files, while the app that can read files
// has no network. It speaks to one fixed address, and takes only these short text fields, each checked here again.

@objc(FeedbackSendService) protocol FeedbackSendService {
    /// `reply`: "ok", "invalid", "quota", "busy", "refused" or "failed".
    func send(kind: String, message: String, email: String, app: String, system: String, reply: @escaping (String) -> Void)
}

enum Form {
    static let host = "api.formdall.de"
    static let path = "/api/v1/f/oilh96W60cv9iwq3g5wuMoFxNc7o8rUzoQQ7HCgG"
    static let kinds = ["problema", "idea", "altro"]
    static let maxMessage = 5_000
    /// Also in bytes: one letter with thousands of accents is still one character.
    static let maxMessageBytes = 20_000
    static let maxEmailBytes = 254
    static let maxResponseBytes = 100_000

    /// The JSON to send, or nil if a field isn't what the form in the app can produce.
    static func body(kind: String, message: String, email: String, app: String, system: String) -> Data? {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard kinds.contains(kind), !text.isEmpty, text.count <= maxMessage, text.utf8.count <= maxMessageBytes else { return nil }
        guard email.isEmpty || email.utf8.count <= maxEmailBytes && !email.contains(where: \.isNewline) && email.range(of: #"^[^\s@<>"]{1,64}@[^\s@<>"]{1,185}\.[^\s@<>".]{2,}$"#, options: .regularExpression) != nil else { return nil }
        // Numbers and points only: it can't be a way to carry anything else.
        for version in [app, system] where !version.isEmpty {
            guard version.range(of: #"^[0-9][0-9. ()]{0,30}$"#, options: .regularExpression) != nil else { return nil }
        }
        var fields = ["tipo": kind, "messaggio": text]
        if !email.isEmpty { fields["email"] = email }
        if !app.isEmpty { fields["versione_app"] = app }
        if !system.isEmpty { fields["versione_macos"] = system }
        return try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    }

    /// What the form's answer means. A success also covers what it files as spam: it says the same to everyone.
    static func outcome(status: Int, body: Data) -> String {
        let answer = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        switch status {
        case 200: return answer?["success"] as? Bool == true ? "ok" : "failed"
        case 429: return answer?["error"] as? String == "quota_exceeded" ? "quota" : "busy"
        case 400, 403, 422: return "refused"
        default: return "failed"
        }
    }
}

final class Delivery: NSObject, URLSessionDataDelegate {
    private let reply: (String) -> Void
    private var answer = Data()
    private var status = 0
    private var finished = false

    init(reply: @escaping (String) -> Void) { self.reply = reply }

    func start(body: Data) {
        let config = URLSessionConfiguration.ephemeral   // no cookies, no cache, nothing kept on disk
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 25
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: URL(string: "https://\(Form.host)\(Form.path)")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Rondelle", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request).resume()
        session.finishTasksAndInvalidate()
    }

    private func finish(_ result: String) {
        guard !finished else { return }
        finished = true
        reply(result)
    }

    // Never elsewhere: what was written goes only to this address.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        answer.append(data)
        if answer.count > Form.maxResponseBytes {
            dataTask.cancel()
            finish("failed")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error == nil ? Form.outcome(status: status, body: answer) : "failed")
    }
}

final class Service: NSObject, FeedbackSendService, NSXPCListenerDelegate {
    func send(kind: String, message: String, email: String, app: String, system: String, reply: @escaping (String) -> Void) {
        guard let body = Form.body(kind: kind, message: message, email: email, app: app, system: system) else { return reply("invalid") }
        Delivery(reply: reply).start(body: body)
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: FeedbackSendService.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }
}

#if DEBUG
// Tests/feedback/run.sh: what the service would send and how it reads an answer, without sending anything.
let arguments = CommandLine.arguments
if arguments.count == 7, arguments[1] == "--body" {
    let body = Form.body(kind: arguments[2], message: arguments[3], email: arguments[4], app: arguments[5], system: arguments[6])
    print(body.flatMap { String(data: $0, encoding: .utf8) } ?? "rifiutato")
    exit(0)
}
if arguments.count == 4, arguments[1] == "--outcome" {
    print(Form.outcome(status: Int(arguments[2]) ?? 0, body: Data(arguments[3].utf8)))
    exit(0)
}
#endif

let service = Service()
let listener = NSXPCListener.service()
listener.delegate = service
listener.resume()
