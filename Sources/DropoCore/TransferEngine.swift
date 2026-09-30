import Foundation

/// Byte-level progress for a whole batch. `update` returns `false` once cancelled, which stops libmtp mid-file.
public final class BatchProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var completed: UInt64 = 0
    private var cancelled = false
    private let report: @Sendable (_ done: UInt64, _ total: UInt64) -> Void
    public private(set) var total: UInt64 = 0

    public init(report: @escaping @Sendable (_ done: UInt64, _ total: UInt64) -> Void) {
        self.report = report
    }

    public var isCancelled: Bool { lock.withLock { cancelled } }
    public func cancel() { lock.withLock { cancelled = true } }

    func setTotal(_ bytes: UInt64) {
        lock.withLock { total = bytes }
        report(0, bytes)
    }

    func fileHandler() -> ProgressHandler {
        { [self] sent, _ in
            let (done, total, cancelled) = lock.withLock { () -> (UInt64, UInt64, Bool) in
                return (completed + sent, self.total, self.cancelled)
            }
            report(done, total)
            return !cancelled
        }
    }

    func finishFile(size: UInt64) {
        lock.withLock {
            completed += size
        }
    }

    func checkCancelled() throws {
        if isCancelled { throw DropoError.cancelled }
    }
}

public enum TransferEngine {
    // MARK: Phone → Mac

    /// Copies items (recursing into folders) into `directory`, returning the top-level URLs created.
    public static func download(_ items: [Item], from device: DeviceBackend, into directory: URL, progress: BatchProgress) async throws -> [URL] {
        var steps: [(item: Item, url: URL)] = []
        var created: [URL] = []
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        var taken = existing
        for item in items {
            let name = Naming.unique(item.name, avoiding: taken)
            taken.insert(name)
            let url = directory.appendingPathComponent(name)
            created.append(url)
            try await plan(item, at: url, device: device, steps: &steps, progress: progress)
        }
        progress.setTotal(steps.reduce(0) { $0 + $1.item.size })

        for step in steps {
            try progress.checkCancelled()
            try await device.download(step.item, to: step.url, progress: progress.fileHandler())
            if let modified = step.item.modified {
                try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: step.url.path)
            }
            progress.finishFile(size: step.item.size)
        }
        return created
    }

    private static func plan(_ item: Item, at url: URL, device: DeviceBackend, steps: inout [(item: Item, url: URL)], progress: BatchProgress) async throws {
        try progress.checkCancelled()
        guard item.isFolder else {
            steps.append((item, url))
            return
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for child in try await device.contents(of: item.asFolder) {
            try await plan(child, at: url.appendingPathComponent(child.name), device: device, steps: &steps, progress: progress)
        }
    }

    // MARK: Mac → Phone

    public struct Upload: Sendable {
        public let source: URL
        public let name: String
        public init(source: URL, name: String) {
            self.source = source
            self.name = name
        }
    }

    /// Copies files and folders into `folder`, returning the top-level items created on the phone.
    public static func upload(_ uploads: [Upload], to device: DeviceBackend, into folder: FolderRef, progress: BatchProgress) async throws -> [Item] {
        progress.setTotal(uploads.reduce(0) { $0 + localSize(of: $1.source) })
        var created: [Item] = []
        for upload in uploads {
            created.append(try await send(upload.source, as: upload.name, into: folder, device: device, progress: progress))
        }
        return created
    }

    private static func send(_ source: URL, as name: String, into folder: FolderRef, device: DeviceBackend, progress: BatchProgress) async throws -> Item {
        try progress.checkCancelled()
        if isDirectory(source) {
            let created = try await device.createFolder(named: name, in: folder)
            let children = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent != ".DS_Store" }
            for child in children {
                _ = try await send(child, as: child.lastPathComponent, into: created.asFolder, device: device, progress: progress)
            }
            return created
        }
        let size = localSize(of: source)
        let item = try await device.upload(source, as: name, into: folder, progress: progress.fileHandler())
        progress.finishFile(size: size)
        return item
    }

    public static func localSize(of url: URL) -> UInt64 {
        guard isDirectory(url) else {
            return UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey])
        var total: UInt64 = 0
        while let child = enumerator?.nextObject() as? URL {
            total += UInt64((try? child.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }
}
