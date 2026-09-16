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

#Preview {
    ScanSettingsView(viewModel: .shared)
}
