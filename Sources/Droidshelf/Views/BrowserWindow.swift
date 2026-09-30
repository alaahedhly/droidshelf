import DroidshelfCore
import QuickLook
import SwiftUI

struct BrowserWindow: View {
    let app: AppModel
    @State private var browser: BrowserModel
    @AppStorage("viewMode") private var viewMode: ViewMode = .list
    @AppStorage("showPathBar") private var showPathBar = true
    @AppStorage("showStatusBar") private var showStatusBar = true
    @AppStorage("showHiddenFiles") private var showHiddenFiles = false
    @State private var showsTransfers = false
    @State private var isDropTargeted = false

    init(app: AppModel) {
        self.app = app
        _browser = State(initialValue: BrowserModel(app: app))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(app: app, browser: browser)
                .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 300)
        } detail: {
            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay {
                        if isDropTargeted {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.accentColor, lineWidth: 3)
                                .padding(2)
                                .allowsHitTesting(false)
                        }
                    }
                    .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { browser.handleDrop($0) }
                if browser.location != nil {
                    if showPathBar {
                        Divider()
                        PathBar(browser: browser)
                    }
                    if showStatusBar {
                        Divider()
                        StatusBar(browser: browser)
                    }
                }
            }
        }
        .navigationTitle(browser.title)
        .toolbar { toolbar }
        .searchable(text: $browser.searchText, placement: .toolbar, prompt: "Search")
        .quickLookPreview($browser.previewURL, in: browser.previewURLs)
        .alert(deleteTitle, isPresented: isPresent(\.pendingDelete)) {
            Button("Delete", role: .destructive) { browser.confirmDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will be deleted from the phone immediately. You can’t undo this action.")
        }
        .alert("Replace existing items?", isPresented: isPresent(\.pendingConflict)) {
            Button("Keep Both") { browser.resolveConflict(.keepBoth) }
            Button("Replace", role: .destructive) { browser.resolveConflict(.replace) }
            Button("Skip") { browser.resolveConflict(.skip) }
            Button("Stop", role: .cancel) {}
        } message: {
            Text(browser.pendingConflict?.message ?? "")
        }
        .alert("Droidshelf", isPresented: isPresent(\.alertMessage)) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(browser.alertMessage ?? "")
        }
        .focusedSceneValue(\FocusedValues.browser, browser)
        .onAppear {
            browser.syncWithDevices()
            DevSnapshot.runIfRequested(browser: browser)
        }
        .onChange(of: deviceSignature) { browser.syncWithDevices() }
        .onChange(of: showHiddenFiles) { browser.selection = [] }
    }

    @ViewBuilder private var content: some View {
        if browser.location == nil {
            EmptyStateView(app: app)
        } else if let error = browser.loadError, browser.items.isEmpty {
            ContentUnavailableView {
                Label("Can’t Read This Folder", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { browser.reload() }
            }
        } else {
            switch viewMode {
            case .icons: IconBrowserView(browser: browser)
            case .list: ListBrowserView(browser: browser)
            case .columns: ColumnBrowserView(browser: browser)
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            ControlGroup {
                Button { browser.goBack() } label: { Image(systemName: "chevron.left") }
                    .help("See folders you viewed previously")
                    .disabled(browser.backStack.isEmpty)
                Button { browser.goForward() } label: { Image(systemName: "chevron.right") }
                    .help("See folders you viewed next")
                    .disabled(browser.forwardStack.isEmpty)
            }
            .controlGroupStyle(.navigation)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Picker("View", selection: $viewMode) {
                ForEach(ViewMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Change the item view")

            Menu {
                ItemMenu(browser: browser, items: browser.selectedItems)
                if browser.selectedItems.isEmpty, browser.location?.path.isEmpty == false {
                    Divider()
                    Button("Add Folder to Sidebar") { browser.addCurrentFolderToSidebar() }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .help("Actions for the selection")
            .disabled(browser.location == nil)

            Button { browser.chooseFilesToUpload() } label: {
                Image(systemName: "square.and.arrow.down.on.square")
            }
            .help("Copy files from this Mac to the phone")
            .disabled(!browser.canWrite)

            if !app.transfers.transfers.isEmpty {
                Button { showsTransfers.toggle() } label: {
                    if let fraction = app.transfers.overallFraction {
                        ProgressView(value: fraction)
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                    } else {
                        Image(systemName: app.transfers.active.isEmpty ? "checkmark.circle" : "arrow.up.arrow.down.circle")
                    }
                }
                .help("Show transfers")
                .popover(isPresented: $showsTransfers, arrowEdge: .bottom) {
                    TransfersView(center: app.transfers)
                }
            }
        }
    }

    private var deviceSignature: [String] {
        app.devices.flatMap { device in device.storages.map { "\(device.id)/\($0.id)" } }
    }

    private var deleteTitle: String {
        guard let targets = browser.pendingDelete else { return "" }
        return targets.count == 1 ? "Delete “\(targets[0].name)”?" : "Delete \(targets.count) items?"
    }

    private func isPresent<T>(_ keyPath: ReferenceWritableKeyPath<BrowserModel, T?>) -> Binding<Bool> {
        Binding { browser[keyPath: keyPath] != nil } set: { if !$0 { browser[keyPath: keyPath] = nil } }
    }
}

struct PathBar: View {
    let browser: BrowserModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                if let location = browser.location, let device = browser.device {
                    crumb(device.info.displayName, systemImage: "smartphone") {
                        browser.go(to: Location(deviceID: location.deviceID, storageID: location.storageID, path: []))
                    }
                    if device.storages.count > 1, let storage = browser.storage {
                        separator
                        crumb(storage.name, systemImage: "internaldrive") {
                            browser.go(to: Location(deviceID: location.deviceID, storageID: location.storageID, path: []))
                        }
                    }
                    ForEach(Array(location.path.enumerated()), id: \.offset) { index, part in
                        separator
                        crumb(part.name, systemImage: "folder.fill") {
                            browser.go(to: Location(deviceID: location.deviceID, storageID: location.storageID, path: Array(location.path.prefix(index + 1))))
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 24)
    }

    private var separator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.tertiary)
    }

    private func crumb(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 11))
                .imageScale(.small)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

struct StatusBar: View {
    let browser: BrowserModel

    var body: some View {
        ZStack {
            Text(browser.statusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if browser.isLoading {
                HStack {
                    ProgressView().controlSize(.mini)
                    Spacer()
                }
                .padding(.horizontal, 10)
            }
        }
        .frame(height: 22)
        .frame(maxWidth: .infinity)
    }
}
