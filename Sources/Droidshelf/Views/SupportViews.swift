import AppKit
import SwiftUI

struct EmptyStateView: View {
    let app: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "cable.connector.horizontal")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                Text("Connect an Android Phone")
                    .font(.title2.weight(.semibold))
                Text("Its files will show up here, just like a drive in Finder.")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                step(1, "Plug the phone into this Mac with a USB cable.")
                step(2, "Unlock the phone.")
                step(3, "Tap the “Charging this device via USB” notification and choose **File transfer**.")
            }
            .padding(16)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            if let issue = app.connectionIssue {
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            if app.isConnecting {
                ProgressView("Connecting…").controlSize(.small)
            } else {
                Button("Look for Phones Again") { app.rescan() }
            }
        }
        .padding(40)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Color.accentColor, in: Circle())
            Text(text)
        }
    }
}

struct TransfersView: View {
    let center: TransferCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transfers").font(.headline)
                Spacer()
                Button("Clear") { center.clearFinished() }
                    .controlSize(.small)
                    .disabled(center.transfers.allSatisfy(\.isRunning))
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(center.transfers) { transfer in
                        TransferRow(transfer: transfer)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 360)
    }
}

private struct TransferRow: View {
    let transfer: Transfer

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: transfer.direction == .toMac ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .font(.title2)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(transfer.title).lineLimit(1).truncationMode(.middle)
                if transfer.isRunning {
                    ProgressView(value: transfer.fraction ?? 0)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
                Text(transfer.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if transfer.isRunning {
                Button { transfer.cancel() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Stop")
            } else if !transfer.results.isEmpty {
                Button { NSWorkspace.shared.activateFileViewerSelecting(transfer.results) } label: {
                    Image(systemName: "magnifyingglass.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Show in Finder")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var tint: Color {
        switch transfer.state {
        case .failed: .red
        case .cancelled: .secondary
        default: .accentColor
        }
    }
}

struct SettingsView: View {
    @AppStorage("downloadFolder") private var downloadFolder = ""
    @AppStorage("showHiddenFiles") private var showHiddenFiles = false
    @AppStorage("foldersOnTop") private var foldersOnTop = true
    @AppStorage("releaseFromImageCapture") private var releaseFromImageCapture = true

    var body: some View {
        Form {
            Section("Files") {
                LabeledContent("Copy phone files to") {
                    HStack {
                        Text(folderName).foregroundStyle(.secondary)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Toggle("Keep folders on top", isOn: $foldersOnTop)
                Toggle("Show hidden files", isOn: $showHiddenFiles)
            }
            Section {
                Toggle("Take the phone over from Photos and Image Capture", isOn: $releaseFromImageCapture)
            } header: {
                Text("Connection")
            } footer: {
                Text("macOS grabs every phone that’s plugged in for photo import, which blocks file transfer. Droidshelf stops that when it connects.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize()
    }

    private var folderName: String {
        downloadFolder.isEmpty ? "Downloads" : (downloadFolder as NSString).lastPathComponent
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { downloadFolder = url.path }
    }
}
