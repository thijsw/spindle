import Foundation
import os

/// A scripted HTTP endpoint for one test. Each stub tags the requests of its
/// own URLSession with a private header, so stubs in tests running in
/// parallel never see each other's traffic (URLProtocol state is global).
final class HTTPStub: Sendable {
    struct Recorded: Sendable {
        let request: URLRequest
        let time: ContinuousClock.Instant
    }

    typealias Responder = @Sendable (URLRequest) -> (status: Int, body: Data, headers: [String: String])

    private let id = UUID().uuidString

    init(_ responder: @escaping Responder) {
        StubProtocol.register(id: id, responder: responder)
    }

    /// Status+body script (no response headers).
    convenience init(_ responder: @escaping @Sendable (URLRequest) -> (Int, Data)) {
        self.init { request in
            let (status, body) = responder(request)
            return (status, body, [:])
        }
    }

    /// An ephemeral session routed through this stub.
    func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        config.httpAdditionalHeaders = [StubProtocol.idHeader: id]
        return URLSession(configuration: config)
    }

    /// Every request seen so far, in arrival order.
    var recorded: [Recorded] { StubProtocol.recorded(id: id) }
}

final class StubProtocol: URLProtocol, @unchecked Sendable {
    static let idHeader = "X-Spindle-Stub"

    private struct Registry {
        var responders: [String: HTTPStub.Responder] = [:]
        var recorded: [String: [HTTPStub.Recorded]] = [:]
    }

    private static let registry = OSAllocatedUnfairLock(initialState: Registry())

    static func register(id: String, responder: @escaping HTTPStub.Responder) {
        registry.withLock { $0.responders[id] = responder }
    }

    static func recorded(id: String) -> [HTTPStub.Recorded] {
        registry.withLock { $0.recorded[id] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let id = request.value(forHTTPHeaderField: Self.idHeader) ?? ""
        let answer = Self.registry.withLock { registry -> (Int, Data, [String: String]) in
            registry.recorded[id, default: []].append(HTTPStub.Recorded(request: request, time: .now))
            return registry.responders[id]?(request) ?? (404, Data(), [:])
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.0, httpVersion: nil, headerFields: answer.2)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.1)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
