import AppKit
import SwiftUI

struct ShortcutSettingsView: View {
    @State private var powerOnShortcut = GlobalHotKeyCoordinator.shared.shortcut(for: .powerOn)
    @State private var powerOffShortcut = GlobalHotKeyCoordinator.shared.shortcut(for: .powerOff)
    @State private var launchAtLoginState = LaunchAtLoginManager.shared.currentState()
    @State private var recordingAction: PowerShortcutAction?
    @State private var localKeyMonitor: Any?
    @State private var suspendedHotKeys = false
    @State private var statusText = "Configure global key combos to trigger power actions while the app is running. On and Off may use the same combo."

    private var defaultsSummary: String {
        let on = GlobalHotKeyCoordinator.defaultShortcut(for: .powerOn).displayString
        let off = GlobalHotKeyCoordinator.defaultShortcut(for: .powerOff).displayString
        return "Defaults: On \(on), Off \(off)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            shortcutRow(for: .powerOn)
            shortcutRow(for: .powerOff)

            HStack(spacing: 10) {
                Button("Reset to Defaults") {
                    resetToDefaults()
                }
                .buttonStyle(.bordered)

                Text(defaultsSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Launch at Login", isOn: Binding(
                    get: { launchAtLoginState.isEnabled },
                    set: { setLaunchAtLogin($0) }
                ))
                .toggleStyle(.switch)

                Text(launchAtLoginState.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
        .onAppear {
            syncShortcuts()
            refreshLaunchAtLoginState()
        }
        .onDisappear {
            stopRecording()
        }
    }

    @ViewBuilder
    private func shortcutRow(for action: PowerShortcutAction) -> some View {
        HStack(spacing: 10) {
            Text(action.label)
                .frame(width: 90, alignment: .leading)

            Text(shortcutText(for: action))
                .font(.body.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(recordingAction == action ? "Press keys..." : "Record") {
                beginRecording(for: action)
            }
            .buttonStyle(.borderedProminent)

            Button("Clear") {
                clearShortcut(for: action)
            }
            .buttonStyle(.bordered)
            .disabled(shortcut(for: action) == nil)
        }
    }

    private func shortcut(for action: PowerShortcutAction) -> GlobalShortcut? {
        switch action {
        case .powerOn: return powerOnShortcut
        case .powerOff: return powerOffShortcut
        }
    }

    private func shortcutText(for action: PowerShortcutAction) -> String {
        shortcut(for: action)?.displayString ?? "Not set"
    }

    private func beginRecording(for action: PowerShortcutAction) {
        stopRecording()
        GlobalHotKeyCoordinator.shared.suspendRegistrationsForRecording()
        suspendedHotKeys = true
        recordingAction = action
        statusText = "Press a key combo for \(action.label). Include at least one modifier key."

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard recordingAction == action else {
                return event
            }

            let activeModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 53 && activeModifiers.isEmpty {
                statusText = "Recording canceled."
                stopRecording()
                return nil
            }

            guard let shortcut = GlobalShortcut.from(event: event) else {
                NSSound.beep()
                statusText = "Shortcut must include Command, Option, Control, or Shift."
                return nil
            }

            do {
                try GlobalHotKeyCoordinator.shared.setShortcut(shortcut, for: action)
                syncShortcuts()
                statusText = "Saved \(action.label): \(shortcut.displayString)"
            } catch {
                NSSound.beep()
                statusText = error.localizedDescription
            }

            stopRecording()
            return nil
        }
    }

    private func clearShortcut(for action: PowerShortcutAction) {
        do {
            try GlobalHotKeyCoordinator.shared.setShortcut(nil, for: action)
            syncShortcuts()
            statusText = "Cleared \(action.label) shortcut."
        } catch {
            NSSound.beep()
            statusText = error.localizedDescription
        }
    }

    private func resetToDefaults() {
        stopRecording()
        do {
            try GlobalHotKeyCoordinator.shared.resetToDefaults()
            syncShortcuts()
            statusText = defaultsSummary
        } catch {
            NSSound.beep()
            statusText = error.localizedDescription
        }
    }

    private func stopRecording() {
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
        if suspendedHotKeys {
            GlobalHotKeyCoordinator.shared.resumeRegistrationsAfterRecording()
            suspendedHotKeys = false
        }
        recordingAction = nil
    }

    private func syncShortcuts() {
        powerOnShortcut = GlobalHotKeyCoordinator.shared.shortcut(for: .powerOn)
        powerOffShortcut = GlobalHotKeyCoordinator.shared.shortcut(for: .powerOff)
    }

    private func refreshLaunchAtLoginState() {
        launchAtLoginState = LaunchAtLoginManager.shared.currentState()
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        LaunchAtLoginManager.shared.markUserPreferenceInitialized()
        do {
            try LaunchAtLoginManager.shared.setEnabled(enabled)
            refreshLaunchAtLoginState()
            statusText = enabled ? "Launch at login enabled." : "Launch at login disabled."
        } catch {
            NSSound.beep()
            refreshLaunchAtLoginState()
            statusText = "Launch at login update failed: \(error.localizedDescription)"
        }
    }
}
