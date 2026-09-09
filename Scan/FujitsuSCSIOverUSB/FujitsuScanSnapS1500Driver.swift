import Foundation

/// Native driver for the ScanSnap models that share the S1500's Fujitsu
/// SCSI-over-USB command flow: S500/S500M, S510/S510M, and S1500/S1500M.
/// The profile is chosen by USB product ID; only the S1500 profile has been
/// validated on hardware, the S500/S510 profiles are protocol-backed.
struct FujitsuScanSnapS1500Driver: ScannerDriver {
    static let profiles: [FujitsuScanSnapModelProfile] = [.s500, .s510, .s1500]

    let name = "Fujitsu ScanSnap legacy SCSI-over-USB"
    var supportedUSBDeviceIDs: Set<USBDeviceID> { Set(Self.profiles.flatMap(\.usbDeviceIDs)) }

    static func profile(for identity: ScannerIdentity) -> FujitsuScanSnapModelProfile {
        guard let deviceID = identity.usbDeviceID else { return .s1500 }
        return profiles.first { $0.usbDeviceIDs.contains(deviceID) } ?? .s1500
    }

    func makeDevice(identity: ScannerIdentity, transport: USBDeviceTransport?) -> ScannerDevice {
        FujitsuScanSnapDevice(identity: identity, transport: transport, profile: Self.profile(for: identity))
    }
}
