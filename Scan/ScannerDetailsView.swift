import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Sheet opened by double-clicking a scanner in the sidebar. Shows every
/// detail Scan knows about the scanner without opening the device, and its
/// paper-feed options.
struct ScannerDetailsView: View {
    /// Sidebar topics, laid out like the Scan Help window.
    private enum Topic: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case details = "Details"
        case feeding = "Feeding & Sensors"
        case statistics = "Statistics"
        case diagnostics = "Diagnostics"

        var id: Self { self }

        var icon: String {
            switch self {
            case .overview: "scanner"
            case .details: "info.circle"
            case .feeding: "doc.on.doc"
            case .statistics: "chart.bar.xaxis"
            case .diagnostics: "stethoscope"
            }
        }
    }

    let details: ScannerDetails
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTopic: Topic = .overview

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                List(Topic.allCases, selection: $selectedTopic) { topic in
                    Label(topic.rawValue, systemImage: topic.icon)
                        .tag(topic)
                }
                .listStyle(.sidebar)
                .navigationTitle(details.identity.name)
                .frame(minWidth: 190)
            } detail: {
                topicContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            Divider()
            HStack {
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(details.plainText, forType: .string)
                } label: { Label("Copy Details", systemImage: "doc.on.doc") }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        // Flexible bounds let the user resize the sheet with the mouse.
        .frame(minWidth: 880, idealWidth: 960, maxWidth: .infinity, minHeight: 620, idealHeight: 760, maxHeight: .infinity)
        .presentationSizing(.fitted)
    }

    @ViewBuilder
    private var topicContent: some View {
        switch selectedTopic {
        case .overview: overview
        case .details: infoTab
        case .feeding: ScannerFeedSettingsView(identity: details.identity, isSupported: details.supportsFeedSettings)
        case .statistics: ScannerStatisticsView(identity: details.identity)
        case .diagnostics: ScannerDiagnosticsSettingsView()
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "scanner").font(.largeTitle).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(details.identity.name).font(.title2.weight(.semibold))
                    Text("\(details.identity.manufacturer) · \(details.identity.connectionKind.rawValue)").foregroundStyle(.secondary)
                }
                Spacer()
            }
            ScannerPhotoView(identity: details.identity)
        }
        .padding(24)
    }

    private var infoTab: some View {
        Form {
            ForEach(details.sections) { section in
                Section {
                    ForEach(section.rows) { row in
                        LabeledContent(row.label) {
                            Text(row.value).textSelection(.enabled).multilineTextAlignment(.trailing)
                        }
                    }
                } header: {
                    Label(section.title, systemImage: section.systemImage)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// "Feeding & Sensors" topic: multifeed detection and the pre-scan sensor
/// check for this scanner. Changes are saved immediately and apply to the
/// next scan.
struct ScannerFeedSettingsView: View {
    let identity: ScannerIdentity
    let isSupported: Bool
    private let store = ScannerFeedSettingsStore(defaults: .standard)
    @State private var settings = ScannerFeedSettings()
    /// Over Wi-Fi only the ultrasonic sensor can be switched, and the sensors cannot be read first.
    private var isWiFi: Bool { identity.connectionKind == .wifi }

    var body: some View {
        Form {
            Section {
                if !isSupported {
                    Text("This scanner's driver does not support these options; they are used by Fujitsu SCSI-over-USB models such as the S1500 and iX500.")
                        .font(.callout).foregroundStyle(.orange)
                }
                Picker("Multifeed detection", selection: $settings.multifeedDetection) {
                    ForEach(isWiFi ? [.off, .ultrasonic] : MultifeedDetection.allCases) { Text($0.label).tag($0) }
                }
                Text(settings.multifeedDetection.explanation).font(.caption).foregroundStyle(.secondary)
            } header: {
                Label("Multifeed (staples)", systemImage: "doc.on.doc")
            }
            .disabled(!isSupported)

            Section {
                Toggle("Check sensors before scanning", isOn: $settings.checksSensorsBeforeScan)
                Text("Reads the scanner's status before the first sheet. An open cover, a multifeed or an error left over from a paper jam (orange light) stops the scan with a clear message.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Paper jams and multifeeds during a scan are always reported with their own message.")
                    .font(.caption).foregroundStyle(.secondary)
                if isWiFi {
                    Text("Over Wi-Fi the sensors cannot be checked before scanning.").font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Label("Sensors and paper jam", systemImage: "exclamationmark.triangle")
            }
            .disabled(!isSupported || isWiFi)
        }
        .formStyle(.grouped)
        .onAppear {
            settings = store.load(for: identity)
            if isWiFi { settings.multifeedDetection = settings.multifeedDetection.usesUltrasonicSensor ? .ultrasonic : .off }
        }
        .onChange(of: settings) { _, newValue in store.save(newValue, for: identity) }
    }
}

/// "Diagnostics" topic: the app-wide copy of the activity log to the macOS
/// system log, so a hung or crashed session can still be read afterwards.
struct ScannerDiagnosticsSettingsView: View {
    private let store = ScannerFeedSettingsStore(defaults: .standard)
    @State private var writesToSystemLog = false

    var body: some View {
        Form {
            Section {
                Toggle("Copy activity log to the macOS system log", isOn: $writesToSystemLog)
                Text("Applies to all scanners. Keeps the log after a hang or crash. Read it in Terminal with:")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(ScanSystemLog.terminalCommand).font(.caption.monospaced()).textSelection(.enabled)
                    Spacer()
                    Button {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(ScanSystemLog.terminalCommand, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Copy command")
                }
            } header: {
                Label("Diagnostics", systemImage: "stethoscope")
            }
        }
        .formStyle(.grouped)
        .onAppear { writesToSystemLog = store.writesActivityToSystemLog }
        .onChange(of: writesToSystemLog) { _, newValue in store.writesActivityToSystemLog = newValue }
    }
}

/// Photo of the scanner model: a user-chosen photo, else a bundled freely
/// licensed one (with its credit), else a placeholder. Dropping an image or
/// choosing one stores it for the whole model.
struct ScannerPhotoView: View {
    let identity: ScannerIdentity
    private let store = ScannerPhotoStore()
    @State private var customPhoto: NSImage?
    @State private var isTargeted = false
    @State private var errorMessage: String?

    private var bundled: BundledScannerPhoto? { ScannerPhotoCatalog.bundledPhoto(for: identity) }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5))
                if let customPhoto {
                    Image(nsImage: customPhoto).resizable().scaledToFit()
                } else if let bundled {
                    Image(bundled.assetName).resizable().scaledToFit()
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "scanner").font(.system(size: 56, weight: .thin)).foregroundStyle(.secondary)
                        Text("No photo available for this model").font(.callout).foregroundStyle(.secondary)
                        Text("Drop a photo here or choose one below.").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                if isTargeted { RoundedRectangle(cornerRadius: 10).strokeBorder(.tint, lineWidth: 3) }
            }
            .frame(minHeight: 160, idealHeight: 220, maxHeight: 340)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                setPhoto(from: url)
                return true
            } isTargeted: { isTargeted = $0 }
            .accessibilityLabel("Photo of \(identity.name)")

            HStack(spacing: 8) {
                if customPhoto != nil {
                    Text("Your photo").font(.caption).foregroundStyle(.secondary)
                } else if let bundled {
                    Text("\(bundled.caption) · Photo: \(bundled.credit), \(bundled.license) ·").font(.caption).foregroundStyle(.secondary)
                    Link("Source", destination: bundled.sourceURL).font(.caption)
                }
                Spacer()
                if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }
                Button("Choose Photo…", action: choosePhoto).controlSize(.small)
                if customPhoto != nil {
                    Button("Remove Photo") { store.removeCustomPhoto(for: identity); customPhoto = nil }.controlSize(.small)
                }
            }
        }
        .onAppear { customPhoto = store.customPhoto(for: identity) }
    }

    private func choosePhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a photo of your \(identity.name)."
        if panel.runModal() == .OK, let url = panel.url { setPhoto(from: url) }
    }

    private func setPhoto(from url: URL) {
        do {
            try store.setCustomPhoto(from: url, for: identity)
            customPhoto = store.customPhoto(for: identity)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
