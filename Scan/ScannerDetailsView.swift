import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Sheet opened by double-clicking a scanner in the sidebar. Shows every
/// detail Scan knows about the scanner without opening the device.
struct ScannerDetailsView: View {
    let details: ScannerDetails
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "scanner").font(.largeTitle).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(details.identity.name).font(.title2.weight(.semibold))
                    Text("\(details.identity.manufacturer) · \(details.identity.connectionKind.rawValue)").foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
            ScannerPhotoView(identity: details.identity)
                .layoutPriority(1)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            Divider()
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
        .frame(minWidth: 520, idealWidth: 640, maxWidth: .infinity, minHeight: 560, idealHeight: 860, maxHeight: .infinity)
        .presentationSizing(.fitted)
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
