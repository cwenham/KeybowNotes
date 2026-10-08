import Foundation

/// Sends a request and hands back what came back: URLSession in the app, a
/// stand-in in tests. What modules that talk to a web API — Claude, data
/// sources, Home Assistant — send through.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

/// URLSession, refusing to follow a redirect to another server: an API key or
/// token travels with every request, and mustn't reach a host it wasn't for.
public final class SameHostTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init() {
        session = URLSession(configuration: .ephemeral, delegate: RedirectGuard(), delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    public func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    /// Whether a redirect is followed: only to the server first asked.
    public static func follows(_ redirect: URLRequest, from original: URLRequest?) -> Bool {
        redirect.url?.host == original?.url?.host
    }

    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            SameHostTransport.follows(request, from: task.originalRequest) ? request : nil
        }
    }
}
