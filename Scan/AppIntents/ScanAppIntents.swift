import AppIntents
import UniformTypeIdentifiers

/// A profile is an App Entity so Shortcuts can offer the user's saved profiles
/// as choices instead of asking them to type a profile name.
struct ScanProfileEntity: AppEntity {
    let id: String
    let name: String

    init(profile: ScanProfile) {
        id = profile.id.uuidString
        name = profile.name
    }

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Scan Profile")

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    static var defaultQuery = ScanProfileEntityQuery()
}

struct ScanProfileEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ScanProfileEntity] {
        let profiles = await MainActor.run {
            ScanProfileStore(defaults: .standard).load()
        }
        return profiles
            .filter { identifiers.contains($0.id.uuidString) }
            .map(ScanProfileEntity.init)
    }

    func suggestedEntities() async throws -> [ScanProfileEntity] {
        await MainActor.run {
            ScanProfileStore(defaults: .standard).load().map(ScanProfileEntity.init)
        }
    }
}

struct ScanDocumentIntent: AppIntent, LongRunningIntent {
    static var title: LocalizedStringResource = "Scan Document"
    static var description = IntentDescription("Scans a document with a saved profile and returns the exported files.")
    static var openAppWhenRun = true

    @Parameter(title: "Profile")
    var profile: ScanProfileEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Scan document with \(\.$profile)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> & ProvidesDialog {
        let workspace = await MainActor.run { ScannerWorkspaceViewModel.shared }
        let result = try await workspace.scanAndExport(
            profileID: profile.flatMap { UUID(uuidString: $0.id) }
        )
        let files = result.outputURLs.map {
            IntentFile(fileURL: $0, filename: $0.lastPathComponent, type: Self.contentType(for: $0))
        }
        let pageNoun = result.pagesScanned == 1 ? "page" : "pages"
        return .result(value: files, dialog: "Scanned \(result.pagesScanned) \(pageNoun).")
    }

    private static func contentType(for url: URL) -> UTType? {
        UTType(filenameExtension: url.pathExtension)
    }
}

struct RefreshScannersIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh Scanners"
    static var description = IntentDescription("Finds connected scanners and updates Scan's device list.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let workspace = await MainActor.run { ScannerWorkspaceViewModel.shared }
        await workspace.refreshDevices()
        let count = await MainActor.run { workspace.discoveredIdentities.count }
        let noun = count == 1 ? "scanner" : "scanners"
        return .result(dialog: "Found \(count) \(noun).")
    }
}

struct OpenScanWorkspaceIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Scan"
    static var description = IntentDescription("Opens the Scan workspace.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "Opening Scan.")
    }
}

struct ScanAppShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .blue

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ScanDocumentIntent(),
            phrases: [
                "Scan a document with \(.applicationName)",
                "Scan with \(.applicationName)"
            ],
            shortTitle: "Scan Document",
            systemImageName: "scanner"
        )
        AppShortcut(
            intent: RefreshScannersIntent(),
            phrases: ["Refresh scanners in \(.applicationName)"],
            shortTitle: "Refresh Scanners",
            systemImageName: "arrow.clockwise"
        )
        AppShortcut(
            intent: OpenScanWorkspaceIntent(),
            phrases: ["Open \(.applicationName)"],
            shortTitle: "Open Scan",
            systemImageName: "doc.viewfinder"
        )
    }
}
