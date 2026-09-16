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

typealias TVCommandProgress = (String) async -> Void

/// Send the wake packet before waiting for any network response.
enum ArtWakePreparation {
    static func prepare(
        target: ArtModeState?,
        mac: String?,
        timeout: TimeInterval = 30,
        progress: TVCommandProgress = { _ in },
        probe: () async -> TVWakeState,
        wake: (String) throws -> Void,
        pause: () async throws -> Void = { try await Task.sleep(nanoseconds: 1_000_000_000) }
    ) async throws -> PreparedArtTarget {
        try Task.checkCancellation()
        let address = mac?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sentWake = !address.isEmpty
        if sentWake {
            await progress("Sending Wake-on-LAN…")
            try wake(address)
            await progress("Wake-on-LAN sent. Checking TV…")
        } else {
            await progress("Checking TV… No MAC saved for Wake-on-LAN.")
        }
        let deadline = Date().addingTimeInterval(timeout)
        var state = await probe()
        if state == .awake { return PreparedArtTarget(target: target, sentWake: sentWake) }

        // Without a wake packet, retry a failed probe before requesting a MAC.
        if !sentWake, state == .unreachable {
            try await pause()
            state = await probe()
            if state == .awake { return PreparedArtTarget(target: target, sentWake: false) }
        }
        guard sentWake else {
            throw SamsungTVControllerError.message("TV is in standby or unreachable. Save its MAC address in the TV tab to enable Wake-on-LAN.")
        }
        while Date() < deadline {
            let remaining = max(1, Int(ceil(deadline.timeIntervalSinceNow)))
            await progress("Wake-on-LAN sent. Waiting for TV… (up to \(remaining)s remaining)")
            try await pause()
            try Task.checkCancellation()
            if await probe() == .awake {
                await progress("TV is responding. Checking Art mode…")
                return PreparedArtTarget(target: target ?? .off, sentWake: true)
            }
        }
        throw SamsungTVControllerError.message("Wake-on-LAN sent, but the TV did not become ready. Check the TV's power, network connection and saved MAC address.")
    }
}
