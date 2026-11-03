import Foundation

// The only part of the app that can reach the network. It runs as a separate process (an XPC service in
// Contents/XPCServices), has no access to the user's files and asks one fixed address for one thing: the
// number of the latest release. The app can't pass it anything, so it can't be used to send data out.

@objc(UpdateCheckService) protocol UpdateCheckService {
    /// `tag` is the latest version (v1.2.3), or nil with `problem` set: "none" (nothing published) or "failed".
    func latestVersion(reply: @escaping (_ tag: String?, _ problem: String?) -> Void)
}

enum Release {
    static let repository = "jackb998/rondelle"   // the test build asks the same one: the check is the real one
    static let host = "api.github.com"
    static let maxResponseBytes = 1_000_000

    /// The tag of a GitHub "latest release" answer, if it is only a version number.
    static func tag(fromJSON data: Data) -> String? {
        guard data.count <= maxResponseBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String, isTag(tag)
        else { return nil }
        return tag
    }

    /// The tag, or why there is none: "none" (nothing published), "busy" (GitHub limits the requests: 403, 429) or "failed".
    static func outcome(status: Int, body: Data) -> (String?, String?) {
        switch status {
        case 200: return tag(fromJSON: body).map { ($0, nil) } ?? (nil, "failed")
        case 404: return (nil, "none")
        case 403, 429: return (nil, "busy")
        default: return (nil, "failed")
        }
    }

    /// v, then two to four numbers of ASCII digits with points between: nothing else, not even a newline at the end.
    static func isTag(_ tag: String) -> Bool {
        let bytes = Array(tag.utf8)
        guard bytes.count <= 64, bytes.first == UInt8(ascii: "v") else { return false }
        let numbers = bytes.dropFirst().split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
        return (2...4).contains(numbers.count) && numbers.allSatisfy { !$0.isEmpty && $0.allSatisfy { (0x30...0x39).contains($0) } }
    }
}

final class Lookup: NSObject, URLSessionDataDelegate {
    private let reply: (String?, String?) -> Void
    private var body = Data()
    private var status = 0
    private var finished = false

    init(reply: @escaping (String?, String?) -> Void) { self.reply = reply }

    func start() {
        let config = URLSessionConfiguration.ephemeral   // no cookies, no cache, nothing kept on disk
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.httpAdditionalHeaders = ["Accept": "application/vnd.github+json", "User-Agent": "UpdateCheck"]
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        let url = URL(string: "https://\(Release.host)/repos/\(Release.repository)/releases/latest")!
        session.dataTask(with: url).resume()
        session.finishTasksAndInvalidate()
    }

    private func finish(_ tag: String?, _ problem: String?) {
        guard !finished else { return }
        finished = true
        reply(tag, problem)
    }

    // GitHub redirects a renamed repository, but always to itself.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let same = request.url?.scheme == "https" && request.url?.host == Release.host
        completionHandler(same ? request : nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        body.append(data)
        if body.count > Release.maxResponseBytes {
            dataTask.cancel()
            finish(nil, "failed")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard error == nil else { return finish(nil, "failed") }
        let (tag, problem) = Release.outcome(status: status, body: body)
        finish(tag, problem)
    }
}

final class Service: NSObject, UpdateCheckService, NSXPCListenerDelegate {
    func latestVersion(reply: @escaping (String?, String?) -> Void) {
        Lookup(reply: reply).start()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: UpdateCheckService.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }
}

#if DEBUG
// Tests/updates/run.sh: what the service would accept from an answer of GitHub.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--parse" {
    let data = FileManager.default.contents(atPath: CommandLine.arguments[2]) ?? Data()
    print(Release.tag(fromJSON: data) ?? "rifiutato")
    exit(0)
}
if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--status" {
    let (tag, problem) = Release.outcome(status: Int(CommandLine.arguments[2]) ?? 0, body: Data(CommandLine.arguments[3].utf8))
    print(tag ?? problem ?? "-")
    exit(0)
}
#endif

let service = Service()
let listener = NSXPCListener.service()
listener.delegate = service
listener.resume()
