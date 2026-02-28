import Foundation
import ServiceManagement

enum LaunchAtLoginState {
    case enabled
    case disabled
    case requiresApproval
    case notFound
    case unsupported

    var isEnabled: Bool {
        self == .enabled
    }

    var statusText: String {
        switch self {
        case .enabled:
            return "App will launch automatically when you log in."
        case .disabled:
            return "App will not launch at login."
        case .requiresApproval:
            return "Login item requires approval in System Settings > General > Login Items."
        case .notFound:
            return "Login item could not be found in this build location."
        case .unsupported:
            return "Launch-at-login status is unavailable on this system."
        }
    }
}

final class LaunchAtLoginManager {
    static let shared = LaunchAtLoginManager()

    private let service = SMAppService.mainApp
    private let initializedDefaultsKey = "launch_at_login_preference_initialized"

    private init() {}

    func currentState() -> LaunchAtLoginState {
        switch service.status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .disabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            return .unsupported
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try service.register()
        } else {
            try service.unregister()
        }
    }

    func bootstrapDefaultEnabled() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: initializedDefaultsKey) {
            return
        }

        defaults.set(true, forKey: initializedDefaultsKey)
        if currentState() == .disabled {
            try? setEnabled(true)
        }
    }

    func markUserPreferenceInitialized() {
        UserDefaults.standard.set(true, forKey: initializedDefaultsKey)
    }
}
