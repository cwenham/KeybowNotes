import KeybowAI
import KeybowData
import KeybowKit
import KeybowLocation
import KeybowStopwatch

/// Every module built in, for each host — the app, the command line — to
/// register before it reads an outline. Adding a module is a line here and a
/// dependency in Package.swift.
public enum BuiltInModules {
    public static func registerAll(host: ModuleHost) {
        ModuleRegistry.shared.register(StopwatchModule(), host: host)
        ModuleRegistry.shared.register(ClaudeModule(), host: host)
        ModuleRegistry.shared.register(DataModule(), host: host)
        ModuleRegistry.shared.register(LocationModule(), host: host)
    }
}
