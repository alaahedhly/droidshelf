import Foundation

/// A fake phone backed by a local folder, for working on the UI without hardware (`Droidshelf --demo <folder>`).
public final class DemoDevice: DeviceBackend, @unchecked Sendable {
    public let info = DeviceInfo(manufacturer: "Droidshelf", model: "Demo Phone", friendlyName: nil, serial: "demo", batteryPercent: 82)

    private static let storageID: UInt32 = 0x0001_0001
    private let root: URL
    private let lock = NSLock()
    private var urlsByID: [UInt32: URL] = [:]
    private var idsByPath: [String: UInt32] = [:]
    private var nextID: UInt32 = 1

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public func close() {}

    public func storages() async throws -> [Storage] {
        let values = try root.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        return [Storage(
            id: Self.storageID, name: "Internal shared storage",
            capacity: UInt64(values.volumeTotalCapacity ?? 0), freeSpace: UInt64(values.volumeAvailableCapacity ?? 0),
            access: .readWrite, isRemovable: false
        )]
    }

    public func contents(of folder: FolderRef) async throws -> [Item] {
        let directory = try url(for: folder)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
            .map { try item(at: $0, parent: folder.folderID) }
    }

    public func download(_ item: Item, to destination: URL, progress: @escaping ProgressHandler) async throws {
        try await copy(from: try url(for: item.id), to: destination, progress: progress)
    }

    public func upload(_ source: URL, as name: String, into folder: FolderRef, progress: @escaping ProgressHandler) async throws -> Item {
        let destination = try url(for: folder).appendingPathComponent(name)
        try await copy(from: source, to: destination, progress: progress)
        return try item(at: destination, parent: folder.folderID)
    }

    public func createFolder(named name: String, in folder: FolderRef) async throws -> Item {
        let destination = try url(for: folder).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        return try item(at: destination, parent: folder.folderID)
    }

    public func delete(_ item: Item) async throws {
        try FileManager.default.removeItem(at: try url(for: item.id))
    }

    public func rename(_ item: Item, to name: String) async throws {
        let source = try url(for: item.id)
        let destination = source.deletingLastPathComponent().appendingPathComponent(name)
        try FileManager.default.moveItem(at: source, to: destination)
        remap(item.id, to: destination)
    }

    public func move(_ item: Item, to folder: FolderRef) async throws {
        let source = try url(for: item.id)
        let destination = try url(for: folder).appendingPathComponent(source.lastPathComponent)
        try FileManager.default.moveItem(at: source, to: destination)
        remap(item.id, to: destination)
    }

    public func thumbnail(for item: Item) async throws -> Data? {
        guard ["jpg", "jpeg", "png", "heic", "gif", "webp"].contains(item.fileExtension) else { return nil }
        return try Data(contentsOf: try url(for: item.id))
    }

    public func read(_ item: Item, offset: UInt64, length: UInt32) async throws -> Data {
        let handle = try FileHandle(forReadingFrom: try url(for: item.id))
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: Int(length)) ?? Data()
    }

    // MARK: - Internals

    private func url(for folder: FolderRef) throws -> URL {
        folder.isRoot ? root : try url(for: folder.folderID)
    }

    private func url(for id: UInt32) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        guard let url = urlsByID[id] else { throw DroidshelfError.operationFailed("That item no longer exists.") }
        return url
    }

    private func id(for url: URL) -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        let path = url.standardizedFileURL.path
        if let id = idsByPath[path] { return id }
        let id = nextID
        nextID += 1
        idsByPath[path] = id
        urlsByID[id] = url.standardizedFileURL
        return id
    }

    private func remap(_ id: UInt32, to url: URL) {
        lock.lock()
        defer { lock.unlock() }
        let oldPrefix = urlsByID[id]?.path ?? ""
        let newPrefix = url.standardizedFileURL.path
        for (childID, childURL) in urlsByID where childURL.path == oldPrefix || childURL.path.hasPrefix(oldPrefix + "/") {
            let moved = URL(fileURLWithPath: newPrefix + childURL.path.dropFirst(oldPrefix.count))
            idsByPath[childURL.path] = nil
            idsByPath[moved.path] = childID
            urlsByID[childID] = moved
        }
    }

    private func item(at url: URL, parent: UInt32) throws -> Item {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        return Item(
            id: id(for: url), parentID: parent, storageID: Self.storageID, name: url.lastPathComponent,
            size: UInt64(values.fileSize ?? 0), modified: values.contentModificationDate, isFolder: values.isDirectory ?? false
        )
    }

    /// Chunked copy with a simulated USB 2 speed so progress UI is visible.
    private func copy(from source: URL, to destination: URL, progress: @escaping ProgressHandler) async throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let total = UInt64((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var done: UInt64 = 0
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
            done += UInt64(chunk.count)
            try await Task.sleep(for: .milliseconds(25))
            if !progress(done, total) {
                try? FileManager.default.removeItem(at: destination)
                throw DroidshelfError.cancelled
            }
        }
    }
}
