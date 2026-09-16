import AppKit
import CoreGraphics

/// Pure idle-period logic, separate from the system clock and TV commands.
struct IdlePeriod {
    enum Event: Equatable { case idle, active }
    private var armedAt: TimeInterval = 0
    private var lastInput: TimeInterval?
    private var fired = false

    mutating func reset(at uptime: TimeInterval) {
        armedAt = uptime
        lastInput = nil
        fired = false
    }

    mutating func sample(idleSeconds: TimeInterval, uptime: TimeInterval,
                         threshold: TimeInterval, available: Bool) -> Event? {
        guard idleSeconds.isFinite, idleSeconds >= 0, threshold > 0 else { return nil }
        let input = uptime - idleSeconds
        let activity = lastInput.map { input > $0 + 0.1 } ?? false
        lastInput = input
        if activity, fired {
            fired = false
            return .active
        }
        guard !fired, available, uptime - max(armedAt, input) >= threshold else { return nil }
        fired = true
        return .idle
    }
}

@MainActor
final class IdleCoordinator {
    var onIdle: (() -> Void)?
    var onActivity: (() -> Void)?
    var canRun: (() -> Bool)?
    var onTick: (() -> Void)?
    private var timer: Timer?
    private var period = IdlePeriod()
    private var threshold: TimeInterval = 300
    private var wakeObserver: NSObjectProtocol?

    func configure(enabled: Bool, minutes: Int) {
        timer?.invalidate()
        timer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        threshold = TimeInterval(max(1, min(240, minutes)) * 60)
        period.reset(at: ProcessInfo.processInfo.systemUptime)
        guard enabled else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Sleep is not fresh inactivity. Start a new interval after wake.
                self?.period.reset(at: ProcessInfo.processInfo.systemUptime)
                self?.onActivity?()
            }
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let idle = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
        let event = period.sample(idleSeconds: idle,
                                  uptime: ProcessInfo.processInfo.systemUptime,
                                  threshold: threshold, available: canRun?() ?? false)
        switch event {
        case .idle: onIdle?()
        case .active: onActivity?()
        case nil: break
        }
        onTick?()
    }

    deinit {
        timer?.invalidate()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }
}
