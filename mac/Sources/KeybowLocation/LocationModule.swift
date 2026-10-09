import Foundation
import KeybowKit

/// Where the Mac is, as values for any template or data source's URL:
///
///   {{location}}             51.50722,-0.12750
///   {{location.latitude}}    51.50722
///   {{location.longitude}}   -0.1275
///   {{location.altitude}}    metres above sea level — usually empty: Macs
///                            find their place from Wi-Fi, which gives none
///   {{location.accuracy}}    how far off it may be, in metres
///
/// Found only when an action uses one, through Location Services, and kept
/// for five minutes. The first time, macOS asks whether KeybowNotes may.
public final class LocationModule: KeybowModule, @unchecked Sendable {
    public static let id = "location"
    /// How old a place may be and still be used.
    static let maxAge: TimeInterval = 300

    static let names = ["location", "location.latitude", "location.longitude", "location.altitude", "location.accuracy"]

    static let precisions: [(places: Int, title: String)] = [
        (5, "As exactly as the Mac knows"), (3, "About 100 m"), (2, "About 1 km"), (1, "About 10 km"),
    ]
    static let defaultPrecision = 5

    public let manifest = ModuleManifest(
        id: id, name: "Location",
        settings: [
            ModuleSetting(key: "precision", title: "Precision",
                          kind: .choice(precisions.map { .init(String($0.places), $0.title) }),
                          defaultValue: String(defaultPrecision), help: """
                How exactly {{location}}, {{location.latitude}} and {{location.longitude}} give your place. \
                Rounding is kinder to your privacy when they go to someone else's API: a weather forecast \
                needs no more than about 1 km.
                """),
        ],
        fetches: [id],
        symbol: "location.fill")

    private let provider: LocationProvider
    private var host: ModuleHost?

    /// `provider` finds the Mac; Location Services unless a test says otherwise.
    public init(provider: LocationProvider? = nil) {
        self.provider = provider ?? CoreLocationProvider.shared
    }

    public func start(host: ModuleHost) {
        self.host = host
    }

    var places: Int {
        host?.setting("precision", for: Self.id).flatMap(Int.init) ?? Self.defaultPrecision
    }

    // MARK: - Fetching

    public func fetch(_ names: [String], params: [String: String], now: Date) async throws -> [String: String] {
        for name in names where !Self.names.contains(name) {
            throw ModuleError("There's no {{\(name)}}",
                              "Location gives " + Self.names.map { "{{\($0)}}" }.joined(separator: ", ") + ".")
        }
        var reading = Self.given(in: params, at: now)
        if reading == nil { reading = try await provider.reading(maxAge: Self.maxAge) }
        guard let reading else { return [:] }
        return Self.values(for: reading, places: places).filter { names.contains($0.key) }
    }

    /// A place the tree gives itself — `location: 40.7128,-74.006`, or
    /// `location.latitude` and `location.longitude` — used instead of the Mac's.
    static func given(in params: [String: String], at now: Date) -> LocationReading? {
        func number(_ text: String?) -> Double? {
            text.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        }
        var latitude = number(params["location.latitude"])
        var longitude = number(params["location.longitude"])
        if latitude == nil || longitude == nil, let pair = params["location"]?.split(separator: ","), pair.count == 2 {
            latitude = number(String(pair[0]))
            longitude = number(String(pair[1]))
        }
        guard let latitude, let longitude, (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        return LocationReading(latitude: latitude, longitude: longitude, altitude: number(params["location.altitude"]),
                               accuracy: 0, at: now)
    }

    /// Every value, rounded to `places` decimal places of a degree.
    static func values(for reading: LocationReading, places: Int) -> [String: String] {
        let latitude = decimal(reading.latitude, places: places)
        let longitude = decimal(reading.longitude, places: places)
        // Rounding moves the place by up to half the last digit: about 55 km
        // for a whole degree of latitude, less for longitude away from the equator.
        let rounding = 111_000 / 2 / pow(10, Double(places))
        return [
            "location": "\(latitude),\(longitude)",
            "location.latitude": latitude,
            "location.longitude": longitude,
            "location.altitude": reading.altitude.map { decimal($0, places: 0) } ?? "",
            "location.accuracy": decimal(max(reading.accuracy, rounding), places: 0),
        ]
    }

    /// "51.5072": fixed places, less any trailing zeros.
    static func decimal(_ value: Double, places: Int) -> String {
        var text = String(format: "%.\(max(places, 0))f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }

    public func fetchSubject(for names: [String]) -> String { "your location" }

    public func standIn(forValue name: String) -> String {
        switch name {
        case "location": return "‹your location›"
        case "location.latitude": return "‹your latitude›"
        case "location.longitude": return "‹your longitude›"
        case "location.altitude": return "‹your altitude›"
        case "location.accuracy": return "‹how far off›"
        default: return "‹\(name)›"
        }
    }

    // MARK: - Not an action

    public func summary(of request: ModuleRequest, now: Date) -> ModuleSummary {
        ModuleSummary(verb: "Locate", subject: request.leaf)
    }

    public func run(_ request: ModuleRequest, now: Date) async -> ActionOutcome {
        .failure("Location gives values to other actions; it isn't an action itself.")
    }
}
