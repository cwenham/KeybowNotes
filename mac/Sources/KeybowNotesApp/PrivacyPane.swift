import AppKit
import Contacts
import CoreLocation
import CoreServices
import EventKit
import KeybowAI
import KeybowKit
import KeybowLocation
import SwiftUI

/// Settings → Privacy: what macOS lets KeybowNotes do, each asked for from
/// one place, and what Claude is sent.
struct PrivacyPane: View {
    /// Watched by the window while this page shows.
    let access: MacAccess
    @State private var sharing = (ModuleRegistry.shared.module(id: ClaudeModule.id) as? ClaudeModule)?.sharing
        ?? ClaudeModule.Sharing()

    /// Kept as it's changed.
    private var shared: Binding<ClaudeModule.Sharing> {
        Binding(get: { sharing }, set: { changed in
            sharing = changed
            for (key, value) in changed.settings { Modules.host.setSetting(value, key, for: ClaudeModule.id) }
        })
    }

    var body: some View {
        Section {
            ForEach(Permission.allCases) { permission in
                PermissionRow(title: permission.title, symbol: permission.symbol, purpose: permission.purpose,
                              state: access.states[permission] ?? .checking,
                              asking: access.asking.contains(permission.rawValue),
                              canAsk: access.canAsk(permission), anchor: permission.anchor,
                              note: access.notes[permission.rawValue]) {
                    Task { await access.ask(permission) }
                }
            }
        } header: {
            Text("What macOS Lets KeybowNotes Do")
        } footer: {
            Text("macOS asks once about each, the first time it's needed — or now, with Allow. Once answered, it can "
                 + "only be changed in System Settings → Privacy & Security.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        Section {
            ForEach(ScriptedApp.all) { app in
                PermissionRow(title: app.name, symbol: "applescript", purpose: app.purpose,
                              state: access.automation[app.bundleID] ?? .checking,
                              asking: access.asking.contains(app.bundleID), canAsk: true,
                              anchor: "Privacy_Automation", note: nil) {
                    Task { await access.ask(app) }
                }
            }
        } header: {
            Text("Apps KeybowNotes Controls")
        } footer: {
            Text("macOS says how it stands only for an app that's open: Ask Now opens it out of the way to ask. Apps "
                 + "that control KeybowNotes — an AI agent's, Shortcuts, a script — are asked about in the same place.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        claude
    }

    // MARK: - What Claude is sent

    @ViewBuilder
    private var claude: some View {
        Section {
            Toggle(isOn: shared.tree) {
                Text("My tree file")
                Text("Its keys, and the contacts, projects and lists in it, so a draft fits with them.")
            }
            Toggle(isOn: shared.apps) {
                Text("The names of my apps and shortcuts")
                Text("So keys open what's installed, and run shortcuts that are there.")
            }
            Toggle(isOn: shared.home) {
                Text("My Home Assistant devices")
                Text("Their names and entity IDs, so keys switch what's in the home.")
            }
        } header: {
            Text("Designing Keypads with Claude")
        } footer: {
            Text("What you write in the conversation always goes, with which keypads are plugged in. It goes to "
                 + "Anthropic, with your API key.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        Section {
            Picker("Claude may see", selection: shared.music.detail) {
                ForEach(MusicSharing.Detail.allCases, id: \.self) { detail in
                    Text(Self.title(detail)).tag(detail)
                }
            }
            .pickerStyle(.radioGroup)
            Toggle("And my playlists' names", isOn: shared.music.playlists)
                .disabled(!sharing.music.isShared)
            Text(Self.explanation(sharing.music))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("My Music Library")
        } footer: {
            Text("Claude looks only when it makes music keys, and sees only what it asks for. AI agents asking through "
                 + "KeybowNotes' MCP server or AppleScript see no more than this either.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        Section {
            Toggle(isOn: shared.selection) {
                Text("The selected text")
                Text("{{selection}}")
            }
            Toggle(isOn: shared.clipboard) {
                Text("The clipboard")
                Text("{{clipboard}}")
            }
            Toggle(isOn: shared.media) {
                Text("Images and PDFs on the clipboard")
                Text("When {{clipboard}} holds a screenshot or a document, rather than text.")
            }
            .disabled(!sharing.clipboard)
            Toggle(isOn: shared.location) {
                Text("Where I am")
                Text("{{location}} and its parts — as exactly as Settings → Location says.")
            }
            Toggle(isOn: shared.calendar) {
                Text("My meetings and reminders")
                Text("{{event}}, {{agenda}} and {{reminder}}: titles, times, who's invited, notes and links.")
            }
        } header: {
            Text("Keys That Ask Claude")
        } footer: {
            Text("What a {{#ai}} block may send. A key whose block uses something unticked doesn't run, and says why. "
                 + "The block's own words always go, and anything else it fills in. Data Sources' Find It sends "
                 + "Claude the page it's looking at.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func title(_ detail: MusicSharing.Detail) -> String {
        switch detail {
        case .nothing: return "Nothing"
        case .genres: return "Its genres"
        case .artists: return "Its genres and artists"
        case .albums: return "Its genres, artists and albums"
        case .songs: return "All of it, down to each song"
        }
    }

    static func explanation(_ sharing: MusicSharing) -> String {
        let seen: String
        switch sharing.detail {
        case .nothing: return "Claude isn't told there's a library. The tree editor lists your music all the same."
        case .genres: seen = "your genres"
        case .artists: seen = "your genres, and the artists in each"
        case .albums: seen = "your genres, the artists in each, and their albums"
        case .songs: seen = "your genres, artists and albums, and every song — your favourites among them"
        }
        return "Claude can see \(seen), with how many songs and how often they're played."
            + (sharing.playlists ? " And your playlists' names, with how many songs each has." : "")
    }
}

/// One thing macOS asks about: what it's for, how it stands, and a way to
/// ask or to change it.
private struct PermissionRow: View {
    let title: String
    let symbol: String
    let purpose: String
    let state: AccessState
    let asking: Bool
    let canAsk: Bool
    /// Its page in System Settings → Privacy & Security.
    let anchor: String
    let note: String?
    let ask: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(purpose).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    Text(note).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Label(state.label, systemImage: state.symbol)
                .font(.callout)
                .foregroundStyle(state.kind == .allowed ? Color.green : state.kind == .refused ? .orange : .secondary)
                .fixedSize()
            button.controlSize(.small).fixedSize()
        }
    }

    @ViewBuilder
    private var button: some View {
        if asking {
            ProgressView().controlSize(.small)
        } else {
            switch state.kind {
            case .askable:
                Button("Allow…", action: ask)
            case .unknown where canAsk:
                Button("Ask Now", action: ask)
            case .refused, .unknown:
                Button("Open Settings…") { Self.open(anchor) }
            case .allowed, .checking, .unavailable:
                EmptyView()
            }
        }
    }

    static func open(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - What macOS says

/// How one permission stands, as far as macOS will say.
struct AccessState: Equatable {
    enum Kind { case allowed, askable, refused, unknown, checking, unavailable }

    let kind: Kind
    let label: String

    static let allowed = AccessState(kind: .allowed, label: "Allowed")
    static let notAsked = AccessState(kind: .askable, label: "Not asked yet")
    static let notAllowed = AccessState(kind: .refused, label: "Not allowed")
    static let whenUsed = AccessState(kind: .unknown, label: "Asked when first used")
    static let checking = AccessState(kind: .checking, label: "Checking…")
    static let installedOnly = AccessState(kind: .unavailable, label: "In the installed app")

    var symbol: String {
        switch kind {
        case .allowed: return "checkmark.circle.fill"
        case .askable: return "questionmark.circle"
        case .refused: return "xmark.circle.fill"
        case .unknown: return "circle.dashed"
        case .checking: return "ellipsis.circle"
        case .unavailable: return "minus.circle"
        }
    }

    /// What macOS says about sending an app Apple Events.
    init(automation status: OSStatus) {
        switch status {
        case 0: self = .allowed                                     // noErr
        case -1744: self = .notAsked                                // errAEEventWouldRequireUserConsent
        case -1743: self = .notAllowed                              // errAEEventNotPermitted
        case -600: self = .init(kind: .unknown, label: "Not open")  // procNotFound: it says only for an open app
        default: self = .init(kind: .unknown, label: "Unknown")
        }
    }

    init(kind: Kind, label: String) {
        self.kind = kind
        self.label = label
    }
}

/// What macOS asks about, apart from controlling other apps.
enum Permission: String, CaseIterable, Identifiable {
    case accessibility, calendars, reminders, contacts, location, music, localNetwork, drives

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .calendars: return "Calendars"
        case .reminders: return "Reminders"
        case .contacts: return "Contacts"
        case .location: return "Location Services"
        case .music: return "Media & Apple Music"
        case .localNetwork: return "Local Network"
        case .drives: return "Removable Volumes"
        }
    }

    var symbol: String {
        switch self {
        case .accessibility: return "accessibility"
        case .calendars: return "calendar"
        case .reminders: return "checklist"
        case .contacts: return "person.crop.circle"
        case .location: return "location.fill"
        case .music: return "music.note"
        case .localNetwork: return "network"
        case .drives: return "externaldrive"
        }
    }

    var purpose: String {
        switch self {
        case .accessibility: return "Reads the selected text for {{selection}}, types and pastes into apps, and moves windows."
        case .calendars:
            return "Adds the events your keys make, reads your meetings for {{event}} and {{agenda}}, and lists your calendars."
        case .reminders:
            return "Adds the reminders your keys make, reads and ticks off those due for {{reminder}}, and lists your lists."
        case .contacts: return "Looks people up when you add them in the tree editor."
        case .location: return "Puts where you are into keys that use {{location}}, only when one's pressed."
        case .music: return "Lists your music in the tree editor, and lets Claude look through as much as you share below."
        case .localNetwork: return "Reaches Home Assistant on your network."
        case .drives: return "Puts CircuitPython and the firmware on a keypad's drive, in Set Up a Keypad."
        }
    }

    /// Its page in System Settings → Privacy & Security.
    var anchor: String {
        switch self {
        case .accessibility: return "Privacy_Accessibility"
        case .calendars: return "Privacy_Calendars"
        case .reminders: return "Privacy_Reminders"
        case .contacts: return "Privacy_Contacts"
        case .location: return "Privacy_LocationServices"
        case .music: return "Privacy_Media"
        case .localNetwork: return "Privacy_LocalNetwork"
        case .drives: return "Privacy_FilesAndFolders"
        }
    }
}

/// An app KeybowNotes scripts, which macOS asks about under Automation.
/// Calendar and Reminders aren't among them: the installed app uses
/// EventKit, asked about above.
struct ScriptedApp: Identifiable {
    let name: String
    let bundleID: String
    let purpose: String

    var id: String { bundleID }

    static let all = [
        ScriptedApp(name: "Notes", bundleID: "com.apple.Notes", purpose: "Makes notes, and adds to them."),
        ScriptedApp(name: "Mail", bundleID: "com.apple.mail", purpose: "Drafts emails. Nothing is sent."),
        ScriptedApp(name: "Music", bundleID: "com.apple.Music",
                    purpose: "Plays songs, albums, artists, genres and playlists."),
    ]
}

/// What macOS lets KeybowNotes do, looked at again and again while the page
/// shows — System Settings says nothing when it changes — and asked for.
@MainActor @Observable
final class MacAccess {
    private(set) var states: [Permission: AccessState] = [:]
    /// By bundle ID.
    private(set) var automation: [String: AccessState] = [:]
    /// What's being asked about, by permission or bundle ID: its button waits.
    private(set) var asking: Set<String> = []
    /// Why a check failed, by permission.
    private(set) var notes: [String: String] = [:]
    /// Home Assistant has a token: there's something to reach.
    private var homeIsSetUp = false

    /// While the page shows: System Settings says nothing when something's
    /// allowed there, so it's looked at again every couple of seconds.
    func watch() async {
        homeIsSetUp = Modules.host.hasSecret("token", for: "home")
        refresh()
        await checkMusic(askingFirst: false)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            refresh()
        }
    }

    func refresh() {
        states[.accessibility] = SelectedText.isAllowed ? .allowed : AccessState(kind: .askable, label: "Not allowed")
        states[.calendars] = eventKit(.event)
        states[.reminders] = eventKit(.reminder)
        states[.contacts] = contacts
        states[.location] = location
        // Known only by trying: see checkMusic and checkHome.
        if states[.music] == nil {
            states[.music] = MusicLibrary.canAsk ? AccessState(kind: .askable, label: "Not checked yet") : .installedOnly
        }
        if states[.localNetwork] == nil { states[.localNetwork] = .whenUsed }
        states[.drives] = .whenUsed
        Task { await refreshAutomation() }
    }

    /// Whether its button can ask, rather than only open System Settings.
    func canAsk(_ permission: Permission) -> Bool {
        switch permission {
        case .localNetwork: return homeIsSetUp
        case .drives: return false
        default: return true
        }
    }

    func ask(_ permission: Permission) async {
        asking.insert(permission.rawValue)
        defer {
            asking.remove(permission.rawValue)
            refresh()
        }
        // The prompts belong to a menu-bar app that isn't in front, and can
        // open behind other windows: coming forward brings them too.
        NSApp.activate()
        switch permission {
        case .accessibility: SelectedText.requestAccess()
        case .calendars: try? await EventKitService.shared.ensureAccess(to: .event)
        case .reminders: try? await EventKitService.shared.ensureAccess(to: .reminder)
        case .contacts: _ = await ContactsService.shared.requestAccess()
        case .location: await CoreLocationProvider.shared.requestAccess()
        case .music: await checkMusic(askingFirst: true)
        case .localNetwork: await checkHome()
        case .drives: break
        }
    }

    // MARK: Each

    private func eventKit(_ type: EKEntityType) -> AccessState {
        guard EventKitService.isAvailable else { return .installedOnly }
        switch EventKitService.status(for: type) {
        case .fullAccess: return .allowed
        case .notDetermined: return .notAsked
        case .writeOnly: return AccessState(kind: .refused, label: "Adding only")
        default: return .notAllowed
        }
    }

    private var contacts: AccessState {
        guard ContactsService.isAvailable else { return .installedOnly }
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined: return .notAsked
        case .denied, .restricted: return .notAllowed
        default: return .allowed
        }
    }

    private var location: AccessState {
        // Without a usage description there's no asking: development builds.
        guard Bundle.main.object(forInfoDictionaryKey: "NSLocationUsageDescription") != nil else { return .installedOnly }
        switch CoreLocationProvider.shared.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return .allowed
        case .notDetermined: return .notAsked
        case .restricted: return AccessState(kind: .refused, label: "Restricted")
        default: return .notAllowed
        }
    }

    /// macOS says nothing about the Music library: reading it is the only
    /// way to find out — and, the first time, to ask. So it's read only once
    /// macOS has been asked, unless `askingFirst`.
    func checkMusic(askingFirst: Bool) async {
        guard MusicLibrary.canAsk, askingFirst || MusicLibrary.hasAsked else { return }
        states[.music] = .checking
        do {
            _ = try await MusicLibrary.shared.contents()
            states[.music] = .allowed
        } catch {
            states[.music] = .notAllowed
        }
    }

    /// Nor about the local network: macOS asks the first time Home Assistant
    /// is reached, so reaching it is the way to ask.
    private func checkHome() async {
        guard let home = ModuleRegistry.shared.module(id: "home") else { return }
        states[.localNetwork] = .checking
        notes[Permission.localNetwork.rawValue] = nil
        do {
            _ = try await home.choices(for: "entity", type: "home", fields: [:])
            states[.localNetwork] = AccessState(kind: .allowed, label: "Home Assistant answered")
        } catch {
            states[.localNetwork] = AccessState(kind: .refused, label: "Not reached")
            notes[Permission.localNetwork.rawValue] = "\(error)"
        }
    }

    // MARK: Automation

    private func refreshAutomation() async {
        let ids = ScriptedApp.all.map(\.bundleID)
        let found = await Task.detached {
            ids.map { ($0, MacAccess.automationStatus($0, ask: false)) }
        }.value
        for (id, status) in found where !asking.contains(id) { automation[id] = AccessState(automation: status) }
    }

    func ask(_ app: ScriptedApp) async {
        let id = app.bundleID
        asking.insert(id)
        defer { asking.remove(id) }
        // macOS answers only for an app that's open: open it, out of sight.
        if !Self.isOpen(id), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            var waited = 0
            while !Self.isOpen(id), waited < 50 {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
        }
        NSApp.activate()
        let status = await Task.detached { MacAccess.automationStatus(id, ask: true) }.value
        automation[id] = AccessState(automation: status)
    }

    private static func isOpen(_ bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { $0.isFinishedLaunching }
    }

    /// Whether KeybowNotes may send the app Apple Events — asking, once,
    /// with `ask`, which waits for the answer. Off the main thread.
    nonisolated static func automationStatus(_ bundleID: String, ask: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        return withExtendedLifetime(target) {
            AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
        }
    }
}
