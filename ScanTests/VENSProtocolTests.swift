import XCTest
@testable import Scan

@MainActor final class VENSProtocolTests: XCTestCase {
    private let mac: [UInt8] = [0x02, 0x11, 0x22, 0x33, 0x44, 0x55]
    private let hostIP: [UInt8] = [192, 0, 2, 10]

    private final class Replies: @unchecked Sendable { var value: [VENSScannerInfo] = [] }

    func testScannerStaysListedWhileSilentUntilItsLidCloses() async throws {
        let address: [UInt8] = [192, 0, 2, 20]
        let replies = Replies()
        replies.value = [VENSScannerInfo(ipAddress: address, interfaceVersion: 1, name: "Scanner", model: "ScanSnap iX500", serialNumber: "TEST", registeredHostIP: hostIP, registeredHostID: [1, 2, 3, 4, 5, 6, 7, 8])]
        // Own defaults, so the test never writes into the app's real settings.
        let suite = "VENSDiscoveryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let discovery = VENSScannerDiscovery(defaults: defaults, probe: { _ in replies.value })

        let firstCount = await discovery.discover().count
        XCTAssertEqual(firstCount, 1)

        replies.value = []
        let silentCount = await discovery.discover().count
        XCTAssertEqual(silentCount, 1, "A scanner in session with this app does not answer discovery.")

        discovery.scannerAnnounced(lidOpen: false, from: address)
        let closedCount = await discovery.discover().count
        XCTAssertEqual(closedCount, 0)

        discovery.scannerAnnounced(lidOpen: true, from: address)
        let reopenedCount = await discovery.discover().count
        XCTAssertEqual(reopenedCount, 1, "It may already be in session again when the lid opens.")
    }

    func testProbeLayout() {
        let probe = VENS.probe(hostIP: hostIP, hostMAC: mac, replyPort: 0xd7e0)
        XCTAssertEqual(probe.count, 32)
        XCTAssertEqual(Array(probe[0..<4]), Array("VENS".utf8))
        XCTAssertEqual(Array(probe[8..<12]), hostIP)
        XCTAssertEqual(Array(probe[12..<18]), mac)
        XCTAssertEqual(Array(probe[22..<26]), [0xd7, 0xe0, 0x00, 0x10])
    }

    func testDiscoveryReplyParsing() throws {
        var reply = [UInt8](repeating: 0, count: 132)
        reply.replaceSubrange(0..<4, with: Array("VENS".utf8))
        reply[9] = 6
        reply.replaceSubrange(16..<20, with: [192, 0, 2, 20])
        let name = Array("iX500-A0XX012345".utf8)
        reply.replaceSubrange(40..<40 + name.count, with: name)
        let model = Array("ScanSnap iX500  ".utf8)
        reply.replaceSubrange(104..<120, with: model)
        reply.replaceSubrange(124..<132, with: [1, 2, 3, 4, 5, 6, 7, 8])

        let info = try XCTUnwrap(VENS.parseDiscoveryReply(reply))
        XCTAssertEqual(info.interfaceVersion, 6)
        XCTAssertEqual(info.serialNumber, "A0XX012345")
        XCTAssertEqual(info.registeredHostID, [1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertTrue(info.isIX500)
        XCTAssertNil(VENS.parseDiscoveryReply(Array(reply.prefix(100))))
    }

    func testPasswordEncodingMatchesKnownExample() {
        XCTAssertEqual(String(decoding: VENS.encodedPassword("8122"), as: UTF8.self), "179130178176")
    }

    func testRegistrationBodyOffsets() {
        let date = Date(timeIntervalSince1970: 1_794_000_000)
        let zone = TimeZone(secondsFromGMT: 3600)!
        let hostID: [UInt8] = [9, 8, 7, 6, 5, 4, 3, 2]
        let body = VENS.registrationBody(interfaceVersion: 6, hostIP: hostIP, password: "8122", hostID: hostID, date: date, timeZone: zone)
        XCTAssertEqual(body.count, 96)
        XCTAssertEqual(Array(body[0..<3]), [0, 6, 0x1e])
        XCTAssertEqual(Array(body[8..<12]), [0, 0, 0, 1])
        XCTAssertEqual(Array(body[12..<16]), hostIP)
        XCTAssertEqual(Array(body[16..<20]), VENS.bigEndian(UInt32(55265)))
        XCTAssertEqual(Array(body[20..<32]), Array("179130178176".utf8))
        XCTAssertEqual(Array(body[76..<84]), hostID)
        XCTAssertEqual(Array(body[84..<88]), VENS.bigEndian(Int32(-3600)))
    }

    func testClientFrameHeader() {
        let frame = VENS.clientFrame(command: 0x11, mac: mac, body: [0xaa])
        XCTAssertEqual(frame.count, 33)
        XCTAssertEqual(Array(frame[0..<4]), [0, 0, 0, 33])
        XCTAssertEqual(Array(frame[8..<12]), [0, 0, 0, 0x11])
        XCTAssertEqual(Array(frame[16..<22]), mac)
        XCTAssertEqual(frame[32], 0xaa)
    }

    func testParameterBlockEnablesUltrasonicDoubleFeedDetection() {
        let block = VENS.parameterBlock(dpi: 300, ultrasonicDoubleFeedDetection: true)
        XCTAssertEqual(block.count, 80)
        XCTAssertEqual(block[4], 0xd0)
        XCTAssertEqual(block[10], 0x90)
        XCTAssertEqual(block[31], 0x30)
        XCTAssertEqual(Array(block[32..<34]), [0x00, 0x10])
        XCTAssertEqual(Array(block[34..<38]), [0x01, 0x2c, 0x01, 0x2c])
        XCTAssertEqual(Array(block[38..<41]), [5, 0x81, 0])
        XCTAssertEqual(Array(block[42..<50]), [0, 0, 0x28, 0xd0, 0, 0, 0x44, 0xdc])
        XCTAssertEqual(block[50], 4)
        XCTAssertEqual(VENS.parameterBlock(dpi: 300, ultrasonicDoubleFeedDetection: false)[4], 0)
    }

    func testReadCommandsForFrontAndBack() {
        XCTAssertEqual(VENS.readImageCDB(back: false, imageIndex: 2), [0x28, 0, 0, 2, 0, 0, 0x30, 0, 0, 0, 2, 0])
        XCTAssertEqual(VENS.readImageCDB(back: true, imageIndex: 3), [0x28, 0, 0, 2, 0, 0x80, 0x30, 0, 0, 0, 3, 0])
        XCTAssertEqual(VENS.imageInfoCDB(imageIndex: 3), [0x28, 0, 0x80, 0, 0, 0x80, 0, 0, 0x20, 0, 3, 0])
    }

    func testSenseCodesMapToPaperErrors() throws {
        var data = [UInt8](repeating: 0, count: 18)
        data[2] = 0x03
        data[12] = 0x80
        data[13] = 0x07
        let doubleFeed = try XCTUnwrap(VENSSense(data))
        XCTAssertFalse(doubleFeed.isFeederEmpty)
        XCTAssertEqual(doubleFeed.paperError?.errorDescription, String(localized: "Double feed detected: several sheets went through together. Pages already scanned are kept. Remove the sheets, then scan again."))
        data[13] = 0x03
        XCTAssertTrue(try XCTUnwrap(VENSSense(data)).isFeederEmpty)
        data[2] = 0x40
        data[12] = 0
        data[13] = 0
        let endOfImage = try XCTUnwrap(VENSSense(data))
        XCTAssertTrue(endOfImage.endOfMedium)
        XCTAssertNil(endOfImage.paperError)
    }

    func testNotificationParsing() throws {
        var notice = [UInt8](repeating: 0, count: 48)
        notice[3] = 0x30
        notice.replaceSubrange(4..<8, with: Array("VENS".utf8))
        notice[11] = 0x01
        notice[16] = 7
        XCTAssertEqual(try XCTUnwrap(VENS.parseNotification(notice)), VENSNotification(event: VENS.buttonPressedEvent, counter: 7))
        XCTAssertNil(VENS.parseNotification(Array(notice.prefix(40))))
        notice[4] = 0
        XCTAssertNil(VENS.parseNotification(notice))
    }

    func testWiFiUsesTheUltrasonicSensorUnlessMultifeedDetectionIsOff() {
        XCTAssertTrue(ScannerFeedSettings().multifeedDetection.usesUltrasonicSensor)
        XCTAssertTrue(MultifeedDetection.ultrasonicAndLength.usesUltrasonicSensor)
        XCTAssertFalse(MultifeedDetection.off.usesUltrasonicSensor)
        XCTAssertFalse(MultifeedDetection.length.usesUltrasonicSensor)
    }

    func testHostIdentifierIsRememberedAndRequired() throws {
        let suite = "VENSProtocolTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func info(hostID: [UInt8]) -> VENSScannerInfo {
            VENSScannerInfo(ipAddress: [192, 0, 2, 20], interfaceVersion: 6, name: "iX500-S", model: "ScanSnap iX500", serialNumber: "S", registeredHostIP: [0, 0, 0, 0], registeredHostID: hostID)
        }
        XCTAssertThrowsError(try VENSHostIdentity.hostID(for: info(hostID: [UInt8](repeating: 0, count: 8)), defaults: defaults))
        let known: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        XCTAssertEqual(try VENSHostIdentity.hostID(for: info(hostID: known), defaults: defaults), known)
        XCTAssertEqual(try VENSHostIdentity.hostID(for: info(hostID: [UInt8](repeating: 0, count: 8)), defaults: defaults), known)
    }
}
