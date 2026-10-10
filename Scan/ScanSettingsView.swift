import SwiftUI

enum ScanProjectLinks {
    static let sourceCode = URL(string: "https://github.com/holgerkrupp/Scan")!
    static let issueReporter = URL(string: "https://github.com/holgerkrupp/Scan/issues/new/choose")!
}

struct ScanSettingsView: View {
    @Bindable var viewModel: ScannerWorkspaceViewModel

    var body: some View {
        Form {
            Section("Saving") {
                LabeledContent("Default location") {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(viewModel.destinationFolder.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(viewModel.destinationFolder.path)
                        Button("Show in Finder") {
                            viewModel.openDestinationFolder()
                        }
                        Button("Choose…") {
                            viewModel.chooseDestination()
                        }
                    }
                }

                Text("Manual exports, automatic saves, and scans run from Shortcuts are saved to this folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Language") {
                Picker("Default OCR language", selection: $viewModel.ocrSettings.language) {
                    ForEach(OCRLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                Toggle("Run OCR (ocrmypdf) after scanning", isOn: $viewModel.ocrSettings.runOCRmyPDF)
                Text(ocrmypdfStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Hardware Button / One-Touch Scan") {
                Toggle("Use physical Scan button", isOn: Binding(
                    get: { viewModel.hardwareButtonEnabled },
                    set: { viewModel.setHardwareButtonEnabled($0) }
                ))
                Toggle("Launch Scan at login", isOn: Binding(
                    get: { viewModel.hardwareLaunchAtLogin },
                    set: { viewModel.setHardwareLaunchAtLogin($0) }
                ))
                .disabled(!viewModel.hardwareButtonEnabled)

                Picker("Default profile", selection: Binding(
                    get: { viewModel.hardwareDefaultProfileID ?? viewModel.selectedProfile.id },
                    set: { viewModel.hardwareDefaultProfileID = $0 }
                )) {
                    ForEach(viewModel.profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .disabled(!viewModel.hardwareButtonEnabled)

                if let identity = viewModel.selectedIdentity {
                    Picker("Profile for \(identity.name)", selection: Binding(
                        get: { viewModel.hardwareProfileID(for: identity) ?? viewModel.selectedProfile.id },
                        set: { viewModel.setHardwareProfileOverride($0, for: identity) }
                    )) {
                        ForEach(viewModel.profiles) { profile in
                            Text(profile.name).tag(profile.id)
                        }
                    }
                    .disabled(!viewModel.hardwareButtonEnabled)

                    HStack {
                        Button("Use global default") { viewModel.setHardwareProfileOverride(nil, for: identity) }
                        Button("Choose destination…") { viewModel.chooseHardwareDestination() }
                    }
                    Text(viewModel.hardwareProfileSummary(for: identity))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let capabilities = viewModel.hardwareButtonCapabilities {
                    Text(capabilities.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("The app listens only while a supported scanner session is open. Unsupported devices remain available for manual scans.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let status = viewModel.hardwareButtonStatusMessage {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Project") {
                Link(destination: ScanProjectLinks.sourceCode) {
                    Label("View Source Code on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: ScanProjectLinks.issueReporter) {
                    Label("Report an Issue…", systemImage: "exclamationmark.bubble")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 620)
    }
}

extension ScanSettingsView {
    private var ocrmypdfStatus: String {
        guard viewModel.ocrSettings.runOCRmyPDF else { return "Exported PDFs are saved without an ocrmypdf text layer." }
        guard let runner = OCRmyPDFRunner.locate() else { return "ocrmypdf was not found. Install it with \"brew install ocrmypdf\"." }
        return "Every exported PDF is passed to \(runner.executableURL.path) with language \(viewModel.ocrSettings.language.tesseractCode)."
    }
}

#Preview {
    ScanSettingsView(viewModel: .shared)
}
