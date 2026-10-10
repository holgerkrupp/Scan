import AppKit
import Foundation

/// A freely licensed product photo bundled in the asset catalog. Only photos
/// whose licence allows redistribution are bundled; each carries its credit.
struct BundledScannerPhoto: Equatable, Sendable {
    let assetName: String
    /// Model actually shown, e.g. when a sibling model shares its housing.
    let caption: String
    let credit: String
    let license: String
    let sourceURL: URL
}

/// Resolves the photo shown in the scanner details dialog: a photo the user
/// chose for the model wins over a bundled one; without either the dialog
/// shows a placeholder that accepts a dropped photo.
enum ScannerPhotoCatalog {
    private static let s1500 = BundledScannerPhoto(
        assetName: "ScannerPhotoS1500",
        caption: "ScanSnap S1500",
        credit: "gtknj",
        license: "CC BY 2.0",
        sourceURL: URL(string: "https://commons.wikimedia.org/wiki/File:Fujitsu_ScanSnap_Color_Image_Scanner_S1500.jpg")!
    )
    private static let ix500 = BundledScannerPhoto(
        assetName: "ScannerPhotoIX500",
        caption: "ScanSnap iX500",
        credit: "최광모",
        license: "CC BY-SA 4.0",
        sourceURL: URL(string: "https://commons.wikimedia.org/wiki/File:Fujitsu_ScanSnap_iX500_DSC12.jpg")!
    )

    /// Bundled photos by USB product ID (vendor 0x04c5). The iX500EE is an
    /// iX500 in the same housing, so it reuses that photo.
    static let bundled: [USBDeviceID: BundledScannerPhoto] = [
        USBDeviceID(vendorID: 0x04c5, productID: 0x11a2): s1500,
        USBDeviceID(vendorID: 0x04c5, productID: 0x132b): ix500,
        USBDeviceID(vendorID: 0x04c5, productID: 0x13f3): ix500
    ]

    static func bundledPhoto(for identity: ScannerIdentity) -> BundledScannerPhoto? {
        identity.usbDeviceID.flatMap { bundled[$0] }
    }

    /// Key under which a user-chosen photo is stored: per model when the USB
    /// IDs are known (so every unit of that model shares it), else per device.
    static func photoKey(for identity: ScannerIdentity) -> String {
        if let usbDeviceID = identity.usbDeviceID { return String(format: "usb-%04x-%04x", usbDeviceID.vendorID, usbDeviceID.productID) }
        return "device-" + String(identity.id.map { (character: Character) -> Character in character.isLetter || character.isNumber ? character : "_" })
    }
}

/// Stores user-chosen scanner photos in Application Support/ScannerPhotos.
struct ScannerPhotoStore {
    let folder: URL

    init(folder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ScannerPhotos", isDirectory: true)) {
        self.folder = folder
    }

    private func fileURL(for identity: ScannerIdentity) -> URL {
        folder.appendingPathComponent(ScannerPhotoCatalog.photoKey(for: identity)).appendingPathExtension("png")
    }

    func customPhoto(for identity: ScannerIdentity) -> NSImage? {
        let url = fileURL(for: identity)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }

    /// Copies the image at `source` as PNG, so the original may move or vanish.
    func setCustomPhoto(from source: URL, for identity: ScannerIdentity) throws {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        guard let image = NSImage(contentsOf: source),
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { throw ScannerError.outputFailed("\(source.lastPathComponent) is not a readable image.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: fileURL(for: identity), options: .atomic)
    }

    func removeCustomPhoto(for identity: ScannerIdentity) {
        try? FileManager.default.removeItem(at: fileURL(for: identity))
    }
}
