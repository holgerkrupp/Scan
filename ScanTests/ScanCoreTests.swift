import AppKit
import XCTest
@testable import Scan

@MainActor
final class ScanCoreTests: XCTestCase {
    func testSizePresetMappingIsDocumentedAndStable() {
        XCTAssertEqual(ScanFileSizePreset.small.documentedMapping.outputDPI, 150)
        XCTAssertEqual(ScanFileSizePreset.small.documentedMapping.colorMode, .gray)
        XCTAssertEqual(ScanFileSizePreset.balanced.documentedMapping.outputDPI, 200)
        XCTAssertEqual(ScanFileSizePreset.highQuality.documentedMapping.quality, 0.92)
        XCTAssertTrue(ScanFileSizePreset.lossless.documentedMapping.lossless)
        var options = ScanOptions(); options.applyPreset(.small)
        XCTAssertEqual(options.acquisition.colorMode, .gray); XCTAssertEqual(options.export.outputDPI, 150)
    }

    func testCapabilityFilteringRejectsUnsupportedOptions() {
        let capabilities = ScannerCapabilities(sources: [.adfFront], colorModes: [.gray], resolutionsDPI: [200], outputFormats: [.png], supportsBlankPageRemoval: false, supportsDeskew: false, supportsAutoCrop: false, supportsAutoRotate: false, supportsDuplex: false)
        var options = ScanOptions(acquisition: AcquisitionSettings(source: .adfDuplex, colorMode: .color, resolutionDPI: 300))
        XCTAssertThrowsError(try capabilities.validate(options))
        options.acquisition = AcquisitionSettings(source: .adfFront, colorMode: .gray, resolutionDPI: 200); options.export.outputFormat = .pdf
        XCTAssertThrowsError(try capabilities.validate(options))
    }

    func testCapabilitiesCanConstrainResolutionBySource() throws {
        let capabilities = ScannerCapabilities(
            sources: [.flatbed, .adfFront],
            colorModes: [.color],
            resolutionsDPI: [150, 300, 600],
            resolutionsBySource: [.flatbed: [150, 300, 600], .adfFront: [150, 300]],
            supportsBlankPageRemoval: true,
            supportsDeskew: true,
            supportsAutoCrop: true,
            supportsDuplex: false
        )
        var options = ScanOptions(acquisition: AcquisitionSettings(source: .flatbed, colorMode: .color, resolutionDPI: 600))
        XCTAssertNoThrow(try capabilities.validate(options))
        options.acquisition.source = .adfFront
        XCTAssertThrowsError(try capabilities.validate(options))
    }

    func testImageCaptureProgressIsNormalizedFromPercentage() {
        XCTAssertEqual(ImageCaptureScannerDevice.normalizedProgress(0), 0)
        XCTAssertEqual(ImageCaptureScannerDevice.normalizedProgress(57), 0.57)
        XCTAssertEqual(ImageCaptureScannerDevice.normalizedProgress(150), 1)
        XCTAssertEqual(ImageCaptureScannerDevice.normalizedProgress(-1), 0)
    }

    func testProfilePersistenceRoundTrip() {
        let defaults = UserDefaults(suiteName: "ScanCoreTests-\(UUID().uuidString)")!
        var store = ScanProfileStore(defaults: defaults); var profile = ScanProfile.defaults[0]; profile.name = "Test profile"; profile.options.processing.paperCleanup = 0.65; store.save([profile]); store.selectedProfileID = profile.id
        XCTAssertEqual(store.load().first?.name, "Test profile"); XCTAssertEqual(store.load().first?.options.processing.paperCleanup, 0.65); XCTAssertEqual(store.selectedProfileID, profile.id)
    }

    func testHardwareButtonSettingsPersistenceKeepsGlobalAndPerScannerOverrides() {
        let defaults = UserDefaults(suiteName: "ScanHardwareSettingsTests-\(UUID().uuidString)")!
        let store = HardwareButtonSettingsStore(defaults: defaults)
        let identity = ScannerIdentity(name: "S1500", manufacturer: "Fujitsu", model: "S1500", serialNumber: "S1", connectionKind: .usb, usbDeviceID: USBDeviceID(vendorID: 0x04c5, productID: 0x11a2), locationID: 1)
        let profileID = UUID()
        var settings = HardwareButtonSettings(enabled: true, launchAtLogin: true, defaultProfileID: profileID, perScannerProfileIDs: [identity.id: UUID()], perScannerDestinationBookmarks: [identity.id: Data([1, 2, 3])])
        store.save(settings)

        let loaded = store.load()
        XCTAssertEqual(loaded, settings)
        XCTAssertEqual(loaded.defaultProfileID, profileID)
        XCTAssertEqual(loaded.perScannerProfileIDs[identity.id], settings.perScannerProfileIDs[identity.id])
        XCTAssertEqual(loaded.perScannerDestinationBookmarks[identity.id], Data([1, 2, 3]))

        settings.enabled = false
        store.save(settings)
        XCTAssertFalse(store.load().enabled)
    }

    func testHardwareButtonSettingsDefaultToOptOutOnlyWhenExplicitlyDisabled() {
        let defaults = UserDefaults(suiteName: "ScanHardwareDefaultTests-\(UUID().uuidString)")!
        let store = HardwareButtonSettingsStore(defaults: defaults)

        XCTAssertTrue(store.load().enabled)

        var settings = store.load()
        settings.enabled = false
        store.save(settings)
        XCTAssertFalse(store.load().enabled)
    }

    func testNativeBackendsExposeButtonCapabilityStates() {
        let s1500 = ScannerIdentity(name: "ScanSnap S1500", manufacturer: "Fujitsu", model: "S1500", serialNumber: nil, connectionKind: .usb, usbDeviceID: USBDeviceID(vendorID: 0x04c5, productID: 0x11a2), locationID: 1)
        let ix500 = ScannerIdentity(name: "ScanSnap iX500", manufacturer: "Fujitsu", model: "iX500", serialNumber: nil, connectionKind: .usb, usbDeviceID: USBDeviceID(vendorID: 0x04c5, productID: 0x132b), locationID: 2)
        let ix1500 = ScannerIdentity(name: "ScanSnap iX1500", manufacturer: "Fujitsu", model: "iX1500", serialNumber: nil, connectionKind: .usb, usbDeviceID: USBDeviceID(vendorID: 0x04c5, productID: 0x159f), locationID: 3)
        let s300 = ScannerIdentity(name: "ScanSnap S300", manufacturer: "Fujitsu", model: "S300", serialNumber: nil, connectionKind: .usb, usbDeviceID: USBDeviceID(vendorID: 0x04c5, productID: 0x1156), locationID: 4)

        let s1500Device = FujitsuScanSnapS1500Driver().makeDevice(identity: s1500, transport: nil) as! ScannerHardwareEventSource
        let ix500Device = FujitsuScanSnapIX500Driver().makeDevice(identity: ix500, transport: nil) as! ScannerHardwareEventSource
        let ix1500Device = FujitsuScanSnapIX1500Driver().makeDevice(identity: ix1500, transport: nil) as! ScannerHardwareEventSource
        let s300Device = FujitsuScanSnapS300Driver(firmwareProvider: { nil }).makeDevice(identity: s300, transport: nil) as! ScannerHardwareEventSource

        XCTAssertEqual(s1500Device.hardwareEventCapabilities.scanButton, .supportedValidated)
        XCTAssertEqual(ix500Device.hardwareEventCapabilities.scanButton, .supportedValidated)
        XCTAssertEqual(ix1500Device.hardwareEventCapabilities.scanButton, .supportedUnvalidated)
        XCTAssertTrue(s1500Device.hardwareEventCapabilities.supportsOneTouchScanning)
        XCTAssertEqual(s300Device.hardwareEventCapabilities.scanButton, .supportedUnvalidated)
        XCTAssertFalse(s300Device.hardwareEventCapabilities.supportsOneTouchScanning)
    }

    func testHardwareButtonMonitoringRestartsAfterAScan() async throws {
        let scanner = ScannerIdentity(name: "Button Scanner", manufacturer: "Fujitsu", model: "iX500", serialNumber: nil, connectionKind: .imageCapture, usbDeviceID: nil, locationID: nil, persistentID: "button-scanner")
        let driver = ButtonMonitoringDriver()
        let viewModel = try makeViewModel(discovery: StaticDiscovery([scanner]), registry: ScannerDriverRegistry(drivers: [driver]))
        // Set directly so the test neither persists the setting nor changes the app's activation policy.
        viewModel.hardwareButtonSettings.enabled = true
        viewModel.selectedIdentity = scanner
        await viewModel.startScan()
        XCTAssertFalse(viewModel.isScanning)
        try await waitUntil { driver.observationStartCount == 1 }
    }

    func testBlankPageDetectionAndJPEGDownsampling() throws {
        let blank = try makeFrame(pageIndex: 1, blank: true, width: 600, height: 800)
        let printed = try makeFrame(pageIndex: 2, blank: false, width: 600, height: 800)
        guard let image = NSImage(data: printed.data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return XCTFail("image") }
        XCTAssertTrue(ScanImageProcessor.isBlank(try XCTUnwrap(NSImage(data: blank.data)?.cgImage(forProposedRect: nil, context: nil, hints: nil))))
        XCTAssertFalse(ScanImageProcessor.isBlank(image))
        let settings = ImageProcessingSettings(); let downsampled = try XCTUnwrap(ScanImageProcessor.process(printed, settings: settings, outputDPI: 150))
        XCTAssertEqual(downsampled.width, 300); XCTAssertEqual(downsampled.height, 400); XCTAssertEqual(downsampled.resolutionDPI, 150)
    }

    func testPaperCleanupSuppressesNearWhiteShadowsWithoutLiftingBlack() throws {
        let source = try makeTwoToneImage(light: 230, dark: 0)
        let cleaned = try XCTUnwrap(ScanImageProcessor.applyPaperCleanup(source, amount: 1))
        let pixels = try rgbaPixels(from: cleaned)
        XCTAssertGreaterThanOrEqual(pixels[0], 250)
        XCTAssertEqual(pixels[4], 0)
    }

    func testLegacyProcessingSettingsDecodeWithPaperCleanupOff() throws {
        let json = Data(#"{"removeBlankPages":true,"autoCrop":true,"deskew":false,"autoRotate":false,"rotation":0}"#.utf8)
        let settings = try JSONDecoder().decode(ImageProcessingSettings.self, from: json)
        XCTAssertTrue(settings.removeBlankPages)
        XCTAssertEqual(settings.paperCleanup, 0)
    }

    func testPDFPageCountBlankRemovalAndUniqueFilenames() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ScanTests-\(UUID().uuidString)"); defer { try? FileManager.default.removeItem(at: folder) }
        let frames = [try makeFrame(pageIndex: 1, blank: false), try makeFrame(pageIndex: 2, blank: true), try makeFrame(pageIndex: 3, blank: false)]
        var options = ScanOptions(acquisition: AcquisitionSettings(source: .adfFront, colorMode: .color, resolutionDPI: 300), processing: ImageProcessingSettings(removeBlankPages: true), export: ExportSettings(outputFormat: .pdf, sizePreset: .custom, outputDPI: 150, exportMode: .combinedPDF, filenameTemplate: "Fixed"))
        let writer = ScanOutputWriter(); let first = try await writer.write(frames: frames, options: options, destinationFolder: folder); XCTAssertEqual(first.pagesScanned, 2); XCTAssertEqual(first.outputURLs.count, 1); XCTAssertEqual(CGPDFDocument(first.outputURLs[0] as CFURL)?.numberOfPages, 2)
        options.export.exportMode = .separateFiles; let second = try await writer.write(frames: [frames[0]], options: options, destinationFolder: folder); XCTAssertEqual(second.outputURLs.count, 1); XCTAssertNotEqual(first.outputURLs[0].lastPathComponent, second.outputURLs[0].lastPathComponent)
    }

    func testCompositeDiscoveryDeduplicatesNativeS1500InFavorOfNative() async {
        let native = ScannerIdentity(name: "Native S1500", manufacturer: "Fujitsu", model: "S1500", serialNumber: "S1", connectionKind: .usb, usbDeviceID: USBDeviceID(vendorID: 0x04c5, productID: 0x11a2), locationID: 7)
        let imageCaptureDuplicate = ScannerIdentity(name: "Image Capture S1500", manufacturer: "macOS", model: "S1500", serialNumber: "S1", connectionKind: .imageCapture, usbDeviceID: native.usbDeviceID, locationID: 7, persistentID: "ic-s1")
        let other = ScannerIdentity(name: "Other Scanner", manufacturer: "Example", model: "Flatbed", serialNumber: "O1", connectionKind: .imageCapture, usbDeviceID: nil, locationID: nil, persistentID: "ic-o1")
        let result = await CompositeScannerDiscovery(native: StaticDiscovery([native]), imageCapture: StaticDiscovery([imageCaptureDuplicate, other])).discover()
        XCTAssertEqual(result.count, 2); XCTAssertTrue(result.contains(native)); XCTAssertFalse(result.contains(imageCaptureDuplicate)); XCTAssertTrue(result.contains(other))
    }

    func testDiscoveryChangesTriggerOneCoalescedAutomaticRefresh() async throws {
        let scanner = ScannerIdentity(name: "Hot-plugged S1500", manufacturer: "Fujitsu", model: "S1500", serialNumber: "H1", connectionKind: .usb, usbDeviceID: USBDeviceID(vendorID: 0x04c5, productID: 0x11a2), locationID: 3)
        let discovery = ObservableDiscovery()
        let viewModel = try makeViewModel(discovery: discovery)
        discovery.identities = [scanner]
        discovery.simulateChange(); discovery.simulateChange()
        try await waitUntil { viewModel.discoveredIdentities == [scanner] && !viewModel.isRefreshing }
        XCTAssertEqual(viewModel.selectedIdentity, scanner); XCTAssertEqual(viewModel.status, .idle); XCTAssertEqual(discovery.discoverCount, 1)
    }

    func testAutomaticRefreshWaitsForRunningScanAndKeepsUnreadError() async throws {
        let scanner = ScannerIdentity(name: "Attached S1500", manufacturer: "Fujitsu", model: "S1500", serialNumber: "A1", connectionKind: .usb, usbDeviceID: USBDeviceID(vendorID: 0x04c5, productID: 0x11a2), locationID: 4)
        let discovery = ObservableDiscovery(identities: [scanner])
        let viewModel = try makeViewModel(discovery: discovery)
        await viewModel.refreshDevices()
        viewModel.isScanning = true
        discovery.simulateChange()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(discovery.discoverCount, 1, "No refresh may run while a scan is in progress.")
        viewModel.status = .error("Paper jam"); viewModel.isScanning = false
        try await waitUntil { discovery.discoverCount == 2 && !viewModel.isRefreshing }
        XCTAssertEqual(viewModel.selectedIdentity, scanner); XCTAssertEqual(viewModel.status, .error("Paper jam"))
    }

    func testLegacyScanSnapUSBModelsAreClaimedByTheNativeDrivers() {
        let legacyDriver = FujitsuScanSnapS1500Driver()
        let expected: Set<USBDeviceID> = [
            USBDeviceID(vendorID: 0x04c5, productID: 0x1096),
            USBDeviceID(vendorID: 0x04c5, productID: 0x10e6),
            USBDeviceID(vendorID: 0x04c5, productID: 0x10f2),
            USBDeviceID(vendorID: 0x04c5, productID: 0x10fe),
            USBDeviceID(vendorID: 0x04c5, productID: 0x1135),
            USBDeviceID(vendorID: 0x04c5, productID: 0x1155),
            USBDeviceID(vendorID: 0x04c5, productID: 0x116f),
            USBDeviceID(vendorID: 0x04c5, productID: 0x11a2)
        ]
        XCTAssertEqual(legacyDriver.supportedUSBDeviceIDs, expected)

        let s510 = ScannerIdentity(name: "ScanSnap S510M", manufacturer: "Fujitsu", model: "S510M", serialNumber: nil, connectionKind: .usb, usbDeviceID: USBDeviceID(vendorID: 0x04c5, productID: 0x116f), locationID: 1)
        XCTAssertEqual(legacyDriver.makeDevice(identity: s510, transport: nil).capabilities.resolutionsDPI, [150, 200, 300, 600])
        let s1500 = ScannerIdentity(name: "ScanSnap S1500", manufacturer: "Fujitsu", model: "S1500", serialNumber: nil, connectionKind: .usb, usbDeviceID: USBDeviceID(vendorID: 0x04c5, productID: 0x11a2), locationID: 1)
        XCTAssertEqual(legacyDriver.makeDevice(identity: s1500, transport: nil).capabilities.resolutionsDPI, [150, 200, 300, 400, 600])

        // The iX500 has its own driver and hardware-validated profile.
        let ix500 = ScannerIdentity(name: "ScanSnap iX500", manufacturer: "Fujitsu", model: "iX500", serialNumber: nil, connectionKind: .usb, usbDeviceID: USBDeviceID(vendorID: 0x04c5, productID: 0x132b), locationID: 1)
        XCTAssertFalse(legacyDriver.canDrive(ix500))
        XCTAssertTrue(ScannerDriverRegistry.live.driver(for: ix500) is FujitsuScanSnapIX500Driver)
        let device = FujitsuScanSnapIX500Driver().makeDevice(identity: ix500, transport: nil)
        XCTAssertEqual(device.capabilities.resolutionsDPI, [150, 200, 300, 600])
        XCTAssertTrue(device.capabilities.supportsDuplex)

        // The iX1500 and iX1600 share their own profile so they cannot pick
        // up the iX500-only command quirks by accident.
        let ix1500 = ScannerIdentity(name: "ScanSnap iX1500", manufacturer: "Fujitsu", model: "iX1500", serialNumber: nil, connectionKind: .usb, usbDeviceID: USBDeviceID(vendorID: 0x04c5, productID: 0x159f), locationID: 2)
        XCTAssertFalse(legacyDriver.canDrive(ix1500))
        XCTAssertTrue(ScannerDriverRegistry.live.driver(for: ix1500) is FujitsuScanSnapIX1500Driver)
        XCTAssertEqual(FujitsuScanSnapIX1500Driver().makeDevice(identity: ix1500, transport: nil).capabilities.resolutionsDPI, [150, 200, 300, 400, 600])
        let ix1600 = ScannerIdentity(name: "ScanSnap iX1600", manufacturer: "Fujitsu", model: "iX1600", serialNumber: nil, connectionKind: .usb, usbDeviceID: USBDeviceID(vendorID: 0x04c5, productID: 0x1632), locationID: 3)
        XCTAssertFalse(legacyDriver.canDrive(ix1600))
        XCTAssertTrue(ScannerDriverRegistry.live.driver(for: ix1600) is FujitsuScanSnapIX1600Driver)
        XCTAssertEqual(FujitsuScanSnapIX1600Driver().makeDevice(identity: ix1600, transport: nil).capabilities, FujitsuScanSnapIX1500Driver().makeDevice(identity: ix1500, transport: nil).capabilities)
    }

    func testEpjitsuDriverClaimsOnlyTheDirectUSBModels() {
        let driver = EpjitsuScanSnapDriver(firmwareProvider: { nil })
        XCTAssertEqual(driver.supportedUSBDeviceIDs, Set(EpjitsuScanSnapModelProfile.all.flatMap(\.usbDeviceIDs)))

        let identity = ScannerIdentity(
            name: "ScanSnap S300",
            manufacturer: "Fujitsu",
            model: "S300",
            serialNumber: nil,
            connectionKind: .usb,
            usbDeviceID: USBDeviceID(vendorID: 0x04c5, productID: 0x1156),
            locationID: 1
        )
        let device = driver.makeDevice(identity: identity, transport: nil)
        XCTAssertEqual(device.capabilities.colorModes, [.color])
        XCTAssertEqual(device.capabilities.resolutionsDPI, [150, 200, 300, 600])
        XCTAssertTrue(device.capabilities.supportsDuplex)
        XCTAssertNotNil(device.capabilities.unsupportedReason)
    }

    func testEpjitsuRegistryRoutesAllClaimedModelsAndNeverSCSIOverUSB() {
        let expected: [(UInt16, EpjitsuScanSnapModelProfile)] = [
            (0x1156, .s300), (0x117f, .s300M), (0x11ed, .s1300), (0x128d, .s1300i)
        ]
        for (productID, profile) in expected {
            let identity = usbIdentity(productID)
            let driver = ScannerDriverRegistry.live.driver(for: identity)
            XCTAssertTrue(driver is EpjitsuScanSnapDriver, profile.name)
            XCTAssertEqual((driver?.makeDevice(identity: identity, transport: nil) as? EpjitsuScanSnapDevice)?.profile, profile)
            XCTAssertFalse(FujitsuScanSnapS1500Driver().canDrive(identity), profile.name)
            XCTAssertFalse(FujitsuScanSnapIX500Driver().canDrive(identity), profile.name)
        }
    }

    func testEpjitsuProfilesKeepFirmwareNamesAndIndependentBookmarkKeys() {
        XCTAssertEqual(EpjitsuScanSnapModelProfile.s300.expectedFirmwareFileNames, ["300_0C00.nal"])
        XCTAssertEqual(EpjitsuScanSnapModelProfile.s300M.expectedFirmwareFileNames, ["300M_0C00.nal"])
        XCTAssertEqual(EpjitsuScanSnapModelProfile.s1300.expectedFirmwareFileNames, ["1300_0C26.nal"])
        XCTAssertEqual(EpjitsuScanSnapModelProfile.s1300i.expectedFirmwareFileNames, ["1300i_0D12.nal"])

        let keys = Set(EpjitsuScanSnapModelProfile.all.map(\.firmwareBookmarkKey))
        XCTAssertEqual(keys.count, EpjitsuScanSnapModelProfile.all.count)
        XCTAssertFalse(keys.contains(EpjitsuScanSnapFirmwareStore.legacyS300BookmarkKey))
    }

    func testEpjitsuFirmwareSelectionRejectsAnotherModelsFilename() {
        let store = EpjitsuScanSnapFirmwareStore(profile: .s1300i, defaults: UserDefaults(suiteName: "EpjitsuFirmware-\(UUID().uuidString)")!)
        XCTAssertThrowsError(try store.saveFirmware(at: URL(fileURLWithPath: "/tmp/1300_0C26.nal"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("S1300i"))
            XCTAssertTrue(error.localizedDescription.contains("1300i_0D12.nal"))
        }
    }

    func testEpjitsuFirmwareBookmarksAreModelSpecificAndMigrateTheOldS300Key() throws {
        let suiteName = "EpjitsuFirmwarePersistence-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("EpjitsuFirmware-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let s300URL = folder.appendingPathComponent("300_0C00.nal")
        let s1300iURL = folder.appendingPathComponent("1300i_0D12.nal")
        let container = Data(repeating: 0x5a, count: 0x100 + EpjitsuCommandEngine.firmwarePayloadLength)
        try container.write(to: s300URL)
        try container.write(to: s1300iURL)

        // The old global bookmark remains usable only by the matching S300
        // profile and is copied to its new per-model key on first read.
        let oldBookmark = try s300URL.bookmarkData(options: [.withSecurityScope])
        defaults.set(oldBookmark, forKey: EpjitsuScanSnapFirmwareStore.legacyS300BookmarkKey)
        let s300Store = EpjitsuScanSnapFirmwareStore(profile: .s300, defaults: defaults)
        XCTAssertEqual(s300Store.selectedFilename, "300_0C00.nal")
        XCTAssertNotNil(defaults.data(forKey: EpjitsuScanSnapModelProfile.s300.firmwareBookmarkKey))

        let s1300iStore = EpjitsuScanSnapFirmwareStore(profile: .s1300i, defaults: defaults)
        XCTAssertNil(s1300iStore.selectedFilename, "S300's old bookmark must not satisfy S1300i")
        try s1300iStore.saveFirmware(at: s1300iURL)
        XCTAssertEqual(s1300iStore.selectedFilename, "1300i_0D12.nal")
        XCTAssertEqual(try s1300iStore.loadFirmwarePayload()?.count, EpjitsuCommandEngine.firmwarePayloadLength)
    }

    func testS1300iUsesTheCommonEpjitsuBootstrapAndIdentityProtocol() async throws {
        var identityResponse = Data("FUJITSU ".utf8)
        identityResponse.append(Data("ScanSnap S1300i ".utf8))
        identityResponse.append(Data(repeating: 0, count: 8))
        XCTAssertEqual(identityResponse.count, 0x20)

        let transport = ScriptedUSBTransport(reads: [Data([0x10, 0x00]), identityResponse])
        let engine = EpjitsuCommandEngine(transport: transport, profile: .s1300i)
        let result = try await engine.prepare(firmwarePayload: nil)
        XCTAssertEqual(result, EpjitsuProtocolIdentity(vendor: "FUJITSU", model: "ScanSnap S1300i"))
        XCTAssertEqual(transport.capturedWrites(), [Data([0x1b, 0x03]), Data([0x1b, 0x13])])
    }

    func testEpjitsu1300FamilyButtonSupportIsUnvalidatedAndNeverOneTouch() {
        for (productID, profile) in [(UInt16(0x11ed), EpjitsuScanSnapModelProfile.s1300), (0x128d, .s1300i)] {
            let identity = usbIdentity(productID)
            let device = EpjitsuScanSnapDriver(firmwareProvider: { nil }).makeDevice(identity: identity, transport: nil)
            let events = (device as! ScannerHardwareEventSource).hardwareEventCapabilities
            XCTAssertEqual(events.scanButton, ScannerHardwareEventSupportState.supportedUnvalidated, profile.name)
            XCTAssertFalse(events.supportsOneTouchScanning, profile.name)
        }
    }

    func testS300FirmwareContainerDropsHeaderAndRequiresFullPayload() throws {
        var file = Data(repeating: 0xaa, count: 0x100)
        file.append(Data((0..<ScanSnapS300CommandEngine.firmwarePayloadLength).map { UInt8(truncatingIfNeeded: $0) }))
        let payload = try ScanSnapS300FirmwareStore.extractPayload(from: file)
        XCTAssertEqual(payload.count, 0x10000)
        XCTAssertEqual(payload.prefix(4), Data([0x00, 0x01, 0x02, 0x03]))
        XCTAssertThrowsError(try ScanSnapS300FirmwareStore.extractPayload(from: Data(repeating: 0, count: 0x10000)))
    }

    func testS300FirmwareBootstrapAndIdentityProtocol() async throws {
        var identityResponse = Data("FUJITSU ".utf8)
        identityResponse.append(Data("ScanSnap S300   ".utf8))
        identityResponse.append(Data(repeating: 0, count: 8))
        XCTAssertEqual(identityResponse.count, 0x20)

        let transport = ScriptedUSBTransport(reads: [
            Data([0x00, 0x00]),
            Data([0x06]),
            Data([0x06]),
            Data([0x06]),
            Data([0x06]),
            Data([0x10, 0x00]),
            identityResponse
        ])
        let engine = ScanSnapS300CommandEngine(transport: transport)
        let payload = Data(repeating: 0x01, count: ScanSnapS300CommandEngine.firmwarePayloadLength)
        let result = try await engine.prepare(firmwarePayload: payload)
        XCTAssertEqual(result, ScanSnapS300ProtocolIdentity(vendor: "FUJITSU", model: "ScanSnap S300"))

        let writes = transport.capturedWrites()
        XCTAssertEqual(writes.count, 9)
        XCTAssertEqual(writes[0], Data([0x1b, 0x03]))
        XCTAssertEqual(writes[1], Data([0x1b, 0x06]))
        XCTAssertEqual(writes[2], Data([0x01, 0x00, 0x01, 0x00]))
        XCTAssertEqual(writes[3], payload)
        XCTAssertEqual(writes[4], Data([0x00]))
        XCTAssertEqual(writes[5], Data([0x1b, 0x16]))
        XCTAssertEqual(writes[6], Data([0x80]))
        XCTAssertEqual(writes[7], Data([0x1b, 0x03]))
        XCTAssertEqual(writes[8], Data([0x1b, 0x13]))
    }

    func testS300HardwareStatusUsesEpjitsuButtonCommand() async throws {
        let transport = ScriptedUSBTransport(reads: [Data([0x00, 0x01, 0x00, 0x00])])
        let engine = ScanSnapS300CommandEngine(transport: transport)

        let status = try await engine.readHardwareStatus()

        XCTAssertEqual(status, Data([0x00, 0x01, 0x00, 0x00]))
        XCTAssertEqual(transport.capturedWrites(), [Data([0x1b, 0x33])])
    }

    private func makeViewModel(discovery: ScannerDiscovery, registry: ScannerDriverRegistry = .live) throws -> ScannerWorkspaceViewModel {
        let suiteName = "ScanCoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suiteName) }
        return ScannerWorkspaceViewModel(discovery: discovery, registry: registry, outputWriter: ScanOutputWriter(), profileStore: ScanProfileStore(defaults: defaults), automaticRefreshDelay: .milliseconds(20))
    }

    private func usbIdentity(_ productID: UInt16) -> ScannerIdentity {
        ScannerIdentity(
            name: "ScanSnap USB 0x\(String(format: "%04x", productID))",
            manufacturer: "Fujitsu",
            model: "Unknown",
            serialNumber: nil,
            connectionKind: .usb,
            usbDeviceID: USBDeviceID(vendorID: 0x04c5, productID: productID),
            locationID: 1
        )
    }

    private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Condition not met within \(timeout).") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeFrame(pageIndex: Int, blank: Bool, width: Int = 300, height: Int = 400) throws -> PageFrame {
        let image = NSImage(size: NSSize(width: width, height: height)); image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill(); if !blank { NSColor.black.setFill(); NSRect(x: 30, y: 40, width: width - 60, height: 20).fill() }; image.unlockFocus(); let tiff = try XCTUnwrap(image.tiffRepresentation); let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff)); let data = try XCTUnwrap(rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])); return PageFrame(pageIndex: pageIndex, side: .front, pixelFormat: .jpeg, width: width, height: height, resolutionDPI: 300, data: data)
    }

    private func makeTwoToneImage(light: UInt8, dark: UInt8) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let data = Data([light, light, light, 255, dark, dark, dark, 255])
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        return try XCTUnwrap(CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func rgbaPixels(from image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }
}

private struct StaticDiscovery: ScannerDiscovery {
    let identities: [ScannerIdentity]
    init(_ identities: [ScannerIdentity]) { self.identities = identities }
    func discover() async -> [ScannerIdentity] { identities }
}

@MainActor
private final class ObservableDiscovery: ScannerDiscovery {
    var identities: [ScannerIdentity]
    private(set) var discoverCount = 0
    private var onChange: (@MainActor () -> Void)?
    init(identities: [ScannerIdentity] = []) { self.identities = identities }
    func discover() async -> [ScannerIdentity] { discoverCount += 1; return identities }
    func observeChanges(_ onChange: @escaping @MainActor () -> Void) { self.onChange = onChange }
    func simulateChange() { onChange?() }
}

/// A scanner whose button monitoring can be observed: it records every start
/// of hardware-event observation and scans an empty feeder.
private final class ButtonMonitoringDriver: ScannerDriver {
    let name = "Button monitoring test driver"
    let supportedUSBDeviceIDs: Set<USBDeviceID> = []
    private(set) var observationStartCount = 0
    func canDrive(_ identity: ScannerIdentity) -> Bool { true }
    func makeDevice(identity: ScannerIdentity, transport: USBDeviceTransport?) -> ScannerDevice { ButtonMonitoringDevice(identity: identity, driver: self) }
    func recordObservationStart() { observationStartCount += 1 }
}

private final class ButtonMonitoringDevice: ScannerDevice, ScannerHardwareEventSource {
    let identity: ScannerIdentity
    let capabilities = ScannerCapabilities(sources: ScanSource.allCases, colorModes: ScanColorMode.allCases, resolutionsDPI: [150, 300, 600], supportsBlankPageRemoval: true, supportsDeskew: true, supportsAutoCrop: true, supportsDuplex: true)
    let status: ScannerStatus = .idle
    let hardwareEventCapabilities = ScannerHardwareEventCapabilities(scanButton: .supportedValidated, supportsOneTouchScanning: true, detail: "Test scanner")
    private let driver: ButtonMonitoringDriver
    init(identity: ScannerIdentity, driver: ButtonMonitoringDriver) { self.identity = identity; self.driver = driver }
    func open() async throws {}
    func close() async {}
    func cancel() async {}
    func startScan(options: ScanOptions) async throws -> AsyncThrowingStream<PageFrame, Error> { AsyncThrowingStream { $0.finish() } }
    func startHardwareEventObservation() async throws -> AsyncStream<ScannerHardwareEvent> {
        driver.recordObservationStart()
        return AsyncStream { _ in }
    }
    func stopHardwareEventObservation() async {}
}

@MainActor
private final class ScriptedUSBTransport: USBDeviceTransport, @unchecked Sendable {
    let identity = ScannerIdentity(
        name: "Scripted S300",
        manufacturer: "Fujitsu",
        model: "S300",
        serialNumber: nil,
        connectionKind: .usb,
        usbDeviceID: USBDeviceID(vendorID: 0x04c5, productID: 0x1156),
        locationID: 1
    )
    var endpointSummary: String { "scripted bulk endpoints" }

    private var reads: [Data]
    private var writes: [Data] = []

    init(reads: [Data]) {
        self.reads = reads
    }

    func open() async throws {}
    func close() async {}
    func abort() async {}

    func controlTransfer(request: USBControlRequest) async throws -> Data {
        throw ScannerError.protocolNotImplemented("No control transfers in scripted transport.")
    }

    func bulkWrite(endpoint: UInt8, data: Data, timeoutMilliseconds: UInt32) async throws {
        writes.append(data)
    }

    func bulkRead(endpoint: UInt8, length: Int, timeoutMilliseconds: UInt32) async throws -> Data {
        guard !reads.isEmpty else {
            throw ScannerError.transportUnavailable("Scripted transport has no queued read.")
        }
        return reads.removeFirst()
    }

    func capturedWrites() -> [Data] {
        writes
    }
}
