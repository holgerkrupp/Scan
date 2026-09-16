import Foundation

/// Native SCSI-over-USB driver for the Fujitsu ScanSnap iX1300
/// (USB 0x04c5/0x162c).
///
/// SANE's `fujitsu` backend lists the iX1300 as working with the generic
/// Fujitsu flow, so it inherits the hardware-validated iX1600 profile
/// (`FujitsuScanSnapModelProfile.ix1300`). Only the U-turn ADF is driven;
/// the straight return path is not supported. Not yet tested on iX1300
/// hardware, so treat it as preliminary support.
struct FujitsuScanSnapIX1300Driver: ScannerDriver {
    private let profile = FujitsuScanSnapModelProfile.ix1300

    var name: String { profile.name }
    var supportedUSBDeviceIDs: Set<USBDeviceID> { profile.usbDeviceIDs }

    func makeDevice(identity: ScannerIdentity, transport: USBDeviceTransport?) -> ScannerDevice {
        FujitsuScanSnapDevice(identity: identity, transport: transport, profile: profile)
    }
}
