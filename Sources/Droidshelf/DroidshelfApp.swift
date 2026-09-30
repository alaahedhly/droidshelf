import AppKit
import SwiftUI

@main
struct DroidshelfApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup("Droidshelf", id: "browser") {
            BrowserWindow(app: app)
                .frame(minWidth: 720, minHeight: 420)
        }
        .defaultSize(width: 1000, height: 620)
        .windowToolbarStyle(.unified)
        .commands { DroidshelfCommands(app: app) }

        Settings {
            SettingsView()
        }
    }
}

/// The bundle's .icns is the light variant; while running, the Dock and ⌘-Tab icon follow the system appearance.
/// (Adapting when the app isn't running needs an Icon Composer icon compiled by Xcode's actool.)
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appearanceObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.applyIcon()
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
            Task { @MainActor in AppDelegate.applyIcon() }
        }
    }

    private static func applyIcon() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let name = isDark ? "AppIcon-Dark" : "AppIcon"
        guard let url = Bundle.main.url(forResource: name, withExtension: "icns") else { return }
        NSApp.applicationIconImage = NSImage(contentsOf: url)
    }
}

struct BrowserFocusKey: FocusedValueKey {
    typealias Value = BrowserModel
}

extension FocusedValues {
    var browser: BrowserModel? {
        get { self[BrowserFocusKey.self] }
        set { self[BrowserFocusKey.self] = newValue }
    }
}

/// Finder's menu layout and shortcuts, so muscle memory carries over.
struct DroidshelfCommands: Commands {
    let app: AppModel
    @FocusedValue(\.browser) private var browser
    @AppStorage("viewMode") private var viewMode: ViewMode = .list
    @AppStorage("showPathBar") private var showPathBar = true
    @AppStorage("showStatusBar") private var showStatusBar = true
    @AppStorage("showHiddenFiles") private var showHiddenFiles = false

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Folder") { browser?.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!(browser?.canWrite ?? false))
            Divider()
            Button("Open") { browser?.openSelection() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(browser?.selection.isEmpty ?? true)
            Button("Quick Look") { browser?.toggleQuickLook() }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(browser?.selection.isEmpty ?? true)
            Divider()
            Button("Copy to Downloads") { browser.map { $0.copyToMac($0.selectedItems) } }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(browser?.selection.isEmpty ?? true)
            Button("Copy to…") { browser.map { $0.copyToMac($0.selectedItems, choosingDestination: true) } }
                .keyboardShortcut("c", modifiers: [.command, .option, .shift])
                .disabled(browser?.selection.isEmpty ?? true)
            Button("Copy Files to Phone…") { browser?.chooseFilesToUpload() }
                .keyboardShortcut("u", modifiers: .command)
                .disabled(!(browser?.canWrite ?? false))
            Divider()
            Button("Rename") { browser?.beginRename() }
                .disabled(browser?.selection.count != 1 || !(browser?.canWrite ?? false))
            Button("Delete…") { browser.map { $0.requestDelete($0.selectedItems) } }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(browser?.selection.isEmpty ?? true)
            Divider()
            Button("Add to Sidebar") {
                guard let browser else { return }
                if let folder = browser.selectedItems.first(where: \.isFolder) {
                    browser.addToSidebar(folder)
                } else {
                    browser.addCurrentFolderToSidebar()
                }
            }
            .keyboardShortcut("t", modifiers: [.command, .control])
            .disabled(browser?.location == nil)
        }

        CommandGroup(before: .toolbar) {
            Picker("View", selection: $viewMode) {
                Text("as Icons").tag(ViewMode.icons).keyboardShortcut("1", modifiers: .command)
                Text("as List").tag(ViewMode.list).keyboardShortcut("2", modifiers: .command)
                Text("as Columns").tag(ViewMode.columns).keyboardShortcut("3", modifiers: .command)
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Show Path Bar", isOn: $showPathBar)
                .keyboardShortcut("p", modifiers: [.command, .option])
            Toggle("Show Status Bar", isOn: $showStatusBar)
                .keyboardShortcut("/", modifiers: .command)
            Toggle("Show Hidden Files", isOn: $showHiddenFiles)
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Divider()
            Button("Refresh") { browser?.reload() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Look for Phones Again") { app.rescan() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
        }

        CommandMenu("Go") {
            Button("Back") { browser?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(browser?.backStack.isEmpty ?? true)
            Button("Forward") { browser?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(browser?.forwardStack.isEmpty ?? true)
            Button("Enclosing Folder") { browser?.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(browser?.location?.path.isEmpty ?? true)
        }
    }
}
