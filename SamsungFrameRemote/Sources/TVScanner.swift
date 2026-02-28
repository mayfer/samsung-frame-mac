import Foundation

struct DetectedTV: Hashable, Identifiable {
    let name: String
    let hostName: String
    let ipAddress: String
    let macAddress: String?
    let port: Int
    let serviceType: String

    var id: String { ipAddress }
}

final class TVScanner: NSObject {
    private let serviceTypes = [
        "_samsungmsf._tcp.",
        "_mediaremotetv._tcp.",
        "_airplay._tcp."
    ]

    private var browsers: [NetServiceBrowser] = []
    private var resolvers: [NetService] = []
    private var discovered = Set<DetectedTV>()
    private var timeoutTimer: Timer?
    private var completion: (([DetectedTV]) -> Void)?

    func scan(timeout: TimeInterval = 8.0, completion: @escaping ([DetectedTV]) -> Void) {
        stopActiveScan()

        self.completion = completion
        discovered.removeAll()

        for serviceType in serviceTypes {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browsers.append(browser)
            browser.searchForServices(ofType: serviceType, inDomain: "local.")
        }

        timeoutTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            self?.finishScan()
        }
    }

    private func finishScan() {
        let sorted = discovered.sorted { lhs, rhs in
            if lhs.ipAddress == rhs.ipAddress {
                if lhs.port == rhs.port {
                    return lhs.name < rhs.name
                }
                return lhs.port < rhs.port
            }
            return lhs.ipAddress < rhs.ipAddress
        }

        var uniqueByIP: [String: DetectedTV] = [:]
        for item in sorted {
            if let existing = uniqueByIP[item.ipAddress] {
                let existingLooksUUID = existing.name.lowercased().hasPrefix("uuid:")
                let itemLooksUUID = item.name.lowercased().hasPrefix("uuid:")
                if existingLooksUUID && !itemLooksUUID {
                    uniqueByIP[item.ipAddress] = item
                } else if existing.macAddress == nil, item.macAddress != nil {
                    uniqueByIP[item.ipAddress] = item
                }
            } else {
                uniqueByIP[item.ipAddress] = item
            }
        }

        let result = uniqueByIP.values.sorted { $0.ipAddress < $1.ipAddress }

        stopActiveScan()
        completion?(result)
        completion = nil
    }

    private func stopActiveScan() {
        timeoutTimer?.invalidate()
        timeoutTimer = nil

        for browser in browsers {
            browser.stop()
        }
        browsers.removeAll()

        for resolver in resolvers {
            resolver.stop()
        }
        resolvers.removeAll()
    }

    private func parseIPAddresses(from addresses: [Data]) -> [String] {
        addresses.compactMap { data in
            data.withUnsafeBytes { rawBuffer -> String? in
                guard let baseAddress = rawBuffer.baseAddress else {
                    return nil
                }

                let sockaddrPointer = baseAddress.assumingMemoryBound(to: sockaddr.self)
                let family = Int32(sockaddrPointer.pointee.sa_family)

                var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result: Int32

                if family == AF_INET {
                    result = getnameinfo(
                        sockaddrPointer,
                        socklen_t(MemoryLayout<sockaddr_in>.size),
                        &hostBuffer,
                        socklen_t(hostBuffer.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                } else if family == AF_INET6 {
                    result = getnameinfo(
                        sockaddrPointer,
                        socklen_t(MemoryLayout<sockaddr_in6>.size),
                        &hostBuffer,
                        socklen_t(hostBuffer.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                } else {
                    return nil
                }

                guard result == 0 else {
                    return nil
                }

                return String(cString: hostBuffer)
            }
        }
    }

    private func parseMACAddress(from addresses: [Data]) -> String? {
        for data in addresses {
            let mac = data.withUnsafeBytes { rawBuffer -> String? in
                guard let baseAddress = rawBuffer.baseAddress else {
                    return nil
                }

                let sockaddrPointer = baseAddress.assumingMemoryBound(to: sockaddr.self)
                guard Int32(sockaddrPointer.pointee.sa_family) == AF_LINK else {
                    return nil
                }

                let linkPointer = baseAddress.assumingMemoryBound(to: sockaddr_dl.self)
                let link = linkPointer.pointee
                guard link.sdl_alen > 0 else {
                    return nil
                }

                let nlen = Int(link.sdl_nlen)
                let alen = Int(link.sdl_alen)
                return withUnsafePointer(to: linkPointer.pointee.sdl_data) { dataStart -> String? in
                    let base = UnsafeRawPointer(dataStart).assumingMemoryBound(to: UInt8.self)
                    let macBytes = UnsafeBufferPointer(start: base.advanced(by: nlen), count: alen)
                    guard !macBytes.isEmpty else {
                        return nil
                    }
                    return macBytes.map { String(format: "%02x", $0) }.joined(separator: ":")
                }
            }

            if let mac {
                return mac
            }
        }

        return nil
    }

    private func parseMACAddressFromARP(for ipAddress: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        process.arguments = ["-n", ipAddress]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: outputData, encoding: .utf8)?.lowercased() else {
            return nil
        }

        let pattern = #"[0-9a-f]{2}(:[0-9a-f]{2}){5}"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..<output.endIndex, in: output)),
            let range = Range(match.range, in: output)
        else {
            return nil
        }

        return String(output[range])
    }

    private func isLikelySamsungFrame(service: NetService) -> Bool {
        let txt: [String: Data]
        if let txtData = service.txtRecordData() {
            txt = NetService.dictionary(fromTXTRecord: txtData)
        } else {
            txt = [:]
        }

        let txtValues = txt.values.compactMap { String(data: $0, encoding: .utf8)?.lowercased() }
        let combinedTXT = txtValues.joined(separator: " ")

        let name = service.name.lowercased()
        let host = (service.hostName ?? "").lowercased()

        let samsungSignals = [name, host, combinedTXT].joined(separator: " ")
        let hasSamsung = samsungSignals.contains("samsung") || service.type.contains("samsung")
        let hasFrame = samsungSignals.contains("frame")

        if service.type == "_samsungmsf._tcp." {
            return hasSamsung
        }

        return hasSamsung && hasFrame
    }

    private func addResolvedService(_ service: NetService) {
        guard isLikelySamsungFrame(service: service) else {
            return
        }

        let addresses = service.addresses ?? []
        let allIPs = parseIPAddresses(from: addresses)
        let ipv4 = allIPs.filter { !$0.contains(":") }
        let chosenIPs = ipv4.isEmpty ? allIPs : ipv4
        let discoveredMAC = parseMACAddress(from: addresses)

        for ip in chosenIPs {
            let mac = discoveredMAC ?? parseMACAddressFromARP(for: ip)
            let item = DetectedTV(
                name: service.name,
                hostName: service.hostName ?? "unknown",
                ipAddress: ip,
                macAddress: mac,
                port: service.port,
                serviceType: service.type
            )
            discovered.insert(item)
        }
    }
}

extension TVScanner: NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        _ = browser
        _ = moreComing

        service.delegate = self
        service.schedule(in: .main, forMode: .default)
        service.resolve(withTimeout: 4.0)
        resolvers.append(service)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        _ = browser
        _ = errorDict
    }
}

extension TVScanner: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        addResolvedService(sender)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        _ = sender
        _ = errorDict
    }
}
