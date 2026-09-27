import AppKit
import Contacts
import KeybowKit

/// The apps installed on this Mac, for the app picker.
@MainActor
enum AppCatalog {
    struct App: Identifiable, Hashable {
        var id: String { url.path }
        let name: String
        let bundleIdentifier: String?
        let url: URL
    }

    /// Scanned once per run: /Applications, /System/Applications and
    /// ~/Applications, each with one level of folders (Utilities, vendor folders).
    static let all: [App] = {
        let manager = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
        var found: [String: App] = [:]
        func add(_ url: URL) {
            let name = url.deletingPathExtension().lastPathComponent
            guard found[name] == nil else { return }
            found[name] = App(name: name, bundleIdentifier: Bundle(url: url)?.bundleIdentifier, url: url)
        }
        for root in roots {
            let entries = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for entry in entries {
                if entry.pathExtension == "app" {
                    add(entry)
                } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    let inner = (try? manager.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? []
                    inner.filter { $0.pathExtension == "app" }.forEach(add)
                }
            }
        }
        return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }()

    static func named(_ name: String) -> App? {
        all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// People in the Contacts app, for filling in a contact's number and address.
/// Needs a usage description in the Info.plist, so only the packaged app can ask.
actor ContactsService {
    static let shared = ContactsService()

    struct Detail: Hashable, Sendable {
        let label: String
        let value: String
    }

    struct Match: Identifiable, Sendable {
        let id: String
        let name: String
        let organisation: String
        let phones: [Detail]
        let emails: [Detail]
    }

    enum Access: Sendable { case granted, denied, unavailable }

    nonisolated static var isAvailable: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSContactsUsageDescription") != nil
    }

    nonisolated static var isAuthorised: Bool {
        CNContactStore.authorizationStatus(for: .contacts) == .authorized
    }

    private let store = CNContactStore()

    func requestAccess() async -> Access {
        guard Self.isAvailable else { return .unavailable }
        if Self.isAuthorised { return .granted }
        let granted = (try? await store.requestAccess(for: .contacts)) ?? false
        return granted ? .granted : .denied
    }

    /// People whose name matches, best first.
    func search(_ name: String) -> [Match] {
        guard Self.isAuthorised, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        let predicate = CNContact.predicateForContacts(matchingName: name)
        let contacts = (try? store.unifiedContacts(matching: predicate, keysToFetch: keys)) ?? []
        return contacts.prefix(8).map { contact in
            func label(_ raw: String?) -> String {
                raw.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } ?? ""
            }
            return Match(
                id: contact.identifier,
                name: CNContactFormatter.string(from: contact, style: .fullName) ?? name,
                organisation: contact.organizationName,
                phones: contact.phoneNumbers.map { Detail(label: label($0.label), value: $0.value.stringValue) },
                emails: contact.emailAddresses.map { Detail(label: label($0.label), value: $0.value as String) }
            )
        }
    }
}
