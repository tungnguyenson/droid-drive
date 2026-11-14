import DeviceService
import Foundation
import ServiceManagement

/// App-wide settings (spec §7), stored in the app's UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    static let defaultNotifyThresholdMB = 500

    private let defaults: UserDefaults

    /// "Mount automatically when a phone connects", on by default.
    @Published var autoMount: Bool { didSet { defaults.set(autoMount, forKey: Keys.autoMount) } }
    /// "Preferred mode when both MTP and ADB are available": ADB by default. Takes effect
    /// once the MTP source exists (phase 2).
    @Published var preferMTP: Bool { didSet { defaults.set(preferMTP, forKey: Keys.preferMTP) } }
    @Published var defaultRefresh: RefreshInterval {
        didSet { defaults.set(defaultRefresh.rawValue, forKey: Keys.defaultRefresh) }
    }
    @Published var notifyLargeTransfers: Bool {
        didSet { defaults.set(notifyLargeTransfers, forKey: Keys.notifyLarge) }
    }
    @Published var notifyThresholdMB: Int { didSet { defaults.set(notifyThresholdMB, forKey: Keys.notifyThreshold) } }
    /// Phones connected before, with their per-device settings.
    @Published private(set) var known: KnownDevices
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoMount = defaults.object(forKey: Keys.autoMount) as? Bool ?? true
        preferMTP = defaults.bool(forKey: Keys.preferMTP)
        defaultRefresh = (defaults.object(forKey: Keys.defaultRefresh) as? Int).flatMap(RefreshInterval.init) ?? .default
        notifyLargeTransfers = defaults.object(forKey: Keys.notifyLarge) as? Bool ?? true
        notifyThresholdMB = defaults.object(forKey: Keys.notifyThreshold) as? Int ?? Self.defaultNotifyThresholdMB
        known = KnownDevices(data: defaults.data(forKey: Keys.known))
    }

    func refreshInterval(for serial: String) -> RefreshInterval {
        known[serial]?.refreshInterval ?? defaultRefresh
    }

    /// nil follows the app-wide default.
    func setRefreshInterval(_ interval: RefreshInterval?, for serial: String) {
        update(known.setting(interval, for: serial))
    }

    func update(_ newValue: KnownDevices) {
        guard newValue != known else { return }
        known = newValue
        defaults.set(newValue.data, forKey: Keys.known)
    }

    /// Spec §7 "Open at login", registered with `SMAppService.mainApp`. Throws the
    /// system's error so the caller can show it.
    func setLaunchAtLogin(_ enabled: Bool) throws {
        defer { launchAtLogin = SMAppService.mainApp.status == .enabled }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Registers "Open at login" once, on the first launch (spec §7: on by default).
    /// Debug builds skip it, so a development build never lands in the user's login items.
    func applyFirstLaunchDefaults() throws {
        #if DEBUG
        return
        #endif
        guard !defaults.bool(forKey: Keys.firstLaunchDone) else { return }
        defaults.set(true, forKey: Keys.firstLaunchDone)
        if SMAppService.mainApp.status != .enabled { try setLaunchAtLogin(true) }
    }

    private enum Keys {
        static let autoMount = "autoMount"
        static let preferMTP = "preferMTP"
        static let defaultRefresh = "defaultRefreshSeconds"
        static let notifyLarge = "notifyLargeTransfers"
        static let notifyThreshold = "notifyThresholdMB"
        static let known = "knownDevices"
        static let firstLaunchDone = "firstLaunchDone"
    }
}
