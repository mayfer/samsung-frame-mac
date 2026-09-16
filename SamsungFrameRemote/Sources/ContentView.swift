import SwiftUI

enum SleepWakePowerMode: String, CaseIterable {
    case off
    case short
    case medium
    case long

    var label: String {
        switch self {
        case .off: return "Off"
        case .short: return "Short press"
        case .medium: return "Medium press"
        case .long: return "Long press"
        }
    }

    var press: PowerPress? {
        switch self {
        case .off: return nil
        case .short: return .click
        case .medium: return .medium
        case .long: return .long
        }
    }
}

enum BannerKind {
    case info
    case success
    case warning
    case error
}

enum ShortcutMode: String, CaseIterable {
    case power, art
    var label: String { self == .power ? "Power mode" : "Art mode" }
    func label(for action: PowerShortcutAction) -> String {
        if self == .power { return action.label }
        return action == .powerOn ? "Enter Art" : "Exit Art"
    }
}

struct CommandEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let text: String
}

@MainActor
final class AppViewModel: ObservableObject {
    static weak var shared: AppViewModel?
    @Published var history: [CommandEntry] = []
    @Published var shortcutMode = ShortcutMode(rawValue: UserDefaults.standard.string(forKey: "shortcut_mode") ?? "power") ?? .power {
        didSet {
            UserDefaults.standard.set(shortcutMode.rawValue, forKey: "shortcut_mode")
            configureIdleTimer()
        }
    }
    @Published var idleEnabled = UserDefaults.standard.bool(forKey: "idle_enabled") {
        didSet { UserDefaults.standard.set(idleEnabled, forKey: "idle_enabled"); configureIdleTimer() }
    }
    @Published var idleMinutes = max(1, min(240, (UserDefaults.standard.object(forKey: "idle_minutes") as? Int) ?? 5)) {
        didSet {
            idleMinutes = max(1, min(240, idleMinutes))
            UserDefaults.standard.set(idleMinutes, forKey: "idle_minutes")
            configureIdleTimer()
        }
    }
    @Published var idleResumeViewing = (UserDefaults.standard.object(forKey: "idle_resume_viewing") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(idleResumeViewing, forKey: "idle_resume_viewing")
            if !idleResumeViewing { idleRestore = nil; idleRestoreRequested = false }
        }
    }
    private let idleCoordinator = IdleCoordinator()
    private var idleRestore: String?
    private var idleRestoreRequested = false
    @Published var discoveredTVs: [DetectedTV] = []
    @Published var selectedIP: String = ""
    @Published var manualIP: String = ""
    @Published var manualMac: String = ""
    @Published var sleepWakeMode: SleepWakePowerMode = .off
    @Published var isScanning = false
    @Published var isRunningCommand = false
    @Published var bannerText = "Ready"
    @Published var bannerKind: BannerKind = .info
    @Published var commandToken: Int = 0

    private let scanner = TVScanner()
    private let controller = SamsungTVController()
    private let sleepWake = SleepWakeCoordinator()
    private let macCache = MACCacheStore()

    private let selectedIPKey = "selected_tv_ip"
    private let manualMacKey = "manual_tv_mac"
    private let sleepWakeModeKey = "sleep_wake_mode"

    init() {
        Self.shared = self
        selectedIP = UserDefaults.standard.string(forKey: selectedIPKey) ?? ""
        manualIP = selectedIP
        manualMac = macCache.get(for: selectedIP) ?? UserDefaults.standard.string(forKey: manualMacKey) ?? ""

        if let modeRaw = UserDefaults.standard.string(forKey: sleepWakeModeKey),
           let mode = SleepWakePowerMode(rawValue: modeRaw) {
            sleepWakeMode = mode
        }

        sleepWake.onSleep = { [weak self] in
            self?.handleSleepWakeEvent(label: "sleep")
        }
        sleepWake.onWake = { [weak self] in
            self?.handleSleepWakeEvent(label: "wake")
        }

        applySleepWakeState()
        idleCoordinator.canRun = { [weak self] in
            guard let self else { return false }
            return !self.isRunningCommand && !self.isScanning && !self.selectedIP.isEmpty
        }
        idleCoordinator.onIdle = { [weak self] in self?.handleIdle() }
        idleCoordinator.onActivity = { [weak self] in
            guard let self, self.idleResumeViewing, self.idleRestore != nil else { return }
            self.idleRestoreRequested = true
        }
        idleCoordinator.onTick = { [weak self] in self?.resumeAfterIdleIfNeeded() }
        configureIdleTimer()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.selectedIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.scanForTVs()
            } else {
                self.discoveredTVs = self.devicesIncludingSavedSelection(from: self.discoveredTVs)
            }
        }
    }

    var selectionSummary: String {
        let ip = selectedIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ip.isEmpty else {
            return "No TV selected"
        }

        let discoveredMac = discoveredTVs.first(where: { $0.ipAddress == ip })?.macAddress
        let cachedMac = macCache.get(for: ip)
        let resolvedMac = discoveredMac ?? cachedMac ?? manualMac.trimmingCharacters(in: .whitespacesAndNewlines)
        let macSuffix = resolvedMac.isEmpty ? "" : "  MAC: \(resolvedMac)"

        return "Selected: \(ip)\(macSuffix)"
    }

    func scanForTVs() {
        guard !isScanning else { return }

        isScanning = true
        setBanner("Searching for TVs...", kind: .info)

        scanner.scan(timeout: 8.0) { [weak self] devices in
            guard let self else { return }
            self.isScanning = false
            let deduped = self.normalizedDevices(devices)
            self.discoveredTVs = self.devicesIncludingSavedSelection(from: deduped)

            if deduped.isEmpty {
                self.setBanner("No TVs found. Use 'Enter manually' if needed.", kind: .warning)
                return
            }

            if deduped.count == 1 {
                self.selectIP(deduped[0].ipAddress)
            } else if !deduped.contains(where: { $0.ipAddress == self.selectedIP }) {
                self.selectIP(deduped[0].ipAddress)
            }

            self.setBanner("Found \(deduped.count) TV(s).", kind: .success)
        }
    }

    func selectIP(_ ip: String) {
        selectedIP = ip
        manualIP = ip
        UserDefaults.standard.set(ip, forKey: selectedIPKey)

        let detectedMac = discoveredTVs.first(where: { $0.ipAddress == ip })?.macAddress
        let cachedMac = macCache.get(for: ip)
        let resolvedMac = detectedMac ?? cachedMac ?? ""
        manualMac = resolvedMac
        UserDefaults.standard.set(resolvedMac, forKey: manualMacKey)
        if !resolvedMac.isEmpty {
            macCache.set(resolvedMac, for: ip)
        }
        discoveredTVs = devicesIncludingSavedSelection(from: discoveredTVs)

        applySleepWakeState()
        configureIdleTimer()
        setBanner("Selected TV: \(ip)", kind: .success)
    }

    func useManualIP() {
        let normalized = manualIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            setBanner("Manual IP is empty.", kind: .warning)
            return
        }

        selectIP(normalized)
    }

    func saveManualMac() {
        let normalized = manualMac.trimmingCharacters(in: .whitespacesAndNewlines)
        manualMac = normalized
        UserDefaults.standard.set(normalized, forKey: manualMacKey)

        let ip = selectedIP.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.isEmpty, !ip.isEmpty {
            macCache.set(normalized, for: ip)
        }

        setBanner(normalized.isEmpty ? "Cleared manual MAC." : "Saved MAC: \(normalized)", kind: .info)
    }

    func setSleepWakeMode(_ mode: SleepWakePowerMode) {
        sleepWakeMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: sleepWakeModeKey)
        applySleepWakeState()
        setBanner("Sleep/wake mode: \(mode.label)", kind: .info)
    }

    func resetSavedData() {
        idleEnabled = false
        sleepWakeMode = .off
        sleepWake.setActive(false)
        discoveredTVs = []
        selectedIP = ""
        manualIP = ""
        manualMac = ""

        UserDefaults.standard.removeObject(forKey: selectedIPKey)
        UserDefaults.standard.removeObject(forKey: manualMacKey)
        UserDefaults.standard.removeObject(forKey: sleepWakeModeKey)
        macCache.clear()

        Task {
            await controller.clearPersistedData()
            await MainActor.run {
                self.setBanner("Cleared saved IP/MAC/cache/tokens.", kind: .success)
            }
        }
    }

    func triggerPair() {
        runIPCommand("pair") { ip in
            try await self.controller.pair(ip: ip)
        }
    }

    func triggerState() {
        runIPCommand("state") { ip in
            let state = await self.controller.onlineState(ip: ip)
            return state.isOnline ? "online" : "offline"
        }
    }

    func triggerPower() {
        runIPCommand("power") { ip in
            try await self.controller.power(ip: ip, press: .click)
        }
    }

    func triggerPowerMedium() {
        runIPCommand("power --medium") { ip in
            try await self.controller.power(ip: ip, press: .medium)
        }
    }

    func triggerPowerLong() {
        runIPCommand("power --long") { ip in
            try await self.controller.power(ip: ip, press: .long)
        }
    }

    func triggerOn() {
        runIPCommand("on") { ip in
            let mac = self.manualMac.trimmingCharacters(in: .whitespacesAndNewlines)
            let macValue = mac.isEmpty ? nil : mac
            return try await self.controller.on(ip: ip, mac: macValue, wolPort: 9)
        }
    }

    func triggerWakeWOLOnly() {
        runIPCommand("wake-wol-only") { ip in
            let mac = self.manualMac.trimmingCharacters(in: .whitespacesAndNewlines)
            let macValue = mac.isEmpty ? nil : mac
            return try await self.controller.wakeWOL(ip: ip, mac: macValue, wolPort: 9)
        }
    }

    func triggerToHDMI() {
        runIPCommand("to-hdmi") { ip in
            try await self.controller.toHDMI(ip: ip)
        }
    }

    func triggerArtModeOn() {
        runIPCommand("art-mode-on") { ip in
            try await self.controller.artModeOn(ip: ip, mac: self.manualMac, progress: self.commandProgress)
        }
    }

    func triggerArtModeOff() {
        runIPCommand("art-mode-off") { ip in
            try await self.controller.artModeOff(ip: ip, mac: self.manualMac, progress: self.commandProgress)
        }
    }

    func triggerTesterOn() {
        runIPCommand("tester-on") { ip in
            let mac = self.manualMac.trimmingCharacters(in: .whitespacesAndNewlines)
            let macValue = mac.isEmpty ? nil : mac
            return try await self.controller.testerOn(ip: ip, mac: macValue, wolPort: 9)
        }
    }

    func triggerTesterOff() {
        runIPCommand("tester-off") { ip in
            try await self.controller.testerOff(ip: ip)
        }
    }

    func triggerKeyPowerOff() {
        runIPCommand("KEY_POWEROFF") { ip in
            try await self.controller.powerOffKey(ip: ip)
        }
    }

    private func applySleepWakeState() {
        let canActivate = sleepWakeMode != .off && !selectedIP.isEmpty
        sleepWake.setActive(canActivate)
    }

    private func currentIPOrStatus() -> String? {
        let ip = selectedIP.trimmingCharacters(in: .whitespacesAndNewlines)
        if ip.isEmpty {
            setBanner("No TV selected. Search or use Enter manually.", kind: .warning)
            return nil
        }
        return ip
    }

    private var commandProgress: TVCommandProgress {
        let token = commandToken
        return { [weak self] text in
            await MainActor.run {
                guard let self, self.isRunningCommand, self.commandToken == token else { return }
                self.setBanner(text, kind: .info)
            }
        }
    }

    private func runIPCommand(
        _ label: String,
        preserveIdleContext: Bool = false,
        onCompletion: ((Bool) -> Void)? = nil,
        command: @escaping (String) async throws -> String
    ) {
        guard !isRunningCommand else {
            setBanner("Another command is already in progress.", kind: .warning)
            return
        }

        guard let ip = currentIPOrStatus() else {
            return
        }

        if !preserveIdleContext {
            idleRestore = nil
            idleRestoreRequested = false
        }
        isRunningCommand = true
        commandToken += 1
        let token = commandToken
        setBanner("Running \(label) for \(ip)...", kind: .info)

        Task {
            do {
                let result = try await command(ip)
                await MainActor.run {
                    guard self.commandToken == token else { return }
                    self.setBanner(result, kind: .success)
                    self.isRunningCommand = false
                    onCompletion?(true)
                }
            } catch {
                await MainActor.run {
                    guard self.commandToken == token else { return }
                    self.setBanner("\(label) failed: \(error.localizedDescription)", kind: .error)
                    self.isRunningCommand = false
                    onCompletion?(false)
                }
            }
        }

    }

    func triggerArtStatus() {
        runIPCommand("Art status") { ip in try await self.controller.artStatus(ip: ip) }
    }

    func triggerShortcut(_ actions: [PowerShortcutAction]) {
        let mode = shortcutMode
        let toggle = Set(actions).count == 2
        guard let action = actions.first else { return }
        runIPCommand(toggle ? "Toggle \(mode.label)" : mode.label(for: action)) { ip in
            if mode == .art {
                return try await self.controller.changeArtMode(ip: ip, target: toggle ? nil : (action == .powerOn ? .on : .off), mac: self.manualMac, progress: self.commandProgress)
            }
            let mac = self.manualMac.trimmingCharacters(in: .whitespacesAndNewlines)
            if toggle {
                let result = try await self.controller.testerOff(ip: ip, press: .long)
                if result.localizedCaseInsensitiveContains("sent ") { return result }
                return try await self.controller.testerOn(ip: ip, mac: mac, wolPort: 9)
            }
            if action == .powerOn { return try await self.controller.on(ip: ip, mac: mac, wolPort: 9) }
            return try await self.controller.testerOff(ip: ip, press: .long)
        }
    }

    private func configureIdleTimer() {
        idleRestore = nil
        idleRestoreRequested = false
        idleCoordinator.configure(enabled: idleEnabled && !selectedIP.isEmpty, minutes: idleMinutes)
    }

    private func handleIdle() {
        guard idleEnabled, !isRunningCommand, !isScanning, !selectedIP.isEmpty else { return }
        let mode = shortcutMode
        if idleResumeViewing { idleRestore = selectedIP }
        let label = mode == .art ? "Idle: enter Art mode" : "Idle: power off"
        runIPCommand(label, preserveIdleContext: true, onCompletion: { [weak self] success in
            if !success { self?.idleRestore = nil; self?.idleRestoreRequested = false }
        }) { ip in
            let result: String
            if mode == .art {
                result = try await self.controller.artModeOn(ip: ip, mac: self.manualMac, progress: self.commandProgress)
            } else {
                result = try await self.controller.testerOff(ip: ip, press: .long)
            }
            // Do not resume a TV that this idle action did not change.
            if result.contains("already on") || result.contains("No action taken") {
                self.idleRestore = nil
                self.idleRestoreRequested = false
            }
            return result
        }
    }

    private func resumeAfterIdleIfNeeded() {
        guard idleRestoreRequested, idleResumeViewing, idleEnabled,
              !isRunningCommand, !isScanning, let restore = idleRestore,
              restore == selectedIP else { return }
        idleRestore = nil
        idleRestoreRequested = false
        runIPCommand("Activity resumed: return to viewing") { ip in
            try await self.controller.artModeOff(ip: ip, mac: self.manualMac, progress: self.commandProgress)
        }
    }

    private func handleSleepWakeEvent(label: String) {
        guard sleepWakeMode != .off else {
            return
        }

        if label == "sleep" {
            let press = sleepWakeMode.press ?? .click
            runIPCommand("\(label) automation") { ip in
                try await self.controller.testerOff(ip: ip, press: press)
            }
            return
        }

        runIPCommand("\(label) automation") { ip in
            let mac = self.manualMac.trimmingCharacters(in: .whitespacesAndNewlines)
            let macValue = mac.isEmpty ? nil : mac
            return try await self.controller.testerOn(ip: ip, mac: macValue, wolPort: 9)
        }
    }

    private func normalizedDevices(_ devices: [DetectedTV]) -> [DetectedTV] {
        var uniqueByIP: [String: DetectedTV] = [:]
        for device in devices {
            guard !device.ipAddress.isEmpty else { continue }
            if let existing = uniqueByIP[device.ipAddress] {
                if existing.macAddress == nil, device.macAddress != nil {
                    uniqueByIP[device.ipAddress] = device
                }
            } else {
                uniqueByIP[device.ipAddress] = device
            }
        }

        var result = uniqueByIP.values.sorted { $0.ipAddress < $1.ipAddress }
        for index in result.indices {
            if let mac = result[index].macAddress, !mac.isEmpty {
                macCache.set(mac, for: result[index].ipAddress)
            } else if let cachedMac = macCache.get(for: result[index].ipAddress) {
                let tv = result[index]
                result[index] = DetectedTV(
                    name: tv.name,
                    hostName: tv.hostName,
                    ipAddress: tv.ipAddress,
                    macAddress: cachedMac,
                    port: tv.port,
                    serviceType: tv.serviceType
                )
            }
        }

        return result
    }

    private func devicesIncludingSavedSelection(from devices: [DetectedTV]) -> [DetectedTV] {
        let selected = selectedIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty else { return devices }
        if devices.contains(where: { $0.ipAddress == selected }) {
            return devices
        }

        let cachedMac = macCache.get(for: selected)
        let manual = manualMac.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedMac = cachedMac ?? (manual.isEmpty ? nil : manual)

        var result = devices
        result.append(
            DetectedTV(
                name: "Saved TV",
                hostName: "saved.local",
                ipAddress: selected,
                macAddress: resolvedMac,
                port: 8002,
                serviceType: "saved"
            )
        )
        return result.sorted { $0.ipAddress < $1.ipAddress }
    }

    private func setBanner(_ text: String, kind: BannerKind) {
        history.insert(CommandEntry(text: text), at: 0)
        history = Array(history.prefix(100))
        bannerText = text
        bannerKind = kind
    }

}
