import Foundation

protocol ScannerDevice: AnyObject {
    var identity: ScannerIdentity { get }
    var capabilities: ScannerCapabilities { get }
    var status: ScannerStatus { get }

    func open() async throws
    func close() async
    func startScan(options: ScanOptions) async throws -> AsyncThrowingStream<PageFrame, Error>
    func cancel() async
}

protocol ScannerDriver {
    var name: String { get }
    var supportedUSBDeviceIDs: Set<USBDeviceID> { get }

    func canDrive(_ identity: ScannerIdentity) -> Bool
    func makeDevice(identity: ScannerIdentity, transport: USBDeviceTransport?) -> ScannerDevice
}

extension ScannerDriver {
    func canDrive(_ identity: ScannerIdentity) -> Bool {
        guard let usbDeviceID = identity.usbDeviceID else { return false }
        return supportedUSBDeviceIDs.contains(usbDeviceID)
    }
}

protocol ScannerDiscovery {
    func discover() async -> [ScannerIdentity]
}

protocol USBDeviceTransport: Sendable {
    var identity: ScannerIdentity { get }
    var endpointSummary: String { get async }

    func open() async throws
    func close() async
    func abort() async
    func controlTransfer(request: USBControlRequest) async throws -> Data
    func bulkWrite(endpoint: UInt8, data: Data, timeoutMilliseconds: UInt32) async throws
    func bulkRead(endpoint: UInt8, length: Int, timeoutMilliseconds: UInt32) async throws -> Data
}

extension USBDeviceTransport {
    func abort() async {}
}

struct USBControlRequest: Sendable {
    let requestType: UInt8
    let request: UInt8
    let value: UInt16
    let index: UInt16
    let data: Data
    let timeoutMilliseconds: UInt32
}

final class ScannerDriverRegistry {
    private let drivers: [ScannerDriver]

    init(drivers: [ScannerDriver]) {
        self.drivers = drivers
    }

    static let live = ScannerDriverRegistry(
        drivers: [
            FujitsuScanSnapS300Driver(),
            FujitsuScanSnapS1500Driver(),
            ImageCaptureScannerDriver()
        ]
    )

    func driver(for identity: ScannerIdentity) -> ScannerDriver? {
        drivers.first { $0.canDrive(identity) }
    }

    func makeDevice(identity: ScannerIdentity, transport: USBDeviceTransport?) -> ScannerDevice? {
        driver(for: identity)?.makeDevice(identity: identity, transport: transport)
    }

    func capabilities(for identity: ScannerIdentity) -> ScannerCapabilities? {
        driver(for: identity)?.makeDevice(identity: identity, transport: nil).capabilities
    }
}
