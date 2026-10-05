import Foundation
import Network

/// A one-shot web server that catches Google's sign-in redirect. It listens on 127.0.0.1 only, on a
/// port the system picks, answers the first request carrying the expected `state` (with a code or an
/// error) with a small "You can close this tab" page, and stops. It gives up after `timeout`.
/// Anything else (a favicon, a stray request, a wrong state) gets a 404 and changes nothing.
final class LoopbackServer: @unchecked Sendable {
    enum Redirect: Equatable, Sendable {
        case code(String)
        /// Google's `error` value, e.g. "access_denied".
        case denied(String)
    }

    private let expectedState: String
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "docket.oauth-loopback")
    // Everything below is only touched on `queue`.
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var portWaiter: CheckedContinuation<UInt16, Error>?
    private var redirectWaiter: CheckedContinuation<Redirect, Error>?
    private var outcome: Result<Redirect, Error>?

    init(expectedState: String, timeout: TimeInterval = 300) {
        self.expectedState = expectedState
        self.timeout = timeout
    }

    deinit {
        listener?.cancel()
        for connection in connections.values { connection.cancel() }
    }

    /// Starts listening; returns the port once the system has picked it.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { self.listen(reportingTo: continuation) }
        }
    }

    /// Waits for the redirect. Throws `.signInTimedOut` after the timeout, `.signInCancelled` after `stop()`.
    func waitForRedirect() async throws -> Redirect {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let outcome = self.outcome {
                    continuation.resume(with: outcome)
                } else {
                    self.redirectWaiter = continuation
                }
            }
        }
    }

    /// Stops listening. Safe to call more than once, or after the redirect arrived.
    func stop() {
        queue.async { self.finish(.failure(IntegrationError.signInCancelled)) }
    }

    // MARK: Listening

    private func listen(reportingTo continuation: CheckedContinuation<UInt16, Error>) {
        guard outcome == nil else {
            continuation.resume(throwing: IntegrationError.signInCancelled)
            return
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            continuation.resume(throwing: IntegrationError.unexpected(.google, "the sign-in listener didn't start"))
            return
        }
        self.listener = listener
        portWaiter = continuation
        listener.stateUpdateHandler = { [weak self] state in self?.listenerChanged(state) }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(.failure(IntegrationError.signInTimedOut))
        }
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port?.rawValue else { return }
            portWaiter?.resume(returning: port)
            portWaiter = nil
        case .failed:
            finish(.failure(IntegrationError.unexpected(.google, "the sign-in listener stopped")))
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard outcome == nil else {
            connection.cancel()
            return
        }
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.connections[key] = nil
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let head = Self.requestHead(in: buffer) {
                self.respond(to: head, on: connection)
            } else if error != nil || isComplete || buffer.count > 32_768 {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(to head: String, on connection: NWConnection) {
        // Only the first matching request counts.
        let redirect = outcome == nil ? Self.parse(requestHead: head, expectedState: expectedState) : nil
        let reply: Data
        switch redirect {
        case .code?: reply = Self.response("200 OK", page: Self.signedInPage)
        case .denied?: reply = Self.response("200 OK", page: Self.deniedPage)
        case nil: reply = Self.response("404 Not Found", page: Self.notFoundPage)
        }
        connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
        if let redirect { finish(.success(redirect), keeping: connection) }
    }

    /// The first result wins: it stops the listener, closes idle connections and wakes the waiter.
    private func finish(_ result: Result<Redirect, Error>, keeping active: NWConnection? = nil) {
        guard outcome == nil else { return }
        outcome = result
        listener?.cancel()
        listener = nil
        for (key, connection) in connections where connection !== active {
            connection.cancel()
            connections[key] = nil
        }
        if let portWaiter {
            if case .failure(let error) = result { portWaiter.resume(throwing: error) } else { portWaiter.resume(throwing: IntegrationError.signInCancelled) }
            self.portWaiter = nil
        }
        redirectWaiter?.resume(with: result)
        redirectWaiter = nil
    }

    // MARK: HTTP (pure, tested)

    /// The request line and headers, once all of them have arrived.
    static func requestHead(in buffer: Data) -> String? {
        guard let end = buffer.range(of: Data([13, 10, 13, 10])) else { return nil }
        return String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
    }

    /// Reads "GET /?state=…&code=… HTTP/1.1". Nil unless it's a GET for "/" with exactly one `state`,
    /// equal to `expectedState`, and a code or an error.
    static func parse(requestHead head: String, expectedState: String) -> Redirect? {
        let line = head.components(separatedBy: "\r\n").first ?? ""
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "GET", parts[2].hasPrefix("HTTP/1."), parts[1].hasPrefix("/"),
              let components = URLComponents(string: "http://127.0.0.1" + parts[1]),
              components.path == "/" || components.path.isEmpty else { return nil }
        let items = components.queryItems ?? []
        /// A parameter that appears exactly once.
        func value(_ name: String) -> String? {
            let matches = items.filter { $0.name == name }
            return matches.count == 1 ? matches[0].value : nil
        }
        guard let state = value("state"), constantTimeEquals(state, expectedState) else { return nil }
        if let code = value("code"), !code.isEmpty { return .code(code) }
        if let error = value("error"), !error.isEmpty { return .denied(error) }
        return nil
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func response(_ status: String, page: String) -> Data {
        let body = Data(page.utf8)
        let head = [
            "HTTP/1.1 \(status)",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(body.count)",
            "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'",
            "Cache-Control: no-store",
            "Referrer-Policy: no-referrer",
            "X-Content-Type-Options: nosniff",
            "Connection: close",
        ].joined(separator: "\r\n")
        return Data((head + "\r\n\r\n").utf8) + body
    }

    private static func page(title: String, message: String) -> String {
        """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><title>Docket</title>
        <meta name="color-scheme" content="light dark">
        <style>
        body{margin:0;min-height:100vh;display:grid;place-items:center;background:#fbfbf9;color:#0e0e0c;
        font:15px/1.5 -apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif}
        main{text-align:center;padding:24px}
        h1{font-size:30px;font-weight:700;letter-spacing:-.6px;margin:0 0 8px}
        p{color:#5b5b56;margin:0}
        @media (prefers-color-scheme:dark){body{background:#0e0e0c;color:#e3e3e2}p{color:#9a9a99}}
        </style></head><body><main><h1>\(title)</h1><p>\(message)</p></main></body></html>
        """
    }

    static let signedInPage = page(title: "You're signed in", message: "You can close this tab and go back to Docket.")
    static let deniedPage = page(title: "Gmail wasn't connected", message: "You can close this tab. To try again, click Connect Gmail in Docket.")
    static let notFoundPage = page(title: "Nothing here", message: "This address only answers Docket's sign-in.")
}
