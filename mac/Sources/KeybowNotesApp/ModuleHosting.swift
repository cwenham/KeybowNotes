import AppKit
import KeybowKit
import KeybowModules

/// The app's modules, and their host.
@MainActor
enum Modules {
    static let host = AppModuleHost()

    /// Before anything reads the outline, so the modules' keywords are known.
    static func registerAll() {
        BuiltInModules.registerAll(host: host)
    }
}

/// The app's side of the module interface: where modules keep state between
/// runs, and how they say their status changed.
final class AppModuleHost: ModuleHost, @unchecked Sendable {
    /// Called on the main thread, once for any number of changes in a row.
    var onChange: (@MainActor () -> Void)?

    private let defaults = UserDefaults.standard
    private let lock = NSLock()
    private var scheduled = false

    private func key(_ key: String, _ module: String) -> String { "module.\(module).\(key)" }

    func load(_ key: String, for module: String) -> Data? {
        defaults.data(forKey: self.key(key, module))
    }

    func save(_ data: Data?, as key: String, for module: String) {
        if let data { defaults.set(data, forKey: self.key(key, module)) } else { defaults.removeObject(forKey: self.key(key, module)) }
    }

    func statusChanged() {
        let first = lock.withLock { () -> Bool in
            defer { scheduled = true }
            return !scheduled
        }
        guard first else { return }
        DispatchQueue.main.async { [self] in
            lock.withLock { scheduled = false }
            MainActor.assumeIsolated { onChange?() }
        }
    }
}

/// A module's clock as text: "3:12", "1:02:03".
enum ModuleClock {
    static func text(for status: ModuleStatus, now: Date = Date()) -> String {
        guard let since = status.countingFrom else { return status.text }
        let total = max(0, Int(now.timeIntervalSince(since)))
        let (hours, minutes, seconds) = (total / 3600, total % 3600 / 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
