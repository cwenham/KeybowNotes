@testable import KeybowData
import KeybowKit
import XCTest

/// Answers every request with a canned response, keeping the requests.
final class StubDataTransport: DataTransport, @unchecked Sendable {
    var status = 200
    var contentType: String? = "application/json"
    var body = Data(#"{"current": {"temp_c": 14.2}}"#.utf8)
    var error: Error?
    private let lock = NSLock()
    private var sent: [URLRequest] = []

    var requests: [URLRequest] { lock.withLock { sent } }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { sent.append(request) }
        if let error { throw error }
        let headers = contentType.map { ["Content-Type": $0] } ?? [:]
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

func assertModuleError(_ work: () async throws -> Any, _ message: String, detail: String? = nil,
                       file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await work()
        XCTFail("expected “\(message)”", file: file, line: line)
    } catch let error as ModuleError {
        XCTAssertEqual(error.message, message, file: file, line: line)
        if let detail { XCTAssertEqual(error.detail, detail, file: file, line: line) }
    } catch {
        XCTFail("expected a ModuleError, got \(error)", file: file, line: line)
    }
}

final class DataFetcherTests: XCTestCase {
    private func source(_ url: String, key: DataSource.KeyUse = .none, keyName: String = "", cache: Int = 0) -> DataSource {
        var source = DataSource(name: "weather", url: url)
        source.keyUse = key
        source.keyName = keyName
        source.cacheSeconds = cache
        return source
    }

    func testPlaceholdersAreEncodedLikeAnyLink() throws {
        let request = try DataFetcher.request(
            for: source("https://api.example.com/v1/current?city={{city}}&units=metric"),
            params: ["city": "São Paulo & Rio"], key: nil)
        XCTAssertEqual(request.url?.absoluteString,
                       "https://api.example.com/v1/current?city=S%C3%A3o%20Paulo%20%26%20Rio&units=metric")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "KeybowNotes")
        XCTAssertEqual(request.timeoutInterval, 20)
    }

    func testAWholeURLPlaceholderIsLeftAsItIs() throws {
        let request = try DataFetcher.request(for: source("{{link}}"), params: ["link": "https://example.com/a?b=c"], key: nil)
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/a?b=c")
    }

    func testRequestsThatCantBeMade() async {
        await assertModuleError({ try DataFetcher.request(for: self.source("https://example.com/?q={{city}}"), params: [:], key: nil) },
                                "“weather” needs a value for {{city}}")
        await assertModuleError({ try DataFetcher.request(for: self.source("http://example.com/data"), params: [:], key: nil) },
                                "“weather” must use https")
        await assertModuleError({ try DataFetcher.request(for: self.source("ftp://example.com/data"), params: [:], key: nil) },
                                "“weather” must use https")
        await assertModuleError({ try DataFetcher.request(for: self.source("not a url"), params: [:], key: nil) },
                                "“weather” has a URL that can't be read")
        await assertModuleError({ try DataFetcher.request(for: self.source("https://example.com", key: .bearer), params: [:], key: nil) },
                                "“weather” needs its API key", detail: "Add it in Data Sources.")
        XCTAssertNoThrow(try DataFetcher.request(for: source("http://localhost:8080/data"), params: [:], key: nil),
                         "a server on this Mac may use plain http")
    }

    func testKeysGoWhereTheAPIExpectsThem() throws {
        let url = "https://api.example.com/data?units=metric"
        let bearer = try DataFetcher.request(for: source(url, key: .bearer), params: [:], key: "k-123")
        XCTAssertEqual(bearer.value(forHTTPHeaderField: "Authorization"), "Bearer k-123")
        XCTAssertEqual(bearer.url?.absoluteString, url)

        let header = try DataFetcher.request(for: source(url, key: .header), params: [:], key: "k-123")
        XCTAssertEqual(header.value(forHTTPHeaderField: "X-API-Key"), "k-123")
        let named = try DataFetcher.request(for: source(url, key: .header, keyName: "apikey"), params: [:], key: "k-123")
        XCTAssertEqual(named.value(forHTTPHeaderField: "apikey"), "k-123")
        XCTAssertNil(named.value(forHTTPHeaderField: "X-API-Key"))

        let query = try DataFetcher.request(for: source(url, key: .query, keyName: "appid"), params: [:], key: "k 123")
        XCTAssertEqual(query.url?.absoluteString, "https://api.example.com/data?units=metric&appid=k%20123")
        XCTAssertNil(query.value(forHTTPHeaderField: "Authorization"))
        let unnamed = try DataFetcher.request(for: source(url, key: .query), params: [:], key: "k")
        XCTAssertEqual(unnamed.url?.query, "units=metric&key=k")

        let none = try DataFetcher.request(for: source(url), params: [:], key: "k-123")
        XCTAssertNil(none.value(forHTTPHeaderField: "Authorization"), "a key isn't sent to a source that doesn't use one")
        XCTAssertEqual(none.url?.absoluteString, url)
    }

    func testResponsesAreKeptForAsLongAsTheSourceSays() async throws {
        let transport = StubDataTransport()
        let fetcher = DataFetcher(transport: transport)
        let kept = source("https://api.example.com/data?city={{city}}", cache: 300)
        let start = Date(timeIntervalSince1970: 1_000_000)

        let first = try await fetcher.fetch(kept, params: ["city": "London"], key: nil, now: start)
        XCTAssertEqual(first.text, #"{"current": {"temp_c": 14.2}}"#)
        XCTAssertEqual(first.contentType, "application/json")
        _ = try await fetcher.fetch(kept, params: ["city": "London"], key: nil, now: start.addingTimeInterval(299))
        XCTAssertEqual(transport.requests.count, 1, "fresh enough to reuse")
        _ = try await fetcher.fetch(kept, params: ["city": "Leeds"], key: nil, now: start.addingTimeInterval(10))
        XCTAssertEqual(transport.requests.count, 2, "each URL is kept apart")
        _ = try await fetcher.fetch(kept, params: ["city": "London"], key: nil, now: start.addingTimeInterval(300))
        XCTAssertEqual(transport.requests.count, 3, "too old")
        _ = try await fetcher.fetch(kept, params: ["city": "London"], key: nil, now: start.addingTimeInterval(301), useCache: false)
        XCTAssertEqual(transport.requests.count, 4, "a sample is always fresh")
        fetcher.forget()
        _ = try await fetcher.fetch(kept, params: ["city": "London"], key: nil, now: start.addingTimeInterval(302))
        XCTAssertEqual(transport.requests.count, 5, "forgotten")

        let unkept = source("https://api.example.com/data")
        _ = try await fetcher.fetch(unkept, params: [:], key: nil, now: start)
        _ = try await fetcher.fetch(unkept, params: [:], key: nil, now: start)
        XCTAssertEqual(transport.requests.count, 7, "no cache: fetched every time")
    }

    func testFailuresSayWhatToCheck() async {
        let transport = StubDataTransport()
        let fetcher = DataFetcher(transport: transport)
        let failing = source("https://api.example.com/data")
        func fetch() async throws -> Any { try await fetcher.fetch(failing, params: [:], key: nil) }

        transport.status = 401
        await assertModuleError(fetch, "“weather” answered HTTP 401", detail: "Check its API key in Data Sources.")
        transport.status = 404
        await assertModuleError(fetch, "“weather” answered HTTP 404", detail: "Check its URL.")
        transport.status = 429
        await assertModuleError(fetch, "“weather” answered HTTP 429", detail: "It's had too many requests; a longer cache may help.")
        transport.status = 500
        transport.body = Data("Internal trouble".utf8)
        await assertModuleError(fetch, "“weather” answered HTTP 500", detail: "Internal trouble")
        transport.status = 302
        await assertModuleError(fetch, "“weather” redirected to another server")

        transport.status = 200
        transport.body = Data(count: DataFetcher.maximumSize + 1)
        await assertModuleError(fetch, "“weather” sent more than 5 MB")

        transport.error = URLError(.notConnectedToInternet)
        await assertModuleError(fetch, "Couldn't reach “weather”")
        transport.error = URLError(.cancelled)
        do {
            _ = try await fetch()
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testRedirectsStayOnTheSameServer() async {
        let transport = SameHostTransport()
        let task = URLSession.shared.dataTask(with: URL(string: "https://api.example.com/data")!)
        let original = HTTPURLResponse(url: URL(string: "https://api.example.com/data")!, statusCode: 301,
                                       httpVersion: nil, headerFields: nil)!
        let sameHost = await transport.urlSession(.shared, task: task, willPerformHTTPRedirection: original,
                                                  newRequest: URLRequest(url: URL(string: "https://api.example.com/v2/data")!))
        XCTAssertNotNil(sameHost)
        let elsewhere = await transport.urlSession(.shared, task: task, willPerformHTTPRedirection: original,
                                                   newRequest: URLRequest(url: URL(string: "https://evil.example.net/steal")!))
        XCTAssertNil(elsewhere, "the key mustn't follow a redirect to another host")
        task.cancel()
    }

    func testNamesAndPlaceholders() {
        XCTAssertTrue(DataSource.isValidName("weather"))
        XCTAssertTrue(DataSource.isValidName("next-train_2"))
        XCTAssertFalse(DataSource.isValidName("2nd"))
        XCTAssertFalse(DataSource.isValidName("my weather"))
        XCTAssertFalse(DataSource.isValidName("weather.raw"))
        XCTAssertFalse(DataSource.isValidName(""))
        XCTAssertEqual(DataSource(name: "w", url: "https://x.example/{{a}}?b={{b|1}}&c={{date:yyyy}}").urlNames, ["a", "b"],
                       "the clock's names need no sample")
    }
}
