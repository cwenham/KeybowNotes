import Foundation
import KeybowKit

extension ClaudeModule {
    /// What the person lets Claude see, as chosen in Settings → Privacy. Kept
    /// with the module's settings, and everything until they say otherwise —
    /// as it was before there was a choice.
    public struct Sharing: Equatable, Sendable {
        // Designing trees: what goes with the first request.

        /// The tree file, with its contacts, projects and lists.
        public var tree = true
        /// The names of the apps and shortcuts on this Mac.
        public var apps = true
        /// Home Assistant's entities: what's in the home, and what each is called.
        public var home = true
        /// How much of the Music library Claude may look through — and agents,
        /// through AppleScript and the MCP server.
        public var music = MusicSharing.everything

        // {{#ai}} blocks: what a key may send in one.

        /// `{{selection}}`.
        public var selection = true
        /// `{{clipboard}}`.
        public var clipboard = true
        /// An image or PDF that `{{clipboard}}` holds.
        public var media = true
        /// `{{location}}` and its parts.
        public var location = true
        /// `{{event}}`, `{{agenda}}` and `{{reminder}}`, and their parts: the
        /// person's meetings, who's in them, and what they've to do.
        public var calendar = true

        public init() {}

        /// As kept: `setting` reads one of the module's settings.
        public init(setting: (String) -> String?) {
            func flag(_ key: String) -> Bool { setting(key) != "false" }
            tree = flag(Key.tree)
            apps = flag(Key.apps)
            home = flag(Key.home)
            music = MusicSharing(setting(Key.music).flatMap(MusicSharing.Detail.init(rawValue:)) ?? .songs,
                                 playlists: flag(Key.playlists))
            selection = flag(Key.selection)
            clipboard = flag(Key.clipboard)
            media = flag(Key.media)
            location = flag(Key.location)
            calendar = flag(Key.calendar)
        }

        /// Each setting as it's kept: nil where it's as it was to begin with.
        public var settings: [(key: String, value: String?)] {
            func flag(_ on: Bool) -> String? { on ? nil : "false" }
            return [
                (Key.tree, flag(tree)), (Key.apps, flag(apps)), (Key.home, flag(home)),
                (Key.music, music.detail == .songs ? nil : music.detail.rawValue), (Key.playlists, flag(music.playlists)),
                (Key.selection, flag(selection)), (Key.clipboard, flag(clipboard)), (Key.media, flag(media)),
                (Key.location, flag(location)), (Key.calendar, flag(calendar)),
            ]
        }

        enum Key {
            static let tree = "share.tree"
            static let apps = "share.apps"
            static let home = "share.home"
            static let music = "share.music"
            static let playlists = "share.playlists"
            static let selection = "send.selection"
            static let clipboard = "send.clipboard"
            static let media = "send.media"
            static let location = "send.location"
            static let calendar = "send.calendar"
        }

        /// Of the names used in a block, the first that's kept from Claude,
        /// and what it is in words: ("selection", "the selected text").
        public func kept(of names: Set<String>) -> (name: String, what: String)? {
            for name in names.sorted() {
                if name == "selection", !selection { return (name, "the selected text") }
                if name == "clipboard", !clipboard { return (name, "the clipboard") }
                if name == "location" || name.hasPrefix("location."), !location { return (name, "where you are") }
                if Self.isCalendar(name), !calendar { return (name, "your calendar and reminders") }
            }
            return nil
        }

        /// `event`, `agenda.today`, `reminder.due`: what the Meetings and
        /// Agenda module reads from the calendar.
        static func isCalendar(_ name: String) -> Bool {
            ["event", "agenda", "reminder"].contains { name == $0 || name.hasPrefix($0 + ".") }
        }
    }
}
