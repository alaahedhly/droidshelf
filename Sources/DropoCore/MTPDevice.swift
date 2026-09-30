import CLibMTP
import Foundation

public struct RawDevice: Hashable, Sendable {
    /// Stable for as long as the cable stays plugged in; a replug gets a new key.
    public let key: String
    public let vendorID: UInt16
    public let productID: UInt16
    public let vendor: String
    public let product: String
}

public enum MTPLibrary {
    private static let queue = DispatchQueue(label: "dropo.mtp.library")
    private static let initialize: Void = {
        LIBMTP_Init()
        LIBMTP_Set_Debug(0)
    }()

    public static func detect() async -> [RawDevice] {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: rawDevices().map(\.public))
            }
        }
    }

    /// Opens the phone, first evicting macOS's Image Capture daemon which grabs any PTP-capable device on plug-in.
    public static func open(_ device: RawDevice, releaseFromImageCapture: Bool) async throws -> MTPDevice {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try openBlocking(device, releaseFromImageCapture: releaseFromImageCapture) })
            }
        }
    }

    private static func rawDevices() -> [(public: RawDevice, raw: LIBMTP_raw_device_t)] {
        _ = initialize
        var list: UnsafeMutablePointer<LIBMTP_raw_device_t>?
        var count: Int32 = 0
        let status = LIBMTP_Detect_Raw_Devices(&list, &count)
        guard status == LIBMTP_ERROR_NONE, let list else { return [] }
        defer { free(list) }
        return (0..<Int(count)).map { index in
            let raw = list[index]
            let entry = raw.device_entry
            let device = RawDevice(
                key: "\(raw.bus_location)-\(raw.devnum)",
                vendorID: entry.vendor_id,
                productID: entry.product_id,
                vendor: entry.vendor.map { String(cString: $0) } ?? "",
                product: entry.product.map { String(cString: $0) } ?? ""
            )
            return (device, raw)
        }
    }

    private static func openBlocking(_ device: RawDevice, releaseFromImageCapture: Bool) throws -> MTPDevice {
        let attempts = releaseFromImageCapture ? 4 : 1
        for attempt in 0..<attempts {
            if releaseFromImageCapture { ImageCaptureGuard.evict() }
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.5) }
            guard var raw = rawDevices().first(where: { $0.public.key == device.key })?.raw else {
                throw DropoError.notConnected
            }
            if let handle = LIBMTP_Open_Raw_Device_Uncached(&raw) {
                return MTPDevice(handle: handle, raw: device)
            }
        }
        throw DropoError.cannotOpen("Unlock the phone and pick “File transfer” in its USB notification.")
    }
}

/// `ptpcamerad` is a per-user LaunchAgent, so it can be stopped without admin rights. launchd restarts it on demand,
/// but by then libmtp holds the USB interface.
enum ImageCaptureGuard {
    static func evict() {
        for name in ["ptpcamerad", "Android File Transfer Agent"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            process.arguments = ["-9", "-x", name]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
    }
}

public final class MTPDevice: DeviceBackend, @unchecked Sendable {
    public let raw: RawDevice
    public let info: DeviceInfo

    private let queue = DispatchQueue(label: "dropo.mtp.device")
    private var handle: UnsafeMutablePointer<LIBMTP_mtpdevice_t>?

    init(handle: UnsafeMutablePointer<LIBMTP_mtpdevice_t>, raw: RawDevice) {
        self.handle = handle
        self.raw = raw

        func take(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
            guard let pointer else { return nil }
            defer { free(pointer) }
            return String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var current: UInt8 = 0
        var maximum: UInt8 = 0
        let battery: Int? = LIBMTP_Get_Batterylevel(handle, &maximum, &current) == 0 && maximum > 0
            ? Int(current) * 100 / Int(maximum) : nil
        info = DeviceInfo(
            manufacturer: take(LIBMTP_Get_Manufacturername(handle)) ?? raw.vendor,
            model: take(LIBMTP_Get_Modelname(handle)) ?? raw.product,
            friendlyName: take(LIBMTP_Get_Friendlyname(handle)),
            serial: take(LIBMTP_Get_Serialnumber(handle)) ?? raw.key,
            batteryPercent: battery
        )
        LIBMTP_Clear_Errorstack(handle)
    }

    deinit { handle.map(LIBMTP_Release_Device) }

    public func close() {
        queue.sync {
            handle.map(LIBMTP_Release_Device)
            handle = nil
        }
    }

    // MARK: - DeviceBackend

    public func storages() async throws -> [Storage] {
        try await run { device in
            guard LIBMTP_Get_Storage(device, Int32(LIBMTP_STORAGE_SORTBY_NOTSORTED)) == 0 else {
                throw self.failure(device, "Couldn't read the phone's storage.")
            }
            var result: [Storage] = []
            var node = device.pointee.storage
            while let storage = node?.pointee {
                result.append(Storage(
                    id: storage.id,
                    name: storage.StorageDescription.map { String(cString: $0) } ?? "Storage",
                    capacity: storage.MaxCapacity,
                    freeSpace: storage.FreeSpaceInBytes,
                    access: storage.AccessCapability == 0 ? .readWrite
                        : storage.AccessCapability == 2 ? .readOnlyWithDelete : .readOnly,
                    // PTP storage type 0x0004 = removable RAM (SD cards)
                    isRemovable: storage.StorageType == 0x0004
                ))
                node = storage.next
            }
            return result
        }
    }

    public func contents(of folder: FolderRef) async throws -> [Item] {
        try await run { device in
            LIBMTP_Clear_Errorstack(device)
            var items: [Item] = []
            var node = LIBMTP_Get_Files_And_Folders(device, folder.storageID, folder.folderID)
            while let file = node {
                items.append(Self.item(from: file.pointee))
                node = file.pointee.next
                LIBMTP_destroy_file_t(file)
            }
            if items.isEmpty, LIBMTP_Get_Errorstack(device) != nil {
                throw self.failure(device, "Couldn't list this folder.")
            }
            return items
        }
    }

    public func download(_ item: Item, to destination: URL, progress: @escaping ProgressHandler) async throws {
        try await run { device in
            let box = ProgressBox(progress)
            let status = withExtendedLifetime(box) {
                LIBMTP_Get_File_To_File(device, item.id, destination.path, progressTrampoline, Unmanaged.passUnretained(box).toOpaque())
            }
            if status != 0 {
                try? FileManager.default.removeItem(at: destination)
                if box.cancelled { throw DropoError.cancelled }
                throw self.failure(device, "Couldn't copy “\(item.name)” from the phone.")
            }
        }
    }

    public func upload(_ source: URL, as name: String, into folder: FolderRef, progress: @escaping ProgressHandler) async throws -> Item {
        try await run { device in
            let size = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? UInt64) ?? 0
            guard let file = LIBMTP_new_file_t() else { throw DropoError.operationFailed("Out of memory.") }
            defer { LIBMTP_destroy_file_t(file) }
            file.pointee.filename = strdup(name)
            file.pointee.filesize = size
            file.pointee.filetype = LIBMTP_FILETYPE_UNKNOWN
            // 0 would make libmtp redirect some types into "default" folders; 0xFFFFFFFF always means the storage root.
            file.pointee.parent_id = folder.folderID
            file.pointee.storage_id = folder.storageID

            let box = ProgressBox(progress)
            let status = withExtendedLifetime(box) {
                LIBMTP_Send_File_From_File(device, source.path, file, progressTrampoline, Unmanaged.passUnretained(box).toOpaque())
            }
            if status != 0 {
                if box.cancelled { throw DropoError.cancelled }
                throw self.failure(device, "Couldn't copy “\(name)” to the phone.")
            }
            return Item(
                id: file.pointee.item_id, parentID: folder.folderID, storageID: folder.storageID,
                name: name, size: size, modified: Date(), isFolder: false
            )
        }
    }

    public func createFolder(named name: String, in folder: FolderRef) async throws -> Item {
        try await run { device in
            let id = name.withCString { pointer in
                LIBMTP_Create_Folder(device, UnsafeMutablePointer(mutating: pointer), folder.isRoot ? 0 : folder.folderID, folder.storageID)
            }
            guard id != 0 else { throw self.failure(device, "Couldn't create the folder “\(name)”.") }
            return Item(id: id, parentID: folder.folderID, storageID: folder.storageID, name: name, size: 0, modified: Date(), isFolder: true)
        }
    }

    public func delete(_ item: Item) async throws {
        try await run { device in try self.deleteBlocking(device, item) }
    }

    public func rename(_ item: Item, to name: String) async throws {
        try await run { device in
            let status = name.withCString { LIBMTP_Set_Object_Filename(device, item.id, UnsafeMutablePointer(mutating: $0)) }
            guard status == 0 else { throw self.failure(device, "Couldn't rename “\(item.name)”.") }
        }
    }

    public func move(_ item: Item, to folder: FolderRef) async throws {
        try await run { device in
            let parent = folder.isRoot ? 0 : folder.folderID
            guard LIBMTP_Move_Object(device, item.id, folder.storageID, parent) == 0 else {
                throw self.failure(device, "This phone doesn't support moving “\(item.name)”.")
            }
        }
    }

    public func thumbnail(for item: Item) async throws -> Data? {
        try await run { device in
            var data: UnsafeMutablePointer<UInt8>?
            var size: UInt32 = 0
            guard LIBMTP_Get_Thumbnail(device, item.id, &data, &size) == 0, let data, size > 0 else {
                LIBMTP_Clear_Errorstack(device)
                return nil
            }
            defer { free(data) }
            return Data(bytes: data, count: Int(size))
        }
    }

    public func read(_ item: Item, offset: UInt64, length: UInt32) async throws -> Data {
        try await run { device in
            var data: UnsafeMutablePointer<UInt8>?
            var size: UInt32 = 0
            guard LIBMTP_GetPartialObject(device, item.id, offset, length, &data, &size) == 0 else {
                throw self.failure(device, "Couldn't read “\(item.name)”.")
            }
            guard let data else { return Data() }
            defer { free(data) }
            return Data(bytes: data, count: Int(size))
        }
    }

    // MARK: - Internals

    private func run<T: Sendable>(_ body: @escaping @Sendable (UnsafeMutablePointer<LIBMTP_mtpdevice_t>) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let handle = self.handle else { return continuation.resume(throwing: DropoError.notConnected) }
                continuation.resume(with: Result { try body(handle) })
            }
        }
    }

    /// Android deletes folders recursively; other MTP devices refuse non-empty folders, so fall back to emptying it first.
    private func deleteBlocking(_ device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>, _ item: Item) throws {
        if LIBMTP_Delete_Object(device, item.id) == 0 { return }
        guard item.isFolder else { throw failure(device, "Couldn't delete “\(item.name)”.") }
        LIBMTP_Clear_Errorstack(device)
        var node = LIBMTP_Get_Files_And_Folders(device, item.storageID, item.id)
        var children: [Item] = []
        while let file = node {
            children.append(Self.item(from: file.pointee))
            node = file.pointee.next
            LIBMTP_destroy_file_t(file)
        }
        for child in children { try deleteBlocking(device, child) }
        guard LIBMTP_Delete_Object(device, item.id) == 0 else { throw failure(device, "Couldn't delete “\(item.name)”.") }
    }

    private func failure(_ device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>, _ message: String) -> DropoError {
        var detail: String?
        var node = LIBMTP_Get_Errorstack(device)
        while let error = node?.pointee {
            if let text = error.error_text { detail = String(cString: text) }
            node = error.next
        }
        LIBMTP_Clear_Errorstack(device)
        if let detail, !detail.isEmpty { return .operationFailed("\(message) (\(detail))") }
        return .operationFailed(message)
    }

    private static func item(from file: LIBMTP_file_t) -> Item {
        Item(
            id: file.item_id,
            parentID: file.parent_id,
            storageID: file.storage_id,
            name: file.filename.map { String(cString: $0) } ?? "Untitled",
            size: file.filesize,
            modified: file.modificationdate > 0 ? Date(timeIntervalSince1970: TimeInterval(file.modificationdate)) : nil,
            isFolder: file.filetype == LIBMTP_FILETYPE_FOLDER
        )
    }
}

private final class ProgressBox {
    let handler: ProgressHandler
    var cancelled = false
    init(_ handler: @escaping ProgressHandler) { self.handler = handler }
}

private let progressTrampoline: LIBMTP_progressfunc_t = { sent, total, context in
    guard let context else { return 0 }
    let box = Unmanaged<ProgressBox>.fromOpaque(context).takeUnretainedValue()
    if box.handler(sent, total) { return 0 }
    box.cancelled = true
    return 1
}
