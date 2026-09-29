import AppKit
import KeybowAI
import KeybowKit
import KeybowModules

/// The app's modules, and their host.
@MainActor
enum Modules {
    static let host = AppModuleHost()

    /// Before anything reads the outline, so the modules' keywords are known.
    static func registerAll() {
        BuiltInModules.registerAll(host: host)
        // Development builds only, on request: a block that just waits, for
        // trying the HUD's timer and Cancel without asking anyone anything.
        // KEYBOW_DEBUG_BLOCKS=claude has it stand in for Claude — {{#ai}},
        // "Asking Claude…" — for screenshots, with no request and no key.
        let debug = ProcessInfo.processInfo.environment["KEYBOW_DEBUG_BLOCKS"]
        if Bundle.main.bundleIdentifier == nil, let debug {
            ModuleRegistry.shared.register(WaitModule(standingInForClaude: debug == "claude"), host: host)
        }
        // Development builds only, on request: Claude answers every request
        // with KEYBOW_DEBUG_CLAUDE_REPLY, with no request sent and no key —
        // for trying and capturing Find It in Data Sources.
        if Bundle.main.bundleIdentifier == nil, let reply = ProcessInfo.processInfo.environment["KEYBOW_DEBUG_CLAUDE_REPLY"] {
            ModuleRegistry.shared.register(ClaudeModule(transport: ScriptedClaude(reply: reply)), host: KeyedHost(host))
        }
    }
}

/// Replies as the Messages API would, with the same text every time.
private struct ScriptedClaude: ClaudeTransport {
    let reply: String

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await Task.sleep(for: .seconds(1.5))
        let body: [String: Any] = ["content": [["type": "text", "text": reply]], "stop_reason": "end_turn"]
        return (try JSONSerialization.data(withJSONObject: body),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// The app's host, with a stand-in Claude key: ScriptedClaude needs none.
private final class KeyedHost: ModuleHost, @unchecked Sendable {
    let host: ModuleHost

    init(_ host: ModuleHost) { self.host = host }

    func load(_ key: String, for module: String) -> Data? { host.load(key, for: module) }
    func save(_ data: Data?, as key: String, for module: String) { host.save(data, as: key, for: module) }
    var templatesFolder: URL? { host.templatesFolder }
    func display(_ display: ModuleDisplay) async -> ModuleDisplay.Result { await host.display(display) }
    func statusChanged() { host.statusChanged() }
    func copy(_ text: String) { host.copy(text) }
    func setting(_ key: String, for module: String) -> String? { host.setting(key, for: module) }
    func secret(_ key: String, for module: String) -> String? { key == "apiKey" ? "scripted" : host.secret(key, for: module) }
    func setSecret(_ value: String?, _ key: String, for module: String) -> String? { host.setSecret(value, key, for: module) }
}

/// `{{#wait seconds=3}}text{{/wait}}` → "TEXT", after the wait. Not in the app.
private final class WaitModule: KeybowModule, @unchecked Sendable {
    let manifest: ModuleManifest
    private let standIn: String

    init(standingInForClaude: Bool) {
        manifest = standingInForClaude
            ? ModuleManifest(id: "ai", name: "Claude", blocks: [ModuleBlockType(name: "ai", title: "Claude")])
            : ModuleManifest(id: "wait", name: "Wait", blocks: [ModuleBlockType(name: "wait", title: "Wait")])
        standIn = standingInForClaude ? "‹Claude's reply›" : "‹wait›"
    }

    func standIn(for call: TemplateBlockCall) -> String { standIn }
    func start(host: ModuleHost) {}
    func summary(of request: ModuleRequest, now: Date) -> ModuleSummary { ModuleSummary(verb: "Wait", subject: "") }
    func run(_ request: ModuleRequest, now: Date) async -> ActionOutcome { .failure("Not an action") }

    func reply(to call: TemplateBlockCall) async throws -> String {
        try await Task.sleep(for: .seconds(Double(call.attributes["seconds"] ?? "") ?? 3))
        return call.body.uppercased()
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
    private var folder: URL?

    /// Modules' state. A development build keeps its own, so trying things
    /// never touches the app's.
    let state = StateFile(url: ConfigStore.supportDirectory
        .appendingPathComponent(Bundle.main.bundleIdentifier == nil ? "state-dev.json" : "state.json"))

    /// Where state used to be kept: moved into `state.json` as it's read.
    private func legacyKey(_ key: String, _ module: String) -> String { "module.\(module).\(key)" }

    func load(_ key: String, for module: String) -> Data? {
        if let data = state.load(key, for: module) { return data }
        guard let legacy = defaults.data(forKey: legacyKey(key, module)) else { return nil }
        // Moved, not copied — but only once it's safely in the file.
        if let problem = state.save(legacy, as: key, for: module) {
            Log.error("state: \(problem); kept \(module).\(key) in preferences")
        } else {
            defaults.removeObject(forKey: legacyKey(key, module))
            Log.info("state: moved \(module).\(key) from preferences to \(state.url.lastPathComponent)")
        }
        return legacy
    }

    func save(_ data: Data?, as key: String, for module: String) {
        if let problem = state.save(data, as: key, for: module) { Log.error("state: \(problem)") }
    }

    /// Set by the app: puts a module's display on screen.
    var onDisplay: (@MainActor (ModuleDisplay) async -> ModuleDisplay.Result)? {
        get { lock.withLock { displayer } }
        set { lock.withLock { displayer = newValue } }
    }
    private var displayer: (@MainActor (ModuleDisplay) async -> ModuleDisplay.Result)?

    func display(_ display: ModuleDisplay) async -> ModuleDisplay.Result {
        guard let show = onDisplay else { return .dismissed }
        return await show(display)
    }

    /// Set by the app from the tree in use.
    var templatesFolder: URL? {
        get { lock.withLock { folder } }
        set { lock.withLock { folder = newValue } }
    }

    // MARK: Settings

    private func settingKey(_ key: String, _ module: String) -> String { "module.\(module).setting.\(key)" }

    func setting(_ key: String, for module: String) -> String? {
        defaults.string(forKey: settingKey(key, module))
    }

    /// From the Settings window.
    func setSetting(_ value: String?, _ key: String, for module: String) {
        if let value { defaults.set(value, forKey: settingKey(key, module)) }
        else { defaults.removeObject(forKey: settingKey(key, module)) }
    }

    /// From the Keychain. Safe to call from any thread.
    func secret(_ key: String, for module: String) -> String? {
        Keychain.read(account: "\(module).\(key)")
    }

    func hasSecret(_ key: String, for module: String) -> Bool {
        secret(key, for: module) != nil
    }

    /// From the Settings window; nil removes it. Says why, if it couldn't.
    @discardableResult
    func setSecret(_ value: String?, _ key: String, for module: String) -> String? {
        Keychain.write(value, account: "\(module).\(key)")
    }

    func copy(_ text: String) {
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
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

/// Secrets in the login keychain, as generic passwords this app made — so it
/// can read them back without asking, and they're listed in Keychain Access
/// as "KeybowNotes: …" should they need removing by hand.
enum Keychain {
    /// A development build keeps its own: reading the app's items would ask
    /// for permission, and it mustn't change them.
    static let service = Bundle.main.bundleIdentifier == nil ? "io.github.cwenham.keybownotes.dev" : "io.github.cwenham.keybownotes"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(account: String) -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Nil on success, else what went wrong.
    static func write(_ value: String?, account: String) -> String? {
        SecItemDelete(query(account) as CFDictionary)
        guard let value, !value.isEmpty else { return nil }
        var item = query(account)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrLabel as String] = "KeybowNotes: \(account)"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status != errSecSuccess else { return nil }
        return (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}
