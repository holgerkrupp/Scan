import Foundation

/// Native SCSI-over-USB driver for the Fujitsu ScanSnap iX1400
/// (USB 0x04c5/0x1630).
///
/// The iX1400 is the iX1600 without touchscreen and Wi-Fi and inherits the
/// hardware-validated iX1600 profile (`FujitsuScanSnapModelProfile.ix1400`).
/// Not yet tested on iX1400 hardware, so treat it as preliminary support.
struct FujitsuScanSnapIX1400Driver: ScannerDriver {
    private let profile = FujitsuScanSnapModelProfile.ix1400

    var name: String { profile.name }
    var supportedUSBDeviceIDs: Set<USBDeviceID> { profile.usbDeviceIDs }

    func makeDevice(identity: ScannerIdentity, transport: USBDeviceTransport?) -> ScannerDevice {
        FujitsuScanSnapDevice(identity: identity, transport: transport, profile: profile)
    }
}
