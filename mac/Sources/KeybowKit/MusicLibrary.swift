import Foundation
import iTunesLibrary

/// The Music app's library — its songs, playlists, favourites and what's been
/// played — read without opening Music: for the tree editor's lists, and for
/// Claude to design music keys from. Needs Media & Apple Music access, which
/// macOS asks for the first time.
public final class MusicLibrary: @unchecked Sendable {
    public struct Song: Equatable, Sendable {
        public var title: String
        public var artist: String
        public var album: String
        public var genre: String
        public var plays: Int
        public var favourite: Bool

        public init(title: String, artist: String, album: String = "", genre: String = "", plays: Int = 0,
                    favourite: Bool = false) {
            self.title = title
            self.artist = artist
            self.album = album
            self.genre = genre
            self.plays = plays
            self.favourite = favourite
        }
    }

    public struct Playlist: Equatable, Sendable {
        public var name: String
        public var songs: Int
        /// Made from rules, rather than chosen song by song.
        public var isSmart: Bool

        public init(name: String, songs: Int, isSmart: Bool = false) {
            self.name = name
            self.songs = songs
            self.isSmart = isSmart
        }
    }

    /// What's in it, as it was read.
    public struct Contents: Equatable, Sendable {
        public var songs: [Song]
        public var playlists: [Playlist]

        public init(songs: [Song], playlists: [Playlist] = []) {
            self.songs = songs
            self.playlists = playlists
        }
    }

    public static let shared = MusicLibrary()

    private let lock = NSLock()
    private var kept: (contents: Contents, at: Date)?
    private let reader: @Sendable () throws -> Contents

    /// `reader` reads the library: Music's own, unless a test says otherwise.
    public init(reader: @escaping @Sendable () throws -> Contents = MusicLibrary.readMusic) {
        self.reader = reader
    }

    /// The library, read again when what's kept is older than `maxAge`.
    /// Reading a large one takes a second or two, off the main thread.
    public func contents(maxAge: TimeInterval = 120) async throws -> Contents {
        if let kept = lock.withLock({ kept }), Date().timeIntervalSince(kept.at) < maxAge { return kept.contents }
        let reader = reader
        let contents = try await Task.detached { try reader() }.value
        lock.withLock { kept = (contents, Date()) }
        return contents
    }

    /// The usage description macOS shows when it asks: only the packaged app
    /// has one, and without it there's no asking.
    public static var canAsk: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSAppleMusicUsageDescription") != nil
    }

    /// Music's library, through iTunesLibrary: songs only — no podcasts,
    /// audiobooks or videos — and the playlists a person made.
    @Sendable public static func readMusic() throws -> Contents {
        guard canAsk else {
            throw ModuleError("Only the installed app can read your Music library",
                              "macOS gives access to the app itself, which asks for it.")
        }
        let library: ITLibrary
        do {
            library = try ITLibrary(apiVersion: "1.1")
        } catch {
            throw ModuleError("KeybowNotes can't read your Music library",
                              "Allow it in System Settings → Privacy & Security → Media & Apple Music.")
        }
        let favourites = Set(library.allPlaylists.filter { $0.distinguishedKind == .kindLovedSongs }
            .flatMap(\.items).map(\.persistentID))
        let songs = library.allMediaItems.filter { $0.mediaKind == .kindSong && !$0.isUserDisabled }.map { item in
            Song(title: item.title,
                 artist: (item.artist?.name).flatMap { $0.isEmpty ? nil : $0 } ?? item.album.albumArtist ?? "",
                 album: item.album.title ?? "",
                 genre: item.genre.trimmingCharacters(in: .whitespaces),
                 plays: item.playCount,
                 favourite: favourites.contains(item.persistentID))
        }
        let playlists = library.allPlaylists.filter { list in
            list.isVisible && !list.isPrimary && list.distinguishedKind == .kindNone && list.kind != .folder
        }.map { list in
            Playlist(name: list.name, songs: list.items.filter { $0.mediaKind == .kindSong }.count,
                     isSmart: list.kind == .smart)
        }
        return Contents(songs: songs, playlists: playlists)
    }
}

// MARK: - What's in it, ranked

extension MusicLibrary.Contents {
    /// A genre, an artist or an album, with how much of it there is and how
    /// often it's played.
    public struct Tally: Equatable, Sendable {
        public var name: String
        /// For an album: whose it is.
        public var artist: String = ""
        public var songs: Int
        public var plays: Int
        public var favourites: Int
    }

    public enum Ranking: String, Sendable, CaseIterable {
        case plays, songs, name
    }

    /// Songs narrowed by genre, artist and album — each matched without
    /// regard to case, and an artist by its name or the album's artist.
    public func songs(genre: String? = nil, artist: String? = nil, album: String? = nil,
                      favouritesOnly: Bool = false) -> [MusicLibrary.Song] {
        songs.filter { song in
            (genre.map { Self.same(song.genre, $0) } ?? true)
                && (artist.map { Self.same(song.artist, $0) } ?? true)
                && (album.map { Self.same(song.album, $0) } ?? true)
                && (!favouritesOnly || song.favourite)
        }
    }

    public func genres(ranked ranking: Ranking = .plays) -> [Tally] {
        Self.tally(songs, by: \.genre, ranked: ranking)
    }

    public func artists(genre: String? = nil, ranked ranking: Ranking = .plays) -> [Tally] {
        Self.tally(songs(genre: genre), by: \.artist, ranked: ranking)
    }

    public func albums(genre: String? = nil, artist: String? = nil, ranked ranking: Ranking = .plays) -> [Tally] {
        var tallies = Self.tally(songs(genre: genre, artist: artist), by: \.album, ranked: ranking)
        for index in tallies.indices {
            let names = songs.filter { Self.same($0.album, tallies[index].name) }.map(\.artist)
            tallies[index].artist = Self.mostCommon(names)
        }
        return tallies
    }

    /// Songs, the most played first — or by title.
    public func ranked(_ songs: [MusicLibrary.Song], by ranking: Ranking = .plays) -> [MusicLibrary.Song] {
        songs.sorted { a, b in
            switch ranking {
            case .plays where a.plays != b.plays: return a.plays > b.plays
            case .name, .plays, .songs:
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
        }
    }

    static func same(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }

    /// Grouped without regard to case, each named as most of its songs spell it.
    private static func tally(_ songs: [MusicLibrary.Song], by key: KeyPath<MusicLibrary.Song, String>,
                              ranked ranking: Ranking) -> [Tally] {
        var groups: [String: [MusicLibrary.Song]] = [:]
        for song in songs where !song[keyPath: key].isEmpty {
            groups[song[keyPath: key].lowercased(), default: []].append(song)
        }
        let tallies = groups.values.map { group in
            Tally(name: mostCommon(group.map { $0[keyPath: key] }), songs: group.count,
                  plays: group.reduce(0) { $0 + $1.plays }, favourites: group.filter(\.favourite).count)
        }
        return tallies.sorted { a, b in
            switch ranking {
            case .plays where a.plays != b.plays: return a.plays > b.plays
            case .plays where a.songs != b.songs, .songs where a.songs != b.songs: return a.songs > b.songs
            default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    private static func mostCommon(_ names: [String]) -> String {
        let counts = Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key ?? ""
    }
}

// MARK: - Asked about

/// A question about the library, as Claude or an agent asks it: what to
/// list, narrowed by genre, artist or album, ranked, and how many.
public struct MusicQuery: Equatable, Sendable {
    public enum List: String, CaseIterable, Sendable {
        case overview, genres, artists, albums, songs, favourites, playlists
    }

    public var list: List
    public var genre: String?
    public var artist: String?
    public var album: String?
    public var ranking: MusicLibrary.Contents.Ranking
    public var limit: Int

    public init(_ list: List, genre: String? = nil, artist: String? = nil, album: String? = nil,
                ranking: MusicLibrary.Contents.Ranking = .plays, limit: Int = 25) {
        self.list = list
        self.genre = genre.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        self.artist = artist.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        self.album = album.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        self.ranking = ranking
        self.limit = min(max(limit, 1), 500)
    }

    /// From a tool's input: `{"list": "artists", "genre": "Jazz", "limit": 4}`.
    public init(input: [String: Any]) throws {
        let word = (input["list"] as? String ?? "overview").lowercased()
        guard let list = List(rawValue: word == "favorites" ? "favourites" : word) else {
            throw ModuleError("“\(word)” isn't something to list",
                              List.allCases.map(\.rawValue).joined(separator: ", "))
        }
        let ranking = (input["rank_by"] as? String).flatMap { MusicLibrary.Contents.Ranking(rawValue: $0.lowercased()) }
        let limit = (input["limit"] as? Int) ?? (input["limit"] as? String).flatMap(Int.init) ?? 25
        self.init(list, genre: input["genre"] as? String, artist: input["artist"] as? String,
                  album: input["album"] as? String, ranking: ranking ?? .plays, limit: limit)
    }

    /// The tool, as Claude is told of it.
    public static let tool: [String: Any] = [
        "name": "music_library",
        "description": """
            Read the person's Apple Music library: its genres, artists, albums, songs, favourites and playlists, \
            with how many songs each has and how often they've been played. Use it whenever they want keys for \
            their music — "my top genres", "artists I play most", "my favourites" — so the tree names what's \
            really there. Start with list: overview. Names are matched without regard to case.
            """,
        "input_schema": [
            "type": "object",
            "properties": [
                "list": ["type": "string", "enum": List.allCases.map(\.rawValue),
                         "description": "What to list. overview: the library in brief."],
                "genre": ["type": "string", "description": "Only this genre's."],
                "artist": ["type": "string", "description": "Only this artist's."],
                "album": ["type": "string", "description": "Only this album's songs."],
                "rank_by": ["type": "string", "enum": MusicLibrary.Contents.Ranking.allCases.map(\.rawValue),
                            "description": "plays (the default): most played first. songs: most songs first. name: A to Z."],
                "limit": ["type": "integer", "description": "How many, at most. Left out: 25."],
            ] as [String: Any],
            "required": ["list"],
        ] as [String: Any],
    ]
}

extension MusicLibrary.Contents {
    /// The answer, as text to read: a heading, then a line each.
    public func answer(_ query: MusicQuery) -> String {
        var narrowed: [String] = []
        if let genre = query.genre { narrowed.append("in \(genre)") }
        if let artist = query.artist { narrowed.append("by \(artist)") }
        if let album = query.album { narrowed.append("on \(album)") }
        let scope = narrowed.isEmpty ? "" : " " + narrowed.joined(separator: " ")
        let matching = songs(genre: query.genre, artist: query.artist, album: query.album)
        if !narrowed.isEmpty, matching.isEmpty, query.list != .playlists {
            return "Nothing in the library is\(scope). " + suggestion(query)
        }
        // With no plays recorded, "most played" can only mean most songs.
        var ranking = query.ranking
        var note = ""
        if ranking == .plays, matching.allSatisfy({ $0.plays == 0 }), !matching.isEmpty {
            ranking = .songs
            note = " No plays are recorded, so they're ranked by songs."
        }
        let order = ranking == .plays ? "most played first" : ranking == .songs ? "most songs first" : "A to Z"

        func lines<T>(_ items: [T], _ line: (T) -> String) -> String {
            items.prefix(query.limit).enumerated().map { "\($0.offset + 1). " + line($0.element) }.joined(separator: "\n")
        }
        func tally(_ item: Tally) -> String {
            var parts = ["\(item.plays) plays", "\(item.songs) songs"]
            if item.favourites > 0 { parts.append("\(item.favourites) favourites") }
            return (item.artist.isEmpty ? item.name : "\(item.name) — \(item.artist)") + " — " + parts.joined(separator: " · ")
        }
        func song(_ song: MusicLibrary.Song) -> String {
            var parts = [song.title, song.artist]
            if !song.album.isEmpty { parts.append(song.album) }
            var tail = ["\(song.plays) plays"]
            if !song.genre.isEmpty { tail.insert(song.genre, at: 0) }
            return parts.joined(separator: " — ") + " · " + tail.joined(separator: " · ") + (song.favourite ? " ★" : "")
        }
        func heading(_ what: String, _ count: Int) -> String {
            "\(what)\(scope), \(order) — \(count) in all\(count > query.limit ? ", the first \(query.limit) here" : ""):\(note)\n"
        }

        switch query.list {
        case .overview:
            let all = self.songs(genre: query.genre, artist: query.artist, album: query.album)
            let genres = Self(songs: all).genres(ranked: ranking)
            let artists = Self(songs: all).artists(ranked: ranking)
            let plays = all.reduce(0) { $0 + $1.plays }
            var text = "\(all.count) songs\(scope) by \(artists.count) artists in \(genres.count) genres; "
                + "\(all.filter(\.favourite).count) favourites; \(plays) plays recorded"
            if narrowed.isEmpty { text += "; \(playlists.count) playlists" }
            text += ".\(note)\n"
            text += "Top genres: " + genres.prefix(8).map(\.name).joined(separator: ", ") + ".\n"
            text += "Top artists: " + artists.prefix(8).map(\.name).joined(separator: ", ") + "."
            return text
        case .genres:
            let all = Self(songs: matching).genres(ranked: ranking)
            return heading("Genres", all.count) + lines(all, tally)
        case .artists:
            let all = Self(songs: matching).artists(ranked: ranking)
            return heading("Artists", all.count) + lines(all, tally)
        case .albums:
            let all = albums(genre: query.genre, artist: query.artist, ranked: ranking)
            return heading("Albums", all.count) + lines(all, tally)
        case .songs, .favourites:
            let chosen = query.list == .favourites ? matching.filter(\.favourite) : matching
            if chosen.isEmpty { return "There are no favourites\(scope). Songs are favourited in Music with the ★." }
            let all = ranked(chosen, by: ranking)
            return heading(query.list == .favourites ? "Favourite songs" : "Songs", all.count) + lines(all, song)
        case .playlists:
            let all = playlists.sorted { a, b in
                ranking == .songs && a.songs != b.songs ? a.songs > b.songs
                    : a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            if all.isEmpty { return "There are no playlists of the person's own." }
            return "Playlists, \(ranking == .songs ? "most songs first" : "A to Z") — \(all.count) in all:\n"
                + lines(all) { "\($0.name) — \($0.songs) songs\($0.isSmart ? " (smart)" : "")" }
        }
    }

    /// The names there are, when one asked for isn't.
    private func suggestion(_ query: MusicQuery) -> String {
        if let genre = query.genre, songs(genre: genre).isEmpty {
            return "Genres there: " + genres().prefix(15).map(\.name).joined(separator: ", ") + "."
        }
        if let artist = query.artist, songs(artist: artist).isEmpty {
            return "Its most played artists: " + artists(genre: query.genre).prefix(15).map(\.name)
                .joined(separator: ", ") + "."
        }
        return "Try fewer of genre, artist and album."
    }
}

// MARK: - For the tree editor

/// What a built-in action's field can be set to, for the tree editor to
/// offer as it's edited — a Music key's playlists, songs, albums, artists
/// and genres — as a module offers its own.
public enum BuiltInChoices {
    /// Given the action's other fields as they stand, so one choice follows
    /// another: an artist's albums, a genre's artists.
    public static func choices(for field: String, type: String, fields: [String: String],
                               library: MusicLibrary = .shared) async throws -> [FieldChoice] {
        guard type == "music.play", ["playlist", "song", "album", "artist", "genre"].contains(field) else { return [] }
        let contents = try await library.contents()
        // A placeholder — artist: {{leaf}} — names nothing until the key's pressed.
        func given(_ key: String) -> String? {
            fields[key].flatMap { $0.isEmpty || $0.contains("{{") ? nil : $0 }
        }
        let genre = given("genre"), artist = given("artist"), album = given("album")
        func count(_ songs: Int) -> String { songs == 1 ? "1 song" : "\(songs) songs" }
        switch field {
        case "playlist":
            return contents.playlists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { FieldChoice($0.name, title: count($0.songs)) }
        case "genre":
            return contents.genres().map { FieldChoice($0.name, title: count($0.songs)) }
        case "artist":
            return contents.artists(genre: genre).map { FieldChoice($0.name, title: count($0.songs)) }
        case "album":
            return contents.albums(genre: genre, artist: artist).map { FieldChoice($0.name, title: $0.artist) }
        default:
            let songs = contents.ranked(contents.songs(genre: genre, artist: artist, album: album))
            return songs.prefix(2000).map { song in
                FieldChoice(song.title, title: [song.artist, song.album].filter { !$0.isEmpty }.joined(separator: ", "))
            }
        }
    }
}
