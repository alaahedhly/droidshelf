import AppKit
import DroidshelfCore
import Observation

/// One phone that is open and browsable. Listings are cached here so every window and column view shares them.
@MainActor @Observable
final class ConnectedDevice: Identifiable {
    let id: String
    let backend: DeviceBackend
    var info: DeviceInfo { backend.info }
    private(set) var storages: [Storage] = []
    private var cache: [FolderRef: [Item]] = [:]

    init(id: String, backend: DeviceBackend) {
        self.id = id
        self.backend = backend
    }

    func storage(_ id: UInt32) -> Storage? { storages.first { $0.id == id } }

    func refreshStorages() async throws {
        storages = try await backend.storages()
    }

    func items(in folder: FolderRef, reload: Bool = false) async throws -> [Item] {
        if !reload, let cached = cache[folder] { return cached }
        let items = try await backend.contents(of: folder)
        cache[folder] = items
        return items
    }

    func cachedItems(in folder: FolderRef) -> [Item]? { cache[folder] }

    func invalidate(_ folder: FolderRef) { cache[folder] = nil }
    func invalidateAll() { cache.removeAll() }
}

struct Favorite: Codable, Hashable, Identifiable {
    var id = UUID()
    var deviceSerial: String
    var storageID: UInt32
    /// Folder names from the storage root. MTP object ids are reassigned every session, so favorites resolve by name.
    var path: [String]

    var name: String { path.last ?? "Storage" }
}

@MainActor @Observable
final class AppModel {
    private(set) var devices: [ConnectedDevice] = []
    private(set) var connectionIssue: String?
    private(set) var isConnecting = false
    let transfers = TransferCenter()
    var favorites: [Favorite] = [] {
        didSet { saveFavorites() }
    }

    @ObservationIgnored private var watcher: USBWatcher?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var ejectedKeys: Set<String> = []
    @ObservationIgnored private var failedKeys: Set<String> = []
    @ObservationIgnored private var waiting: [String: ConnectedDevice] = [:]

    init() {
        favorites = (UserDefaults.standard.data(forKey: "favorites"))
            .flatMap { try? JSONDecoder().decode([Favorite].self, from: $0) } ?? []

        if let demoRoot = Self.demoRoot() {
            let device = ConnectedDevice(id: "demo", backend: DemoDevice(root: demoRoot))
            devices = [device]
            Task { try? await device.refreshStorages() }
            return
        }
        watcher = USBWatcher { [weak self] in
            MainActor.assumeIsolated {
                self?.failedKeys.removeAll()
                self?.scheduleScan(after: .milliseconds(800))
            }
        }
        scheduleScan(after: .zero)
    }

    func device(_ id: String?) -> ConnectedDevice? { devices.first { $0.id == id } }

    func rescan() {
        failedKeys.removeAll()
        ejectedKeys.removeAll()
        scheduleScan(after: .zero)
    }

    func eject(_ device: ConnectedDevice) {
        ejectedKeys.insert(device.id)
        devices.removeAll { $0.id == device.id }
        device.backend.close()
    }

    /// USB events arrive in bursts (a phone switching to File Transfer re-enumerates), so collapse them into one scan.
    private func scheduleScan(after delay: Duration) {
        scanTask?.cancel()
        scanTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await scan()
        }
    }

    private func scan() async {
        let present = await MTPLibrary.detect()
        let presentKeys = Set(present.map(\.key))

        for device in devices + waiting.values where !presentKeys.contains(device.id) {
            device.backend.close()
        }
        devices.removeAll { !presentKeys.contains($0.id) }
        waiting = waiting.filter { presentKeys.contains($0.key) }
        ejectedKeys.formIntersection(presentKeys)

        let known = Set(devices.map(\.id)).union(waiting.keys)
        let pending = present.filter { !known.contains($0.key) && !ejectedKeys.contains($0.key) && !failedKeys.contains($0.key) }
        guard !pending.isEmpty else {
            if present.isEmpty { connectionIssue = nil }
            return
        }

        isConnecting = true
        defer { isConnecting = false }
        let release = UserDefaults.standard.object(forKey: "releaseFromImageCapture") as? Bool ?? true
        for raw in pending {
            do {
                let backend = try await MTPLibrary.open(raw, releaseFromImageCapture: release)
                let device = ConnectedDevice(id: raw.key, backend: backend)
                try await device.refreshStorages()
                if device.storages.isEmpty {
                    connectionIssue = "\(backend.info.displayName) is locked. Unlock it to see its files."
                    waitForUnlock(device)
                    continue
                }
                devices.append(device)
                connectionIssue = nil
            } catch {
                failedKeys.insert(raw.key)
                connectionIssue = error.localizedDescription
            }
        }
    }

    /// Unlocking doesn't re-enumerate USB, so poll the open session until Android publishes its storage.
    private func waitForUnlock(_ device: ConnectedDevice) {
        waiting[device.id] = device
        Task {
            while waiting[device.id] === device {
                try? await Task.sleep(for: .seconds(1.5))
                guard waiting[device.id] === device else { return }
                try? await device.refreshStorages()
                if !device.storages.isEmpty {
                    waiting[device.id] = nil
                    devices.append(device)
                    connectionIssue = nil
                }
            }
        }
    }

    // MARK: Favorites

    func favorites(for device: ConnectedDevice) -> [Favorite] {
        favorites.filter { $0.deviceSerial == device.info.serial }
    }

    func addFavorite(device: ConnectedDevice, storageID: UInt32, path: [String]) {
        guard !favorites.contains(where: { $0.deviceSerial == device.info.serial && $0.storageID == storageID && $0.path == path }) else { return }
        favorites.append(Favorite(deviceSerial: device.info.serial, storageID: storageID, path: path))
    }

    func removeFavorite(_ favorite: Favorite) {
        favorites.removeAll { $0.id == favorite.id }
    }

    private func saveFavorites() {
        UserDefaults.standard.set(try? JSONEncoder().encode(favorites), forKey: "favorites")
    }

    private static func demoRoot() -> URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--demo") else { return nil }
        let path = arguments.indices.contains(index + 1) ? arguments[index + 1] : NSTemporaryDirectory() + "DroidshelfDemo"
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
