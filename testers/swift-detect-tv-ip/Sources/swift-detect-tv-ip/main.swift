import Foundation

let scanner = TVScanner()
let timeout = 8.0
var finished = false

print("Scanning local network for Samsung Frame TVs (\(Int(timeout))s)...")

scanner.scan(timeout: timeout) { devices in
    if devices.isEmpty {
        print("No Samsung Frame TV found.")
    } else {
        print("Found \(devices.count) Samsung TV device(s):")
        for (index, device) in devices.enumerated() {
            let mac = device.macAddress ?? "unknown"
            print("\(index + 1). \(device.ipAddress)  mac=\(mac)  name=\(device.name)  host=\(device.hostName)  port=\(device.port)  service=\(device.serviceType)")
        }
    }

    finished = true
    CFRunLoopStop(CFRunLoopGetMain())
}

while !finished {
    RunLoop.main.run(mode: .default, before: .distantFuture)
}
