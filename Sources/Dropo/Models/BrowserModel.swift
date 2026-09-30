import AppKit
import DropoCore
import Observation
import UniformTypeIdentifiers

struct Crumb: Hashable {
    let id: UInt32
    let name: String
}

struct Location: Hashable {
    let deviceID: String
    let storageID: UInt32
    var path: [Crumb]

    var folder: FolderRef {
        FolderRef(storageID: storageID, folderID: path.last?.id ?? FolderRef.rootID)
    }

    func appending(_ item: Item) -> Location {
        Location(deviceID: deviceID, storageID: storageID, path: path + [Crumb(id: item.id, name: item.name)])
    }

    var parent: Location? {
        guard !path.isEmpty else { return nil }
        return Location(deviceID: deviceID, storageID: storageID, path: Array(path.dropLast()))
    }
}

enum ViewMode: String, CaseIterable, Identifiable {
    case icons, list, columns
    var id: String { rawValue }

    var title: String {
        switch self {
        case .icons: "as Icons"
        case .list: "as List"
        case .columns: "as Columns"
        }
    }

    var symbol: String {
        switch self {
        case .icons: "square.grid.2x2"
        case .list: "list.bullet"
        case .columns: "rectangle.split.3x1"
        }
    }
}

struct UploadConflict {
    let sources: [URL]
    let target: FolderRef
    let existing: [Item]

    var message: String {
        existing.count == 1
            ? "An item named “\(existing[0].name)” already exists in this location. Do you want to replace it with the one you’re copying?"
            : "\(existing.count) items with the same names already exist in this location. Do you want to replace them with the ones you’re copying?"
    }
}

/// Navigation and file operations for one window.
@MainActor @Observable
final class BrowserModel {
    let app: AppModel

    private(set) var location: Location?
    private(set) var backStack: [Location] = []
    private(set) var forwardStack: [Location] = []
    private(set) var items: [Item] = []
    private(set) var isLoading = false
    private(set) var loadError: String?

    var selection: Set<Item.ID> = []
    var sortOrder: [KeyPathComparator<Item>] = [KeyPathComparator(\.name, comparator: .localizedStandard)]
    var searchText = ""
    var renamingID: Item.ID?
    var previewURL: URL?
    var previewURLs: [URL] = []
    var pendingDelete: [Item]?
    var pendingConflict: UploadConflict?
    var alertMessage: String?

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// Icon view: the grid's deselect tap also fires for clicks on an icon, so it checks when an icon was last clicked.
    @ObservationIgnored var lastIconTap = Date.distantPast

    init(app: AppModel) {
        self.app = app
    }

    var device: ConnectedDevice? { app.device(location?.deviceID) }
    var storage: Storage? { location.flatMap { device?.storage($0.storageID) } }

    var title: String {
        guard let location else { return "Dropo" }
        if let folder = location.path.last { return folder.name }
        if let device, device.storages.count == 1 { return device.info.displayName }
        return storage?.name ?? "Dropo"
    }

    var visibleItems: [Item] {
        let showHidden = UserDefaults.standard.bool(forKey: "showHiddenFiles")
        let foldersOnTop = UserDefaults.standard.object(forKey: "foldersOnTop") as? Bool ?? true
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let filtered = items.filter { item in
            (showHidden || !item.isHidden) && (query.isEmpty || item.name.localizedStandardContains(query))
        }
        let sorted = filtered.sorted(using: sortOrder)
        guard foldersOnTop else { return sorted }
        return sorted.filter(\.isFolder) + sorted.filter { !$0.isFolder }
    }

    var selectedItems: [Item] { visibleItems.filter { selection.contains($0.id) } }

    var statusText: String {
        let count = visibleItems.count
        let itemsText = count == 1 ? "1 item" : "\(count) items"
        let selected = selection.isEmpty ? itemsText : "\(selection.count) of \(itemsText) selected"
        guard let storage else { return selected }
        return "\(selected), \(ByteCountFormatter.string(fromByteCount: Int64(storage.freeSpace), countStyle: .file)) available"
    }

    var canWrite: Bool { storage?.isWritable ?? false }

    // MARK: Navigation

    func go(to newLocation: Location, recordHistory: Bool = true) {
        guard newLocation != location else { return }
        if recordHistory, let location {
            backStack.append(location)
            forwardStack.removeAll()
        }
        location = newLocation
        selection = []
        searchText = ""
        renamingID = nil
        items = device?.cachedItems(in: newLocation.folder) ?? []
        reload(useCache: true)
    }

    func openStorage(_ storage: Storage, on device: ConnectedDevice) {
        go(to: Location(deviceID: device.id, storageID: storage.id, path: []))
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        if let location { forwardStack.append(location) }
        go(to: previous, recordHistory: false)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        if let location { backStack.append(location) }
        go(to: next, recordHistory: false)
    }

    func goUp() {
        guard let parent = location?.parent, let child = location?.path.last else { return }
        go(to: parent)
        selection = [child.id]
    }

    /// Resolves a favorite by folder names, since MTP ids change between sessions.
    func openFavorite(_ favorite: Favorite) {
        guard let device = app.devices.first(where: { $0.info.serial == favorite.deviceSerial }) else { return }
        Task {
            var location = Location(deviceID: device.id, storageID: favorite.storageID, path: [])
            do {
                for name in favorite.path {
                    let children = try await device.items(in: location.folder)
                    guard let match = children.first(where: { $0.isFolder && $0.name == name }) else {
                        alertMessage = "The folder “\(favorite.name)” couldn’t be found on \(device.info.displayName)."
                        return
                    }
                    location = location.appending(match)
                }
                go(to: location)
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    /// Keeps the window pointing somewhere valid as phones come and go.
    func syncWithDevices() {
        if let location, app.device(location.deviceID) == nil {
            self.location = nil
            items = []
            backStack.removeAll { app.device($0.deviceID) == nil }
            forwardStack.removeAll { app.device($0.deviceID) == nil }
        }
        if location == nil, let device = app.devices.first, let storage = device.storages.first {
            openStorage(storage, on: device)
        }
    }

    func reload(useCache: Bool = false) {
        guard let location, let device else { return }
        loadTask?.cancel()
        isLoading = true
        loadError = nil
        loadTask = Task {
            do {
                let fresh = try await device.items(in: location.folder, reload: !useCache)
                guard !Task.isCancelled, self.location == location else { return }
                items = fresh
                selection.formIntersection(Set(fresh.map(\.id)))
            } catch {
                guard !Task.isCancelled, self.location == location else { return }
                loadError = error.localizedDescription
            }
            isLoading = false
        }
    }

    // MARK: Opening

    func open(_ item: Item) {
        if item.isFolder, let location {
            go(to: location.appending(item))
            return
        }
        Task {
            guard let urls = try? await localCopies(of: [item], title: "Opening “\(item.name)”") else { return }
            urls.forEach { NSWorkspace.shared.open($0) }
        }
    }

    func openSelection() {
        let selected = selectedItems
        if selected.count == 1, selected[0].isFolder { return open(selected[0]) }
        selected.filter { !$0.isFolder }.forEach(open)
    }

    func toggleQuickLook() {
        if previewURL != nil {
            previewURL = nil
            return
        }
        let files = selectedItems.filter { !$0.isFolder }
        guard !files.isEmpty else { return }
        Task {
            guard let urls = try? await localCopies(of: files, title: "Preparing preview") else { return }
            previewURLs = urls
            previewURL = urls.first
        }
    }

    /// Downloads into a per-item cache so reopening the same file is instant.
    private func localCopies(of files: [Item], title: String) async throws -> [URL] {
        guard let device else { return [] }
        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.hortensia.dropo/\(device.info.serial)")
        var urls: [URL] = []
        var missing: [(Item, URL)] = []
        for file in files {
            let folder = cacheRoot.appendingPathComponent("\(file.storageID)-\(file.id)")
            let url = folder.appendingPathComponent(file.name)
            urls.append(url)
            let cachedSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init)
            if cachedSize != file.size { missing.append((file, folder)) }
        }
        for (file, folder) in missing {
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try await app.transfers.run(missing.count == 1 ? title : "\(title) (\(missing.count) items)", direction: .toMac) { progress in
                try await TransferEngine.download([file], from: device.backend, into: folder, progress: progress)
            }
        }
        return urls
    }

    // MARK: Phone → Mac

    func copyToMac(_ items: [Item], choosingDestination: Bool = false) {
        guard let device, !items.isEmpty else { return }
        var destination = downloadFolder
        if choosingDestination {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Copy Here"
            panel.directoryURL = destination
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        }
        let title = items.count == 1 ? "Copying “\(items[0].name)” to \(destination.lastPathComponent)" : "Copying \(items.count) items to \(destination.lastPathComponent)"
        Task {
            do {
                try await app.transfers.run(title, direction: .toMac) { progress in
                    try await TransferEngine.download(items, from: device.backend, into: destination, progress: progress)
                }
            } catch DropoError.cancelled {
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    /// Called by Finder when a dragged phone file is dropped; materialises it in a temporary folder.
    func exportForDrag(_ item: Item) async throws -> URL {
        guard let device else { throw DropoError.notConnected }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DropoDrag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let urls = try await app.transfers.run("Copying “\(item.name)”", direction: .toMac) { progress in
            try await TransferEngine.download([item], from: device.backend, into: folder, progress: progress)
        }
        return urls[0]
    }

    var downloadFolder: URL {
        if let path = UserDefaults.standard.string(forKey: "downloadFolder"), !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    // MARK: Mac → Phone

    func chooseFilesToUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Copy to Phone"
        guard panel.runModal() == .OK else { return }
        upload(panel.urls)
    }

    func upload(_ sources: [URL], into target: FolderRef? = nil) {
        guard let device, let target = target ?? location?.folder else { return }
        guard device.storage(target.storageID)?.isWritable ?? false else {
            alertMessage = DropoError.readOnly.localizedDescription
            return
        }
        Task {
            let existing = (try? await device.items(in: target)) ?? []
            let names = Set(sources.map(\.lastPathComponent))
            let clashes = existing.filter { names.contains($0.name) }
            if clashes.isEmpty {
                performUpload(sources, into: target, resolution: .keepBoth)
            } else {
                pendingConflict = UploadConflict(sources: sources, target: target, existing: clashes)
            }
        }
    }

    enum ConflictResolution { case keepBoth, replace, skip }

    func resolveConflict(_ resolution: ConflictResolution) {
        guard let conflict = pendingConflict else { return }
        pendingConflict = nil
        performUpload(conflict.sources, into: conflict.target, resolution: resolution, clashes: conflict.existing)
    }

    private func performUpload(_ sources: [URL], into target: FolderRef, resolution: ConflictResolution, clashes: [Item] = []) {
        guard let device else { return }
        let clashNames = Set(clashes.map(\.name))
        var taken = Set((device.cachedItems(in: target) ?? []).map(\.name))
        var uploads: [TransferEngine.Upload] = []
        for source in sources {
            var name = source.lastPathComponent
            if clashNames.contains(name) {
                switch resolution {
                case .skip: continue
                case .replace: break
                case .keepBoth: name = Naming.unique(name, avoiding: taken)
                }
            }
            taken.insert(name)
            uploads.append(.init(source: source, name: name))
        }
        guard !uploads.isEmpty else { return }
        let replaced = resolution == .replace ? clashes : []
        let title = uploads.count == 1 ? "Copying “\(uploads[0].name)” to \(device.info.displayName)" : "Copying \(uploads.count) items to \(device.info.displayName)"

        Task {
            do {
                for item in replaced { try await device.backend.delete(item) }
                try await app.transfers.run(title, direction: .toPhone) { progress in
                    try await TransferEngine.upload(uploads, to: device.backend, into: target, progress: progress)
                }
            } catch DropoError.cancelled {
            } catch {
                alertMessage = error.localizedDescription
            }
            await refresh(after: target)
        }
    }

    // MARK: Editing

    func newFolder() {
        guard let device, let target = location?.folder, canWrite else { return }
        let name = Naming.unique("untitled folder", avoiding: Set(items.map(\.name)))
        Task {
            do {
                let folder = try await device.backend.createFolder(named: name, in: target)
                await refresh(after: target)
                selection = [folder.id]
                renamingID = visibleItems.first { $0.name == name }?.id ?? folder.id
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    func beginRename() {
        guard canWrite, selection.count == 1 else { return }
        renamingID = selection.first
    }

    func commitRename(_ item: Item, to newName: String) {
        renamingID = nil
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard name != item.name, let device, let target = location?.folder else { return }
        if let problem = Naming.validationError(for: name) {
            alertMessage = problem
            return
        }
        if items.contains(where: { $0.id != item.id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            alertMessage = "The name “\(name)” is already taken. Please choose a different name."
            return
        }
        if let index = items.firstIndex(of: item) { items[index].name = name }
        Task {
            do {
                try await device.backend.rename(item, to: name)
            } catch {
                alertMessage = error.localizedDescription
            }
            await refresh(after: target)
        }
    }

    func requestDelete(_ targets: [Item]) {
        guard !targets.isEmpty, storage?.access != .readOnly else { return }
        pendingDelete = targets
    }

    var deleteMessage: String {
        guard let targets = pendingDelete else { return "" }
        let subject = targets.count == 1 ? "“\(targets[0].name)”" : "the \(targets.count) selected items"
        return "Are you sure you want to delete \(subject) from the phone? This can’t be undone."
    }

    func confirmDelete() {
        guard let targets = pendingDelete, let device, let target = location?.folder else { return }
        pendingDelete = nil
        let ids = Set(targets.map(\.id))
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        Task {
            do {
                for item in targets { try await device.backend.delete(item) }
            } catch {
                alertMessage = error.localizedDescription
            }
            await refresh(after: target)
        }
    }

    func addToSidebar(_ item: Item) {
        guard item.isFolder, let device, let location else { return }
        app.addFavorite(device: device, storageID: location.storageID, path: location.path.map(\.name) + [item.name])
    }

    func addCurrentFolderToSidebar() {
        guard let device, let location, !location.path.isEmpty else { return }
        app.addFavorite(device: device, storageID: location.storageID, path: location.path.map(\.name))
    }

    private func refresh(after folder: FolderRef) async {
        guard let device else { return }
        device.invalidate(folder)
        try? await device.refreshStorages()
        if location?.folder == folder, let fresh = try? await device.items(in: folder) {
            items = fresh
        }
    }

    // MARK: Drag & drop

    func dragProvider(for item: Item) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = item.name
        let type = item.isFolder ? UTType.folder : (UTType(filenameExtension: item.fileExtension) ?? .data)
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            let progress = Progress(totalUnitCount: 1)
            Task { @MainActor in
                do {
                    let url = try await self.exportForDrag(item)
                    progress.completedUnitCount = 1
                    completion(url, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return progress
        }
        return provider
    }

    func handleDrop(_ providers: [NSItemProvider], into target: FolderRef? = nil) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty, canWrite else { return false }
        let group = DispatchGroup()
        let dropped = DroppedURLs()
        for provider in fileProviders {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { dropped.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated {
                let urls = dropped.urls
                if !urls.isEmpty { self.upload(urls, into: target) }
            }
        }
        return true
    }
}

private final class DroppedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []
    var urls: [URL] { lock.withLock { storage } }
    func append(_ url: URL) { lock.withLock { storage.append(url) } }
}
