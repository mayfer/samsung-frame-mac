import Foundation

final class InsecureWebSocketDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        _ = session
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

enum PowerPress {
    case click
    case medium
    case long
}

enum ArtModeState: String {
    case on
    case off
    case unavailable
    case unknown
}

struct TVState {
    let isReachable: Bool
    let artMode: ArtModeState
}

struct TVOnlineState {
    let isOnline: Bool
}

enum SamsungTVControllerError: Error, LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text):
            return text
        }
    }
}

actor SamsungTVController {
    // Keep identical default app name with working binary.
    private let appName = "frame-mac-local"
    private let tokenPath: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".samsung_tv_tokens.json")

    func pair(ip: String) async throws -> String {
        try await sendRemoteKeys(ip: ip, keys: ["KEY_HOME"])
        return "Pair/connect command sent. Approve this app on TV if prompted."
    }

    func toHDMI(ip: String) async throws -> String {
        try await sendRemoteKeys(ip: ip, keys: ["KEY_SOURCE", "KEY_RIGHT", "KEY_ENTER"])
        return "Sent Art-to-HDMI sequence (KEY_SOURCE, KEY_RIGHT, KEY_ENTER)."
    }

    func artModeOn(ip: String, mac: String? = nil, progress: TVCommandProgress = { _ in }) async throws -> String {
        try await changeArtMode(ip: ip, target: .on, mac: mac, progress: progress)
    }

    func artModeOff(ip: String, mac: String? = nil, progress: TVCommandProgress = { _ in }) async throws -> String {
        try await changeArtMode(ip: ip, target: .off, mac: mac, progress: progress)
    }

    func powerOffKey(ip: String) async throws -> String {
        try await sendRemoteKeys(ip: ip, keys: ["KEY_POWEROFF"])
        return "Sent KEY_POWEROFF."
    }

    func power(ip: String, press: PowerPress) async throws -> String {
        switch press {
        case .click:
            try await sendRemoteKeys(ip: ip, keys: ["KEY_POWER"])
            return "Sent power button click (KEY_POWER)."
        case .medium:
            try await sendHeldPower(ip: ip, holdMilliseconds: 1500)
            return "Sent medium power press (~1.5s)."
        case .long:
            try await sendHeldPower(ip: ip, holdMilliseconds: 3200)
            return "Sent long power press (~3.2s)."
        }
    }

    func state(ip: String) async -> TVState {
        await getTVState(ip: ip)
    }

    func onlineState(ip: String) async -> TVOnlineState {
        // Fast "is TV online" probe: do not depend on art-mode websocket.
        let reachable = await fetchTVDeviceInfo(ip: ip) != nil
        return TVOnlineState(isOnline: reachable)
    }

    func testerOn(ip: String, mac: String?, wolPort: Int = 9) async throws -> String {
        if let deviceInfo = await fetchTVDeviceInfo(ip: ip) {
            let powerState = extractPowerState(from: deviceInfo)
            if powerState == "standby" {
                try await sendRemoteKeys(ip: ip, keys: ["KEY_POWER"])
                return "TV is online in standby. Sent short power press."
            }
            return "TV is already online (powerState=\(powerState ?? "unknown")). No action taken."
        }

        let providedMac = mac?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let finalMac = providedMac, !finalMac.isEmpty else {
            throw SamsungTVControllerError.message("TV is offline; MAC required for WOL.")
        }

        try sendWOL(mac: finalMac, ip: ip, port: wolPort)
        return "TV is offline. Sent Wake-on-LAN packet to \(finalMac)."
    }

    func testerOff(ip: String, press: PowerPress = .click) async throws -> String {
        guard let deviceInfo = await fetchTVDeviceInfo(ip: ip) else {
            return "TV is offline. No action taken."
        }

        let powerState = extractPowerState(from: deviceInfo)
        if powerState == "standby" {
            return "TV is in standby. No action taken."
        }

        if powerState == "on" || powerState == "active" || powerState == nil {
            switch press {
            case .click:
                try await sendRemoteKeys(ip: ip, keys: ["KEY_POWER"])
                return "TV is online (\(powerState ?? "unknown")). Sent short power press."
            case .medium:
                try await sendHeldPower(ip: ip, holdMilliseconds: 1500)
                return "TV is online (\(powerState ?? "unknown")). Sent medium power press."
            case .long:
                try await sendHeldPower(ip: ip, holdMilliseconds: 3200)
                return "TV is online (\(powerState ?? "unknown")). Sent long power press."
            }
        }

        return "TV power state is \(powerState!). No action taken."
    }

    func on(ip: String, mac: String?, wolPort: Int = 9) async throws -> String {
        let current = await getTVState(ip: ip)
        if !current.isReachable {
            let providedMac = mac?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let finalMac = providedMac, !finalMac.isEmpty else {
                throw SamsungTVControllerError.message(
                    "MAC address required for power on. Use: on --mac AA:BB:CC:DD:EE:FF"
                )
            }

            try sendWOL(mac: finalMac, ip: ip, port: wolPort)
            return "TV appears off. Sent Wake-on-LAN packet to \(finalMac) for TV \(ip)."
        }

        switch current.artMode {
        case .on:
            try await sendRemoteKeys(ip: ip, keys: ["KEY_POWER"])
            return "TV is in Art Mode. Sent KEY_POWER to enter active TV mode."
        case .off:
            return "TV is already on (active mode). No action taken."
        case .unavailable, .unknown:
            return "TV is reachable but art-mode state is unavailable. No toggle sent."
        }
    }

    func wakeWOL(ip: String, mac: String?, wolPort: Int = 9) async throws -> String {
        let providedMac = mac?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let finalMac = providedMac, !finalMac.isEmpty else {
            throw SamsungTVControllerError.message(
                "MAC address required for Wake-on-LAN. Use: on --mac AA:BB:CC:DD:EE:FF"
            )
        }

        try sendWOL(mac: finalMac, ip: ip, port: wolPort)
        return "Sent Wake-on-LAN packet to \(finalMac) for TV \(ip)."
    }

    func clearPersistedData() {
        try? FileManager.default.removeItem(at: tokenPath)
    }

    private func sendRemoteKeys(ip: String, keys: [String]) async throws {
        guard let appData = appName.data(using: .utf8) else {
            throw SamsungTVControllerError.message("Invalid app name")
        }
        let nameB64 = appData.base64EncodedString()

        var urlString = "wss://\(ip):8002/api/v2/channels/samsung.remote.control?name=\(nameB64)"
        if let token = getSavedToken(ip: ip), !token.isEmpty {
            urlString += "&token=\(token)"
        }

        guard let url = URL(string: urlString) else {
            throw SamsungTVControllerError.message("Invalid TV URL")
        }

        let delegate = InsecureWebSocketDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let ws = session.webSocketTask(with: url)
        ws.resume()
        let timeout = Task {
            try await Task.sleep(nanoseconds: 12_000_000_000)
            ws.cancel(with: .goingAway, reason: nil)
        }
        defer {
            timeout.cancel()
            ws.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        var connected = false
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            do {
                let message = try await ws.receive()
                let text: String
                switch message {
                case .string(let value):
                    text = value
                case .data(let value):
                    text = String(decoding: value, as: UTF8.self)
                @unknown default:
                    text = ""
                }

                if let token = extractToken(from: text) {
                    setSavedToken(ip: ip, token: token)
                }
                if isConnectEvent(text) {
                    connected = true
                    break
                }
            } catch {
                throw error
            }
        }
        guard connected else {
            throw SamsungTVControllerError.message("TV remote channel did not connect. Pair with the TV and approve the connection if prompted.")
        }

        for key in keys {
            let payload = try remotePayload(key: key)
            try await ws.send(.string(payload))
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        ws.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    private func sendHeldPower(ip: String, holdMilliseconds: UInt64) async throws {
        guard let appData = appName.data(using: .utf8) else {
            throw SamsungTVControllerError.message("Invalid app name")
        }
        let nameB64 = appData.base64EncodedString()

        var urlString = "wss://\(ip):8002/api/v2/channels/samsung.remote.control?name=\(nameB64)"
        if let token = getSavedToken(ip: ip), !token.isEmpty {
            urlString += "&token=\(token)"
        }

        guard let url = URL(string: urlString) else {
            throw SamsungTVControllerError.message("Invalid TV URL")
        }

        let delegate = InsecureWebSocketDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let ws = session.webSocketTask(with: url)
        ws.resume()
        let timeout = Task {
            try await Task.sleep(nanoseconds: 12_000_000_000)
            ws.cancel(with: .goingAway, reason: nil)
        }
        defer {
            timeout.cancel()
            ws.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        var connected = false
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            do {
                let message = try await ws.receive()
                let text: String
                switch message {
                case .string(let value):
                    text = value
                case .data(let value):
                    text = String(decoding: value, as: UTF8.self)
                @unknown default:
                    text = ""
                }

                if let token = extractToken(from: text) {
                    setSavedToken(ip: ip, token: token)
                }
                if isConnectEvent(text) {
                    connected = true
                    break
                }
            } catch {
                throw error
            }
        }
        guard connected else {
            throw SamsungTVControllerError.message("TV remote channel did not connect. Pair with the TV and approve the connection if prompted.")
        }

        let pressPayload = try remotePayload(key: "KEY_POWER", cmd: "Press")
        try await ws.send(.string(pressPayload))
        try await Task.sleep(nanoseconds: holdMilliseconds * 1_000_000)
        let releasePayload = try remotePayload(key: "KEY_POWER", cmd: "Release")
        try await ws.send(.string(releasePayload))

        ws.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    private func fetchTVDeviceInfo(ip: String) async -> [String: Any]? {
        guard let url = URL(string: "http://\(ip):8001/api/v2/") else {
            return nil
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 2
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        do {
            let (data, _) = try await session.data(from: url)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return object
        } catch {
            return nil
        }
    }

    func artStatus(ip: String) async throws -> String {
        try await NetworkRetry.once {
            let connection = try ArtModeConnection(ip: ip)
            defer { connection.close() }
            try await connection.connect()
            return "Art mode: \(try await connection.status().rawValue)"
        }
    }

    func changeArtMode(ip: String, target: ArtModeState? = nil, mac: String? = nil, progress: TVCommandProgress = { _ in }) async throws -> String {
        let prepared = try await ArtWakePreparation.prepare(target: target, mac: mac, progress: progress, probe: {
            guard let info = await self.fetchTVDeviceInfo(ip: ip) else { return .unreachable }
            let power = self.extractPowerState(from: info)
            return ["standby", "off"].contains(power ?? "") ? .standby : .awake
        }, wake: { address in
            try self.sendWOL(mac: address, ip: ip, port: 9)
        })
        let result = try await ArtModeConnection.changeWithRetry(target: prepared.target, progress: progress, connect: {
            try ArtModeConnection(ip: ip)
        }, exitArt: {
            try await self.sendRemoteKeys(ip: ip, keys: ["KEY_POWER"])
        })
        return prepared.sentWake ? "Wake-on-LAN sent; TV responded. \(result)" : result
    }

    private func queryArtModeState(ip: String) async -> ArtModeState {
        do {
            let connection = try ArtModeConnection(ip: ip)
            defer { connection.close() }
            try await connection.connect()
            return try await connection.status()
        } catch { return .unavailable }
    }

    private func getTVState(ip: String) async -> TVState {
        guard await fetchTVDeviceInfo(ip: ip) != nil else {
            return TVState(isReachable: false, artMode: .unknown)
        }

        let art = await queryArtModeState(ip: ip)
        return TVState(isReachable: true, artMode: art)
    }

    private func extractPowerState(from root: [String: Any]) -> String? {
        guard let device = root["device"] as? [String: Any],
              let value = device["PowerState"] as? String else {
            return nil
        }
        return value.lowercased()
    }

    private func parseMAC(_ raw: String) throws -> [UInt8] {
        let hex = raw.filter { $0.isHexDigit }
        guard hex.count == 12 else {
            throw SamsungTVControllerError.message("Invalid MAC address: \(raw)")
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(6)

        var index = hex.startIndex
        for _ in 0..<6 {
            let next = hex.index(index, offsetBy: 2)
            let part = hex[index..<next]
            guard let value = UInt8(part, radix: 16) else {
                throw SamsungTVControllerError.message("Invalid MAC address: \(raw)")
            }
            bytes.append(value)
            index = next
        }

        return bytes
    }

    private func inferSubnetBroadcast(ip: String) -> String {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return "255.255.255.255" }
        return "\(parts[0]).\(parts[1]).\(parts[2]).255"
    }

    private func sendWOL(mac: String, ip: String, port: Int) throws {
        let macBytes = try parseMAC(mac)
        var packet = [UInt8](repeating: 0xff, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: macBytes) }

        let targets = ["255.255.255.255", inferSubnetBroadcast(ip: ip)]
        var sentPacket = false

        for target in targets {
            let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            if sock < 0 { continue }

            var enable: Int32 = 1
            _ = withUnsafePointer(to: &enable) { ptr in
                setsockopt(sock, SOL_SOCKET, SO_BROADCAST, ptr, socklen_t(MemoryLayout<Int32>.size))
            }

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)

            let ok = target.withCString { cs in inet_pton(AF_INET, cs, &addr.sin_addr) }
            if ok == 1 {
                packet.withUnsafeBytes { p in
                    withUnsafePointer(to: &addr) { a in
                        a.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            if sendto(sock, p.baseAddress, packet.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) == packet.count {
                                sentPacket = true
                            }
                        }
                    }
                }
            }

            close(sock)
        }
        guard sentPacket else {
            throw SamsungTVControllerError.message("Could not send Wake-on-LAN. Check your Mac's network connection.")
        }
    }

    private func remotePayload(key: String, cmd: String = "Click") throws -> String {
        let payload: [String: Any] = [
            "method": "ms.remote.control",
            "params": [
                "Cmd": cmd,
                "DataOfCmd": key,
                "Option": "false",
                "TypeOfRemote": "SendRemoteKey"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return String(decoding: data, as: UTF8.self)
    }

    private func extractToken(from text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inner = object["data"] as? [String: Any],
              let token = inner["token"] else {
            return nil
        }
        return String(describing: token)
    }

    private func isConnectEvent(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = object["event"] as? String else {
            return false
        }
        return event == "ms.channel.connect"
    }

    private func loadTokens() -> [String: String] {
        guard let data = try? Data(contentsOf: tokenPath) else {
            return [:]
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    private func saveTokens(_ tokens: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: tokens, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }

        try? data.write(to: tokenPath, options: .atomic)
    }

    private func getSavedToken(ip: String) -> String? {
        loadTokens()[ip]
    }

    private func setSavedToken(ip: String, token: String) {
        var tokens = loadTokens()
        tokens[ip] = token
        saveTokens(tokens)
    }
}
