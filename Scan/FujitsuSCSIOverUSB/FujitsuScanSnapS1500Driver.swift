import Foundation

struct FujitsuScanSnapS1500Driver: ScannerDriver {
    private let profile = FujitsuScanSnapModelProfile.s1500

    var name: String { profile.name }
    var supportedUSBDeviceIDs: Set<USBDeviceID> { profile.usbDeviceIDs }

    func makeDevice(identity: ScannerIdentity, transport: USBDeviceTransport?) -> ScannerDevice {
        FujitsuScanSnapDevice(identity: identity, transport: transport, profile: profile)
    }
}
