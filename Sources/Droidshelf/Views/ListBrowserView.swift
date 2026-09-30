import DroidshelfCore
import SwiftUI

struct ListBrowserView: View {
    @Bindable var browser: BrowserModel

    var body: some View {
        Table(of: Item.self, selection: $browser.selection, sortOrder: $browser.sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { item in
                NameCell(browser: browser, item: item)
            }
            .width(min: 180, ideal: 320)

            TableColumn("Date Modified", value: \.modifiedSortKey) { item in
                Text(item.modifiedText).foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 170)

            TableColumn("Size", value: \.size) { item in
                Text(item.sizeText)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 80)

            TableColumn("Kind", value: \.kind, comparator: .localizedStandard) { item in
                Text(item.kind).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 140)
        } rows: {
            ForEach(browser.visibleItems) { item in
                TableRow(item)
                    .itemProvider { browser.dragProvider(for: item) }
            }
        }
        .contextMenu(forSelectionType: Item.ID.self) { ids in
            ItemMenu(browser: browser, items: browser.visibleItems.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            browser.selection = ids
            browser.openSelection()
        }
        .onKeyPress(.space) {
            browser.toggleQuickLook()
            return .handled
        }
        .onKeyPress(.return) {
            guard browser.renamingID == nil else { return .ignored }
            browser.beginRename()
            return .handled
        }
    }
}

private struct NameCell: View {
    let browser: BrowserModel
    let item: Item
    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 6) {
            ItemIcon(item: item, device: browser.device, size: 16, loadsThumbnail: true)
            if browser.renamingID == item.id {
                RenameField(item: item) { browser.commitRename(item, to: $0) } onCancel: { browser.renamingID = nil }
            } else {
                Text(item.name).lineLimit(1).truncationMode(.middle)
            }
        }
        .opacity(item.isHidden ? 0.5 : 1)
        .padding(.horizontal, 2)
        .background(isTargeted ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .onDrop(of: item.isFolder ? [.fileURL] : [], isTargeted: $isTargeted) { providers in
            browser.handleDrop(providers, into: item.asFolder)
        }
    }
}
