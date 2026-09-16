import Foundation

enum TVWakeState {
    case awake
    case standby
    case unreachable
}

struct PreparedArtTarget {
    let target: ArtModeState?
    let sentWake: Bool
}

/// Reachability is not proof of panel power. Wake-on-LAN is safe to attempt
/// after two failed probes; never use a blind power toggle to wake the TV.
enum ArtWakePreparation {
    static func prepare(
        target: ArtModeState?,
        mac: String?,
        timeout: TimeInterval = 30,
        probe: () async -> TVWakeState,
        wake: (String) throws -> Void,
        pause: () async throws -> Void = { try await Task.sleep(nanoseconds: 1_000_000_000) }
    ) async throws -> PreparedArtTarget {
        try Task.checkCancellation()
        var state = await probe()
        if state == .unreachable {
            // A single lost response should not change a normal toggle into wake.
            try await pause()
            state = await probe()
        }
        if state == .awake { return PreparedArtTarget(target: target, sentWake: false) }

        let address = mac?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !address.isEmpty else {
            throw SamsungTVControllerError.message("TV is in standby or unreachable. Save its MAC address in the TV tab to enable Wake-on-LAN.")
        }
        try Task.checkCancellation()
        try wake(address)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try await pause()
            try Task.checkCancellation()
            if await probe() == .awake {
                // An offline toggle means resume viewing, regardless of boot mode.
                return PreparedArtTarget(target: target ?? .off, sentWake: true)
            }
        }
        throw SamsungTVControllerError.message("Wake-on-LAN sent, but the TV did not become ready. Check the TV's power, network connection and saved MAC address.")
    }
}
