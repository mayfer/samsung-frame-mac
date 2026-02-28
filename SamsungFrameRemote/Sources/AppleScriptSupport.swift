import AppKit
import Foundation

private enum AppleScriptPowerAction {
    case on
    case off
}

private enum AppleScriptPowerBridgeError: LocalizedError {
    case noTVSelected
    case timedOut

    var errorDescription: String? {
        switch self {
        case .noTVSelected:
            return "No TV selected. Pick a TV in Samsung Frame Remote first."
        case .timedOut:
            return "Command timed out."
        }
    }
}

private final class AppleScriptPowerBridge {
    static let shared = AppleScriptPowerBridge()

    private let controller = SamsungTVController()
    private let macCache = MACCacheStore()
    private let selectedIPKey = "selected_tv_ip"
    private let manualMacKey = "manual_tv_mac"

    private init() {}

    func handle(action: AppleScriptPowerAction) throws -> String {
        let ip = try currentIP()
        let mac = currentMAC(for: ip)

        switch action {
        case .on:
            return try runSynchronously {
                try await self.controller.on(ip: ip, mac: mac, wolPort: 9)
            }
        case .off:
            return try runSynchronously {
                try await self.controller.testerOff(ip: ip, press: .long)
            }
        }
    }

    private func currentIP() throws -> String {
        let ip = (UserDefaults.standard.string(forKey: selectedIPKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if ip.isEmpty {
            throw AppleScriptPowerBridgeError.noTVSelected
        }
        return ip
    }

    private func currentMAC(for ip: String) -> String? {
        if let cached = macCache.get(for: ip) {
            let value = cached.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }

        let manual = (UserDefaults.standard.string(forKey: manualMacKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return manual.isEmpty ? nil : manual
    }

    private func runSynchronously(
        timeoutSeconds: TimeInterval = 10,
        _ operation: @escaping () async throws -> String
    ) throws -> String {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<String, Error>?

        Task {
            defer { semaphore.signal() }
            do {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }
        }

        let waitResult = semaphore.wait(timeout: .now() + timeoutSeconds)
        if waitResult == .timedOut {
            throw AppleScriptPowerBridgeError.timedOut
        }

        guard let result else {
            throw AppleScriptPowerBridgeError.timedOut
        }
        return try result.get()
    }
}

@objc(OnScriptCommand)
final class OnScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        do {
            return try AppleScriptPowerBridge.shared.handle(action: .on)
        } catch {
            scriptErrorNumber = -10000
            scriptErrorString = error.localizedDescription
            return nil
        }
    }
}

@objc(OffScriptCommand)
final class OffScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        do {
            return try AppleScriptPowerBridge.shared.handle(action: .off)
        } catch {
            scriptErrorNumber = -10000
            scriptErrorString = error.localizedDescription
            return nil
        }
    }
}
