import Foundation

protocol ArtTransport {
    func receive() async throws -> URLSessionWebSocketTask.Message
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func close()
}

final class WebSocketArtTransport: ArtTransport {
    let session: URLSession
    let socket: URLSessionWebSocketTask

    init(url: URL) {
        session = URLSession(configuration: .ephemeral)
        socket = session.webSocketTask(with: url)
        socket.resume()
    }
    func receive() async throws -> URLSessionWebSocketTask.Message { try await socket.receive() }
    func send(_ message: URLSessionWebSocketTask.Message) async throws { try await socket.send(message) }
    func close() {
        socket.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

/// The local Art API sequence verified in screensaver-tv/SamsungFrameAPI.
final class ArtModeConnection {
    private let transport: ArtTransport
    private let transportTimeout: UInt64

    init(ip: String) throws {
        let name = Data("frame-mac-local".utf8).base64EncodedString()
        guard let url = URL(string: "ws://\(ip):8001/api/v2/channels/com.samsung.art-app?name=\(name)") else {
            throw SamsungTVControllerError.message("Invalid TV address")
        }
        transportTimeout = 6_000_000_000
        transport = WebSocketArtTransport(url: url)
    }

    init(transport: ArtTransport, transportTimeout: UInt64 = 6_000_000_000) {
        self.transport = transport
        self.transportTimeout = transportTimeout
    }

    func close() { transport.close() }

    private func withTransportTimeout<T>(_ operation: () async throws -> T) async throws -> T {
        let deadline = Date().addingTimeInterval(Double(transportTimeout) / 1_000_000_000)
        let timeout = Task {
            try await Task.sleep(nanoseconds: transportTimeout)
            transport.close()
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            do { return try await operation() }
            catch {
                try Task.checkCancellation()
                if Date() >= deadline { throw URLError(.timedOut) }
                throw error
            }
        }, onCancel: { self.transport.close() })
    }

    private func receive() async throws -> [String: Any] {
        let message = try await withTransportTimeout { try await transport.receive() }
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: throw SamsungTVControllerError.message("Unknown TV response")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SamsungTVControllerError.message("Invalid Art response")
        }
        let event = object["event"] as? String ?? ""
        if ["ms.error", "ms.channel.unauthorized", "ms.channel.timeOut"].contains(event) {
            throw SamsungTVControllerError.message("Art channel rejected connection: \(event)")
        }
        if event == "d2d_service_message" {
            if let nested = object["data"] as? [String: Any] { return nested }
            if let text = object["data"] as? String,
               let nested = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] { return nested }
        }
        return object
    }

    func connect() async throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if try await receive()["event"] as? String == "ms.channel.ready" { return }
        }
        throw SamsungTVControllerError.message("Art channel did not become ready")
    }

    @discardableResult
    private func send(_ request: String, params: [String: Any] = [:]) async throws -> String {
        let id = UUID().uuidString
        var inner = params
        inner["request"] = request
        inner["id"] = id
        inner["request_id"] = id
        let encoded = try JSONSerialization.data(withJSONObject: inner)
        let envelope: [String: Any] = ["method": "ms.channel.emit", "params": [
            "event": "art_app_request", "to": "host", "data": String(decoding: encoded, as: UTF8.self)
        ]]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        try await withTransportTimeout { try await transport.send(.string(String(decoding: data, as: UTF8.self))) }
        return id
    }

    private func call(_ request: String) async throws -> [String: Any] {
        let id = try await send(request)
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            let response = try await receive()
            guard (response["request_id"] as? String ?? response["id"] as? String) == id else { continue }
            if response["event"] as? String == "error" {
                throw SamsungTVControllerError.message("TV rejected \(request)")
            }
            return response
        }
        throw SamsungTVControllerError.message("TV did not answer \(request)")
    }

    func status() async throws -> ArtModeState {
        let response = try await call("get_artmode_status")
        guard let value = response["value"] as? String,
              let state = ArtModeState(rawValue: value), state == .on || state == .off else {
            throw SamsungTVControllerError.message("TV returned an unknown Art state")
        }
        return state
    }

    func setMode(_ target: ArtModeState, progress: TVCommandProgress = { _ in }, exitArt: (() async throws -> Void)? = nil) async throws -> String {
        let before = try await status()
        guard before != target else { return "Art mode is already \(target.rawValue)." }
        if target == .on {
            await progress("Entering Art mode…")
            let artwork = try await call("get_current_artwork")
            guard let contentID = artwork["content_id"] as? String, !contentID.isEmpty else {
                throw SamsungTVControllerError.message("TV did not return an existing artwork")
            }
            try await send("select_image", params: ["category_id": NSNull(), "content_id": contentID, "show": true])
        } else {
            guard let exitArt else {
                throw SamsungTVControllerError.message("No remote available to exit Art mode")
            }
            // A short power click while Art is ON uses the TV's normal resume path.
            // The Art API off setter opens the Art Store on the user's TV.
            await progress("Exiting Art mode…")
            try await exitArt()
        }
        await progress("Confirming Art mode \(target.rawValue)…")
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 500_000_000)
            if try await status() == target {
                return "Confirmed: Art mode \(target.rawValue)."
            }
        }
        throw SamsungTVControllerError.message("Art mode transition was not confirmed")
    }
}

/// Retry transport failures once; never retry TV rejections or invalid responses.
enum NetworkRetry {
    static func isTransient(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSURLErrorDomain {
            return [URLError.timedOut, .cannotFindHost, .cannotConnectToHost,
                    .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet,
                    .cancelled].contains(URLError.Code(rawValue: error.code))
        }
        if error.domain == NSPOSIXErrorDomain {
            return [ECONNRESET, ECONNREFUSED, ECONNABORTED, ENOTCONN, ETIMEDOUT,
                    EHOSTUNREACH, ENETUNREACH, ENETDOWN, EPIPE].contains(Int32(error.code))
        }
        return false
    }

    static func once<T>(delay: UInt64 = 750_000_000, onRetry: () async -> Void = {}, operation: () async throws -> T) async throws -> T {
        do { return try await operation() }
        catch {
            try Task.checkCancellation()
            guard isTransient(error) else { throw error }
            await onRetry()
            try await Task.sleep(nanoseconds: delay)
            return try await operation()
        }
    }
}

extension ArtModeConnection {
    static func changeWithRetry(
        target: ArtModeState?,
        retryDelay: UInt64 = 750_000_000,
        progress: TVCommandProgress = { _ in },
        connect: () throws -> ArtModeConnection,
        exitArt: @escaping () async throws -> Void
    ) async throws -> String {
        // Resolve a toggle once. A lost acknowledgement must not reverse the goal.
        var desired = target
        return try await NetworkRetry.once(delay: retryDelay, onRetry: {
            await progress("Network error. Retrying once…")
        }) {
            await progress("Connecting to TV’s Art controls…")
            let connection = try connect()
            defer { connection.close() }
            try await connection.connect()
            await progress("Checking Art mode…")
            if desired == nil { desired = try await connection.status() == .on ? .off : .on }
            return try await connection.setMode(desired!, progress: progress, exitArt: exitArt)
        }
    }
}
