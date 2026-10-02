import Foundation

/// Finds and fetches CircuitPython for a board: the newest release the
/// firmware supports, from Adafruit's downloads, kept in a cache so setting
/// up a second keypad — or one offline — needn't fetch it again.
public struct CircuitPythonDownloads: Sendable {
    public let cache: URL
    private let session: URLSession

    public static var defaultCache: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("KeybowNotes/CircuitPython", isDirectory: true)
    }

    public init(cache: URL = Self.defaultCache, session: URLSession = .shared) {
        self.cache = cache
        self.session = session
    }

    /// The newest release in `majors` published for `board`. Asks GitHub for
    /// the releases, then Adafruit's downloads for the newest few, since a
    /// release isn't always built for every board.
    public func newest(board: String, majors: ClosedRange<Int>) async throws -> CircuitPythonVersion {
        var request = URLRequest(url: CircuitPythonReleases.releasesURL, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ModuleError("GitHub didn't list CircuitPython's releases",
                              "It answered \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        let releases = try JSONDecoder().decode([CircuitPythonReleases.Release].self, from: data)
        let candidates = CircuitPythonReleases.candidates(releases, majors: majors)
        guard !candidates.isEmpty else {
            throw ModuleError("There's no CircuitPython \(majors.lowerBound)–\(majors.upperBound) release listed")
        }
        for version in candidates.prefix(4) {
            var head = URLRequest(url: CircuitPythonReleases.downloadURL(board: board, version: version), timeoutInterval: 20)
            head.httpMethod = "HEAD"
            if let (_, response) = try? await session.data(for: head), (response as? HTTPURLResponse)?.statusCode == 200 {
                return version
            }
        }
        throw ModuleError("CircuitPython isn't published for \(board)",
                          "None of \(candidates.prefix(4).map(\.description).joined(separator: ", ")) has a download for it.")
    }

    /// The newest copy in the cache, for when the downloads can't be reached.
    public func newestCached(board: String, majors: ClosedRange<Int>) -> (version: CircuitPythonVersion, file: URL)? {
        let files = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { file -> (CircuitPythonVersion, URL)? in
            guard let version = CircuitPythonReleases.version(ofFile: file.lastPathComponent, board: board),
                  majors.contains(version.major) else { return nil }
            return (version, file)
        }.max { $0.0 < $1.0 }
    }

    /// The UF2 file for `version`, from the cache or downloaded into it, and
    /// checked to be a whole RP2040 image either way.
    public func file(board: String, version: CircuitPythonVersion) async throws -> URL {
        let name = CircuitPythonReleases.fileName(board: board, version: version)
        let cached = cache.appendingPathComponent(name)
        if let data = try? Data(contentsOf: cached), UF2.problem(with: data, family: UF2.rp2040) == nil {
            return cached
        }
        let url = CircuitPythonReleases.downloadURL(board: board, version: version)
        let (download, response) = try await session.download(for: URLRequest(url: url, timeoutInterval: 60))
        defer { try? FileManager.default.removeItem(at: download) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ModuleError("CircuitPython \(version) couldn't be downloaded",
                              "\(url.host ?? "The server") answered \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        let data = try Data(contentsOf: download)
        if let problem = UF2.problem(with: data, family: UF2.rp2040) {
            throw ModuleError("The CircuitPython download can't be used: \(problem)")
        }
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try data.write(to: cached, options: .atomic)
        return cached
    }
}
