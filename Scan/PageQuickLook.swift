import AppKit
import Observation
import Quartz

/// Quick Look for the page grid, modelled on the Finder: the panel always
/// previews the selected page (nothing when nothing is selected), follows the
/// selection while it is open, and forwards the arrow keys, Home, End and
/// Space to the workspace instead of navigating on its own.
@MainActor
final class PageQuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = PageQuickLookController()

    /// The workspace whose selection is previewed. Set once at launch.
    var workspace: ScannerWorkspaceViewModel? {
        didSet { observeSelection() }
    }

    private var panel: QLPreviewPanel? { QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Space / Command-Y: open the panel for the selection or close it.
    func toggle() {
        if isVisible {
            panel?.orderOut(nil)
        } else {
            QLPreviewPanel.shared()?.makeKeyAndOrderFront(nil)
        }
    }

    /// Reloads the panel after the selection or a page's content changed.
    func reload() {
        guard let panel, panel.isVisible else { return }
        panel.reloadData()
    }

    /// Re-registers an observation on the selected page so an open panel
    /// tracks selection changes, deletions, rotations and cleared batches.
    private func observeSelection() {
        guard let workspace else { return }
        withObservationTracking {
            _ = workspace.selectedPageID
            _ = workspace.pages
        } onChange: {
            Task { @MainActor [weak self] in
                self?.reload()
                self?.observeSelection()
            }
        }
    }

    // MARK: QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        workspace?.selectedPage == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        workspace?.selectedPage.map { PagePreviewItem(page: $0) }
    }

    // MARK: QLPreviewPanelDelegate

    /// The Finder keeps the keyboard in the file view while Quick Look is
    /// open; here the keys move the grid selection, and Space closes the panel.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, let workspace else { return false }
        if let move = Self.move(for: event) {
            workspace.selectPage(moving: move, columns: workspace.gridColumns)
            return true
        }
        if event.charactersIgnoringModifiers == " " {
            toggle()
            return true
        }
        return false
    }

    /// Arrow keys, Home and End as grid moves; `nil` for any other key.
    nonisolated static func move(for event: NSEvent) -> PageGridNavigation.Move? {
        switch event.specialKey {
        case .leftArrow?: .left
        case .rightArrow?: .right
        case .upArrow?: .up
        case .downArrow?: .down
        case .home?: .first
        case .end?: .last
        default: nil
        }
    }
}

/// The selected page as a Quick Look item with a readable title.
final class PagePreviewItem: NSObject, QLPreviewItem {
    let page: StoredPage
    init(page: StoredPage) { self.page = page }
    var previewItemURL: URL! { page.fileURL }
    var previewItemTitle: String! { "Page \(page.pageIndex)\(page.side == .unknown ? "" : " · \(page.side.rawValue)")" }
}

/// Hands the shared Quick Look panel its data source and delegate. The panel
/// looks for a controller along the responder chain and finally asks the
/// application delegate, which is the one stable object in a SwiftUI app.
final class ScanAppDelegate: NSObject, NSApplicationDelegate {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = PageQuickLookController.shared
        panel.delegate = PageQuickLookController.shared
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}
