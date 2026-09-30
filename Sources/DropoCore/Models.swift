import Foundation

public struct DeviceInfo: Hashable, Sendable {
    public var manufacturer: String
    public var model: String
    public var friendlyName: String?
    public var serial: String
    public var batteryPercent: Int?

    public init(manufacturer: String, model: String, friendlyName: String?, serial: String, batteryPercent: Int?) {
        self.manufacturer = manufacturer
        self.model = model
        self.friendlyName = friendlyName
        self.serial = serial
        self.batteryPercent = batteryPercent
    }

    public var displayName: String {
        if let friendlyName, !friendlyName.isEmpty { return friendlyName }
        return model.isEmpty ? manufacturer : model
    }
}

public struct Storage: Identifiable, Hashable, Sendable {
    public enum Access: Sendable { case readWrite, readOnly, readOnlyWithDelete }

    public let id: UInt32
    public var name: String
    public var capacity: UInt64
    public var freeSpace: UInt64
    public var access: Access
    public var isRemovable: Bool

    public init(id: UInt32, name: String, capacity: UInt64, freeSpace: UInt64, access: Access, isRemovable: Bool) {
        self.id = id
        self.name = name
        self.capacity = capacity
        self.freeSpace = freeSpace
        self.access = access
        self.isRemovable = isRemovable
    }

    public var isWritable: Bool { access == .readWrite }
}

/// A folder on a device. `folderID` is `FolderRef.rootID` for the top of a storage.
public struct FolderRef: Hashable, Sendable {
    public static let rootID: UInt32 = 0xFFFF_FFFF

    public let storageID: UInt32
    public let folderID: UInt32

    public init(storageID: UInt32, folderID: UInt32) {
        self.storageID = storageID
        self.folderID = folderID
    }

    public static func root(_ storageID: UInt32) -> FolderRef {
        FolderRef(storageID: storageID, folderID: rootID)
    }

    public var isRoot: Bool { folderID == Self.rootID }
}

public struct Item: Identifiable, Hashable, Sendable {
    public let id: UInt32
    public var parentID: UInt32
    public var storageID: UInt32
    public var name: String
    public var size: UInt64
    public var modified: Date?
    public var isFolder: Bool

    public init(id: UInt32, parentID: UInt32, storageID: UInt32, name: String, size: UInt64, modified: Date?, isFolder: Bool) {
        self.id = id
        self.parentID = parentID
        self.storageID = storageID
        self.name = name
        self.size = size
        self.modified = modified
        self.isFolder = isFolder
    }

    public var asFolder: FolderRef { FolderRef(storageID: storageID, folderID: id) }
    public var isHidden: Bool { name.hasPrefix(".") }
    public var fileExtension: String { (name as NSString).pathExtension.lowercased() }
}

public enum DropoError: LocalizedError, Sendable {
    case notConnected
    case cannotOpen(String)
    case operationFailed(String)
    case cancelled
    case readOnly

    public var errorDescription: String? {
        switch self {
        case .notConnected: "The phone is no longer connected."
        case .cannotOpen(let why): "Dropo couldn't open the phone. \(why)"
        case .operationFailed(let why): why
        case .cancelled: "The operation was cancelled."
        case .readOnly: "This storage is read-only."
        }
    }
}

/// Reports bytes done / total. Return `false` to cancel the transfer.
public typealias ProgressHandler = @Sendable (_ done: UInt64, _ total: UInt64) -> Bool

/// Everything the UI needs from a phone. `MTPDevice` talks to real hardware; `DemoDevice` mirrors a local folder.
public protocol DeviceBackend: AnyObject, Sendable {
    var info: DeviceInfo { get }
    func storages() async throws -> [Storage]
    func contents(of folder: FolderRef) async throws -> [Item]
    func download(_ item: Item, to destination: URL, progress: @escaping ProgressHandler) async throws
    func upload(_ source: URL, as name: String, into folder: FolderRef, progress: @escaping ProgressHandler) async throws -> Item
    func createFolder(named name: String, in folder: FolderRef) async throws -> Item
    func delete(_ item: Item) async throws
    func rename(_ item: Item, to name: String) async throws
    func move(_ item: Item, to folder: FolderRef) async throws
    func thumbnail(for item: Item) async throws -> Data?
    /// Reads `length` bytes at `offset` without downloading the whole file (MTP GetPartialObject).
    func read(_ item: Item, offset: UInt64, length: UInt32) async throws -> Data
    func close()
}
