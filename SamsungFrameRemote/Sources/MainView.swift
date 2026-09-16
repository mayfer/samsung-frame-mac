import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppViewModel
    @State private var confirmReset = false

    private var busy: Bool { model.isRunningCommand || model.isScanning }
    private var commandDisabled: Bool { busy || model.selectedIP.isEmpty }
    private var statusColor: Color {
        switch model.bannerKind {
        case .info: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "tv").font(.largeTitle).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Samsung Frame").font(.title2.bold())
                    Text(model.selectedIP.isEmpty ? "Choose a TV to get started" : model.selectedIP)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.shortcutMode.label).font(.callout).foregroundStyle(.secondary)
            }.padding(24)

            TabView {
                page { tvTab }.tabItem { Label("TV", systemImage: "tv") }
                page { shortcutsTab }.tabItem { Label("Shortcuts", systemImage: "keyboard") }
                page { debugTab }.tabItem { Label("Test & Debug", systemImage: "wrench.and.screwdriver") }
            }.padding(.horizontal, 16)

            HStack(alignment: .top, spacing: 10) {
                if busy { ProgressView().controlSize(.small) }
                else { Image(systemName: "circle.fill").font(.caption2).foregroundStyle(statusColor) }
                Text(model.bannerText).font(.callout).textSelection(.enabled)
                Spacer(minLength: 0)
            }.padding(18).frame(minHeight: 64, alignment: .leading)
        }
        .frame(minWidth: 660, minHeight: 600)
        .alert("Reset TV connection?", isPresented: $confirmReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) { model.resetSavedData() }
        } message: {
            Text("This removes the saved TV, MAC addresses and pairing tokens, and disables idle and sleep/wake automation. Keyboard shortcuts stay saved.")
        }
    }

    private func page<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20, content: content)
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section<Content: View>(_ title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.headline)
                Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                content()
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var tvTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            section("Your TV", subtitle: "Connect your Mac and Frame to the same network.") {
                HStack {
                    Button { model.scanForTVs() } label: { Label("Search for TVs", systemImage: "magnifyingglass") }
                        .buttonStyle(.borderedProminent)
                    Spacer()
                    Button("Pair with TV") { model.triggerPair() }.disabled(commandDisabled)
                }.disabled(busy)
                if model.discoveredTVs.isEmpty {
                    Text("No TVs found yet. Search or enter an address below.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.discoveredTVs) { tv in
                        Button { model.selectIP(tv.ipAddress) } label: {
                            HStack {
                                Image(systemName: model.selectedIP == tv.ipAddress ? "checkmark.circle.fill" : "circle")
                                Text(tv.name)
                                Spacer()
                                Text(tv.ipAddress).monospaced().foregroundStyle(.secondary)
                            }.padding(8).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(busy)
                    }
                }
                Text("Approve the connection on your TV if prompted.").font(.caption).foregroundStyle(.secondary)
            }
            section("Connection details", subtitle: "Use a manual IP if discovery cannot find your TV. A MAC address is needed to wake an offline TV.") {
                HStack {
                    TextField("TV IP address", text: $model.manualIP)
                    Button("Use IP") { model.useManualIP() }
                }
                HStack {
                    TextField("MAC address · AA:BB:CC:DD:EE:FF", text: $model.manualMac)
                    Button("Save MAC") { model.saveManualMac() }
                }
            }.textFieldStyle(.roundedBorder).disabled(busy)
        }
    }

    private var shortcutsTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            section("Shortcut behavior", subtitle: "Choose what your keyboard shortcuts control. Your key combinations stay the same.") {
                Picker("Mode", selection: $model.shortcutMode) {
                    ForEach(ShortcutMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().disabled(model.isRunningCommand)
                Text(model.shortcutMode == .art
                     ? "Enter Art displays your current artwork. Exit Art resumes viewing, waking the TV first if needed. Save its MAC address in the TV tab to enable wake. A shared shortcut wakes an offline TV into viewing mode."
                     : "Power On wakes the TV or returns from Art. Power Off sends a long power press.")
                    .font(.callout).foregroundStyle(.secondary)
                Divider()
                ShortcutSettingsView(mode: model.shortcutMode)
            }
            section("When your Mac is idle", subtitle: "Uses keyboard and mouse activity across your Mac while this app is running.") {
                Toggle(model.shortcutMode == .art ? "Enter Art mode after inactivity" : "Turn TV off after inactivity", isOn: $model.idleEnabled)
                    .toggleStyle(.checkbox)
                HStack {
                    Text("After")
                    TextField("Minutes", value: $model.idleMinutes, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder).frame(width: 65)
                    Stepper("minutes", value: $model.idleMinutes, in: 1...240)
                    Spacer()
                }.disabled(!model.idleEnabled)
                Toggle("Return to viewing when activity resumes", isOn: $model.idleResumeViewing)
                    .toggleStyle(.checkbox).disabled(!model.idleEnabled)
                Text(model.shortcutMode == .art
                     ? "Shows your current artwork once per idle period."
                     : "Sends a long power press to fully turn off the TV, including from Art mode.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("1–240 minutes. The interval restarts when you change these settings or your Mac wakes. Mac sleep/wake actions below are independent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            section("Mac sleep & wake", subtitle: "Independent of shortcut mode. Sleep sends a power press; wake checks the TV and wakes it if needed.") {
                Picker("Sleep action", selection: Binding(get: { model.sleepWakeMode }, set: { model.setSleepWakeMode($0) })) {
                    ForEach(SleepWakePowerMode.allCases, id: \.rawValue) { Text($0.label).tag($0) }
                }
            }
        }
    }

    private var debugTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            section("Test your shortcuts", subtitle: "Runs the same actions as your configured keyboard shortcuts, using \(model.shortcutMode.label.lowercased()).") {
                HStack {
                    Button(model.shortcutMode.label(for: .powerOn)) { model.triggerShortcut([.powerOn]) }
                    Button(model.shortcutMode.label(for: .powerOff)) { model.triggerShortcut([.powerOff]) }
                    Button("Toggle") { model.triggerShortcut([.powerOn, .powerOff]) }
                }.disabled(commandDisabled)
            }
            section("Diagnostics", subtitle: "Read the TV’s state or send a specific command.") {
                HStack {
                    Button("Check reachability") { model.triggerState() }
                    Button("Read Art state") { model.triggerArtStatus() }
                }
                HStack {
                    Button("Enter Art") { model.triggerArtModeOn() }
                    Button("Exit Art") { model.triggerArtModeOff() }
                    Button("Wake via LAN") { model.triggerWakeWOLOnly() }
                }
                DisclosureGroup("Advanced remote commands") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("These send remote button presses; results depend on the TV’s current state.").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Power click") { model.triggerPower() }
                            Button("Hold 1.5s") { model.triggerPowerMedium() }
                            Button("Hold 3.2s") { model.triggerPowerLong() }
                        }
                        HStack {
                            Button("Power-off key") { model.triggerKeyPowerOff() }
                            Button("Source → Right → Enter") { model.triggerToHDMI() }
                        }
                    }.padding(.top, 8)
                }
            }.disabled(commandDisabled)
            section("Activity", subtitle: "Recent commands and results, newest first. Kept for this session only.") {
                HStack {
                    Button("Copy log") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.history.map { "\($0.date.formatted())  \($0.text)" }.joined(separator: "\n"), forType: .string)
                    }
                    Button("Clear") { model.history.removeAll() }
                }.disabled(model.history.isEmpty)
                if model.history.isEmpty { Text("No activity yet.").foregroundStyle(.secondary) }
                ForEach(model.history) { entry in
                    HStack(alignment: .top) {
                        Text(entry.date, style: .time).foregroundStyle(.secondary).frame(width: 85, alignment: .leading)
                        Text(entry.text).frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.caption.monospaced()).textSelection(.enabled)
                    Divider()
                }
            }
            Button("Reset saved TV connection…", role: .destructive) { confirmReset = true }.disabled(busy)
        }
    }
}
