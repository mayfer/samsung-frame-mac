import SwiftUI

enum SleepWakePowerMode: String, CaseIterable {
    case off
    case short
    case medium
    case long

    var label: String {
        switch self {
        case .off: return "TV controller off"
        case .short: return "Sleep: power (short)"
        case .medium: return "Sleep: power (medium)"
        case .long: return "Sleep: power (long)"
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

enum CommandTimeoutError: LocalizedError {
    case timedOut
    var errorDescription: String? { "Timed out after 3s" }
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var discoveredTVs: [DetectedTV] = []
    @Published var selectedIP: String = ""
    @Published var manualIP: String = ""
    @Published var manualMac: String = ""
    @Published var sleepWakeMode: SleepWakePowerMode = .off
    @Published var isScanning = false
    @Published var isRunningCommand = false
    @Published var showManualEntry = false
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

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.selectedIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.scanForTVs()
            } else {
                self.setBanner("Using saved TV selection. Search only if you want to refresh discovery.", kind: .info)
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

        if discoveredTVs.contains(where: { $0.ipAddress == ip }) {
            return "Selected: \(ip)\(macSuffix)"
        }
        return "Saved selection: \(ip)\(macSuffix)"
    }

    func scanForTVs() {
        guard !isScanning else { return }

        isScanning = true
        setBanner("Searching for TVs...", kind: .info)

        scanner.scan(timeout: 8.0) { [weak self] devices in
            guard let self else { return }
            self.isScanning = false
            let deduped = self.normalizedDevices(devices)
            self.discoveredTVs = deduped

            if deduped.isEmpty {
                self.setBanner("No TVs found. Use 'Enter manually' to provide IP/MAC.", kind: .warning)
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

        applySleepWakeState()
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
            try await self.controller.artModeOn(ip: ip)
        }
    }

    func triggerArtModeOff() {
        runIPCommand("art-mode-off") { ip in
            try await self.controller.artModeOff(ip: ip)
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

    private func runIPCommand(
        _ label: String,
        command: @escaping (String) async throws -> String
    ) {
        guard !isRunningCommand else {
            setBanner("Another command is already in progress.", kind: .warning)
            return
        }

        guard let ip = currentIPOrStatus() else {
            return
        }

        isRunningCommand = true
        commandToken += 1
        let token = commandToken
        setBanner("Running \(label) for \(ip)...", kind: .info)

        Task {
            do {
                let result = try await runWithTimeout(seconds: 3) {
                    try await command(ip)
                }
                await MainActor.run {
                    guard self.commandToken == token else { return }
                    self.setBanner(result, kind: .success)
                    self.isRunningCommand = false
                }
            } catch {
                await MainActor.run {
                    guard self.commandToken == token else { return }
                    self.setBanner("\(label) failed: \(error.localizedDescription)", kind: .error)
                    self.isRunningCommand = false
                }
            }
        }

        // Hard UI watchdog: never let "Running..." persist past 3s.
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                guard self.commandToken == token, self.isRunningCommand else { return }
                self.setBanner("\(label) failed: Timed out after 3s", kind: .error)
                self.isRunningCommand = false
            }
        }
    }

    private func handleSleepWakeEvent(label: String) {
        guard sleepWakeMode != .off else {
            return
        }

        if label == "sleep" {
            let press = sleepWakeMode.press ?? .long
            runIPCommand("\(label) automation: \(sleepWakeMode.label)") { ip in
                try await self.controller.power(ip: ip, press: press)
            }
        } else {
            runIPCommand("\(label) automation: on --mac") { ip in
                let mac = self.manualMac.trimmingCharacters(in: .whitespacesAndNewlines)
                let macValue = mac.isEmpty ? nil : mac
                return try await self.controller.on(ip: ip, mac: macValue, wolPort: 9)
            }
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

    private func setBanner(_ text: String, kind: BannerKind) {
        bannerText = text
        bannerKind = kind
    }

    private func runWithTimeout<T>(
        seconds: Double,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                let nanos = UInt64((seconds * 1_000_000_000).rounded())
                try await Task.sleep(nanoseconds: nanos)
                throw CommandTimeoutError.timedOut
            }

            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }
}

struct ContentView: View {
    @StateObject private var model = AppViewModel()

    private var bannerColor: Color {
        switch model.bannerKind {
        case .info: return Color.blue.opacity(0.15)
        case .success: return Color.green.opacity(0.15)
        case .warning: return Color.yellow.opacity(0.15)
        case .error: return Color.red.opacity(0.15)
        }
    }

    private var commandButtonsDisabled: Bool {
        model.isRunningCommand || model.isScanning
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Button("Search for Samsung Frame TVs") {
                        model.scanForTVs()
                    }
                    .disabled(model.isScanning)

                    Button(model.showManualEntry ? "Hide manual entry" : "Enter manually") {
                        model.showManualEntry.toggle()
                    }
                    .disabled(model.isRunningCommand)

                    Spacer()

                    Text(model.selectionSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    if model.isScanning {
                        ProgressView()
                    }
                    Text(model.bannerText)
                        .font(.caption)
                        .lineLimit(2)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(bannerColor)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                GroupBox("Discovery") {
                    if model.discoveredTVs.isEmpty {
                        Text(model.isScanning ? "Searching..." : "No TVs discovered yet")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    } else {
                        List(model.discoveredTVs, selection: Binding(
                            get: { model.selectedIP.isEmpty ? nil : model.selectedIP },
                            set: { newValue in
                                if let ip = newValue {
                                    model.selectIP(ip)
                                }
                            }
                        )) { tv in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tv.ipAddress)
                                    .font(.body.monospaced())
                                Text("MAC: \(tv.macAddress ?? "unknown")")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                Text(tv.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(tv.ipAddress)
                        }
                        .frame(minHeight: 140)
                    }
                }

                GroupBox("Sleep/Wake Automation") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sleep uses selected power press. Wake uses on --mac.")
                            .font(.subheadline)

                        Picker("Sleep/wake mode", selection: Binding(
                            get: { model.sleepWakeMode },
                            set: { model.setSleepWakeMode($0) }
                        )) {
                            ForEach(SleepWakePowerMode.allCases, id: \.rawValue) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 260)

                        Text("TV controller off disables sleep/wake actions.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                }

                GroupBox("Manual Commands") {
                    VStack(alignment: .leading, spacing: 8) {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            Button("State") { model.triggerState() }
                            Button("Pair") { model.triggerPair() }
                            Button("To HDMI") { model.triggerToHDMI() }
                            Button("Art Mode On") { model.triggerArtModeOn() }
                            Button("Art Mode Off") { model.triggerArtModeOff() }
                            Button("Power") { model.triggerPower() }
                            Button("Power Medium") { model.triggerPowerMedium() }
                            Button("Power Long") { model.triggerPowerLong() }
                            Button("On (WOL/state)") { model.triggerOn() }
                            Button("Wake (WOL only)") { model.triggerWakeWOLOnly() }
                            Button("Off (power --long)") { model.triggerPowerLong() }
                            Button("KEY_POWEROFF") { model.triggerKeyPowerOff() }
                        }
                        .disabled(commandButtonsDisabled)
                    }
                    .padding(.top, 2)
                }

                GroupBox("Testers") {
                    HStack(spacing: 8) {
                        Button("On") { model.triggerTesterOn() }
                        Button("Off") { model.triggerTesterOff() }
                    }
                    .disabled(commandButtonsDisabled)
                    .padding(.top, 2)
                }

                if model.showManualEntry {
                    GroupBox("Manual Entry") {
                        VStack(spacing: 8) {
                            HStack(spacing: 8) {
                                TextField("Manual TV IP", text: $model.manualIP)
                                    .textFieldStyle(.roundedBorder)

                                Button("Use IP") {
                                    model.useManualIP()
                                }
                                .disabled(commandButtonsDisabled)
                            }

                            HStack(spacing: 8) {
                                TextField("TV MAC for Wake-on-LAN (AA:BB:CC:DD:EE:FF)", text: $model.manualMac)
                                    .textFieldStyle(.roundedBorder)

                                Button("Save MAC") {
                                    model.saveManualMac()
                                }
                                .disabled(commandButtonsDisabled)

                                Button("Reset Saved Data") {
                                    model.resetSavedData()
                                }
                                .disabled(commandButtonsDisabled)
                            }

                            Text("MAC is required to power on when TV is fully off unless ARP already has it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.top, 2)
                    }
                }
            }
            .padding(16)
        }
        .frame(minWidth: 760, minHeight: 620)
    }
}
