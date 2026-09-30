import AppKit
import DropoCore
import SwiftUI

/// Finder icon for an item, upgraded to the phone's own thumbnail for photos and videos.
struct ItemIcon: View {
    let item: Item
    let device: ConnectedDevice?
    var size: CGFloat = 16
    var loadsThumbnail = false

    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                // Quick Look's icon mode already adds Finder's page curl, frame and shadow.
                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: FileIcons.icon(for: item))
                    .resizable()
                    .interpolation(.high)
            }
        }
        .frame(width: size, height: size)
        .task(id: loadsThumbnail ? item.id : nil) {
            guard loadsThumbnail, let device else { return }
            thumbnail = await ThumbnailStore.shared.thumbnail(for: item, on: device, size: size)
        }
    }
}

/// Inline rename, committing on Return or when focus leaves — like Finder.
struct RenameField: View {
    let item: Item
    var centered = false
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String
    @State private var finished = false
    @FocusState private var focused: Bool

    init(item: Item, centered: Bool = false, onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.item = item
        self.centered = centered
        self.onCommit = onCommit
        self.onCancel = onCancel
        _text = State(initialValue: item.name)
    }

    var body: some View {
        TextField("Name", text: $text)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(centered ? .center : .leading)
            .focused($focused)
            .onAppear { focused = true }
            .onSubmit { finish(commit: true) }
            .onExitCommand { finish(commit: false) }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { finish(commit: true) }
            }
    }

    private func finish(commit: Bool) {
        guard !finished else { return }
        finished = true
        commit ? onCommit(text) : onCancel()
    }
}

/// The right-click menu shared by every view mode.
struct ItemMenu: View {
    let browser: BrowserModel
    let items: [Item]

    var body: some View {
        if items.isEmpty {
            Button("New Folder") { browser.newFolder() }.disabled(!browser.canWrite)
            Button("Copy Files to Phone…") { browser.chooseFilesToUpload() }.disabled(!browser.canWrite)
            Divider()
            Button("Refresh") { browser.reload() }
        } else {
            Button("Open") {
                items.count == 1 ? browser.open(items[0]) : items.filter { !$0.isFolder }.forEach(browser.open)
            }
            if items.contains(where: { !$0.isFolder }) {
                Button("Quick Look") {
                    browser.selection = Set(items.map(\.id))
                    browser.toggleQuickLook()
                }
            }
            Divider()
            Button("Copy to \(browser.downloadFolder.lastPathComponent)") { browser.copyToMac(items) }
            Button("Copy to…") { browser.copyToMac(items, choosingDestination: true) }
            Divider()
            if items.count == 1 {
                Button("Rename") {
                    browser.selection = [items[0].id]
                    browser.beginRename()
                }
                .disabled(!browser.canWrite)
            }
            Button(items.count == 1 ? "Delete…" : "Delete \(items.count) Items…", role: .destructive) {
                browser.requestDelete(items)
            }
            .disabled(browser.storage?.access == .readOnly)
            if items.count == 1, items[0].isFolder {
                Divider()
                Button("Add to Sidebar") { browser.addToSidebar(items[0]) }
            }
        }
    }
}

extension Item {
    var sizeText: String {
        isFolder ? "--" : ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    /// Finder style: "Today at 14:02", "Yesterday at 09:10", otherwise the full date.
    var modifiedText: String {
        guard let modified else { return "--" }
        let time = modified.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(modified) { return "Today at \(time)" }
        if Calendar.current.isDateInYesterday(modified) { return "Yesterday at \(time)" }
        return modified.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())
    }
}
