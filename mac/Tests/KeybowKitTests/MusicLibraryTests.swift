@testable import KeybowKit
import XCTest

/// The Music library, ranked and asked about — and the Music keys it makes
/// possible. A made-up library: nothing reads Music's own.
final class MusicLibraryTests: XCTestCase {
    private typealias Song = MusicLibrary.Song

    private let library = MusicLibrary.Contents(songs: [
        Song(title: "So What", artist: "Miles Davis", album: "Kind of Blue", genre: "Jazz", plays: 40, favourite: true),
        Song(title: "Blue in Green", artist: "Miles Davis", album: "Kind of Blue", genre: "Jazz", plays: 25),
        Song(title: "Naima", artist: "John Coltrane", album: "Giant Steps", genre: "jazz", plays: 30),
        Song(title: "Take Five", artist: "Dave Brubeck", album: "Time Out", genre: "Jazz", plays: 5),
        Song(title: "Paranoid Android", artist: "Radiohead", album: "OK Computer", genre: "Rock", plays: 60, favourite: true),
        Song(title: "Karma Police", artist: "Radiohead", album: "OK Computer", genre: "Rock", plays: 10),
        Song(title: "Clair de Lune", artist: "Claude Debussy", album: "Suite bergamasque", genre: "Classical"),
        Song(title: "Gymnopédie No. 1", artist: "Erik Satie", album: "Gymnopédies", genre: "Classical"),
    ], playlists: [
        MusicLibrary.Playlist(name: "Focus", songs: 12),
        MusicLibrary.Playlist(name: "Recently Loved", songs: 30, isSmart: true),
    ])

    func testGenresAndArtistsRankedByPlays() {
        let genres = library.genres()
        XCTAssertEqual(genres.map(\.name), ["Jazz", "Rock", "Classical"], "jazz and Jazz are one")
        XCTAssertEqual(genres[0].plays, 100)
        XCTAssertEqual(genres[0].songs, 4)
        XCTAssertEqual(genres[0].favourites, 1)
        XCTAssertEqual(library.genres(ranked: .songs).map(\.name), ["Jazz", "Classical", "Rock"])
        XCTAssertEqual(library.genres(ranked: .name).map(\.name), ["Classical", "Jazz", "Rock"])

        XCTAssertEqual(library.artists(genre: "JAZZ").map(\.name), ["Miles Davis", "John Coltrane", "Dave Brubeck"])
        XCTAssertEqual(library.albums(artist: "miles davis").map(\.name), ["Kind of Blue"])
        XCTAssertEqual(library.albums(genre: "Rock").first?.artist, "Radiohead")
    }

    func testTheTopFourGenresThenTheirTopArtists() {
        // What Claude does for "my top 4 genres, then the top 4 artists in each".
        let top = library.answer(MusicQuery(.genres, limit: 4))
        XCTAssertEqual(top, """
            Genres, most played first — 3 in all:
            1. Jazz — 100 plays · 4 songs · 1 favourites
            2. Rock — 70 plays · 2 songs · 1 favourites
            3. Classical — 0 plays · 2 songs
            """)
        XCTAssertEqual(library.answer(MusicQuery(.artists, genre: "Jazz", limit: 2)), """
            Artists in Jazz, most played first — 3 in all, the first 2 here:
            1. Miles Davis — 65 plays · 2 songs · 1 favourites
            2. John Coltrane — 30 plays · 1 songs
            """)
        XCTAssertTrue(library.answer(MusicQuery(.artists, genre: "Classical"))
            .contains("No plays are recorded, so they're ranked by songs."))
    }

    func testOtherQuestions() {
        let overview = library.answer(MusicQuery(.overview))
        XCTAssertTrue(overview.hasPrefix("8 songs by 6 artists in 3 genres; 2 favourites; 170 plays recorded; 2 playlists."),
                      overview)
        XCTAssertTrue(overview.contains("Top genres: Jazz, Rock, Classical."))
        XCTAssertEqual(library.answer(MusicQuery(.favourites)), """
            Favourite songs, most played first — 2 in all:
            1. Paranoid Android — Radiohead — OK Computer · Rock · 60 plays ★
            2. So What — Miles Davis — Kind of Blue · Jazz · 40 plays ★
            """)
        XCTAssertTrue(library.answer(MusicQuery(.songs, album: "kind of blue")).contains("2. Blue in Green"))
        XCTAssertEqual(library.answer(MusicQuery(.playlists)), """
            Playlists, A to Z — 2 in all:
            1. Focus — 12 songs
            2. Recently Loved — 30 songs (smart)
            """)
        XCTAssertEqual(library.answer(MusicQuery(.artists, genre: "Polka")),
                       "Nothing in the library is in Polka. Genres there: Jazz, Rock, Classical.")
        XCTAssertEqual(library.answer(MusicQuery(.favourites, genre: "Classical")),
                       "There are no favourites in Classical. Songs are favourited in Music with the ★.")
    }

    func testAToolsInput() throws {
        let query = try MusicQuery(input: ["list": "Favorites", "genre": "Jazz", "rank_by": "songs", "limit": 4])
        XCTAssertEqual(query, MusicQuery(.favourites, genre: "Jazz", ranking: .songs, limit: 4))
        XCTAssertEqual(try MusicQuery(input: [:]), MusicQuery(.overview))
        XCTAssertEqual(try MusicQuery(input: ["list": "songs", "limit": "9000", "artist": " "]).limit, 500)
        XCTAssertNil(try MusicQuery(input: ["list": "songs", "artist": " "]).artist)
        XCTAssertThrowsError(try MusicQuery(input: ["list": "podcasts"]))
        let schema = MusicQuery.tool["input_schema"] as? [String: Any]
        XCTAssertEqual(schema?["required"] as? [String], ["list"])
    }

    func testTheEditorsLists() async throws {
        let library = MusicLibrary { self.library }
        func choices(_ field: String, _ fields: [String: String] = [:]) async throws -> [String] {
            try await BuiltInChoices.choices(for: field, type: "music.play", fields: fields, library: library).map(\.value)
        }
        let genres = try await choices("genre")
        XCTAssertEqual(genres, ["Jazz", "Rock", "Classical"])
        let jazz = try await choices("artist", ["genre": "Jazz"])
        XCTAssertEqual(jazz, ["Miles Davis", "John Coltrane", "Dave Brubeck"], "the genre's, most played first")
        let placeholder = try await choices("artist", ["genre": "{{parent}}"])
        XCTAssertEqual(placeholder.count, 6, "a placeholder narrows nothing until the key's pressed")
        let albums = try await choices("album", ["artist": "Radiohead"])
        XCTAssertEqual(albums, ["OK Computer"])
        let songs = try await BuiltInChoices.choices(for: "song", type: "music.play", fields: ["album": "OK Computer"],
                                                     library: library)
        XCTAssertEqual(songs, [FieldChoice("Paranoid Android", title: "Radiohead, OK Computer"),
                               FieldChoice("Karma Police", title: "Radiohead, OK Computer")])
        let playlists = try await BuiltInChoices.choices(for: "playlist", type: "music.play", fields: [:], library: library)
        XCTAssertEqual(playlists.first, FieldChoice("Focus", title: "12 songs"))
        let elsewhere = try await BuiltInChoices.choices(for: "url", type: "url.open", fields: [:], library: library)
        XCTAssertEqual(elsewhere, [])
    }

    func testTheLibraryIsReadOnceInAWhile() async throws {
        let reads = Counter()
        let library = MusicLibrary { reads.add(); return MusicLibrary.Contents(songs: []) }
        _ = try await library.contents()
        _ = try await library.contents()
        XCTAssertEqual(reads.value, 1)
        _ = try await library.contents(maxAge: 0)
        XCTAssertEqual(reads.value, 2)
    }

    // MARK: - Shared

    func testOnlyWhatsSharedIsAnswered() throws {
        let genres = MusicSharing(.genres, playlists: false)
        XCTAssertEqual(genres.lists, [.overview, .genres])
        XCTAssertEqual(try library.answer(MusicQuery(.overview), sharing: genres), """
            8 songs in 3 genres; 2 favourites; 170 plays recorded.
            Top genres: Jazz, Rock, Classical.
            """, "no artists, and no playlists")
        XCTAssertThrowsError(try library.answer(MusicQuery(.artists), sharing: genres)) { error in
            XCTAssertEqual((error as? ModuleError)?.message, "Of the Music library, only the genres are shared — not its artists")
        }
        XCTAssertThrowsError(try library.answer(MusicQuery(.genres, artist: "Radiohead"), sharing: genres),
                             "narrowing by an artist would say whether they're there")
        XCTAssertThrowsError(try library.answer(MusicQuery(.playlists), sharing: genres))

        let albums = MusicSharing(.albums)
        XCTAssertEqual(albums.lists, [.overview, .genres, .artists, .albums, .playlists])
        XCTAssertEqual(albums.summary, "genres, artists, albums and playlists")
        XCTAssertNoThrow(try library.answer(MusicQuery(.albums, artist: "Radiohead"), sharing: albums))
        XCTAssertThrowsError(try library.answer(MusicQuery(.favourites), sharing: albums)) { error in
            XCTAssertEqual((error as? ModuleError)?.message,
                           "Of the Music library, only the genres, artists, albums and playlists are shared — not its favourite songs")
        }
        XCTAssertThrowsError(try library.answer(MusicQuery(.songs, album: "OK Computer"), sharing: albums))

        XCTAssertEqual(try library.answer(MusicQuery(.overview), sharing: .everything), library.answer(MusicQuery(.overview)))
        XCTAssertThrowsError(try library.answer(MusicQuery(.overview), sharing: MusicSharing(.nothing))) { error in
            XCTAssertEqual((error as? ModuleError)?.message, "The person doesn't share their Music library")
        }
    }

    func testTheToolOffersOnlyWhatsShared() {
        let tool = MusicQuery.tool(sharing: MusicSharing(.artists, playlists: false))
        let properties = (tool["input_schema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
        XCTAssertEqual((properties["list"] as? [String: Any])?["enum"] as? [String], ["overview", "genres", "artists"])
        XCTAssertNotNil(properties["artist"])
        XCTAssertNil(properties["album"], "albums aren't shared, so there's no narrowing by one")
        XCTAssertTrue((tool["description"] as? String ?? "")
            .hasSuffix("The person shares only the library's genres and artists: ask for nothing else."))
        XCTAssertFalse((MusicQuery.tool["description"] as? String ?? "").contains("shares only"))
        let all = (MusicQuery.tool["input_schema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
        XCTAssertEqual((all["list"] as? [String: Any])?["enum"] as? [String], MusicQuery.List.allCases.map(\.rawValue))
    }

    // MARK: - Music keys

    private func plan(_ outline: String, path: [Int]) throws -> ActionPlan {
        let config = try XCTUnwrap(OutlineCompiler.compile(OutlineParser.parse(outline).0, locateApp: { _ in nil }).config)
        let selection = try XCTUnwrap(config.resolve(path: path))
        return try ActionPlanner.plan(selection, config: config, context: ActionContext(templatesDirectory: nil)).plan
    }

    func testAKeyPlaysASongAnArtistOrAGenre() throws {
        let outline = """
        1. Jazz [Music, genre: Jazz, artist: "{{leaf}}"]
           1. Miles Davis
           2. Everything [artist: ""]
           3. In order [artist: "", shuffle: no]
           4. Focus [playlist: Focus]
        2. Songs [Music]
           1. So What [song: "{{leaf}}", artist: Miles Davis]
           2. Kind of Blue [album: Kind of Blue, song: ""]
           3. Late Night
        """
        XCTAssertEqual(try plan(outline, path: [0, 0]), .playMusic(artist: "Miles Davis", genre: "Jazz", shuffle: nil))
        XCTAssertEqual(try plan(outline, path: [0, 1]), .playMusic(artist: "", genre: "Jazz", shuffle: nil))
        XCTAssertEqual(try plan(outline, path: [0, 2]), .playMusic(artist: "", genre: "Jazz", shuffle: false))
        XCTAssertEqual(try plan(outline, path: [0, 3]), .playPlaylist("Focus", shuffle: nil), "a playlist named wins")
        XCTAssertEqual(try plan(outline, path: [1, 0]), .playSong("So What", artist: "Miles Davis"))
        XCTAssertEqual(try plan(outline, path: [1, 1]), .playAlbum("Kind of Blue", artist: ""))
        XCTAssertEqual(try plan(outline, path: [1, 2]), .playPlaylist("Late Night", shuffle: nil), "the label, as ever")

        let config = try XCTUnwrap(OutlineCompiler.compile(OutlineParser.parse(outline).0, locateApp: { _ in nil }).config)
        func summary(_ path: [Int]) throws -> ActionSummary {
            ActionSummary(selection: try XCTUnwrap(config.resolve(path: path)), config: config)
        }
        XCTAssertEqual(try summary([0, 0]).subject, "Miles Davis")
        XCTAssertEqual(try summary([0, 0]).details, ["artist, in Jazz", "shuffled"])
        XCTAssertEqual(try summary([0, 2]).details, ["genre", "in order"])
        XCTAssertEqual(try summary([1, 0]).details, ["song by Miles Davis"])
    }

    func testTheMusicScriptsCompile() throws {
        // Compiling only reads Music's dictionary: nothing is sent to it.
        for (name, source) in [("playPlaylist", Scripts.playPlaylist), ("playAlbum", Scripts.playAlbum),
                               ("playSong", Scripts.playSong), ("playMusic", Scripts.playMusic)] {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("keybow-\(UUID().uuidString).scpt")
            defer { try? FileManager.default.removeItem(at: out) }
            let result = try Subprocess.runAndWait("/usr/bin/osacompile", ["-o", out.path], input: source, timeout: 60)
            XCTAssertTrue(result.succeeded, "\(name): \(result.errorText)")
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
