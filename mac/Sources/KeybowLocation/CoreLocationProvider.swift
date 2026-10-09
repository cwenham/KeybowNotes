import AppKit
import CoreLocation
import KeybowKit

/// Where the Mac is, as it knows it.
public struct LocationReading: Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    /// Metres above sea level; nil when the Mac doesn't know, as is usual.
    public var altitude: Double?
    /// How far off it may be, in metres.
    public var accuracy: Double
    public var at: Date

    public init(latitude: Double, longitude: Double, altitude: Double? = nil, accuracy: Double, at: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.accuracy = accuracy
        self.at = at
    }
}

/// Finds the Mac — Location Services in the app, a stand-in in tests.
public protocol LocationProvider: Sendable {
    /// A place no older than `maxAge`, asking for a new one if need be.
    /// Cancelling the task stops the wait.
    func reading(maxAge: TimeInterval) async throws -> LocationReading
}

/// Location Services. Asks for permission the first time it's needed, and
/// for one place at a time — it never follows the Mac about.
@MainActor
public final class CoreLocationProvider: NSObject, LocationProvider, CLLocationManagerDelegate {
    public nonisolated static let shared = CoreLocationProvider()

    /// Touches nothing: the manager is made on first use, on the main thread.
    nonisolated override init() {
        super.init()
    }

    /// A Mac on Wi-Fi usually answers within a few seconds.
    static let timeout: TimeInterval = 20
    /// Time to find and answer the permission prompt.
    static let answerTimeout: TimeInterval = 120

    private lazy var manager: CLLocationManager = {
        let manager = CLLocationManager()
        // Wi-Fi gives tens of metres at best; asking for more only waits longer.
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.delegate = self
        return manager
    }()

    private var waiting: [UUID: CheckedContinuation<CLLocation, Error>] = [:]
    private var answering: [UUID: CheckedContinuation<Void, Never>] = [:]

    public nonisolated func reading(maxAge: TimeInterval) async throws -> LocationReading {
        // Not on the main thread: it can take a moment.
        guard CLLocationManager.locationServicesEnabled() else {
            throw ModuleError("Location Services are off on this Mac",
                              "Turn them on in System Settings → Privacy & Security → Location Services.")
        }
        return try await locate(maxAge: maxAge)
    }

    private func locate(maxAge: TimeInterval) async throws -> LocationReading {
        try await authorize()
        if let known = manager.location, known.horizontalAccuracy >= 0, -known.timestamp.timeIntervalSinceNow < maxAge {
            return Self.reading(known)
        }
        return Self.reading(try await requestOne())
    }

    static func reading(_ location: CLLocation) -> LocationReading {
        LocationReading(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                        altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
                        accuracy: location.horizontalAccuracy, at: location.timestamp)
    }

    // MARK: Permission

    /// Whether KeybowNotes may use Location Services: for Settings → Privacy.
    public var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    /// Asks, if macOS hasn't yet — from Settings → Privacy, rather than at a
    /// key press — without finding where the Mac is.
    public func requestAccess() async {
        try? await authorize()
    }

    private func authorize() async throws {
        if manager.authorizationStatus == .notDetermined {
            // The prompt belongs to a menu-bar app that isn't in front, and
            // can open behind other windows; bringing it forward helps.
            NSApp?.activate()
            manager.requestWhenInUseAuthorization()
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    answering[id] = continuation
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(Self.answerTimeout))
                        self?.answering.removeValue(forKey: id)?.resume()
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.answering.removeValue(forKey: id)?.resume() }
            }
            try Task.checkCancellation()
        }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return
        case .notDetermined:
            throw ModuleError("No answer yet about using your location",
                              "macOS asks whether KeybowNotes may; the prompt may be behind other windows.")
        case .restricted:
            throw ModuleError("Location Services are restricted on this Mac", "A profile or Screen Time setting prevents them.")
        default:
            throw ModuleError("KeybowNotes isn't allowed to use your location",
                              "Allow it in System Settings → Privacy & Security → Location Services.")
        }
    }

    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            guard manager.authorizationStatus != .notDetermined else { return }
            let answered = answering.values
            answering.removeAll()
            answered.forEach { $0.resume() }
        }
    }

    // MARK: A place

    /// The next place Location Services find, however many are waiting for it.
    private func requestOne() async throws -> CLLocation {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiting[id] = continuation
                if waiting.count == 1 { manager.requestLocation() }
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(Self.timeout))
                    self?.finish(id, .failure(ModuleError("Couldn't find where this Mac is in time", Self.wifiHint)))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, .failure(CancellationError())) }
        }
    }

    private func finish(_ id: UUID, _ result: Result<CLLocation, Error>) {
        waiting.removeValue(forKey: id)?.resume(with: result)
    }

    private func finishAll(_ result: Result<CLLocation, Error>) {
        let all = waiting.values
        waiting.removeAll()
        all.forEach { $0.resume(with: result) }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        MainActor.assumeIsolated { finishAll(.success(latest)) }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let explained = Self.explain(error)
        MainActor.assumeIsolated { finishAll(.failure(explained)) }
    }

    nonisolated static let wifiHint = "Macs find their place from nearby Wi-Fi networks: is Wi-Fi on?"

    nonisolated static func explain(_ error: Error) -> ModuleError {
        switch (error as? CLError)?.code {
        case .denied:
            return ModuleError("KeybowNotes isn't allowed to use your location",
                               "Allow it in System Settings → Privacy & Security → Location Services.")
        case .locationUnknown:
            return ModuleError("Couldn't find where this Mac is", wifiHint)
        case .network:
            return ModuleError("Couldn't find where this Mac is", "Location Services need a network connection.")
        default:
            return ModuleError("Couldn't find where this Mac is", error.localizedDescription)
        }
    }
}
