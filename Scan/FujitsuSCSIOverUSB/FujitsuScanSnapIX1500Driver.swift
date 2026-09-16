import Foundation

/// Native SCSI-over-USB driver for the Fujitsu ScanSnap iX1500
/// (USB 0x04c5/0x159f).
///
/// SANE's `fujitsu` backend uses the generic Fujitsu command flow for this
/// model. This profile is therefore protocol-backed and intentionally does not
/// enable the iX500-specific pre-read, JPEG-table, hopper, buffering, or
/// hardware-compression behavior until it has been validated on hardware.
struct FujitsuScanSnapIX1500Driver: ScannerDriver {
    private let profile = FujitsuScanSnapModelProfile.ix1500

    var name: String { profile.name }
    var supportedUSBDeviceIDs: Set<USBDeviceID> { profile.usbDeviceIDs }

    func makeDevice(identity: ScannerIdentity, transport: USBDeviceTransport?) -> ScannerDevice {
        FujitsuScanSnapDevice(identity: identity, transport: transport, profile: profile)
    }
}
