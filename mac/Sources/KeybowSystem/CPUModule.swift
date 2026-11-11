import AppKit
import Darwin
import Foundation
import KeybowKit

/// The CPU's load, live, on a key of a keypad with screens:
///
///   # pinned
///   1. CPU [CPU]
///
/// The key shows how busy the processor is — all its cores together, as a
/// share of what they could do — as a number and a fill rising from the
/// bottom, looked at again every second. Pressing it opens Activity Monitor,
/// or brings it forward if it's open.
public final class CPUModule: KeybowModule, @unchecked Sendable {
    public static let id = "cpu"
    static let activityMonitor = "com.apple.ActivityMonitor"

    public let manifest = ModuleManifest(
        id: id, name: "CPU",
        actionTypes: [
            ModuleActionType(
                type: "cpu", title: "CPU load", keywords: ["CPU"], symbol: "cpu", fields: [],
                needsDisplay: true),
        ],
        symbol: "cpu")

    private let sampler: CPUSampler
    private let openApp: @Sendable (String) async -> Bool
    private let lock = NSLock()
    private var last: CPUTicks?

    public init(sampler: CPUSampler = HostCPUSampler(),
                openApp: @escaping @Sendable (String) async -> Bool = CPUModule.open) {
        self.sampler = sampler
        self.openApp = openApp
    }

    public func start(host: ModuleHost) {}

    /// On the press: it's a look at what's going on, nothing to cancel.
    public func firesAtOnce(_ request: ModuleRequest) -> Bool { true }

    public func summary(of request: ModuleRequest, now: Date) -> ModuleSummary {
        ModuleSummary(verb: "Open", subject: "Activity Monitor")
    }

    public func run(_ request: ModuleRequest, now: Date) async -> ActionOutcome {
        await openApp(Self.activityMonitor) ? .success("Activity Monitor") : .failure("Activity Monitor didn't open")
    }

    // MARK: - Live

    public func liveInterval(for key: LiveKeySpec) -> TimeInterval? { key.type == "cpu" ? 1 : nil }

    public func reading(for key: LiveKeySpec, now: Date) async -> LiveKeyReading? {
        guard key.type == "cpu", let ticks = sampler.ticks() else { return nil }
        let previous = lock.withLock { () -> CPUTicks? in
            defer { last = ticks }
            return last
        }
        // The first look has nothing to compare with: since the Mac started.
        let load = ticks.load(since: previous)
        return Self.reading(load)
    }

    public func standInReading(for key: LiveKeySpec) -> LiveKeyReading? {
        key.type == "cpu" ? Self.reading(0.42) : nil
    }

    static func reading(_ load: Double) -> LiveKeyReading {
        LiveKeyReading(value: "\(Int((load * 100).rounded()))%", caption: "CPU", level: load)
    }

    /// Opens an app by bundle ID, or brings it forward.
    public static func open(_ bundleID: String) async -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return (try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)) != nil
    }
}

/// The processor's time since the Mac started, by what it was doing.
public struct CPUTicks: Equatable, Sendable {
    public var busy: UInt64
    public var idle: UInt64

    public init(busy: UInt64, idle: UInt64) {
        self.busy = busy
        self.idle = idle
    }

    /// The share of time busy between then and now, 0 to 1.
    public func load(since earlier: CPUTicks?) -> Double {
        let busy = self.busy &- (earlier?.busy ?? 0)
        let idle = self.idle &- (earlier?.idle ?? 0)
        let total = busy &+ idle
        // A counter that went backwards (wrapped, or a new Mac) tells us nothing.
        guard total > 0, busy <= total else { return 0 }
        return Double(busy) / Double(total)
    }
}

public protocol CPUSampler: Sendable {
    func ticks() -> CPUTicks?
}

/// All cores together, from the kernel's counts.
public struct HostCPUSampler: CPUSampler {
    public init() {}

    public func ticks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return CPUTicks(busy: user + system + nice, idle: idle)
    }
}
