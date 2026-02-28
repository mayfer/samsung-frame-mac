import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum SamsungTVError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let msg):
            return msg
        }
    }
}

struct Config {
    static let defaultIP = "192.168.1.48"
    static let defaultAppName = "frame-mac-local"
    static let tokenFile = ".samsung_tv_tokens.json"
}

struct CLIArgs {
    let ip: String
    let appName: String
    let command: String
    let mac: String?
    let wolPort: Int
    let mediumPress: Bool
    let longPress: Bool
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

final class InsecureWebSocketDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

func parseArgs(_ argv: [String]) throws -> CLIArgs {
    var ip = Config.defaultIP
    var appName = Config.defaultAppName
    var mac: String?
    var wolPort = 9
    var mediumPress = false
    var longPress = false

    var i = 1
    var command: String?

    while i < argv.count {
        let arg = argv[i]
        if arg == "--ip" {
            i += 1
            guard i < argv.count else { throw SamsungTVError.message("Missing value for --ip") }
            ip = argv[i]
        } else if arg == "--app-name" {
            i += 1
            guard i < argv.count else { throw SamsungTVError.message("Missing value for --app-name") }
            appName = argv[i]
        } else if arg.hasPrefix("--") {
            break
        } else {
            command = arg
            i += 1
            break
        }
        i += 1
    }

    guard let cmd = command else {
        throw SamsungTVError.message(usage())
    }

    while i < argv.count {
        let arg = argv[i]
        switch arg {
        case "--mac":
            i += 1
            guard i < argv.count else { throw SamsungTVError.message("Missing value for --mac") }
            mac = argv[i]
        case "--wol-port":
            i += 1
            guard i < argv.count, let parsed = Int(argv[i]) else {
                throw SamsungTVError.message("Invalid value for --wol-port")
            }
            wolPort = parsed
        case "--medium":
            mediumPress = true
        case "--long":
            longPress = true
        default:
            throw SamsungTVError.message("Unknown argument: \(arg)\n\n\(usage())")
        }
        i += 1
    }

    if mediumPress, longPress {
        throw SamsungTVError.message("Use only one of --medium or --long")
    }
    if cmd != "power", mediumPress || longPress {
        throw SamsungTVError.message("--medium/--long are only valid with the `power` command")
    }
    if cmd != "on", mac != nil {
        throw SamsungTVError.message("--mac is only valid with the `on` command")
    }
    if cmd != "on", wolPort != 9 {
        throw SamsungTVError.message("--wol-port is only valid with the `on` command")
    }

    return CLIArgs(ip: ip, appName: appName, command: cmd, mac: mac, wolPort: wolPort, mediumPress: mediumPress, longPress: longPress)
}

func usage() -> String {
    return """
    Usage:
      frame-tv-control [--ip IP] [--app-name NAME] <command> [options]

    Commands:
      pair
      state
      power [--medium|--long]
      off
      to-hdmi
      on [--mac AA:BB:CC:DD:EE:FF] [--wol-port 9]
    """
}

func loadTokens() -> [String: String] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: Config.tokenFile)) else {
        return [:]
    }
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
        return [:]
    }
    return obj
}

func saveTokens(_ tokens: [String: String]) throws {
    let data = try JSONSerialization.data(withJSONObject: tokens, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: Config.tokenFile), options: .atomic)
}

func getSavedToken(ip: String) -> String? {
    return loadTokens()[ip]
}

func setSavedToken(ip: String, token: String) {
    var tokens = loadTokens()
    tokens[ip] = token
    try? saveTokens(tokens)
}

func parseMAC(_ raw: String) throws -> [UInt8] {
    let hex = raw.filter { $0.isHexDigit }
    guard hex.count == 12 else {
        throw SamsungTVError.message("Invalid MAC address: \(raw)")
    }

    var bytes: [UInt8] = []
    bytes.reserveCapacity(6)
    var idx = hex.startIndex
    for _ in 0..<6 {
        let next = hex.index(idx, offsetBy: 2)
        let part = hex[idx..<next]
        guard let b = UInt8(part, radix: 16) else {
            throw SamsungTVError.message("Invalid MAC address: \(raw)")
        }
        bytes.append(b)
        idx = next
    }
    return bytes
}

func discoverMacFromARP(ip: String) -> String? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
    proc.arguments = ["-n", ip]

    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe

    do {
        try proc.run()
        proc.waitUntilExit()
    } catch {
        return nil
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let out = String(data: data, encoding: .utf8) else { return nil }

    let pattern = #"(([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2})"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(out.startIndex..<out.endIndex, in: out)
    guard let match = regex.firstMatch(in: out, options: [], range: range), let r = Range(match.range(at: 1), in: out) else {
        return nil
    }
    return String(out[r])
}

func inferSubnetBroadcast(ip: String) -> String {
    let parts = ip.split(separator: ".")
    guard parts.count == 4 else { return "255.255.255.255" }
    return "\(parts[0]).\(parts[1]).\(parts[2]).255"
}

func sendWOL(mac: String, ip: String, port: Int) throws {
    let macBytes = try parseMAC(mac)
    var packet = [UInt8](repeating: 0xff, count: 6)
    for _ in 0..<16 { packet.append(contentsOf: macBytes) }

    let targets = ["255.255.255.255", inferSubnetBroadcast(ip: ip)]

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
                        _ = sendto(sock, p.baseAddress, packet.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        close(sock)
    }
}

func remotePayload(key: String, cmd: String = "Click") throws -> String {
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

func extractToken(from text: String) -> String? {
    guard let data = text.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let d = obj["data"] as? [String: Any],
          let token = d["token"] else {
        return nil
    }
    return String(describing: token)
}

func isConnectEvent(_ text: String) -> Bool {
    guard let data = text.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let event = obj["event"] as? String else {
        return false
    }
    return event == "ms.channel.connect"
}

func sendRemoteKeys(ip: String, keys: [String], appName: String) async throws {
    guard let appData = appName.data(using: .utf8) else {
        throw SamsungTVError.message("Invalid app name")
    }
    let nameB64 = appData.base64EncodedString()

    var urlString = "wss://\(ip):8002/api/v2/channels/samsung.remote.control?name=\(nameB64)"
    if let token = getSavedToken(ip: ip), !token.isEmpty {
        urlString += "&token=\(token)"
    }

    guard let url = URL(string: urlString) else {
        throw SamsungTVError.message("Invalid TV URL")
    }

    let delegate = InsecureWebSocketDelegate()
    let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    let ws = session.webSocketTask(with: url)
    ws.resume()

    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline {
        do {
            let msg = try await ws.receive()
            let text: String
            switch msg {
            case .string(let s): text = s
            case .data(let d): text = String(decoding: d, as: UTF8.self)
            @unknown default: text = ""
            }
            if let token = extractToken(from: text) {
                setSavedToken(ip: ip, token: token)
            }
            if isConnectEvent(text) {
                break
            }
        } catch {
            break
        }
    }

    for key in keys {
        let payload = try remotePayload(key: key)
        try await ws.send(.string(payload))
        try await Task.sleep(nanoseconds: 250_000_000)
    }

    ws.cancel(with: .normalClosure, reason: nil)
    session.invalidateAndCancel()
}

func sendHeldPower(ip: String, appName: String, holdMilliseconds: UInt64) async throws {
    guard let appData = appName.data(using: .utf8) else {
        throw SamsungTVError.message("Invalid app name")
    }
    let nameB64 = appData.base64EncodedString()

    var urlString = "wss://\(ip):8002/api/v2/channels/samsung.remote.control?name=\(nameB64)"
    if let token = getSavedToken(ip: ip), !token.isEmpty {
        urlString += "&token=\(token)"
    }

    guard let url = URL(string: urlString) else {
        throw SamsungTVError.message("Invalid TV URL")
    }

    let delegate = InsecureWebSocketDelegate()
    let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    let ws = session.webSocketTask(with: url)
    ws.resume()

    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline {
        do {
            let msg = try await ws.receive()
            let text: String
            switch msg {
            case .string(let s): text = s
            case .data(let d): text = String(decoding: d, as: UTF8.self)
            @unknown default: text = ""
            }
            if let token = extractToken(from: text) {
                setSavedToken(ip: ip, token: token)
            }
            if isConnectEvent(text) {
                break
            }
        } catch {
            break
        }
    }

    let pressPayload = try remotePayload(key: "KEY_POWER", cmd: "Press")
    try await ws.send(.string(pressPayload))
    try await Task.sleep(nanoseconds: holdMilliseconds * 1_000_000)
    let releasePayload = try remotePayload(key: "KEY_POWER", cmd: "Release")
    try await ws.send(.string(releasePayload))

    ws.cancel(with: .normalClosure, reason: nil)
    session.invalidateAndCancel()
}

func fetchTVDeviceInfo(ip: String) async -> [String: Any]? {
    guard let url = URL(string: "http://\(ip):8001/api/v2/") else {
        return nil
    }

    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = 2
    cfg.timeoutIntervalForResource = 2
    let session = URLSession(configuration: cfg)
    defer { session.invalidateAndCancel() }

    do {
        let (data, _) = try await session.data(from: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    } catch {
        return nil
    }
}

func extractArtModeState(from text: String) -> ArtModeState? {
    guard let data = text.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }

    if let event = obj["event"] as? String, event == "d2d_service_message",
       let inner = obj["data"] as? String,
       let innerData = inner.data(using: .utf8),
       let nested = try? JSONSerialization.jsonObject(with: innerData) as? [String: Any] {
        if let status = nested["status"] as? String {
            if status.lowercased() == "on" { return .on }
            if status.lowercased() == "off" { return .off }
        }
        if let value = nested["value"] as? String {
            if value.lowercased() == "on" { return .on }
            if value.lowercased() == "off" { return .off }
        }
    }

    if text.contains("\"status\":\"on\"") || text.contains("\"value\":\"on\"") {
        return .on
    }
    if text.contains("\"status\":\"off\"") || text.contains("\"value\":\"off\"") {
        return .off
    }
    return nil
}

func queryArtModeState(ip: String, appName: String) async -> ArtModeState {
    guard let appData = appName.data(using: .utf8) else {
        return .unknown
    }
    let nameB64 = appData.base64EncodedString()
    guard let url = URL(string: "wss://\(ip):8002/api/v2/channels/com.samsung.art-app?name=\(nameB64)") else {
        return .unknown
    }

    let delegate = InsecureWebSocketDelegate()
    let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    let ws = session.webSocketTask(with: url)
    ws.resume()
    defer {
        ws.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    let requestPayload: [String: Any] = [
        "method": "ms.channel.emit",
        "params": [
            "event": "art_app_request",
            "to": "host",
            "data": #"{"request":"get_artmode_status","id":"swift-tv-controller"}"#
        ]
    ]

    if let data = try? JSONSerialization.data(withJSONObject: requestPayload),
       let text = String(data: data, encoding: .utf8) {
        do {
            try await ws.send(.string(text))
        } catch {
            return .unavailable
        }
    }

    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        do {
            let msg = try await ws.receive()
            let text: String
            switch msg {
            case .string(let s): text = s
            case .data(let d): text = String(decoding: d, as: UTF8.self)
            @unknown default: text = ""
            }
            if let state = extractArtModeState(from: text) {
                return state
            }
        } catch {
            return .unavailable
        }
    }

    return .unknown
}

func getTVState(ip: String, appName: String) async -> TVState {
    guard await fetchTVDeviceInfo(ip: ip) != nil else {
        return TVState(isReachable: false, artMode: .unknown)
    }
    let art = await queryArtModeState(ip: ip, appName: appName)
    return TVState(isReachable: true, artMode: art)
}

@main
struct SamsungFrameCLI {
    static func main() async {
        do {
            let args = try parseArgs(CommandLine.arguments)
            switch args.command {
            case "on":
                let state = await getTVState(ip: args.ip, appName: args.appName)
                if !state.isReachable {
                    let mac = args.mac ?? discoverMacFromARP(ip: args.ip)
                    guard let resolved = mac else {
                        throw SamsungTVError.message(
                            "MAC address required for power on. Pass --mac (example: AA:BB:CC:DD:EE:FF) or run once while TV is on so ARP can discover it."
                        )
                    }
                    try sendWOL(mac: resolved, ip: args.ip, port: args.wolPort)
                    print("TV appears off. Sent Wake-on-LAN packet to \(resolved) for TV \(args.ip)")
                    break
                }
                switch state.artMode {
                case .on:
                    try await sendRemoteKeys(ip: args.ip, keys: ["KEY_POWER"], appName: args.appName)
                    print("TV is in Art Mode. Sent KEY_POWER to enter active TV mode.")
                case .off:
                    print("TV is already on (active mode). No action taken.")
                case .unavailable, .unknown:
                    print("TV is reachable but art-mode state is unavailable. No toggle sent.")
                }
            case "off":
                let state = await getTVState(ip: args.ip, appName: args.appName)
                if !state.isReachable {
                    print("TV appears off/unreachable already. No action taken.")
                    break
                }
                switch state.artMode {
                case .off:
                    try await sendRemoteKeys(ip: args.ip, keys: ["KEY_POWER"], appName: args.appName)
                    print("TV is active. Sent KEY_POWER to enter Art Mode.")
                case .on:
                    print("TV is already in Art Mode. No action taken.")
                case .unavailable, .unknown:
                    print("TV is reachable but art-mode state is unavailable. No toggle sent.")
                }
            case "pair":
                try await sendRemoteKeys(ip: args.ip, keys: ["KEY_HOME"], appName: args.appName)
                print("Pair/connect command sent. Approve this app on TV if prompted.")
            case "state":
                let state = await getTVState(ip: args.ip, appName: args.appName)
                if !state.isReachable {
                    print("power=off art=unknown")
                } else {
                    print("power=on art=\(state.artMode.rawValue)")
                }
            case "power":
                if args.longPress {
                    try await sendHeldPower(ip: args.ip, appName: args.appName, holdMilliseconds: 3200)
                    print("Sent long power press (~3.2s) for hard power toggle (KEY_POWER Press/Release)")
                } else if args.mediumPress {
                    try await sendHeldPower(ip: args.ip, appName: args.appName, holdMilliseconds: 1500)
                    print("Sent medium power press (~1.5s) (KEY_POWER Press/Release)")
                } else {
                    try await sendRemoteKeys(ip: args.ip, keys: ["KEY_POWER"], appName: args.appName)
                    print("Sent power button click (KEY_POWER)")
                }
            case "to-hdmi":
                try await sendRemoteKeys(ip: args.ip, keys: ["KEY_SOURCE", "KEY_RIGHT", "KEY_ENTER"], appName: args.appName)
                print("Sent Art-to-HDMI sequence (KEY_SOURCE, KEY_RIGHT, KEY_ENTER)")
            default:
                throw SamsungTVError.message("Unknown command: \(args.command)\n\n\(usage())")
            }
            exit(0)
        } catch let err as SamsungTVError {
            fputs("Error: \(err.description)\n", stderr)
            exit(2)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(2)
        }
    }
}
