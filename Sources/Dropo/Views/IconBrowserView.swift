import AppKit
import DropoCore
import SwiftUI

struct IconBrowserView: View {
    @Bindable var browser: BrowserModel
    @State private var anchor: Item.ID?
    @State private var columnCount = 1
    @FocusState private var focused: Bool

    private static let cellWidth: CGFloat = 104
    private static let spacing: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.cellWidth, maximum: Self.cellWidth), spacing: Self.spacing)], spacing: 14) {
                    ForEach(browser.visibleItems) { item in
                        IconCell(browser: browser, item: item, isSelected: browser.selection.contains(item.id))
                            .onTapGesture {
                                browser.lastIconTap = .now
                                select(item)
                            }
                            .simultaneousGesture(TapGesture(count: 2).onEnded { browser.open(item) })
                            .onDrag { browser.dragProvider(for: item) }
                            .contextMenu {
                                ItemMenu(browser: browser, items: browser.selection.contains(item.id) ? browser.selectedItems : [item])
                            }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
                .contentShape(Rectangle())
                // Also fires for clicks on an icon — after the double-click interval, since SwiftUI first waits to see if
                // the icon gets a double-click — so only deselect when no icon was just clicked.
                .onTapGesture {
                    focused = true
                    if Date.now.timeIntervalSince(browser.lastIconTap) > NSEvent.doubleClickInterval + 0.25 {
                        browser.selection = []
                    }
                }
                .contextMenu { ItemMenu(browser: browser, items: []) }
            }
            .onAppear { updateColumns(geometry.size.width) }
            .onChange(of: geometry.size.width) { _, width in updateColumns(width) }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.space) {
            browser.toggleQuickLook()
            return .handled
        }
        .onKeyPress(.return) {
            guard browser.renamingID == nil else { return .ignored }
            browser.beginRename()
            return .handled
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            guard browser.renamingID == nil else { return .ignored }
            let step = switch press.key {
            case .leftArrow: -1
            case .rightArrow: 1
            case .upArrow: -columnCount
            default: columnCount
            }
            moveSelection(by: step)
            return .handled
        }
    }

    private func updateColumns(_ width: CGFloat) {
        columnCount = max(1, Int((width - 24 + Self.spacing) / (Self.cellWidth + Self.spacing)))
    }

    private func select(_ item: Item) {
        focused = true
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.command) {
            if browser.selection.contains(item.id) { browser.selection.remove(item.id) } else { browser.selection.insert(item.id) }
            anchor = item.id
        } else if modifiers.contains(.shift), let anchor, let from = browser.visibleItems.firstIndex(where: { $0.id == anchor }),
                  let to = browser.visibleItems.firstIndex(of: item) {
            browser.selection = Set(browser.visibleItems[min(from, to)...max(from, to)].map(\.id))
        } else {
            browser.selection = [item.id]
            anchor = item.id
        }
    }

    private func moveSelection(by step: Int) {
        let items = browser.visibleItems
        guard !items.isEmpty else { return }
        let current = items.lastIndex { browser.selection.contains($0.id) }
        let next = current.map { min(max($0 + step, 0), items.count - 1) } ?? 0
        browser.selection = [items[next].id]
        anchor = items[next].id
    }
}

private struct IconCell: View {
    let browser: BrowserModel
    let item: Item
    let isSelected: Bool
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 4) {
            ItemIcon(item: item, device: browser.device, size: 64, loadsThumbnail: true)
                .padding(5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected || isTargeted ? Color.primary.opacity(0.12) : .clear)
                )
            if browser.renamingID == item.id {
                RenameField(item: item, centered: true) { browser.commitRename(item, to: $0) } onCancel: { browser.renamingID = nil }
                    .frame(width: 100)
            } else {
                Text(item.name)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .foregroundStyle(isSelected ? Color.white : .primary)
                    .background(isSelected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .frame(width: 100)
        .opacity(item.isHidden ? 0.5 : 1)
        .contentShape(Rectangle())
        .onDrop(of: item.isFolder ? [.fileURL] : [], isTargeted: $isTargeted) { providers in
            browser.handleDrop(providers, into: item.asFolder)
        }
    }
}
