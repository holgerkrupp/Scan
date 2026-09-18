import XCTest
@testable import Scan

final class PageGridNavigationTests: XCTestCase {
    func testNothingSelectedPicksFirstOrLast() {
        XCTAssertEqual(PageGridNavigation.index(after: nil, move: .right, count: 5, columns: 3), 0)
        XCTAssertEqual(PageGridNavigation.index(after: nil, move: .up, count: 5, columns: 3), 0)
        XCTAssertEqual(PageGridNavigation.index(after: nil, move: .first, count: 5, columns: 3), 0)
        XCTAssertEqual(PageGridNavigation.index(after: nil, move: .last, count: 5, columns: 3), 4)
        XCTAssertNil(PageGridNavigation.index(after: nil, move: .right, count: 0, columns: 3))
        XCTAssertNil(PageGridNavigation.index(after: 0, move: .right, count: 0, columns: 3))
    }

    func testHorizontalMovesStopAtTheEdges() {
        XCTAssertEqual(PageGridNavigation.index(after: 2, move: .right, count: 5, columns: 3), 3)
        XCTAssertEqual(PageGridNavigation.index(after: 4, move: .right, count: 5, columns: 3), 4)
        XCTAssertEqual(PageGridNavigation.index(after: 3, move: .left, count: 5, columns: 3), 2)
        XCTAssertEqual(PageGridNavigation.index(after: 0, move: .left, count: 5, columns: 3), 0)
        XCTAssertEqual(PageGridNavigation.index(after: 1, move: .first, count: 5, columns: 3), 0)
        XCTAssertEqual(PageGridNavigation.index(after: 1, move: .last, count: 5, columns: 3), 4)
    }

    func testVerticalMovesFollowTheColumnsLikeTheFinder() {
        // 5 pages in 3 columns: rows [0 1 2] [3 4].
        XCTAssertEqual(PageGridNavigation.index(after: 1, move: .down, count: 5, columns: 3), 4)
        XCTAssertEqual(PageGridNavigation.index(after: 2, move: .down, count: 5, columns: 3), 4, "below an empty cell the last page is chosen")
        XCTAssertEqual(PageGridNavigation.index(after: 4, move: .down, count: 5, columns: 3), 4, "last row stays")
        XCTAssertEqual(PageGridNavigation.index(after: 4, move: .up, count: 5, columns: 3), 1)
        XCTAssertEqual(PageGridNavigation.index(after: 2, move: .up, count: 5, columns: 3), 2, "first row stays")
        // A single column degenerates to a list.
        XCTAssertEqual(PageGridNavigation.index(after: 1, move: .down, count: 3, columns: 1), 2)
        XCTAssertEqual(PageGridNavigation.index(after: 1, move: .down, count: 3, columns: 0), 2, "zero columns are treated as one")
    }

    func testColumnCountMatchesAnAdaptiveGrid() {
        XCTAssertEqual(PageGridNavigation.columnCount(forWidth: 0, minimumItemWidth: 170, spacing: 14), 1)
        XCTAssertEqual(PageGridNavigation.columnCount(forWidth: 170, minimumItemWidth: 170, spacing: 14), 1)
        XCTAssertEqual(PageGridNavigation.columnCount(forWidth: 354, minimumItemWidth: 170, spacing: 14), 2)
        XCTAssertEqual(PageGridNavigation.columnCount(forWidth: 353, minimumItemWidth: 170, spacing: 14), 1)
        XCTAssertEqual(PageGridNavigation.columnCount(forWidth: 1000, minimumItemWidth: 110, spacing: 14), 8)
    }

    @MainActor
    func testPageStoreNamesFilesForQuickLook() async throws {
        let store = ScanPageStore()
        defer { Task { await store.clear() } }
        let front = PageFrame(pageIndex: 1, side: .front, pixelFormat: .jpeg, width: 8, height: 8, resolutionDPI: 300, data: Data([0xff, 0xd8, 0xff, 0xd9]))
        let stored = try await store.append(front)
        XCTAssertEqual(stored.fileURL.lastPathComponent, "Page 1 front.jpg")
        let unknownSide = PageFrame(pageIndex: 2, side: .unknown, pixelFormat: .png, width: 8, height: 8, resolutionDPI: 300, data: Data([0x89]))
        let storedUnknown = try await store.append(unknownSide)
        XCTAssertEqual(storedUnknown.fileURL.lastPathComponent, "Page 2.png")
        // A second frame with the same index and side must not overwrite the first.
        let duplicate = try await store.append(front)
        XCTAssertNotEqual(duplicate.fileURL, stored.fileURL)
        XCTAssertTrue(duplicate.fileURL.lastPathComponent.hasPrefix("Page 1 front "))
        XCTAssertEqual(ScanPageStore.fileExtension(for: .rgb8), "page")
    }
}

final class PageQuickLookTests: XCTestCase {
    private func keyEvent(_ code: UInt16, characters: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    func testArrowHomeAndEndKeysMapToGridMoves() {
        XCTAssertEqual(PageQuickLookController.move(for: keyEvent(123, characters: "\u{F702}")), .left)
        XCTAssertEqual(PageQuickLookController.move(for: keyEvent(124, characters: "\u{F703}")), .right)
        XCTAssertEqual(PageQuickLookController.move(for: keyEvent(126, characters: "\u{F700}")), .up)
        XCTAssertEqual(PageQuickLookController.move(for: keyEvent(125, characters: "\u{F701}")), .down)
        XCTAssertEqual(PageQuickLookController.move(for: keyEvent(115, characters: "\u{F729}")), .first)
        XCTAssertEqual(PageQuickLookController.move(for: keyEvent(119, characters: "\u{F72B}")), .last)
        XCTAssertNil(PageQuickLookController.move(for: keyEvent(49, characters: " ")))
        XCTAssertNil(PageQuickLookController.move(for: keyEvent(0, characters: "a")))
    }

    @MainActor
    func testPanelPreviewsExactlyTheSelectedPage() async throws {
        let workspace = ScannerWorkspaceViewModel(discovery: StubDiscovery(), registry: ScannerDriverRegistry(drivers: []), outputWriter: ScanOutputWriter(), profileStore: ScanProfileStore(defaults: UserDefaults(suiteName: "PageQuickLookTests")!))
        let controller = PageQuickLookController()
        controller.workspace = workspace
        XCTAssertEqual(controller.numberOfPreviewItems(in: nil), 0)

        let store = ScanPageStore()
        defer { Task { await store.clear() } }
        let page = try await store.append(PageFrame(pageIndex: 2, side: .back, pixelFormat: .jpeg, width: 8, height: 8, resolutionDPI: 300, data: Data([0xff, 0xd8, 0xff, 0xd9])))
        workspace.pages = [page]
        XCTAssertEqual(controller.numberOfPreviewItems(in: nil), 0, "nothing selected, nothing previewed")

        workspace.selectedPageID = page.id
        XCTAssertEqual(controller.numberOfPreviewItems(in: nil), 1)
        let item = try XCTUnwrap(controller.previewPanel(nil, previewItemAt: 0) as? PagePreviewItem)
        XCTAssertEqual(item.previewItemURL, page.fileURL)
        XCTAssertEqual(item.previewItemTitle, "Page 2 · back")
    }

    private struct StubDiscovery: ScannerDiscovery {
        func discover() async -> [ScannerIdentity] { [] }
    }
}
