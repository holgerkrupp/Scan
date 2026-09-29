import AppKit
import SwiftUI

/// In-app guide for the workflow and settings exposed by Scan.
struct ScanDocumentationView: View {
    private enum Topic: String, CaseIterable, Identifiable {
        case gettingStarted = "Getting started"
        case scanning = "Scanning"
        case profiles = "Profiles"
        case image = "Image & export"
        case processing = "Processing"
        case review = "Reviewing pages"
        case settings = "App settings"
        case troubleshooting = "Troubleshooting"

        var id: Self { self }

        var icon: String {
            switch self {
            case .gettingStarted: "sparkles"
            case .scanning: "scanner"
            case .profiles: "slider.horizontal.3"
            case .image: "doc.richtext"
            case .processing: "wand.and.stars"
            case .review: "rectangle.grid.2x2"
            case .settings: "gearshape"
            case .troubleshooting: "stethoscope"
            }
        }
    }

    @State private var selectedTopic: Topic = .gettingStarted

    var body: some View {
        NavigationSplitView {
            List(Topic.allCases, selection: $selectedTopic) { topic in
                Label(topic.rawValue, systemImage: topic.icon)
                    .tag(topic)
            }
            .listStyle(.sidebar)
            .navigationTitle("Scan Help")
            .frame(minWidth: 190)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) { topicContent }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(32)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(minWidth: 880, minHeight: 620)
    }

    @ViewBuilder
    private var topicContent: some View {
        switch selectedTopic {
        case .gettingStarted: gettingStarted
        case .scanning: scanning
        case .profiles: profiles
        case .image: imageAndExport
        case .processing: processing
        case .review: reviewing
        case .settings: appSettings
        case .troubleshooting: troubleshooting
        }
    }

    private var gettingStarted: some View {
        DocumentationTopic(title: "Welcome to Scan", icon: "sparkles", intro: "Scan is a native macOS document-scanning workspace for Fujitsu ScanSnap, fi-series USB scanners, and scanners exposed through Image Capture.") {
            DocumentationSection(title: "A typical scan", icon: "checklist") {
                StepRow(number: 1, title: "Connect a scanner", text: "Plug in the scanner, open Scan, and click refresh if it is not listed.")
                StepRow(number: 2, title: "Choose a scanner and profile", text: "Select a scanner in the left sidebar, then choose a saved profile in the inspector on the right.")
                StepRow(number: 3, title: "Load pages and scan", text: "Place pages in the feeder or on the flatbed and press Scan. Command–Return does the same thing.")
                StepRow(number: 4, title: "Review", text: "Pages appear in the center grid as they are processed. Select a page to rotate, delete, preview, or auto-align it.")
                StepRow(number: 5, title: "Save or export", text: "Choose Save/Export when the pages look right. Automatic saving can be enabled in a profile’s Image settings.")
            }
            NoteCard(title: "Two kinds of settings", icon: "arrow.triangle.branch", text: "Profile settings describe how a scan is captured, processed, and exported. App Settings describe the default folder and physical scanner-button behavior for the whole app.")
        }
    }

    private var scanning: some View {
        DocumentationTopic(title: "Scanning", icon: "scanner", intro: "The scanner list shows every device that Scan can discover. Select a device to see the options its backend supports.") {
            DocumentationSection(title: "Source settings", icon: "rectangle.and.hand.point.up.left") {
                DefinitionRow(term: "Source", definition: "ADF Front scans one side, ADF Back scans the reverse side, ADF Duplex scans both sides, and Flatbed uses a flatbed when the scanner provides one.")
                DefinitionRow(term: "Color mode", definition: "Color preserves color, Gray is useful for smaller document files, and Lineart is a black-and-white mode suited to clean text.")
                DefinitionRow(term: "DPI", definition: "Higher DPI captures more detail and creates larger files. 200–300 dpi is practical for most documents; use 400–600 dpi for fine detail or archival work.")
                DefinitionRow(term: "Scanner buffering", definition: "Allows supported Fujitsu scanners to read the next sheet while the previous page is transferred. It can improve throughput for long batches.")
                DefinitionRow(term: "Hardware JPEG compression", definition: "Asks supported scanners to compress color pages before sending them over USB. This reduces transfer size; the export format is controlled separately in Image settings.")
            }
            DocumentationSection(title: "During a scan", icon: "arrow.triangle.2.circlepath") {
                DefinitionRow(term: "Scan", definition: "Starts a batch using the selected scanner and profile. A progress indicator and page count appear in the footer.")
                DefinitionRow(term: "Cancel", definition: "Stops the active scan. Pages already received remain available for review unless you clear them.")
                DefinitionRow(term: "Refresh", definition: "Rechecks USB and Image Capture devices. Use it after connecting, disconnecting, or waking a scanner.")
            }
        }
    }

    private var profiles: some View {
        DocumentationTopic(title: "Profiles", icon: "slider.horizontal.3", intro: "A profile is a reusable recipe for acquisition, image processing, and export. Scan includes practical starting profiles, and changes are saved automatically.") {
            DocumentationSection(title: "Working with profiles", icon: "square.stack.3d.up") {
                DefinitionRow(term: "Profile picker", definition: "Choose a saved recipe from the Profile section at the top of the inspector. The selected profile is remembered for the next launch.")
                DefinitionRow(term: "Profile name", definition: "Rename a profile to describe its job, such as “Receipts” or “Archive duplex”.")
                DefinitionRow(term: "Duplicate profile", definition: "Creates a copy so you can try different settings without changing the original recipe.")
                DefinitionRow(term: "Scanner capabilities", definition: "Options unavailable on the selected scanner are disabled. Hover a disabled control to see why it is unavailable.")
            }
            NoteCard(title: "Good starting points", icon: "lightbulb", text: "Use a duplex color PDF for mixed office documents, a searchable PDF when you need text search, and a separate-file JPEG profile for photos or receipts.")
        }
    }

    private var imageAndExport: some View {
        DocumentationTopic(title: "Image & export", icon: "doc.richtext", intro: "These settings control the files written when you export. They do not change the scanner’s capture resolution unless a profile preset also changes the acquisition color mode.") {
            DocumentationSection(title: "Output", icon: "square.and.arrow.down") {
                DefinitionRow(term: "PDF", definition: "Creates a document from the scanned pages. One combined PDF is the default export mode.")
                DefinitionRow(term: "Searchable PDF", definition: "Adds OCR text to the PDF. Select one or more OCR languages; the page image remains visible while recognized text becomes searchable.")
                DefinitionRow(term: "JPEG, PNG, TIFF", definition: "Exports individual page images. Choose Separate per-page files for image formats; combined PDF is available for PDF output.")
                DefinitionRow(term: "File size", definition: "Small, Balanced, High Quality, and Lossless presets set sensible DPI, color, and compression combinations. Custom exposes JPEG quality and output DPI.")
                DefinitionRow(term: "Export", definition: "One combined PDF creates a single document. Separate per-page files writes one file for each page.")
                DefinitionRow(term: "Filename template", definition: "Use {date}, {time}, {page}, and {side} in the name. For example, Scan-{date}-{page} creates numbered files for the current batch.")
                DefinitionRow(term: "Automatically save after scanning", definition: "Exports as soon as the batch finishes processing. Turn this off when you want to inspect every page before writing files.")
            }
        }
    }

    private var processing: some View {
        DocumentationTopic(title: "Processing", icon: "wand.and.stars", intro: "Processing is applied in the background as pages arrive and is re-applied when you change a processing option. Blank pages are hidden, not destroyed, so you can bring them back.") {
            DocumentationSection(title: "Cleanup and layout", icon: "crop") {
                DefinitionRow(term: "Whiten paper", definition: "Measures the paper tone of each page and stretches it toward white while keeping dark content dark. This is useful when a scanner delivers plain paper as light gray.")
                DefinitionRow(term: "Paper cleanup", definition: "Suppresses faint shadows, creases, and paper texture. Increase it for clean office paper; reduce it to preserve light pencil marks and subtle detail.")
                DefinitionRow(term: "Remove blank pages", definition: "Hides pages with no meaningful ink relative to the paper tone. The page count shows how many blank pages are hidden; switch this off to review them.")
                DefinitionRow(term: "Deskew and crop to page", definition: "Straightens a skewed sheet and crops away its paper edges. It is the automatic equivalent of Edit > Auto-Align Page.")
                DefinitionRow(term: "Crop to content", definition: "Trims paper margins down to the printed content. It is especially useful for receipts, clippings, and small documents on a larger sheet.")
                DefinitionRow(term: "Automatic orientation", definition: "Detects page orientation and rotates pages so text reads upright when the selected scanner backend supports it.")
            }
            NoteCard(title: "Processing versus export", icon: "arrow.down.right.and.arrow.up.left", text: "Processing changes what you review in the page grid. Export then writes exactly the visible pages, applying the selected output resolution and compression.")
        }
    }

    private var reviewing: some View {
        DocumentationTopic(title: "Reviewing pages", icon: "rectangle.grid.2x2", intro: "The page grid works like Finder’s icon view: select a page, make a correction, and export only when the batch is ready.") {
            DocumentationSection(title: "Page actions", icon: "hand.tap") {
                DefinitionRow(term: "Rotate", definition: "Rotates the selected page by 90 degrees. The change is per-page and does not alter the profile.")
                DefinitionRow(term: "Auto-Align Page", definition: "Straightens the selected sheet and crops to its page boundary. Find it in the Edit menu, in the page context menu, or with Command–Shift–L.")
                DefinitionRow(term: "Quick Look", definition: "Opens the selected page at a larger size. Space and Command–Y open it; arrow keys can continue moving through the grid.")
                DefinitionRow(term: "Delete", definition: "Removes the selected page from the current review session. Clear removes the whole batch and the last-export reference.")
                DefinitionRow(term: "Thumbnail size", definition: "Use the slider beside Reveal in Finder to change the grid cell size. This only affects the review layout, not exported files.")
            }
            DocumentationSection(title: "Keyboard shortcuts", icon: "keyboard") {
                ShortcutRow(keys: "Command–Return", action: "Scan or start a new scan")
                ShortcutRow(keys: "Command–Y / Space", action: "Quick Look the selected page")
                ShortcutRow(keys: "Command–Shift–E", action: "Export pages")
                ShortcutRow(keys: "Command–Shift–L", action: "Auto-align selected page")
                ShortcutRow(keys: "Command–R", action: "Rotate selected page")
                ShortcutRow(keys: "Command–Shift–R", action: "Refresh scanners")
                ShortcutRow(keys: "Arrow keys, Home, End", action: "Move selection in the page grid")
            }
        }
    }

    private var appSettings: some View {
        DocumentationTopic(title: "App settings", icon: "gearshape", intro: "Open Scan > Settings to configure behavior shared by the app. Profile-specific controls remain in the inspector beside the page grid.") {
            DocumentationSection(title: "Saving", icon: "folder") {
                DefinitionRow(term: "Default location", definition: "The folder used by manual exports, automatic saves, and scans started from Shortcuts. Use Choose… to select a folder and Show in Finder to open it.")
            }
            DocumentationSection(title: "Hardware Button / One-Touch Scan", icon: "button.programmable") {
                DefinitionRow(term: "Use physical Scan button", definition: "Listens for the scanner’s physical Scan button while a supported scanner session is open. A button press starts a scan using the configured profile and destination.")
                DefinitionRow(term: "Launch Scan at login", definition: "Starts Scan when you log in so one-touch scanning is ready without opening the app manually.")
                DefinitionRow(term: "Default profile", definition: "The profile used by hardware-button scans unless a scanner-specific profile is selected.")
                DefinitionRow(term: "Profile for [scanner]", definition: "Overrides the global profile for the selected scanner. Use Use global default to remove the override.")
                DefinitionRow(term: "Choose destination…", definition: "Sets a destination just for hardware-button scans from the selected scanner. If none is set, the default saving location is used.")
            }
            NoteCard(title: "Permissions", icon: "lock.shield", text: "macOS may ask for permission to access a chosen folder or to deliver notifications. Keep the scanner connected while enabling one-touch scanning so Scan can open its session and listen for button events.")
        }
    }

    private var troubleshooting: some View {
        DocumentationTopic(title: "Troubleshooting", icon: "stethoscope", intro: "Most problems are resolved by checking the selected scanner, its supported options, and the activity log in the inspector.") {
            DocumentationSection(title: "Common fixes", icon: "wrench.and.screwdriver") {
                DefinitionRow(term: "Scanner is missing", definition: "Reconnect the USB cable, wake the scanner, quit other scanner software, then choose Refresh Scanners. ScanSnap Home may hold a scanner exclusively; quit it before using Scan.")
                DefinitionRow(term: "An option is disabled", definition: "The selected backend does not expose that capability for this scanner or source. Hover the control for the reason and choose a supported value.")
                DefinitionRow(term: "Feeder is empty", definition: "Load pages in the ADF and make sure the guides are snug. For a flatbed source, place the page on the glass and close the lid.")
                DefinitionRow(term: "Pages look gray", definition: "Enable Whiten paper. Use Paper cleanup for shadows and texture; keep it low if light marks need to be preserved.")
                DefinitionRow(term: "Pages are tilted or have large margins", definition: "Enable Deskew and crop to page. Enable Crop to content when the goal is the printed area rather than the sheet boundary.")
                DefinitionRow(term: "Need more detail", definition: "Expand Activity log in Diagnostics and use Copy log when reporting an issue. Include the scanner model, source, color mode, DPI, and the profile settings used.")
            }
            DocumentationSection(title: "Experimental scanners", icon: "exclamationmark.triangle") {
                Text("Some legacy ScanSnap models are identified but not fully validated. The S300/S300M and S1300/S1300i experimental backend may ask for a model-specific firmware file under Diagnostics; firmware is not bundled with Scan. A scanner marked unsupported can still remain visible for diagnostics, while Image Capture-compatible scanners continue to use macOS’s Image Capture backend.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct DocumentationTopic<Content: View>: View {
    let title: String
    let icon: String
    let intro: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.largeTitle.weight(.semibold))
            Text(intro).font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            content()
        }
    }
}

private struct DocumentationSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(16)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct DefinitionRow: View {
    let term: String
    let definition: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(term).font(.headline)
            Text(definition).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct StepRow: View {
    let number: Int
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)").font(.headline.monospacedDigit()).frame(width: 26, height: 26).background(Color.accentColor, in: Circle()).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ShortcutRow: View {
    let keys: String
    let action: String

    var body: some View {
        HStack { Text(keys).font(.body.monospaced()); Spacer(); Text(action).foregroundStyle(.secondary) }
    }
}

private struct NoteCard: View {
    let title: String
    let icon: String
    let text: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: icon).font(.title2).foregroundStyle(Color.accentColor)
        }
        .padding(16)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }
}
