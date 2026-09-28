import CoreGraphics
import XCTest
@testable import Scan

/// The workspace keeps the raw scans, shows processed renditions, re-renders
/// them when the processing options change, and exports what it shows.
@MainActor
final class WorkspaceProcessingTests: XCTestCase {
    private struct NoDiscovery: ScannerDiscovery {
        func discover() async -> [ScannerIdentity] { [] }
    }

    private func makeWorkspace() -> ScannerWorkspaceViewModel {
        let defaults = UserDefaults(suiteName: "WorkspaceProcessingTests-\(UUID().uuidString)")!
        let workspace = ScannerWorkspaceViewModel(discovery: NoDiscovery(), registry: ScannerDriverRegistry(drivers: []), outputWriter: ScanOutputWriter(), profileStore: ScanProfileStore(defaults: defaults))
        var profile = workspace.selectedProfile
        profile.options.processing = ImageProcessingSettings(removeBlankPages: true, whitenPaper: true)
        workspace.updateProfile(profile)
        return workspace
    }

    private func frame(index: Int, paper: CGFloat, textLines: Int, width: Int = 600, height: Int = 800) throws -> PageFrame {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: paper, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for line in 0..<textLines { context.fill(CGRect(x: 60, y: 100 + line * 50, width: width - 120, height: 6)) }
        let data = try ScanImageProcessor.encodeJPEG(context.makeImage()!, quality: 0.95)
        return PageFrame(pageIndex: index, side: .front, pixelFormat: .jpeg, width: width, height: height, resolutionDPI: 300, data: data)
    }

    private func paperLevel(of page: StoredPage) throws -> Int {
        let image = try XCTUnwrap(NSImage(contentsOf: page.fileURL)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        return ScanImageProcessor.inkStatistics(image).paperLevel
    }

    private func settle(_ workspace: ScannerWorkspaceViewModel) async {
        // Re-processing after a settings change is debounced.
        try? await Task.sleep(for: .milliseconds(400))
        await workspace.waitForProcessing()
    }

    func testPagesAreProcessedOnArrivalAndBlankOnesHidden() async throws {
        let workspace = makeWorkspace()
        try await workspace.ingest(frame(index: 1, paper: 0.94, textLines: 4))
        try await workspace.ingest(frame(index: 2, paper: 0.94, textLines: 0))
        XCTAssertEqual(workspace.rawPages.count, 2)
        await workspace.waitForProcessing()

        XCTAssertEqual(workspace.pages.count, 1, "the blank page is hidden")
        XCTAssertEqual(workspace.hiddenBlankPageCount, 1)
        XCTAssertEqual(workspace.pendingProcessingCount, 0)
        XCTAssertEqual(workspace.selectedPageID, workspace.pages.first?.id)
        XCTAssertGreaterThanOrEqual(try paperLevel(of: workspace.pages[0]), 250, "the shown page is whitened")
        XCTAssertTrue(workspace.pages[0].fileURL.lastPathComponent.hasPrefix("Page 1 front"))
        XCTAssertTrue(workspace.rawPages[0].fileURL.lastPathComponent.hasPrefix("Raw 1 front"))
    }

    func testChangingProcessingOptionsReRendersTheRawPages() async throws {
        let workspace = makeWorkspace()
        try await workspace.ingest(frame(index: 1, paper: 0.94, textLines: 4))
        try await workspace.ingest(frame(index: 2, paper: 0.94, textLines: 0))
        await workspace.waitForProcessing()
        XCTAssertEqual(workspace.pages.count, 1)

        var profile = workspace.selectedProfile
        profile.options.processing.removeBlankPages = false
        profile.options.processing.whitenPaper = false
        workspace.updateProfile(profile)
        await settle(workspace)

        XCTAssertEqual(workspace.pages.count, 2, "the blank page is back")
        XCTAssertEqual(workspace.hiddenBlankPageCount, 0)
        XCTAssertLessThan(try paperLevel(of: workspace.pages[0]), 248, "no longer whitened")

        // Switching to a profile with the original settings hides it again.
        profile.options.processing.removeBlankPages = true
        workspace.updateProfile(profile)
        await settle(workspace)
        XCTAssertEqual(workspace.pages.count, 1)
    }

    func testRotationAndAlignmentAreKeptAsPerPageEditsAcrossReprocessing() async throws {
        let workspace = makeWorkspace()
        try await workspace.ingest(frame(index: 1, paper: 1, textLines: 4))
        await workspace.waitForProcessing()
        XCTAssertEqual(workspace.pages[0].width, 600)

        await workspace.rotateSelectedPage()
        await workspace.waitForProcessing()
        XCTAssertEqual(workspace.pages[0].width, 800)
        XCTAssertEqual(workspace.pages[0].height, 600)
        XCTAssertEqual(workspace.pageEdits[workspace.pages[0].id]?.quarterTurns, 1)

        // The edit survives a settings change: the page stays rotated.
        var profile = workspace.selectedProfile
        profile.options.processing.paperCleanup = 0.5
        workspace.updateProfile(profile)
        await settle(workspace)
        XCTAssertEqual(workspace.pages[0].width, 800)

        await workspace.alignSelectedPage()
        await workspace.waitForProcessing()
        XCTAssertTrue(workspace.pageEdits[workspace.pages[0].id]?.align ?? false)
        XCTAssertTrue(workspace.effectiveProcessingSettings(for: workspace.pages[0].id).deskew)
    }

    func testDeleteAndClearDropRawPagesToo() async throws {
        let workspace = makeWorkspace()
        try await workspace.ingest(frame(index: 1, paper: 1, textLines: 4))
        try await workspace.ingest(frame(index: 2, paper: 1, textLines: 4))
        await workspace.waitForProcessing()
        XCTAssertEqual(workspace.pages.count, 2)

        workspace.selectedPageID = workspace.pages[0].id
        await workspace.deleteSelectedPage()
        XCTAssertEqual(workspace.pages.count, 1)
        XCTAssertEqual(workspace.rawPages.count, 1)
        XCTAssertEqual(workspace.selectedPageID, workspace.pages[0].id)

        await workspace.clearPages()
        XCTAssertTrue(workspace.pages.isEmpty)
        XCTAssertTrue(workspace.rawPages.isEmpty)
        XCTAssertNil(workspace.selectedPageID)
    }

    func testExportWritesTheShownPagesWithoutProcessingAgain() async throws {
        let workspace = makeWorkspace()
        try await workspace.ingest(frame(index: 1, paper: 0.94, textLines: 4))
        try await workspace.ingest(frame(index: 2, paper: 0.94, textLines: 0))
        await workspace.waitForProcessing()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WorkspaceProcessingTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        workspace.destinationFolder = folder
        var profile = workspace.selectedProfile
        profile.options.export.outputFormat = .pdf; profile.options.export.exportMode = .combinedPDF; profile.options.export.outputDPI = 300
        workspace.updateProfile(profile)
        await settle(workspace)

        await workspace.saveExport()
        XCTAssertEqual(workspace.lastOutputs.count, 1)
        XCTAssertEqual(CGPDFDocument(try XCTUnwrap(workspace.lastOutputs.first) as CFURL)?.numberOfPages, 1, "only the visible page")
    }
}
