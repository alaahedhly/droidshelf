import DropoCore
import SwiftUI

/// Finder's column view: one column per folder along the current path, plus a preview of a selected file.
struct ColumnBrowserView: View {
    @Bindable var browser: BrowserModel

    var body: some View {
        if let location = browser.location {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(0..<location.path.count, id: \.self) { level in
                            let prefix = Location(deviceID: location.deviceID, storageID: location.storageID, path: Array(location.path.prefix(level)))
                            ParentColumn(browser: browser, location: prefix, selectedID: location.path[level].id)
                            Divider()
                        }
                        CurrentColumn(browser: browser)
                        Divider()
                        if browser.selectedItems.count == 1, let file = browser.selectedItems.first, !file.isFolder {
                            PreviewColumn(browser: browser, item: file)
                        }
                        Color.clear.frame(width: 1).id("end")
                    }
                }
                .onChange(of: location) { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("end") } }
                .onChange(of: browser.selection) { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("end") } }
            }
        }
    }
}

private struct ColumnRow: View {
    let browser: BrowserModel
    let item: Item

    var body: some View {
        HStack(spacing: 6) {
            ItemIcon(item: item, device: browser.device, size: 16, loadsThumbnail: true)
            Text(item.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if item.isFolder {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(item.isHidden ? 0.5 : 1)
    }
}

/// A column for an ancestor folder; its highlighted row is the next folder along the path.
private struct ParentColumn: View {
    let browser: BrowserModel
    let location: Location
    let selectedID: UInt32
    @State private var items: [Item] = []

    var body: some View {
        List(selection: Binding<UInt32?>(get: { selectedID }, set: { id in
            guard let id, let item = items.first(where: { $0.id == id }) else { return }
            if item.isFolder {
                browser.go(to: location.appending(item))
            } else {
                browser.go(to: location)
                browser.selection = [item.id]
            }
        })) {
            ForEach(sorted) { item in
                ColumnRow(browser: browser, item: item).tag(item.id)
            }
        }
        .frame(width: 230)
        .task(id: location) {
            items = (try? await browser.device?.items(in: location.folder)) ?? []
        }
    }

    private var sorted: [Item] {
        let showHidden = UserDefaults.standard.bool(forKey: "showHiddenFiles")
        return items.filter { showHidden || !$0.isHidden }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

private struct CurrentColumn: View {
    @Bindable var browser: BrowserModel

    var body: some View {
        // A Table rather than a List: its rows handle drag and click-to-select natively, whereas a drag provider on
        // List row content swallows clicks on the name and icon.
        Table(of: Item.self, selection: $browser.selection) {
            TableColumn("Name") { item in
                ColumnRow(browser: browser, item: item)
            }
        } rows: {
            ForEach(browser.visibleItems) { item in
                TableRow(item).itemProvider { browser.dragProvider(for: item) }
            }
        }
        .tableColumnHeaders(.hidden)
        .alternatingRowBackgrounds(.disabled)
        .frame(width: 230)
        .contextMenu(forSelectionType: Item.ID.self) { ids in
            ItemMenu(browser: browser, items: browser.visibleItems.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            browser.selection = ids
            browser.openSelection()
        }
        .onChange(of: browser.selection) { _, selection in
            guard selection.count == 1, let item = browser.selectedItems.first, item.isFolder,
                  let location = browser.location else { return }
            browser.go(to: location.appending(item))
        }
        .onKeyPress(.space) {
            browser.toggleQuickLook()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            browser.goUp()
            return .handled
        }
    }
}

private struct PreviewColumn: View {
    let browser: BrowserModel
    let item: Item

    var body: some View {
        VStack(spacing: 12) {
            ItemIcon(item: item, device: browser.device, size: 160, loadsThumbnail: true)
                .padding(.top, 24)
            Text(item.name)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Text("\(item.kind) — \(item.sizeText)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Divider().padding(.horizontal)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("Modified").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(item.modifiedText)
                }
            }
            .font(.caption)
            Button("Copy to \(browser.downloadFolder.lastPathComponent)") { browser.copyToMac([item]) }
                .controlSize(.small)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(width: 260)
    }
}
