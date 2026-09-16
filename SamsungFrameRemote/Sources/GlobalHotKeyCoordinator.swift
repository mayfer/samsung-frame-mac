import AppKit
import Carbon.HIToolbox
import Foundation

enum PowerShortcutAction: String, CaseIterable {
    case powerOn
    case powerOff

    var label: String {
        switch self {
        case .powerOn: return "Power On"
        case .powerOff: return "Power Off"
        }
    }

    fileprivate var defaultsKey: String {
        switch self {
        case .powerOn: return "global_shortcut_power_on"
        case .powerOff: return "global_shortcut_power_off"
        }
    }
}

struct GlobalShortcut: Equatable, Hashable {
    let keyCode: UInt32
    let modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(serializedValue: String) {
        let components = serializedValue.split(separator: ":")
        guard components.count == 2,
              let keyCode = UInt32(components[0]),
              let modifiers = UInt32(components[1]) else {
            return nil
        }

        self.init(keyCode: keyCode, modifiers: modifiers)
    }

    var serializedValue: String {
        "\(keyCode):\(modifiers)"
    }

    var displayString: String {
        var label = ""
        if modifiers & UInt32(controlKey) != 0 { label += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { label += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { label += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { label += "⌘" }
        label += Self.keyName(for: keyCode)
        return label
    }

    static func from(event: NSEvent) -> GlobalShortcut? {
        let modifiers = carbonModifiers(from: event.modifierFlags)
        guard modifiers != 0 else {
            return nil
        }

        let keyCode = UInt32(event.keyCode)
        guard !modifierKeyCodes.contains(keyCode) else {
            return nil
        }

        return GlobalShortcut(keyCode: keyCode, modifiers: modifiers)
    }

    private static let modifierKeyCodes: Set<UInt32> = [
        54, // right command
        55, // left command
        56, // left shift
        57, // caps lock
        58, // left option
        59, // left control
        60, // right shift
        61, // right option
        62, // right control
        63  // fn
    ]

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }

    private static func keyName(for keyCode: UInt32) -> String {
        if let known = keyCodeMap[keyCode] {
            return known
        }
        return "Key\(keyCode)"
    }

    private static let keyCodeMap: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3",
        21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]",
        31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";",
        42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`", 36: "↩", 48: "⇥", 49: "Space",
        51: "⌫", 53: "⎋", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
        100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 123: "←", 124: "→", 125: "↓", 126: "↑"
    ]
}

enum GlobalHotKeyError: LocalizedError {
    case registrationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .registrationFailed(let status):
            return "Failed to register global shortcut (OSStatus \(status))."
        }
    }
}

final class GlobalHotKeyCoordinator {
    static let shared = GlobalHotKeyCoordinator()

    private let signature = fourCharCode("SFRM")

    private var registeredRefs: [UInt32: EventHotKeyRef] = [:]
    private var actionsByHotKeyID: [UInt32: [PowerShortcutAction]] = [:]
    private var handlerRef: EventHandlerRef?
    private var registrationsSuspended = false

    private init() {}

    func start() {
        installEventHandlerIfNeeded()
        try? refreshRegistrations()
    }

    func shortcut(for action: PowerShortcutAction) -> GlobalShortcut? {
        guard let stored = UserDefaults.standard.string(forKey: action.defaultsKey) else {
            return nil
        }
        return GlobalShortcut(serializedValue: stored)
    }

    static func defaultShortcut(for action: PowerShortcutAction) -> GlobalShortcut {
        let baseModifiers = UInt32(controlKey) | UInt32(optionKey) | UInt32(cmdKey)
        switch action {
        case .powerOn:
            // Control + Option + Command + O
            return GlobalShortcut(keyCode: 31, modifiers: baseModifiers)
        case .powerOff:
            // Control + Option + Shift + Command + O
            return GlobalShortcut(keyCode: 31, modifiers: baseModifiers | UInt32(shiftKey))
        }
    }

    func setShortcut(_ shortcut: GlobalShortcut?, for action: PowerShortcutAction) throws {
        if let shortcut {
            UserDefaults.standard.set(shortcut.serializedValue, forKey: action.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: action.defaultsKey)
        }

        if !registrationsSuspended {
            try refreshRegistrations()
        }
    }

    func resetToDefaults() throws {
        for action in PowerShortcutAction.allCases {
            let shortcut = Self.defaultShortcut(for: action)
            UserDefaults.standard.set(shortcut.serializedValue, forKey: action.defaultsKey)
        }
        if !registrationsSuspended {
            try refreshRegistrations()
        }
    }

    func suspendRegistrationsForRecording() {
        guard !registrationsSuspended else { return }
        registrationsSuspended = true
        unregisterAllHotKeys()
        actionsByHotKeyID.removeAll()
    }

    func resumeRegistrationsAfterRecording() {
        guard registrationsSuspended else { return }
        registrationsSuspended = false
        try? refreshRegistrations()
    }

    private func installEventHandlerIfNeeded() {
        guard handlerRef == nil else { return }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let eventRef, let userData else {
                    return noErr
                }

                let coordinator = Unmanaged<GlobalHotKeyCoordinator>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                return coordinator.handleHotKeyEvent(eventRef)
            },
            1,
            &eventSpec,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &handlerRef
        )

        if status != noErr {
            handlerRef = nil
        }
    }

    private func handleHotKeyEvent(_ eventRef: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let result = GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard result == noErr else {
            return result
        }

        guard hotKeyID.signature == signature,
              let actions = actionsByHotKeyID[hotKeyID.id] else {
            return noErr
        }

        trigger(actions)
        return noErr
    }

    private func refreshRegistrations() throws {
        if registrationsSuspended {
            unregisterAllHotKeys()
            actionsByHotKeyID.removeAll()
            return
        }

        unregisterAllHotKeys()
        actionsByHotKeyID.removeAll()

        var groupedActions: [GlobalShortcut: [PowerShortcutAction]] = [:]
        for action in PowerShortcutAction.allCases {
            guard let shortcut = shortcut(for: action) else {
                continue
            }
            groupedActions[shortcut, default: []].append(action)
        }

        let orderedShortcuts = groupedActions.keys.sorted {
            if $0.keyCode != $1.keyCode { return $0.keyCode < $1.keyCode }
            return $0.modifiers < $1.modifiers
        }

        var nextHotKeyID: UInt32 = 1

        for shortcut in orderedShortcuts {
            let actions = groupedActions[shortcut] ?? []

            var hotKeyRef: EventHotKeyRef?
            let id = EventHotKeyID(signature: signature, id: nextHotKeyID)
            let status = RegisterEventHotKey(
                shortcut.keyCode,
                shortcut.modifiers,
                id,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )

            guard status == noErr, let hotKeyRef else {
                throw GlobalHotKeyError.registrationFailed(status)
            }

            registeredRefs[nextHotKeyID] = hotKeyRef
            actionsByHotKeyID[nextHotKeyID] = actions
            nextHotKeyID += 1
        }
    }

    private func unregisterAllHotKeys() {
        for ref in registeredRefs.values {
            UnregisterEventHotKey(ref)
        }
        registeredRefs.removeAll()
    }

    private func trigger(_ actions: [PowerShortcutAction]) {
        guard !actions.isEmpty else { return }

        Task { @MainActor in
            AppViewModel.shared?.triggerShortcut(actions)
        }
    }


}

private func fourCharCode(_ string: String) -> OSType {
    let bytes = Array(string.utf8.prefix(4))
    guard bytes.count == 4 else { return 0 }
    return bytes.reduce(0) { ($0 << 8) + UInt32($1) }
}
