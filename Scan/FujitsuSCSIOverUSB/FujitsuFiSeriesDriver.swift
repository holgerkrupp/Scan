import Foundation

/// Native driver for Fujitsu fi-series document scanners of the fi-5000 and
/// fi-6000 generations. They speak the same Fujitsu SCSI-over-USB dialect as
/// the ScanSnap S1500, but Ricoh's macOS driver only covers the fi-7000 and
/// fi-8000 generations, so these models have no vendor support on current
/// macOS. The profile is chosen by USB product ID; none of these profiles has
/// been validated on hardware yet.
struct FujitsuFiSeriesDriver: ScannerDriver {
    static let profiles: [FujitsuScanSnapModelProfile] = [.fi5000, .fi5530C, .fi6000]

    let name = "Fujitsu fi-series SCSI-over-USB"
    var supportedUSBDeviceIDs: Set<USBDeviceID> { Set(Self.profiles.flatMap(\.usbDeviceIDs)) }

    static func profile(for identity: ScannerIdentity) -> FujitsuScanSnapModelProfile {
        guard let deviceID = identity.usbDeviceID else { return .fi6000 }
        return profiles.first { $0.usbDeviceIDs.contains(deviceID) } ?? .fi6000
    }

    func makeDevice(identity: ScannerIdentity, transport: USBDeviceTransport?) -> ScannerDevice {
        FujitsuScanSnapDevice(identity: identity, transport: transport, profile: Self.profile(for: identity))
    }
}
