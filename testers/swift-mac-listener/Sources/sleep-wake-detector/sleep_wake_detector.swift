import AppKit
import Foundation

@main
struct SleepWakeDetectorCLI {
    static func main() {
        let config = Config.parse(arguments: CommandLine.arguments)
        if config.showHelp {
            print(Config.helpText)
            return
        }

        let handler = SleepWakeHandler(
            onSleepCommand: config.onSleepCommand,
            onWakeCommand: config.onWakeCommand
        )
        handler.start()
    }
}

private struct Config {
    let onSleepCommand: String
    let onWakeCommand: String
    let showHelp: Bool

    static var helpText: String {
        """
        Usage:
          sleep-wake-detector [--on-sleep "<command>"] [--on-wake "<command>"]

        Defaults:
          --on-sleep 'printf "%s sleep\\n" "$(date -Iseconds)" >> /tmp/test.txt'
          --on-wake  'printf "%s wake\\n"  "$(date -Iseconds)" >> /tmp/test.txt'
        """
    }

    static func parse(arguments: [String]) -> Config {
        let defaultSleep = #"printf "%s sleep\n" "$(date -Iseconds)" >> /tmp/test.txt"#
        let defaultWake = #"printf "%s wake\n" "$(date -Iseconds)" >> /tmp/test.txt"#

        var onSleepCommand = defaultSleep
        var onWakeCommand = defaultWake
        var showHelp = false

        var index = 1
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--on-sleep":
                guard index + 1 < arguments.count else {
                    fputs("Missing value for --on-sleep\n", stderr)
                    showHelp = true
                    break
                }
                onSleepCommand = arguments[index + 1]
                index += 1
            case "--on-wake":
                guard index + 1 < arguments.count else {
                    fputs("Missing value for --on-wake\n", stderr)
                    showHelp = true
                    break
                }
                onWakeCommand = arguments[index + 1]
                index += 1
            case "-h", "--help":
                showHelp = true
            default:
                fputs("Unknown argument: \(arg)\n", stderr)
                showHelp = true
            }

            index += 1
        }

        return Config(
            onSleepCommand: onSleepCommand,
            onWakeCommand: onWakeCommand,
            showHelp: showHelp
        )
    }
}

private final class SleepWakeHandler {
    private let onSleepCommand: String
    private let onWakeCommand: String
    private var observers: [NSObjectProtocol] = []

    init(onSleepCommand: String, onWakeCommand: String) {
        self.onSleepCommand = onSleepCommand
        self.onWakeCommand = onWakeCommand
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter

        let sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { [onSleepCommand] _ in
            Self.runCommand(onSleepCommand, label: "sleep")
        }

        let wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [onWakeCommand] _ in
            Self.runCommand(onWakeCommand, label: "wake")
        }

        observers = [sleepObserver, wakeObserver]

        print("Listening for sleep/wake events...")
        print("Sleep command: \(onSleepCommand)")
        print("Wake command: \(onWakeCommand)")
        print("Press Ctrl+C to exit.")

        RunLoop.main.run()
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers {
            center.removeObserver(observer)
        }
    }

    private static func runCommand(_ command: String, label: String) {
        guard !command.isEmpty else {
            fputs("Skipping empty \(label) command.\n", stderr)
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", command]

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                fputs("Command failed for \(label) with status \(process.terminationStatus)\n", stderr)
            }
        } catch {
            fputs("Failed to run \(label) command: \(error)\n", stderr)
        }
    }
}
