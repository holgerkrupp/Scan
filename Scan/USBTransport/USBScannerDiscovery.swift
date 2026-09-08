import Foundation
import IOKit
import IOKit.usb

final class USBScannerDiscovery: ScannerDiscovery {
    private let matchingVendorIDs: Set<UInt16>

    init(matchingVendorIDs: Set<UInt16> = [0x04c5]) {
        self.matchingVendorIDs = matchingVendorIDs
    }

    func discover() async -> [ScannerIdentity] {
        USBDeviceEnumerator().discoverDevices(matchingVendorIDs: matchingVendorIDs)
    }
}

struct USBDeviceEnumerator {
    func discoverDevices(matchingVendorIDs: Set<UInt16>) -> [ScannerIdentity] {
        let matching = IOServiceMatching(kIOUSBDeviceClassName)
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var identities: [ScannerIdentity] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }

            guard
                let vendorID = readUInt16Property("idVendor", from: service),
                matchingVendorIDs.contains(vendorID),
                let productID = readUInt16Property("idProduct", from: service)
            else {
                continue
            }

            let productName = readStringProperty("USB Product Name", from: service)
                ?? readStringProperty("Product Name", from: service)
                ?? "USB Scanner"
            let manufacturer = readStringProperty("USB Vendor Name", from: service)
                ?? readStringProperty("Manufacturer", from: service)
                ?? "Fujitsu"
            let serial = readStringProperty("USB Serial Number", from: service)
            let locationID = readUInt32Property("locationID", from: service)
            let deviceID = USBDeviceID(vendorID: vendorID, productID: productID)

            identities.append(
                ScannerIdentity(
                    name: productName,
                    manufacturer: manufacturer,
                    model: productName,
                    serialNumber: serial,
                    connectionKind: .usb,
                    usbDeviceID: deviceID,
                    locationID: locationID
                )
            )
        }

        return identities.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func readUInt16Property(_ key: String, from service: io_service_t) -> UInt16? {
        readNumberProperty(key, from: service).map { UInt16(truncatingIfNeeded: $0.uint32Value) }
    }

    private func readUInt32Property(_ key: String, from service: io_service_t) -> UInt32? {
        readNumberProperty(key, from: service)?.uint32Value
    }

    private func readNumberProperty(_ key: String, from service: io_service_t) -> NSNumber? {
        let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? NSNumber
    }

    private func readStringProperty(_ key: String, from service: io_service_t) -> String? {
        let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? String
    }
}

final class IOKitUSBDeviceTransport: @unchecked Sendable, USBDeviceTransport {
    let identity: ScannerIdentity
    private let hostTransport = ScanUSBHostTransport()
    private let ioQueue = DispatchQueue(label: "de.holgerkrupp.Scan.usb-transport", qos: .userInitiated)

    init(identity: ScannerIdentity) {
        self.identity = identity
    }

    var endpointSummary: String {
        get async {
            await withCheckedContinuation { continuation in
                ioQueue.async {
                    continuation.resume(returning: self.hostTransport.endpointSummary)
                }
            }
        }
    }

    func open() async throws {
        guard let usbDeviceID = identity.usbDeviceID else {
            throw ScannerError.transportUnavailable("Missing USB identity.")
        }
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async {
                do {
                    try self.hostTransport.open(
                        withVendorID: usbDeviceID.vendorID,
                        productID: usbDeviceID.productID,
                        locationID: self.identity.locationID ?? 0
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: ScannerError.transportUnavailable(error.localizedDescription))
                }
            }
        }
    }

    func close() async {
        await withCheckedContinuation { continuation in
            ioQueue.async {
                self.hostTransport.close()
                continuation.resume()
            }
        }
    }

    func controlTransfer(request: USBControlRequest) async throws -> Data {
        throw ScannerError.protocolNotImplemented("Control transfers are not used by the Fujitsu SCSI-over-USB command flow.")
    }

    func bulkWrite(endpoint: UInt8, data: Data, timeoutMilliseconds: UInt32) async throws {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async {
                do {
                    try self.hostTransport.bulkWrite(data, timeout: TimeInterval(timeoutMilliseconds) / 1000.0)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: ScannerError.transportUnavailable(error.localizedDescription))
                }
            }
        }
    }

    func bulkRead(endpoint: UInt8, length: Int, timeoutMilliseconds: UInt32) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async {
                do {
                    let data = try self.hostTransport.bulkReadLength(
                        UInt(length),
                        timeout: TimeInterval(timeoutMilliseconds) / 1000.0
                    )
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: ScannerError.transportUnavailable(error.localizedDescription))
                }
            }
        }
    }

    func abort() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                try? self.hostTransport.abort()
                continuation.resume()
            }
        }
    }
}
