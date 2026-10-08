import AppKit
import KeybowKit
import os

/// Messages go to the unified log, so Console.app shows what a Finder-launched
/// app is doing, and to stdout when run from a terminal.
enum Log {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "io.github.cwenham.keybownotes",
                                       category: "app")

    static func info(_ message: String) {
        print(message)
        // Notice rather than info: info-level messages aren't kept on disk, so
        // `log show` and Console.app would miss them after the fact.
        logger.notice("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        print(message)
        logger.error("\(message, privacy: .public)")
    }
}

/// Only one copy may drive the Keybow: two would compete for every key press.
enum SingleInstance {
    private static var descriptor: Int32 = -1

    /// Takes the lock, or returns false when another copy holds it.
    static func acquire() -> Bool {
        try? FileManager.default.createDirectory(at: ConfigStore.supportDirectory, withIntermediateDirectories: true)
        let path = ConfigStore.supportDirectory.appendingPathComponent(".lock").path
        descriptor = open(path, O_CREAT | O_RDWR, 0o644)
        // If the lock file can't even be opened, don't stop the app over it.
        guard descriptor >= 0 else { return true }
        // Held until the process exits, which releases it even after a crash.
        return flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }
}

/// Finds, loads and watches the config: `tree.md`, compiled as it's read.
@MainActor
final class ConfigStore {
    nonisolated static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/KeybowNotes")
    }

    nonisolated static var defaultURL: URL { supportDirectory.appendingPathComponent("tree.md") }

    /// Keeps the keys dark until a usable config exists.
    static let empty = try! KeybowConfig.parse(Data(#"{ "trees": {} }"#.utf8))

    let url: URL
    private(set) var config = ConfigStore.empty
    /// Why the file couldn't be used, if it couldn't. The previous config, if
    /// any, stays in force.
    private(set) var problem: String?
    /// Mistakes in a tree that otherwise loaded: what they touch is left out.
    private(set) var mistakes = ConfigFile.Loaded(config: ConfigStore.empty, errors: [])
    /// Called after a reload, successful or not.
    var onChange: (() -> Void)?

    private var lastModified: Date?
    private var timer: Timer?

    var templatesDirectory: URL { url.deletingLastPathComponent().appendingPathComponent("templates") }

    init(url: URL) {
        self.url = url
        load()
    }

    /// On first run there is no tree, so put the bundled example and its
    /// templates where the app looks. Returns what was done, if anything.
    static func installDefaultsIfNeeded() -> String? {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: defaultURL.path),
              let bundled = Bundle.main.url(forResource: "tree.demo", withExtension: "md") else { return nil }
        do {
            try manager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            try manager.copyItem(at: bundled, to: defaultURL)
            let templates = supportDirectory.appendingPathComponent("templates")
            if let bundledTemplates = Bundle.main.url(forResource: "templates", withExtension: nil),
               !manager.fileExists(atPath: templates.path) {
                try manager.copyItem(at: bundledTemplates, to: templates)
            }
            return "Installed the example tree at \(defaultURL.path)"
        } catch {
            return "Couldn't install the example config: \(error.localizedDescription)"
        }
    }

    func reload() {
        load()
        onChange?()
    }

    /// Checks the file every couple of seconds. Polling, rather than file
    /// events, survives editors that save by replacing the file.
    func startWatching() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.modificationDate() != self.lastModified else { return }
                self.reload()
            }
        }
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    private func load() {
        lastModified = modificationDate()
        do {
            let loaded = try ConfigFile.load(url)
            config = loaded.config
            mistakes = loaded
            problem = nil
        } catch let error as ConfigError {
            problem = error.description
        } catch {
            problem = error.localizedDescription
        }
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

/// Pictures of a window as drawn, for checking a layout without screen
/// recording: development builds only, with KEYBOW_WINDOW_SNAPSHOTS=<folder>.
/// Each window writes <name>.png there every two seconds while it's open.
@MainActor
enum WindowSnapshots {
    static func keep(_ window: NSWindow, as name: String) {
        guard Bundle.main.bundleIdentifier == nil,
              let folder = ProcessInfo.processInfo.environment["KEYBOW_WINDOW_SNAPSHOTS"] else { return }
        let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name).png")
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak window] timer in
            MainActor.assumeIsolated {
                guard let window, window.isVisible, let view = window.contentView else { return timer.invalidate() }
                // Drawn into layers from the next time on, so they can be pictured.
                if view.layer == nil { view.wantsLayer = true }
                // The layers, as drawn: caching the display leaves SwiftUI's text out.
                guard let layer = view.layer, let picture = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: picture) else { return }
                let cg = context.cgContext
                cg.setFillColor(NSColor.windowBackgroundColor.cgColor)
                cg.fill(CGRect(x: 0, y: 0, width: picture.pixelsWide, height: picture.pixelsHigh))
                cg.translateBy(x: 0, y: CGFloat(picture.pixelsHigh))
                cg.scaleBy(x: 2, y: -2)
                layer.render(in: cg)
                try? picture.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
    }
}
