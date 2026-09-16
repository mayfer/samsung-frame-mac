import Foundation

func XCTAssertEqual<T: Equatable>(_ actual: T, _ expected: T) { precondition(actual == expected, "Expected \(expected), got \(actual)") }
func XCTAssertTrue(_ condition: Bool) { precondition(condition) }
func XCTFail(_ message: String) { fatalError(message) }

final class FakeArtTransport: ArtTransport {
    var state = "off"
    var hasArtwork = true
    var requests: [[String: Any]] = []
    var replies: [[String: Any]] = [["event": "ms.channel.connect"], ["event": "ms.channel.ready"]]
    var closed = false

    func close() { closed = true }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        guard !replies.isEmpty else { throw SamsungTVControllerError.message("No queued reply") }
        return .data(try JSONSerialization.data(withJSONObject: replies.removeFirst()))
    }
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard case .string(let text) = message,
              let envelope = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let params = envelope["params"] as? [String: Any],
              let inner = params["data"] as? String,
              let request = try JSONSerialization.jsonObject(with: Data(inner.utf8)) as? [String: Any] else {
            XCTFail("Invalid envelope"); return
        }
        XCTAssertEqual(envelope["method"] as? String, "ms.channel.emit")
        XCTAssertEqual(params["event"] as? String, "art_app_request")
        XCTAssertEqual(params["to"] as? String, "host")
        XCTAssertEqual(request["id"] as? String, request["request_id"] as? String)
        requests.append(request)
        var response: [String: Any] = ["request_id": request["request_id"]!]
        switch request["request"] as? String {
        case "get_artmode_status": response["value"] = state
        case "get_current_artwork": if hasArtwork { response["content_id"] = "saved-art" }
        case "select_image": state = "on"; return // Setters intentionally have no acknowledgement.
        case "set_artmode_status": XCTFail("Art off setter opens the Art Store; do not send it")
        default: XCTFail("Unexpected request")
        }
        // An unrelated event must not be mistaken for the response.
        replies.append(["event": "d2d_service_message", "data": "{\"request_id\":\"unrelated\",\"value\":\"on\"}"])
        let encoded = try JSONSerialization.data(withJSONObject: response)
        replies.append(["event": "d2d_service_message", "data": String(decoding: encoded, as: UTF8.self)])
    }
}

final class StalledArtTransport: ArtTransport {
    let stallSend: Bool
    private let lock = NSLock()
    private var closed = false
    private var pending: CheckedContinuation<Void, Error>?
    init(stallSend: Bool) { self.stallSend = stallSend }
    func close() {
        lock.lock()
        closed = true
        let continuation = pending
        pending = nil
        lock.unlock()
        continuation?.resume(throwing: URLError(.cancelled))
    }
    private func stall() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if closed {
                lock.unlock()
                continuation.resume(throwing: URLError(.cancelled))
            } else {
                pending = continuation
                lock.unlock()
            }
        }
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        if !stallSend { try await stall() }
        return .string("{\"event\":\"ms.channel.ready\"}")
    }
    func send(_ message: URLSessionWebSocketTask.Message) async throws { try await stall() }
}

@main
struct ArtModeConnectionTests {
    static func main() async throws {
        let tests = ArtModeConnectionTests()
        try await tests.testEnterArtPreservesCurrentArtworkAndVerifiesState()
        try await tests.testExitArtUsesRemoteAndVerifiesState()
        try await tests.testAlreadyInTargetStateSendsNoSetter()
        try await tests.testMissingArtworkFailsWithoutChangingTV()
        try await tests.testUnauthorizedChannelFails()
        try await tests.testExitOnlySendsRemoteWhileArtIsOn()
        try await tests.testAlreadyOffDoesNotTogglePower()
        try await tests.testRemoteFailureDoesNotClaimSuccess()
        try await tests.testNetworkFailureRetriesExactlyOnce()
        try await tests.testTVErrorIsNotRetried()
        try await tests.testLostExitReplyDoesNotToggleBack()
        try await tests.testCancellationIsNotRetried()
        try await tests.testAwakeTVDoesNotWakeOrOverrideToggle()
        try await tests.testTransientProbeFailureDoesNotWake()
        try await tests.testOfflineToggleWakesThenExitsArt()
        try await tests.testWakePreservesExplicitEnterArt()
        try await tests.testStandbyNeedsWakeEvenWhenReachable()
        try await tests.testWakeNeedsMAC()
        try await tests.testWakeTimeoutStopsBeforeArtCommands()
        try await tests.testWakeSendFailureStopsImmediately()
        try await tests.testWakeAndStatusPrecedeFirstProbe()
        try await tests.testWakeWaitReportsProgress()
        try await tests.testStalledSendTimesOut()
        try await tests.testStalledReceiveTimesOut()
        tests.testIdleFiresOncePerPeriod()
        tests.testIdleActivityRearmsTimer()
        tests.testIdleDefersWhileBusy()
        tests.testIdleConfigurationStartsFreshInterval()
        tests.testIdleIgnoresInvalidSamples()
        tests.testIdleResetAfterWake()
        print("Passed 30 Art, wake, network and idle timer tests")
    }
    func testEnterArtPreservesCurrentArtworkAndVerifiesState() async throws {
        let transport = FakeArtTransport()
        let api = ArtModeConnection(transport: transport)
        try await api.connect()
        let result = try await api.setMode(.on)
        XCTAssertEqual(result, "Confirmed: Art mode on.")
        XCTAssertEqual(transport.requests.compactMap { $0["request"] as? String },
                       ["get_artmode_status", "get_current_artwork", "select_image", "get_artmode_status"])
        let select = transport.requests[2]
        XCTAssertEqual(select["content_id"] as? String, "saved-art")
        XCTAssertTrue(select["category_id"] is NSNull)
        XCTAssertEqual(select["show"] as? Bool, true)
        XCTAssertEqual(Set(transport.requests.compactMap { $0["id"] as? String }).count, 4)
    }

    func testExitArtUsesRemoteAndVerifiesState() async throws {
        let transport = FakeArtTransport()
        transport.state = "on"
        let api = ArtModeConnection(transport: transport)
        try await api.connect()
        var presses = 0
        _ = try await api.setMode(.off, exitArt: {
            presses += 1
            transport.state = "off"
        })
        XCTAssertEqual(presses, 1)
        XCTAssertEqual(transport.requests.compactMap { $0["request"] as? String },
                       ["get_artmode_status", "get_artmode_status"])
    }

    func testAlreadyInTargetStateSendsNoSetter() async throws {
        let transport = FakeArtTransport()
        let api = ArtModeConnection(transport: transport)
        try await api.connect()
        _ = try await api.setMode(.off)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testMissingArtworkFailsWithoutChangingTV() async throws {
        let transport = FakeArtTransport()
        transport.hasArtwork = false
        let api = ArtModeConnection(transport: transport)
        try await api.connect()
        do { _ = try await api.setMode(.on); XCTFail("Expected missing artwork error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("existing artwork")) }
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testUnauthorizedChannelFails() async throws {
        let transport = FakeArtTransport()
        transport.replies = [["event": "ms.channel.unauthorized"]]
        let api = ArtModeConnection(transport: transport)
        do { try await api.connect(); XCTFail("Expected authorization error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("unauthorized")) }
    }
    func testExitOnlySendsRemoteWhileArtIsOn() async throws {
        let transport = FakeArtTransport()
        transport.state = "on"
        let api = ArtModeConnection(transport: transport)
        try await api.connect()
        var pressed = false
        let result = try await api.setMode(.off, exitArt: {
            XCTAssertEqual(transport.state, "on")
            XCTAssertEqual(transport.requests.count, 1)
            pressed = true
            transport.state = "off"
        })
        XCTAssertTrue(pressed)
        XCTAssertEqual(result, "Confirmed: Art mode off.")
    }

    func testAlreadyOffDoesNotTogglePower() async throws {
        let api = ArtModeConnection(transport: FakeArtTransport())
        try await api.connect()
        _ = try await api.setMode(.off, exitArt: { XCTFail("Must not toggle power when Art is already off") })
    }

    func testRemoteFailureDoesNotClaimSuccess() async throws {
        let transport = FakeArtTransport()
        transport.state = "on"
        let api = ArtModeConnection(transport: transport)
        try await api.connect()
        do {
            _ = try await api.setMode(.off, exitArt: { throw SamsungTVControllerError.message("Remote unavailable") })
            XCTFail("Expected remote error")
        } catch {
            XCTAssertEqual(transport.state, "on")
            XCTAssertEqual(transport.requests.count, 1)
            XCTAssertTrue(error.localizedDescription.contains("Remote unavailable"))
        }
    }

    func testNetworkFailureRetriesExactlyOnce() async throws {
        var attempts = 0
        let value = try await NetworkRetry.once(delay: 0) {
            attempts += 1
            if attempts == 1 { throw URLError(.networkConnectionLost) }
            return "ok"
        }
        XCTAssertEqual(value, "ok")
        XCTAssertEqual(attempts, 2)
        attempts = 0
        do {
            _ = try await NetworkRetry.once(delay: 0) { () -> String in
                attempts += 1
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTCONN))
            }
            XCTFail("Expected final network failure")
        } catch { XCTAssertEqual(attempts, 2) }
    }

    func testTVErrorIsNotRetried() async throws {
        var attempts = 0
        do {
            _ = try await NetworkRetry.once(delay: 0) { () -> String in
                attempts += 1
                throw SamsungTVControllerError.message("Unauthorized")
            }
            XCTFail("Expected TV rejection")
        } catch { XCTAssertEqual(attempts, 1) }
    }

    func testLostExitReplyDoesNotToggleBack() async throws {
        var state = "on"
        var connections = 0
        var presses = 0
        let result = try await ArtModeConnection.changeWithRetry(target: nil, retryDelay: 0, connect: {
            connections += 1
            let transport = FakeArtTransport()
            transport.state = state
            return ArtModeConnection(transport: transport)
        }, exitArt: {
            presses += 1
            state = "off" // TV applied the command, but the connection failed afterwards.
            throw URLError(.networkConnectionLost)
        })
        XCTAssertEqual(result, "Art mode is already off.")
        XCTAssertEqual(connections, 2)
        XCTAssertEqual(presses, 1)
    }

    func testCancellationIsNotRetried() async throws {
        var attempts = 0
        do {
            _ = try await NetworkRetry.once(delay: 0) { () -> String in
                attempts += 1
                throw CancellationError()
            }
            XCTFail("Expected cancellation")
        } catch { XCTAssertEqual(attempts, 1) }
    }

    func testAwakeTVDoesNotWakeOrOverrideToggle() async throws {
        let prepared = try await ArtWakePreparation.prepare(target: nil, mac: nil,
            probe: { .awake }, wake: { _ in XCTFail("Already awake") }, pause: {})
        XCTAssertEqual(prepared.target, nil)
        XCTAssertEqual(prepared.sentWake, false)
    }

    func testTransientProbeFailureDoesNotWake() async throws {
        var probes = 0
        let prepared = try await ArtWakePreparation.prepare(target: nil, mac: nil, probe: {
            probes += 1
            return probes == 1 ? .unreachable : .awake
        }, wake: { _ in XCTFail("Transient probe failure should not wake") }, pause: {})
        XCTAssertEqual(probes, 2)
        XCTAssertEqual(prepared.target, nil)
    }

    func testOfflineToggleWakesThenExitsArt() async throws {
        var states: [TVWakeState] = [.unreachable, .unreachable, .standby, .awake]
        var wakes = 0
        let prepared = try await ArtWakePreparation.prepare(target: nil, mac: " AA:BB:CC:DD:EE:FF ", probe: {
            states.removeFirst()
        }, wake: { mac in
            XCTAssertEqual(mac, "AA:BB:CC:DD:EE:FF")
            wakes += 1
        }, pause: {})
        XCTAssertEqual(wakes, 1)
        XCTAssertEqual(prepared.target, .off)
        XCTAssertTrue(prepared.sentWake)
        let transport = FakeArtTransport()
        transport.state = "on"
        var presses = 0
        _ = try await ArtModeConnection.changeWithRetry(target: prepared.target, retryDelay: 0,
            connect: { ArtModeConnection(transport: transport) }, exitArt: {
                presses += 1
                transport.state = "off"
            })
        XCTAssertEqual(presses, 1)
        XCTAssertEqual(transport.state, "off")
    }

    func testWakePreservesExplicitEnterArt() async throws {
        var awake = false
        let prepared = try await ArtWakePreparation.prepare(target: .on, mac: "AA:BB:CC:DD:EE:FF",
            probe: { awake ? .awake : .unreachable }, wake: { _ in awake = true }, pause: {})
        XCTAssertEqual(prepared.target, .on)
    }

    func testStandbyNeedsWakeEvenWhenReachable() async throws {
        var awake = false
        var wakes = 0
        let prepared = try await ArtWakePreparation.prepare(target: .off, mac: "AA:BB:CC:DD:EE:FF",
            probe: { awake ? .awake : .standby }, wake: { _ in awake = true; wakes += 1 }, pause: {})
        XCTAssertEqual(wakes, 1)
        XCTAssertEqual(prepared.target, .off)
    }

    func testWakeNeedsMAC() async throws {
        do {
            _ = try await ArtWakePreparation.prepare(target: .off, mac: " ", probe: { .unreachable },
                wake: { _ in XCTFail("Must not wake without a MAC") }, pause: {})
            XCTFail("Expected missing MAC error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("MAC address")) }
    }

    func testWakeTimeoutStopsBeforeArtCommands() async throws {
        var wakes = 0
        do {
            _ = try await ArtWakePreparation.prepare(target: .off, mac: "AA:BB:CC:DD:EE:FF", timeout: 0,
                probe: { .unreachable }, wake: { _ in wakes += 1 }, pause: {})
            XCTFail("Must not proceed to Art when wake timed out")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("did not become ready"))
            XCTAssertEqual(wakes, 1)
        }
    }

    func testWakeSendFailureStopsImmediately() async throws {
        var probes = 0
        do {
            _ = try await ArtWakePreparation.prepare(target: .off, mac: "invalid", probe: {
                probes += 1
                return .standby
            }, wake: { _ in throw SamsungTVControllerError.message("Invalid MAC") }, pause: {})
            XCTFail("Expected wake send failure")
        } catch {
            XCTAssertEqual(probes, 0)
            XCTAssertTrue(error.localizedDescription.contains("Invalid MAC"))
        }
    }

    func testWakeAndStatusPrecedeFirstProbe() async throws {
        var events: [String] = []
        let prepared = try await ArtWakePreparation.prepare(target: nil, mac: "AA:BB:CC:DD:EE:FF",
            progress: { events.append($0) }, probe: {
                XCTAssertEqual(events, ["Sending Wake-on-LAN…", "packet", "Wake-on-LAN sent. Checking TV…"])
                return .awake
            }, wake: { _ in events.append("packet") }, pause: {})
        XCTAssertTrue(prepared.sentWake)
        XCTAssertEqual(prepared.target, nil)
    }

    func testWakeWaitReportsProgress() async throws {
        var states: [TVWakeState] = [.standby, .awake]
        var messages: [String] = []
        let prepared = try await ArtWakePreparation.prepare(target: nil, mac: "AA:BB:CC:DD:EE:FF",
            progress: { messages.append($0) }, probe: { states.removeFirst() }, wake: { _ in }, pause: {})
        XCTAssertEqual(prepared.target, .off)
        XCTAssertTrue(messages.contains { $0.contains("remaining") })
        XCTAssertEqual(messages.last, "TV is responding. Checking Art mode…")
    }

    func testStalledSendTimesOut() async throws {
        let api = ArtModeConnection(transport: StalledArtTransport(stallSend: true), transportTimeout: 10_000_000)
        try await api.connect()
        do { _ = try await api.status(); XCTFail("Expected send timeout") }
        catch { XCTAssertEqual((error as NSError).code, URLError.timedOut.rawValue) }
    }

    func testStalledReceiveTimesOut() async throws {
        let api = ArtModeConnection(transport: StalledArtTransport(stallSend: false), transportTimeout: 10_000_000)
        do { try await api.connect(); XCTFail("Expected receive timeout") }
        catch { XCTAssertEqual((error as NSError).code, URLError.timedOut.rawValue) }
    }

    func testIdleFiresOncePerPeriod() {
        var period = IdlePeriod()
        period.reset(at: 0)
        XCTAssertEqual(period.sample(idleSeconds: 59, uptime: 59, threshold: 60, available: true), nil)
        XCTAssertEqual(period.sample(idleSeconds: 60, uptime: 60, threshold: 60, available: true), .idle)
        XCTAssertEqual(period.sample(idleSeconds: 120, uptime: 120, threshold: 60, available: true), nil)
    }

    func testIdleActivityRearmsTimer() {
        var period = IdlePeriod()
        period.reset(at: 0)
        XCTAssertEqual(period.sample(idleSeconds: 60, uptime: 60, threshold: 60, available: true), .idle)
        XCTAssertEqual(period.sample(idleSeconds: 0, uptime: 61, threshold: 60, available: true), .active)
        XCTAssertEqual(period.sample(idleSeconds: 1, uptime: 62, threshold: 60, available: true), nil)
        XCTAssertEqual(period.sample(idleSeconds: 60, uptime: 121, threshold: 60, available: true), .idle)
    }

    func testIdleDefersWhileBusy() {
        var period = IdlePeriod()
        period.reset(at: 0)
        XCTAssertEqual(period.sample(idleSeconds: 60, uptime: 60, threshold: 60, available: false), nil)
        XCTAssertEqual(period.sample(idleSeconds: 61, uptime: 61, threshold: 60, available: true), .idle)
        // Activity still reports while a TV command is in flight.
        XCTAssertEqual(period.sample(idleSeconds: 0, uptime: 62, threshold: 60, available: false), .active)
    }

    func testIdleConfigurationStartsFreshInterval() {
        var period = IdlePeriod()
        period.reset(at: 1000)
        XCTAssertEqual(period.sample(idleSeconds: 300, uptime: 1001, threshold: 60, available: true), nil)
        XCTAssertEqual(period.sample(idleSeconds: 359, uptime: 1060, threshold: 60, available: true), .idle)
    }

    func testIdleIgnoresInvalidSamples() {
        var period = IdlePeriod()
        period.reset(at: 0)
        XCTAssertEqual(period.sample(idleSeconds: .infinity, uptime: 60, threshold: 60, available: true), nil)
        XCTAssertEqual(period.sample(idleSeconds: .nan, uptime: 60, threshold: 60, available: true), nil)
        XCTAssertEqual(period.sample(idleSeconds: -1, uptime: 60, threshold: 60, available: true), nil)
        XCTAssertEqual(period.sample(idleSeconds: 60, uptime: 60, threshold: 60, available: true), .idle)
    }

    func testIdleResetAfterWake() {
        var period = IdlePeriod()
        period.reset(at: 0)
        XCTAssertEqual(period.sample(idleSeconds: 60, uptime: 60, threshold: 60, available: true), .idle)
        period.reset(at: 1000)
        XCTAssertEqual(period.sample(idleSeconds: 1001, uptime: 1001, threshold: 60, available: true), nil)
        XCTAssertEqual(period.sample(idleSeconds: 1060, uptime: 1060, threshold: 60, available: true), .idle)
    }

}
