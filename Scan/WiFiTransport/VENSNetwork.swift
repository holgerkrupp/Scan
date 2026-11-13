import Darwin
import Foundation

nonisolated struct VENSInterface: Sendable {
    let ipAddress: [UInt8]
    let broadcastAddress: [UInt8]?
    let macAddress: [UInt8]

    /// Active IPv4 interfaces that have a hardware address.
    static func all() -> [VENSInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var macs: [String: [UInt8]] = [:]
        var entries: [(name: String, ip: [UInt8], broadcast: [UInt8]?)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr else { continue }
            let name = String(cString: entry.ifa_name)
            let flags = Int32(entry.ifa_flags)
            if Int32(address.pointee.sa_family) == AF_LINK {
                let link = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_dl.self).pointee
                guard link.sdl_alen == 6 else { continue }
                let offset = MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_data)! + Int(link.sdl_nlen)
                macs[name] = Array(UnsafeRawBufferPointer(start: UnsafeRawPointer(address) + offset, count: 6))
            } else if Int32(address.pointee.sa_family) == AF_INET, flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 {
                let broadcast = flags & IFF_BROADCAST != 0 ? entry.ifa_dstaddr.map(ipv4Bytes) : nil
                entries.append((name, ipv4Bytes(address), broadcast))
            }
        }
        return entries.compactMap { entry in
            macs[entry.name].map { VENSInterface(ipAddress: entry.ip, broadcastAddress: entry.broadcast, macAddress: $0) }
        }
    }

    /// The interface the system would use to reach `scannerIP`.
    static func route(to scannerIP: [UInt8]) -> VENSInterface? {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var remote = socketAddress(ip: scannerIP, port: 9)
        guard withSocketAddress(&remote, { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }) == 0 else { return nil }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withSocketAddress(&local, { getsockname(descriptor, $0, &length) }) == 0 else { return nil }
        let localIP = withUnsafeBytes(of: local.sin_addr) { Array($0) }
        return all().first { $0.ipAddress == localIP }
    }
}

nonisolated func socketAddress(ip: [UInt8], port: UInt16) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    withUnsafeMutableBytes(of: &address.sin_addr) { $0.copyBytes(from: ip.prefix(4)) }
    return address
}

nonisolated func withSocketAddress<T>(_ address: inout sockaddr_in, _ body: (UnsafeMutablePointer<sockaddr>) -> T) -> T {
    withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1, body) }
}

nonisolated private func ipv4Bytes(_ address: UnsafeMutablePointer<sockaddr>) -> [UInt8] {
    let ipv4 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee
    return withUnsafeBytes(of: ipv4.sin_addr) { Array($0) }
}

/// A blocking TCP connection with timeouts. `interrupt()` may be called from
/// another thread to wake a blocked read when a scan is cancelled.
nonisolated final class VENSSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32

    init(ip: [UInt8], port: UInt16, timeout: TimeInterval) throws {
        descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw VENSError.scannerNotReachable }
        do {
            try connectWithTimeout(ip: ip, port: port, timeout: timeout)
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    private func connectWithTimeout(ip: [UInt8], port: UInt16, timeout: TimeInterval) throws {
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var limit = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))

        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        var address = socketAddress(ip: ip, port: port)
        let target = descriptor
        let result = withSocketAddress(&address) { connect(target, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        if result != 0 {
            guard errno == EINPROGRESS else { throw VENSError.scannerNotReachable }
            var waiter = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            guard poll(&waiter, 1, Int32(timeout * 1000)) == 1 else { throw VENSError.scannerNotReachable }
            var failure: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &length) == 0, failure == 0 else {
                throw VENSError.scannerNotReachable
            }
        }
        _ = fcntl(descriptor, F_SETFL, flags)
    }

    private var currentDescriptor: Int32 {
        lock.lock(); defer { lock.unlock() }
        return descriptor
    }

    func send(_ bytes: [UInt8]) throws {
        let target = currentDescriptor
        var sent = 0
        try bytes.withUnsafeBytes { buffer in
            while sent < buffer.count {
                let count = Darwin.send(target, buffer.baseAddress! + sent, buffer.count - sent, 0)
                guard count > 0 else { throw VENSError.connectionLost(count == 0 ? "closed by the scanner" : errno == EAGAIN ? "no answer from the scanner" : String(cString: strerror(errno))) }
                sent += count
            }
        }
    }

    func read(exactly length: Int) throws -> [UInt8] {
        let target = currentDescriptor
        var bytes = [UInt8](repeating: 0, count: length)
        var received = 0
        try bytes.withUnsafeMutableBytes { buffer in
            while received < length {
                let count = recv(target, buffer.baseAddress! + received, length - received, 0)
                guard count > 0 else { throw VENSError.connectionLost(count == 0 ? "closed by the scanner" : errno == EAGAIN ? "no answer from the scanner" : String(cString: strerror(errno))) }
                received += count
            }
        }
        return bytes
    }

    func readFrame() throws -> [UInt8] {
        let head = try read(exactly: 8)
        guard Array(head[4..<8]) == VENS.magic else { throw VENSError.protocolViolation("Unexpected reply from the scanner.") }
        let length = Int(head[0]) << 24 | Int(head[1]) << 16 | Int(head[2]) << 8 | Int(head[3])
        guard (VENS.serverHeaderLength...VENS.maximumFrameLength).contains(length) else {
            throw VENSError.protocolViolation("Invalid frame length (\(length)).")
        }
        return try head + read(exactly: length - 8)
    }

    func interrupt() {
        let target = currentDescriptor
        if target >= 0 { shutdown(target, SHUT_RDWR) }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
    }
}

/// One connection to the scan channel: SCSI commands tunnelled over TCP.
nonisolated final class VENSChannel {
    static let checkCondition: UInt32 = 2

    let socket: VENSSocket
    private let mac: [UInt8]

    init(ip: [UInt8], mac: [UInt8], timeout: TimeInterval = 60) throws {
        socket = try VENSSocket(ip: ip, port: VENS.scanPort, timeout: timeout)
        self.mac = mac
        guard try socket.readFrame().count == VENS.serverHeaderLength else {
            throw VENSError.protocolViolation("Unexpected greeting from the scanner.")
        }
    }

    func command(_ cdb: [UInt8], output: [UInt8] = [], inputLength: Int = 0) throws -> (status: UInt32, data: [UInt8]) {
        try socket.send(VENS.scsiFrame(mac: mac, cdb: cdb, output: output, inputLength: inputLength))
        let reply = try socket.readFrame()
        guard reply.count >= VENS.scsiReplyHeaderLength else { throw VENSError.protocolViolation("SCSI reply too short.") }
        let status = UInt32(reply[12]) << 24 | UInt32(reply[13]) << 16 | UInt32(reply[14]) << 8 | UInt32(reply[15])
        return (status, Array(reply[VENS.scsiReplyHeaderLength...]))
    }

    func requestSense() throws -> VENSSense {
        guard let sense = VENSSense(try command(VENS.requestSenseCDB, inputLength: 0x12).data) else {
            throw VENSError.protocolViolation("Scanner diagnostic data too short.")
        }
        return sense
    }

    @discardableResult
    func checked(_ cdb: [UInt8], output: [UInt8] = [], inputLength: Int = 0) throws -> [UInt8] {
        let reply = try command(cdb, output: output, inputLength: inputLength)
        if reply.status == Self.checkCondition {
            let sense = try requestSense()
            throw sense.paperError ?? VENSError.commandFailed(String(format: "Command %02x failed (%@).", cdb[0], sense.description))
        }
        guard reply.status == 0 else { throw VENSError.commandFailed(String(format: "Command %02x failed (status %d).", cdb[0], reply.status)) }
        return reply.data
    }

    func close() { socket.close() }
}

/// Finds iX500 scanners on the local network with a UDP broadcast, and asks
/// known addresses directly: macOS's firewall can drop answers to a broadcast
/// but lets answers to a direct probe through. Only the discovery probe is
/// sent: this neither registers nor opens a session.
nonisolated enum VENSProbe {
    static func discover(knownAddresses: [[UInt8]] = [], timeout: TimeInterval = 1.5) -> [VENSScannerInfo] {
        let interfaces = VENSInterface.all()
        let broadcasts = interfaces.compactMap { interface in interface.broadcastAddress.map { (interface: interface, address: $0) } }
        let direct = knownAddresses.flatMap { address in interfaces.map { (interface: $0, address: address) } }
        return send(targets: broadcasts + direct, timeout: timeout)
    }

    static func query(ip: [UInt8], interface: VENSInterface, timeout: TimeInterval = 1.0) -> VENSScannerInfo? {
        send(targets: [(interface, ip)], timeout: timeout).first { $0.ipAddress == ip }
    }

    private static func send(targets: [(interface: VENSInterface, address: [UInt8])], timeout: TimeInterval) -> [VENSScannerInfo] {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0, !targets.isEmpty else { return [] }
        defer { close(descriptor) }
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var local = socketAddress(ip: [0, 0, 0, 0], port: 0)
        guard withSocketAddress(&local, { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }) == 0 else { return [] }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withSocketAddress(&bound, { getsockname(descriptor, $0, &length) }) == 0 else { return [] }
        let replyPort = UInt16(bigEndian: bound.sin_port)

        for _ in 0..<3 { // UDP: a single probe or reply can be lost
            for target in targets {
                let probe = VENS.probe(hostIP: target.interface.ipAddress, hostMAC: target.interface.macAddress, replyPort: replyPort)
                var destination = socketAddress(ip: target.address, port: VENS.discoveryPort)
                _ = withSocketAddress(&destination) { sendto(descriptor, probe, probe.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            usleep(100_000)
        }

        var found: [VENSScannerInfo] = []
        let deadline = Date().addingTimeInterval(timeout)
        while case let remaining = deadline.timeIntervalSinceNow, remaining > 0 {
            var waiter = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&waiter, 1, Int32(remaining * 1000)) == 1 else { break }
            var buffer = [UInt8](repeating: 0, count: 2048)
            var sender = sockaddr_in()
            var senderLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withSocketAddress(&sender) { recvfrom(descriptor, &buffer, buffer.count, 0, $0, &senderLength) }
            guard count > 0, let info = VENS.parseDiscoveryReply(Array(buffer.prefix(count))), info.isIX500 else { continue }
            let senderIP = withUnsafeBytes(of: sender.sin_addr) { Array($0) }
            if info.ipAddress == senderIP, !found.contains(where: { $0.ipAddress == senderIP }) { found.append(info) }
        }
        return found
    }
}

/// Receives the scanner's UDP notices (button, lid closed, lid opened) for the whole app.
nonisolated final class VENSNotificationListener: @unchecked Sendable {
    static let shared = VENSNotificationListener()
    typealias Handler = @Sendable (_ senderIP: [UInt8], _ notification: VENSNotification) -> Void

    private let lock = NSLock()
    private var handlers: [UUID: Handler] = [:]
    private var started = false
    private let delivery = DispatchQueue(label: "vens.notifications")
    private var lastNotice: (ip: [UInt8], notification: VENSNotification, time: Date)?

    @discardableResult
    func subscribe(_ handler: @escaping Handler) -> UUID {
        lock.lock(); defer { lock.unlock() }
        let id = UUID()
        handlers[id] = handler
        if !started {
            started = true
            Thread.detachNewThread { [self] in run() }
        }
        return id
    }

    private func bound(port: UInt16) -> Int32? {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { return nil }
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var local = socketAddress(ip: [0, 0, 0, 0], port: port)
        guard withSocketAddress(&local, { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }) == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    private func run() {
        // A port another program still holds is tried again later.
        var sockets: [UInt16: Int32] = [:]
        let ports = [UInt16(VENS.notificationPort), VENS.startupNoticePort]
        var nextBind = Date.distantPast
        while true {
            if sockets.count < ports.count, Date() >= nextBind {
                for port in ports where sockets[port] == nil { sockets[port] = bound(port: port) }
                nextBind = Date().addingTimeInterval(5)
            }
            var waiters = sockets.values.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            guard !waiters.isEmpty, poll(&waiters, nfds_t(waiters.count), 1000) > 0 else {
                if waiters.isEmpty { usleep(1_000_000) }
                continue
            }
            for waiter in waiters where waiter.revents & Int16(POLLIN) != 0 { receive(from: waiter.fd) }
        }
    }

    private func receive(from descriptor: Int32) {
        var buffer = [UInt8](repeating: 0, count: 2048)
        var sender = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = withSocketAddress(&sender) { recvfrom(descriptor, &buffer, buffer.count, 0, $0, &length) }
        guard count > 0, let notification = VENS.parseNotification(Array(buffer.prefix(count))) else { return }
        let ip = withUnsafeBytes(of: sender.sin_addr) { Array($0) }
        lock.lock(); defer { lock.unlock() }
        if let last = lastNotice, last.ip == ip, last.notification == notification, Date().timeIntervalSince(last.time) < 3 { return }
        lastNotice = (ip, notification, Date())
        let current = Array(handlers.values)
        delivery.async { current.forEach { $0(ip, notification) } }
    }
}

/// UDP keep-alive sent while a session is open, every 500 ms like the reference clients.
/// The scanner answers each one; when the answers stop, it has dropped the session.
nonisolated final class VENSHeartbeat: @unchecked Sendable {
    /// Without an answer for this long, the scanner is taken to have dropped the session.
    static let silenceLimit: TimeInterval = 10
    private let lock = NSLock()
    private var stopped = false

    /// `onSilence` is called on the heartbeat thread each time the scanner has been silent for `silenceLimit`.
    func start(scannerIP: [UInt8], interface: VENSInterface, onSilence: @escaping @Sendable () -> Void) {
        Thread.detachNewThread { [self] in
            while !isStopped {
                run(scannerIP: scannerIP, interface: interface)
                if !isStopped { onSilence() }
            }
        }
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    /// Sends on a fresh socket until the scanner stays silent for `silenceLimit`.
    private func run(scannerIP: [UInt8], interface: VENSInterface) {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { usleep(500_000); return }
        defer { close(descriptor) }
        var local = socketAddress(ip: [0, 0, 0, 0], port: VENS.heartbeatSourcePort)
        if withSocketAddress(&local, { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }) != 0 {
            var fallback = socketAddress(ip: [0, 0, 0, 0], port: 0)
            _ = withSocketAddress(&fallback) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withSocketAddress(&bound) { getsockname(descriptor, $0, &length) }
        let probe = VENS.probe(hostIP: interface.ipAddress, hostMAC: interface.macAddress, replyPort: UInt16(bigEndian: bound.sin_port), flag: VENS.heartbeatFlag, sequence: 1)
        var scanner = socketAddress(ip: scannerIP, port: VENS.discoveryPort)
        var discard = [UInt8](repeating: 0, count: 64)
        var lastAnswer = Date()
        var lastSendError: Int32 = 0
        while !isStopped {
            let sent = withSocketAddress(&scanner) { sendto(descriptor, probe, probe.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            let sendError = sent < 0 ? errno : 0
            if sendError != lastSendError, sendError != 0 {
                ScanTrace.post("Wi-Fi: the keep-alive could not be sent (\(String(cString: strerror(sendError)))).")
            }
            lastSendError = sendError
            while recv(descriptor, &discard, discard.count, MSG_DONTWAIT) > 0 { lastAnswer = Date() }
            if Date().timeIntervalSince(lastAnswer) > Self.silenceLimit { return }
            usleep(500_000)
        }
    }
}
