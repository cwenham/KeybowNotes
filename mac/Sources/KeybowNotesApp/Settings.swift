import AppKit
import KeybowKit
import SwiftUI

/// Settings for this Mac, kept in UserDefaults and edited in the settings
/// window. The tree itself stays in the config file.
@MainActor @Observable
final class AppSettings {
    enum Change {
        case placement, configFile, timing, brightness, dryRun, defaults
    }

    /// Where the overlay appears.
    var placement: OverlayPlacement { didSet { save(); onChange?(.placement) } }
    /// Empty for the standard location in Application Support.
    var configPath: String { didSet { save(); onChange?(.configFile) } }

    /// Timings set here, overriding the config file's. Nil means "use the file's".
    var commitDelay: Double? { didSet { save(); onChange?(.timing) } }
    var idleTimeout: Double? { didSet { save(); onChange?(.timing) } }
    var longPressCancel: Double? { didSet { save(); onChange?(.timing) } }

    /// Calendar and Reminders list identifiers for actions that name none.
    /// Empty means the system's defaults.
    var defaultCalendarID: String { didSet { save(); onChange?(.defaults) } }
    var defaultReminderListID: String { didSet { save(); onChange?(.defaults) } }

    /// 0.05 to 1.
    var brightness: Double { didSet { save(); onChange?(.brightness) } }
    var dryRun: Bool { didSet { save(); onChange?(.dryRun) } }
    /// For {{selection}} in apps that won't share it: send ⌘C and put the
    /// clipboard back afterwards.
    var copySelection: Bool { didSet { save(); onChange?(.defaults) } }

    // MARK: Live status, shown in the window but not saved

    var keybowStatus = "Looking for keypads…"
    /// Keypads known, or named in the tree, that aren't connected.
    var missingKeypads: [MissingKeypad] = []
    var openAtLogin = false
    var accessibilityAllowed = false
    /// Why Open at Login isn't simply on or off, when it isn't.
    var openAtLoginNote: String?
    var configProblem: String?
    var configSummary = ""
    /// The config file's own timings, to show beside the sliders.
    var fileTimings = (commitDelay: 1.0, idleTimeout: 10.0, longPressCancel: 1.5)

    @ObservationIgnored var onChange: ((Change) -> Void)?
    @ObservationIgnored private let store = UserDefaults.standard

    init() {
        placement = OverlayPlacement(storageKey: store.string(forKey: Keys.placement) ?? "")
        configPath = store.string(forKey: Keys.configPath) ?? ""
        commitDelay = store.object(forKey: Keys.commitDelay) as? Double
        idleTimeout = store.object(forKey: Keys.idleTimeout) as? Double
        longPressCancel = store.object(forKey: Keys.longPressCancel) as? Double
        defaultCalendarID = store.string(forKey: Keys.defaultCalendar) ?? ""
        defaultReminderListID = store.string(forKey: Keys.defaultReminderList) ?? ""
        brightness = store.object(forKey: Keys.brightness) as? Double ?? 1
        dryRun = store.bool(forKey: Keys.dryRun)
        copySelection = store.object(forKey: Keys.copySelection) as? Bool ?? true
    }

    var configURL: URL {
        configPath.isEmpty ? AppLocations.defaultTree
            : URL(fileURLWithPath: (configPath as NSString).expandingTildeInPath)
    }

    var hasTimingOverrides: Bool {
        commitDelay != nil || idleTimeout != nil || longPressCancel != nil
    }

    func useFileTimings() {
        commitDelay = nil
        idleTimeout = nil
        longPressCancel = nil
    }

    /// The config as it should run: the file's tree with any timings set here.
    func apply(to config: KeybowConfig) -> KeybowConfig {
        config.with(commitDelay: commitDelay, idleTimeout: idleTimeout, longPressCancel: longPressCancel)
    }

    private enum Keys {
        static let placement = "overlayPlacement"
        static let configPath = AppLocations.treePathKey
        static let commitDelay = "commitDelay"
        static let idleTimeout = "idleTimeout"
        static let longPressCancel = "longPressCancel"
        static let defaultCalendar = "defaultCalendarID"
        static let defaultReminderList = "defaultReminderListID"
        static let brightness = "keyBrightness"
        static let dryRun = "dryRun"
        static let copySelection = "copySelectionWithCommandC"
    }

    private func save() {
        store.set(placement.storageKey, forKey: Keys.placement)
        store.set(configPath, forKey: Keys.configPath)
        for (key, value) in [(Keys.commitDelay, commitDelay), (Keys.idleTimeout, idleTimeout),
                             (Keys.longPressCancel, longPressCancel)] {
            if let value { store.set(value, forKey: key) } else { store.removeObject(forKey: key) }
        }
        store.set(defaultCalendarID, forKey: Keys.defaultCalendar)
        store.set(defaultReminderListID, forKey: Keys.defaultReminderList)
        store.set(brightness, forKey: Keys.brightness)
        store.set(dryRun, forKey: Keys.dryRun)
        store.set(copySelection, forKey: Keys.copySelection)
    }
}

extension OverlayPlacement {
    init(storageKey: String) {
        switch storageKey {
        case "main": self = .mainScreen
        case let key where key.hasPrefix("display:"): self = .display(String(key.dropFirst("display:".count)))
        default: self = .screenWithCursor
        }
    }

    var storageKey: String {
        switch self {
        case .screenWithCursor: return "pointer"
        case .mainScreen: return "main"
        case .display(let name): return "display:" + name
        }
    }
}

/// What the settings window can ask the app to do.
struct SettingsActions {
    var testOverlay: () -> Void
    var requestCalendarAccess: () async -> Void
    var reloadConfig: () -> Void
    var loadCalendarChoices: () async -> (calendars: [EventKitService.Choice], lists: [EventKitService.Choice])
    var setOpenAtLogin: (Bool) -> Void
    /// Opens the troubleshooter on a keypad, by unique ID or model; nil for
    /// every one that's missing.
    var troubleshoot: (String?) -> Void
    var forgetKeypad: (String) -> Void
}

/// A keypad Settings shows as not connected.
struct MissingKeypad: Identifiable, Equatable {
    let keypad: SoughtKeypad
    /// Known from having been plugged in, rather than named in the tree.
    let canForget: Bool

    var id: String { keypad.serial ?? keypad.model?.rawValue ?? keypad.name }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let settings: AppSettings
    private let actions: SettingsActions

    init(settings: AppSettings, actions: SettingsActions) {
        self.settings = settings
        self.actions = actions
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(settings: settings, actions: actions))
            let window = NSWindow(contentViewController: hosting)
            window.title = "KeybowNotes Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("KeybowNotesSettings")
            self.window = window
            WindowSnapshots.keep(window, as: "settings")
        }
        window?.bringToFront()
    }

    func windowWillClose(_ notification: Notification) {
        // Hand focus back to whatever was in use before.
        NSApp.hide(nil)
    }
}
