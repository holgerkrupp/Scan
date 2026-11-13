import Foundation

final class VENSScannerDiscovery: ScannerDiscovery {
    private nonisolated static let knownAddressesKey = "scan.wifi.knownAddresses"

    private nonisolated static func knownAddresses(in defaults: UserDefaults) -> [[UInt8]] {
        (defaults.stringArray(forKey: knownAddressesKey) ?? []).map { $0.split(separator: ".").compactMap { UInt8($0) } }.filter { $0.count == 4 }
    }

    private nonisolated static func remember(_ address: [UInt8], in defaults: UserDefaults) {
        let text = address.map(String.init).joined(separator: ".")
        var known = defaults.stringArray(forKey: knownAddressesKey) ?? []
        guard known.first != text else { return }
        known.removeAll { $0 == text }
        defaults.set(Array(([text] + known).prefix(4)), forKey: knownAddressesKey)
    }

    private let probe: @Sendable ([[UInt8]]) -> [VENSScannerInfo]
    /// Where the last known addresses are kept; tests pass their own.
    private let defaults: UserDefaults
    /// A scanner stops answering discovery while this app holds a session with
    /// it, so one that has answered stays listed until it says its lid closed.
    private var identities: [ScannerIdentity] = []
    private var closedLids: Set<UInt32> = []

    init(defaults: UserDefaults = .standard, probe: @escaping @Sendable ([[UInt8]]) -> [VENSScannerInfo] = { VENSProbe.discover(knownAddresses: $0) }) {
        self.defaults = defaults
        self.probe = probe
    }

    private nonisolated static func location(of address: [UInt8]) -> UInt32 {
        address.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    func discover() async -> [ScannerIdentity] {
        let addresses = Self.knownAddresses(in: defaults)
        let probe = self.probe
        let found = await Task.detached { probe(addresses) }.value
        for info in found {
            Self.remember(info.ipAddress, in: defaults)
            let location = Self.location(of: info.ipAddress)
            let identity = ScannerIdentity(
                name: "ScanSnap iX500 (Wi-Fi)",
                manufacturer: "Fujitsu",
                model: info.model,
                serialNumber: info.serialNumber,
                connectionKind: .wifi,
                usbDeviceID: nil,
                locationID: location,
                persistentID: info.serialNumber
            )
            closedLids.remove(location)
            if let index = identities.firstIndex(where: { $0.id == identity.id }) { identities[index] = identity } else { identities.append(identity) }
        }
        return identities.filter { !closedLids.contains($0.locationID ?? 0) }
    }

    func scannerAnnounced(lidOpen: Bool, from address: [UInt8]) {
        let location = Self.location(of: address)
        if lidOpen { closedLids.remove(location) } else { closedLids.insert(location) }
    }

    /// Opening or closing the lid is announced by the scanner.
    func observeChanges(_ onChange: @escaping @MainActor () -> Void) {
        // UserDefaults is thread-safe; the notices arrive on the listener's queue.
        nonisolated(unsafe) let defaults = self.defaults
        VENSNotificationListener.shared.subscribe { [weak self] sender, notification in
            guard notification.event == VENS.powerOnEvent || notification.event == VENS.powerOffEvent else { return }
            Self.remember(sender, in: defaults)
            let lidOpen = notification.event == VENS.powerOnEvent
            Task { @MainActor in
                self?.scannerAnnounced(lidOpen: lidOpen, from: sender)
                onChange()
            }
        }
    }
}

struct FujitsuScanSnapIX500WiFiDriver: ScannerDriver {
    let name = "Fujitsu ScanSnap iX500 (Wi-Fi)"
    let supportedUSBDeviceIDs: Set<USBDeviceID> = []
    func canDrive(_ identity: ScannerIdentity) -> Bool { identity.connectionKind == .wifi }
    func makeDevice(identity: ScannerIdentity, transport: USBDeviceTransport?) -> ScannerDevice { FujitsuScanSnapWiFiDevice(identity: identity) }
}

/// The host identifier the scanner requires when a computer registers.
///
/// Today it can only be one the scanner already knows, so the value it reports
/// over Wi-Fi is remembered per scanner. Registering a new computer in the
/// scanner's host table is a separate step, and this is where it will plug in.
nonisolated enum VENSHostIdentity {
    private static func key(serial: String) -> String { "scan.wifi.hostID.\(serial)" }

    static func hostID(for info: VENSScannerInfo, defaults: UserDefaults = .standard) throws -> [UInt8] {
        if let saved = defaults.data(forKey: key(serial: info.serialNumber)), saved.count == 8 { return Array(saved) }
        guard info.registeredHostID.contains(where: { $0 != 0 }) else { throw VENSError.notPaired }
        defaults.set(Data(info.registeredHostID), forKey: key(serial: info.serialNumber))
        return info.registeredHostID
    }
}

/// Lets `cancel()` wake the scan thread, which is blocked on the network.
nonisolated final class VENSCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var socket: VENSSocket?

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func attach(_ socket: VENSSocket?) {
        lock.lock(); defer { lock.unlock() }
        self.socket = socket
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        socket?.interrupt()
    }
}

/// The app's single registration with a scanner. It outlives individual scans:
/// the Scan button only works while the scanner considers this Mac registered,
/// and registering again without need can be rejected. Blocking calls: use off
/// the main actor.
nonisolated final class VENSSession: @unchecked Sendable {
    private nonisolated(unsafe) static var sessions: [[UInt8]: VENSSession] = [:]
    private static let sessionsLock = NSLock()

    private let ip: [UInt8]
    private let registration = NSLock() // held for the whole of a registration
    private let state = NSLock()
    private let heartbeat = VENSHeartbeat()
    private var registered = false
    /// The scanner went silent while registered and has not taken this Mac back yet.
    private var lost = false
    private var isScanning = false
    private var running = false
    private var mac: [UInt8] = []
    private var inquiryText = "?"
    /// The last discovery reply: the scanner does not answer while a session is still open.
    private var lastInfo: VENSScannerInfo?
    private var buttonHandler: (@Sendable () -> Void)?

    private init(ip: [UInt8]) { self.ip = ip }

    static func shared(ip: [UInt8]) throws -> VENSSession {
        sessionsLock.lock()
        let session = sessions[ip] ?? VENSSession(ip: ip)
        sessions[ip] = session
        sessionsLock.unlock()
        try session.ensureRegistered()
        return session
    }

    var inquiry: String {
        state.lock(); defer { state.unlock() }
        return inquiryText
    }

    private var hostMAC: [UInt8] {
        state.lock(); defer { state.unlock() }
        return mac
    }

    private func setRegistered(_ value: Bool) {
        state.lock(); defer { state.unlock() }
        registered = value
    }

    func setButtonHandler(_ handler: (@Sendable () -> Void)?) {
        state.lock(); defer { state.unlock() }
        buttonHandler = handler
    }

    private func ensureRegistered() throws {
        registration.lock(); defer { registration.unlock() }
        state.lock()
        let alreadyRegistered = registered
        let previousInfo = lastInfo
        state.unlock()
        guard !alreadyRegistered else { return }

        guard let interface = VENSInterface.route(to: ip) else { throw VENSError.noRouteToScanner }
        guard let info = VENSProbe.query(ip: ip, interface: interface) ?? previousInfo else { throw VENSError.scannerNotReachable }
        let hostID = try VENSHostIdentity.hostID(for: info)
        try Self.register(info: info, interface: interface, hostID: hostID)

        let channel = try VENSChannel(ip: ip, mac: interface.macAddress, timeout: 10)
        defer { channel.close() }
        let reply = try channel.checked(VENS.inquiryCDB, inputLength: 0x60)
        try channel.checked(VENS.hardwareStatusCDB, inputLength: 0x20)

        state.lock()
        registered = true
        lost = false
        lastInfo = info
        mac = interface.macAddress
        if reply.count >= 36 { inquiryText = String(decoding: reply[8..<36], as: UTF8.self) }
        let startsNow = !running
        running = true
        state.unlock()
        if startsNow {
            heartbeat.start(scannerIP: ip, interface: interface) { [weak self] in self?.heartbeatWentSilent() }
            VENSNotificationListener.shared.subscribe { [weak self] sender, notification in
                self?.handle(notification, from: sender)
            }
        }
    }

    /// The scanner stopped answering the keep-alive while this Mac thought it was
    /// registered (seen on an overloaded Mac): the Scan button then stays silent
    /// until this Mac registers again. Retried at each silence until it works or
    /// the lid is closed.
    private func heartbeatWentSilent() {
        state.lock()
        let shouldRegister = (registered || lost) && !isScanning
        if shouldRegister { registered = false; lost = true }
        state.unlock()
        guard shouldRegister else { return }
        ScanTrace.post("Wi-Fi: the scanner stopped answering; registering again.")
        do {
            try ensureRegistered()
            ScanTrace.post("Wi-Fi: registered again.")
        } catch {
            ScanTrace.post("Wi-Fi: could not register again (\(error.localizedDescription)).")
        }
    }

    private func setScanning(_ value: Bool) {
        state.lock(); defer { state.unlock() }
        isScanning = value
    }

    private func handle(_ notification: VENSNotification, from sender: [UInt8]) {
        guard sender == ip else { return }
        switch notification.event {
        case VENS.buttonPressedEvent:
            state.lock()
            let handler = buttonHandler
            state.unlock()
            handler?()
        case VENS.powerOffEvent:
            state.lock(); registered = false; lost = false; state.unlock()
        case VENS.powerOnEvent:
            // The lid was opened: without a new registration the button stays silent.
            setRegistered(false)
            try? ensureRegistered()
        default:
            break
        }
    }

    private static func register(info: VENSScannerInfo, interface: VENSInterface, hostID: [UInt8]) throws {
        let socket = try VENSSocket(ip: info.ipAddress, port: VENS.controlPort, timeout: 10)
        defer { socket.close() }
        guard try socket.readFrame().count == VENS.serverHeaderLength else {
            throw VENSError.protocolViolation("Unexpected greeting from the scanner.")
        }
        let body = VENS.registrationBody(
            interfaceVersion: info.interfaceVersion, hostIP: interface.ipAddress,
            password: String(info.serialNumber.suffix(4)), hostID: hostID, date: Date(), timeZone: .current
        )
        try socket.send(VENS.clientFrame(command: 0x11, mac: interface.macAddress, body: body))
        guard let status = VENS.registrationStatus(reply: try socket.readFrame()) else {
            throw VENSError.protocolViolation("Registration reply too short.")
        }
        guard status == 0 else { throw VENSError.registrationRejected(status) }
    }

    /// Scans until the feeder is empty, handing over each sheet's front and back JPEG.
    ///
    /// The scanner can end a Wi-Fi transfer while paper remains, and the image
    /// index only allows so many sheets per transfer, so a long batch is
    /// carried over several transfers. Anything but a clean end is thrown: a
    /// sheet that may be lost must never be skipped silently.
    func scan(dpi: Int, ultrasonicDoubleFeedDetection: Bool, cancellation: VENSCancellation, onSheet: (_ front: [UInt8], _ back: [UInt8]) async throws -> Void) async throws {
        setScanning(true)
        defer { setScanning(false) }
        var total = 0
        while !cancellation.isCancelled {
            let transfer = try await scanTransfer(dpi: dpi, ultrasonicDoubleFeedDetection: ultrasonicDoubleFeedDetection, cancellation: cancellation, onSheet: onSheet)
            total += transfer.sheets
            guard transfer.paperRemains, transfer.sheets > 0, !cancellation.isCancelled else { break }
            setRegistered(false)
            try ensureRegistered()
        }
        if total == 0, !cancellation.isCancelled { throw ScannerError.feederEmpty }
    }

    private func scanTransfer(dpi: Int, ultrasonicDoubleFeedDetection: Bool, cancellation: VENSCancellation, onSheet: (_ front: [UInt8], _ back: [UInt8]) async throws -> Void) async throws -> (sheets: Int, paperRemains: Bool) {
        let channel = try VENSChannel(ip: ip, mac: hostMAC)
        cancellation.attach(channel.socket)
        defer {
            cancellation.attach(nil)
            channel.close()
        }
        let transfer: (sheets: Int, paperRemains: Bool)
        do {
            transfer = try await scanSheets(channel: channel, dpi: dpi, ultrasonicDoubleFeedDetection: ultrasonicDoubleFeedDetection, cancellation: cancellation, onSheet: onSheet)
        } catch {
            channel.close()
            try? release()
            // A paper problem leaves the session intact; anything else may not have.
            if case VENSError.paper = error {} else { setRegistered(false) }
            throw error
        }
        // The scanner only answers the release once the scan connection is closed.
        channel.close()
        do { try release() } catch {
            // Every sheet has been received: the next scan registers again.
            ScanTrace.post("Wi-Fi: could not release the scanner: \(error.localizedDescription)")
            setRegistered(false)
        }
        return transfer
    }

    private func scanSheets(channel: VENSChannel, dpi: Int, ultrasonicDoubleFeedDetection: Bool, cancellation: VENSCancellation, onSheet: (_ front: [UInt8], _ back: [UInt8]) async throws -> Void) async throws -> (sheets: Int, paperRemains: Bool) {
        try channel.checked(VENS.hardwareStatusCDB, inputLength: 0x20)
        try channel.checked(VENS.openSessionCDB, output: [UInt8](repeating: 0, count: 8), inputLength: 8)
        try channel.checked(VENS.startJobCDB)
        try channel.checked(VENS.setWindowCDB, output: VENS.windowBlock(dpi: dpi))
        try channel.checked(VENS.setParametersCDB, output: VENS.parameterBlock(dpi: dpi, ultrasonicDoubleFeedDetection: ultrasonicDoubleFeedDetection))
        try channel.checked(VENS.hardwareStatusCDB, inputLength: 0x20)
        _ = try channel.requestSense()

        var imageIndex = 0
        var sheets = 0
        while !cancellation.isCancelled {
            guard sheets < VENS.maximumSheetsPerTransfer else { return (sheets, true) }
            let feed = try channel.command(VENS.feedCDB)
            if feed.status == VENSChannel.checkCondition {
                let sense = try channel.requestSense()
                if sense.isFeederEmpty {
                    // The end of a transfer looks the same as an empty feeder: ask the sensor.
                    let hopper = try? channel.checked(VENS.hardwareStatusCDB, inputLength: 0x20)
                    return (sheets, hopper.flatMap(VENS.hopperHasPaper) ?? false)
                }
                throw sense.paperError ?? VENSError.commandFailed("Feeding failed (\(sense.description)).")
            }
            guard feed.status == 0 else { throw VENSError.commandFailed("Feeding failed (status \(feed.status)).") }
            let front = try readImage(channel: channel, back: false, imageIndex: imageIndex)
            let back = try readImage(channel: channel, back: true, imageIndex: imageIndex + 1)
            try channel.checked(VENS.imageInfoCDB(imageIndex: imageIndex + 1), inputLength: 0x20)
            try channel.checked(VENS.hardwareStatusCDB, inputLength: 0x20)
            imageIndex += 2
            sheets += 1
            try await onSheet(front, back)
        }
        return (sheets, false)
    }

    private func readImage(channel: VENSChannel, back: Bool, imageIndex: Int) throws -> [UInt8] {
        var image: [UInt8] = []
        for chunk in 0..<256 {
            let reply = try channel.command(VENS.readImageCDB(back: back, imageIndex: imageIndex), inputLength: VENS.readLength)
            var ended = false
            if reply.status == VENSChannel.checkCondition {
                let sense = try channel.requestSense()
                guard sense.endOfMedium else { throw sense.paperError ?? VENSError.commandFailed("Reading failed (\(sense.description)).") }
                ended = true
            } else if reply.status != 0 {
                throw VENSError.commandFailed("Reading failed (status \(reply.status)).")
            }
            guard reply.data.count >= 2, reply.data[0] == UInt8(imageIndex & 0xff), reply.data[1] == UInt8(chunk) else {
                throw VENSError.protocolViolation("Unexpected header for image \(imageIndex).")
            }
            image += reply.data[2...]
            guard image.count <= VENS.maximumImageLength else { throw VENSError.protocolViolation("Abnormally large image.") }
            if ended { return image }
        }
        throw VENSError.protocolViolation("Image split into too many pieces.")
    }

    private func release() throws {
        let channel = try VENSChannel(ip: ip, mac: hostMAC, timeout: 10)
        defer { channel.close() }
        try channel.checked(VENS.releaseCDB)
    }
}

final class FujitsuScanSnapWiFiDevice: ScannerDevice, ScannerHardwareEventSource {
    let identity: ScannerIdentity
    let capabilities = ScannerCapabilities(
        sources: [.adfFront, .adfDuplex],
        colorModes: [.color, .gray, .lineart],
        resolutionsDPI: VENS.supportedResolutions,
        supportsDuplex: true
    )
    let hardwareEventCapabilities = ScannerHardwareEventCapabilities(
        scanButton: .supportedUnvalidated,
        supportsOneTouchScanning: true,
        detail: "The scanner announces the Scan button over Wi-Fi to the registered Mac."
    )
    private(set) var status: ScannerStatus = .disconnected
    private var session: VENSSession?
    private var cancellation = VENSCancellation()
    private var buttonContinuation: AsyncStream<ScannerHardwareEvent>.Continuation?

    init(identity: ScannerIdentity) { self.identity = identity }

    private var scannerIP: [UInt8] {
        let value = identity.locationID ?? 0
        return [UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]
    }

    func open() async throws {
        let ip = scannerIP
        ScanTrace.post("Wi-Fi: connecting to the scanner at \(ip.map(String.init).joined(separator: ".")).")
        let connected = try await Task.detached { try VENSSession.shared(ip: ip) }.value
        session = connected
        status = .idle
        ScanTrace.post("Wi-Fi: registered, inquiry \(connected.inquiry).")
    }

    /// Leaves the registration in place, so the Scan button keeps working.
    func close() async {
        await stopHardwareEventObservation()
        session = nil
        status = .disconnected
    }

    func startHardwareEventObservation() async throws -> AsyncStream<ScannerHardwareEvent> {
        guard let session else { throw ScannerError.transportUnavailable("Open the scanner before observing its hardware button.") }
        await stopHardwareEventObservation()
        let stream = AsyncStream<ScannerHardwareEvent> { continuation in
            buttonContinuation = continuation
            session.setButtonHandler { continuation.yield(.scanButtonPressed) }
        }
        ScanTrace.post("Wi-Fi: listening for the physical Scan button.")
        return stream
    }

    func stopHardwareEventObservation() async {
        guard let continuation = buttonContinuation else { return }
        session?.setButtonHandler(nil)
        continuation.finish()
        buttonContinuation = nil
    }

    func startScan(options: ScanOptions) async throws -> AsyncThrowingStream<PageFrame, Error> {
        await stopHardwareEventObservation()
        try capabilities.validate(options)
        guard let session else { throw ScannerError.transportUnavailable("The Wi-Fi session with the scanner is not open.") }
        status = .scanning(progress: nil, pagesScanned: 0)
        let cancellation = VENSCancellation()
        self.cancellation = cancellation
        let dpi = options.acquisition.resolutionDPI
        let colorMode = options.acquisition.colorMode
        let includesBack = options.acquisition.source == .adfDuplex
        let detectsDoubleFeed = ScannerFeedSettingsStore(defaults: .standard).load(for: identity).multifeedDetection.usesUltrasonicSensor

        return AsyncThrowingStream { continuation in
            Task.detached { [weak self] in
                var pageIndex = 0
                do {
                    try await session.scan(dpi: dpi, ultrasonicDoubleFeedDetection: detectsDoubleFeed, cancellation: cancellation) { front, back in
                        let sides: [(PageSide, [UInt8])] = includesBack ? [(.front, front), (.back, back)] : [(.front, front)]
                        for (side, jpeg) in sides {
                            let finished = try await FujitsuScanSnapImageDecoder.finishHardwareJPEG(Data(jpeg), outputColorMode: colorMode)
                            pageIndex += 1
                            continuation.yield(PageFrame(pageIndex: pageIndex, side: side, pixelFormat: .jpeg, width: finished.size.width, height: finished.size.height, resolutionDPI: dpi, data: finished.data))
                            await self?.setStatus(.scanning(progress: nil, pagesScanned: pageIndex))
                        }
                    }
                    await self?.setStatus(.idle)
                    if cancellation.isCancelled { continuation.finish(throwing: ScannerError.scanCancelled) } else { continuation.finish() }
                } catch {
                    if cancellation.isCancelled {
                        await self?.setStatus(.idle)
                        continuation.finish(throwing: ScannerError.scanCancelled)
                    } else {
                        await self?.setStatus(.error(error.localizedDescription))
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }

    private func setStatus(_ newValue: ScannerStatus) { status = newValue }

    func cancel() async {
        cancellation.cancel()
    }
}
