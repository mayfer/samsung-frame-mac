import AppKit
import Foundation

final class SleepWakeCoordinator {
    private var observers: [NSObjectProtocol] = []
    private var isActive = false

    var onSleep: (() -> Void)?
    var onWake: (() -> Void)?

    func setActive(_ active: Bool) {
        if active == isActive {
            return
        }

        isActive = active
        if active {
            startObserving()
        } else {
            stopObserving()
        }
    }

    private func startObserving() {
        let center = NSWorkspace.shared.notificationCenter

        let sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onSleep?()
        }

        let wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onWake?()
        }

        observers = [sleepObserver, wakeObserver]
    }

    private func stopObserving() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
    }

    deinit {
        stopObserving()
    }
}
