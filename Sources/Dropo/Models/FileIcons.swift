import AppKit
import AVFoundation
import QuickLookThumbnailing
import DropoCore
import UniformTypeIdentifiers

/// Finder's own icons and kind strings, so phone files look exactly like Mac files.
@MainActor
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    /// Android's standard folders get the matching Finder special-folder icon.
    private static let specialFolders: [String: FileManager.SearchPathDirectory] = [
        "download": .downloadsDirectory, "downloads": .downloadsDirectory,
        "documents": .documentDirectory, "pictures": .picturesDirectory,
        "music": .musicDirectory, "movies": .moviesDirectory,
    ]

    static func icon(for item: Item) -> NSImage {
        if item.isFolder {
            let key = item.name.lowercased()
            if let directory = specialFolders[key], let url = FileManager.default.urls(for: directory, in: .userDomainMask).first {
                return cached("folder:\(key)") { NSWorkspace.shared.icon(forFile: url.path) }
            }
            return cached("folder") { NSWorkspace.shared.icon(for: .folder) }
        }
        let ext = item.fileExtension
        return cached("ext:\(ext)") { NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data) }
    }

    nonisolated static func kind(for item: Item) -> String {
        if item.isFolder { return "Folder" }
        guard !item.fileExtension.isEmpty, let type = UTType(filenameExtension: item.fileExtension) else { return "Document" }
        return type.localizedDescription ?? "Document"
    }

    nonisolated static func isMovie(_ item: Item) -> Bool {
        guard !item.isFolder, let type = UTType(filenameExtension: item.fileExtension) else { return false }
        return type.conforms(to: .movie)
    }

    nonisolated static func isImage(_ item: Item) -> Bool {
        guard !item.isFolder, let type = UTType(filenameExtension: item.fileExtension) else { return false }
        return type.conforms(to: .image)
    }

    private static func cached(_ key: String, _ make: () -> NSImage) -> NSImage {
        if let image = cache[key] { return image }
        let image = make()
        cache[key] = image
        return image
    }
}

/// Finder-style previews (album art, video frames, document pages) rendered by Quick Look in icon mode.
/// Only the bytes Quick Look needs are fetched from the phone; results are cached in memory and on disk.
@MainActor
final class ThumbnailStore {
    static let shared = ThumbnailStore()
    private let memory = NSCache<NSString, NSImage>()
    private var misses: Set<String> = []
    private let gate = FetchGate()
    private let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.hortensia.dropo/previews")

    func thumbnail(for item: Item, on device: ConnectedDevice, size: CGFloat) async -> NSImage? {
        guard !item.isFolder else { return nil }
        let pixels = size <= 32 ? 64 : size <= 64 ? 128 : 512
        // Object ids change between sessions, so the disk key uses what identifies the content instead.
        let identity = "\(device.info.serial)|\(item.storageID)|\(item.name)|\(item.size)|\(item.modified?.timeIntervalSince1970 ?? 0)"
        let key = "\(identity.hashValue)-\(pixels)" as NSString
        let diskURL = cacheRoot.appendingPathComponent("\(stableHash(identity))-\(pixels).png")

        if let image = memory.object(forKey: key) { return image }
        if misses.contains(key as String) { return nil }
        if let image = NSImage(contentsOf: diskURL) {
            memory.setObject(image, forKey: key)
            return image
        }

        guard await gate.acquire() else { return nil }
        defer { gate.release() }
        guard !Task.isCancelled else { return nil }

        guard let image = await render(item, on: device, pixels: pixels) else {
            misses.insert(key as String)
            return nil
        }
        memory.setObject(image, forKey: key)
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: diskURL)
        }
        return image
    }

    private func render(_ item: Item, on device: ConnectedDevice, pixels: Int) async -> NSImage? {
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("DropoPreview-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let local = workDir.appendingPathComponent(item.name)

        do {
            // Photos: the phone's MediaStore thumbnail is tiny and instant.
            if FileIcons.isImage(item), let data = try? await device.backend.thumbnail(for: item), !data.isEmpty {
                // Phones send JPEG thumbnails, but name the file by its real format so Quick Look accepts it.
                let ext = data.starts(with: [0xFF, 0xD8]) ? "jpg" : item.fileExtension
                let thumbURL = workDir.appendingPathComponent("thumb.\(ext)")
                try data.write(to: thumbURL)
                if let styled = await quickLook(thumbURL, pixels: pixels) { return styled }
                return NSImage(data: data)
            }
            let backend = device.backend
            let plan = try await PreviewPlanner.plan(for: item) { offset, length in
                try await backend.read(item, offset: offset, length: length)
            }
            switch plan {
            case .none:
                return nil
            case .whole:
                try await backend.download(item, to: local) { _, _ in !Task.isCancelled }
            case .ranges(let ranges):
                FileManager.default.createFile(atPath: local.path, contents: nil)
                let handle = try FileHandle(forWritingTo: local)
                defer { try? handle.close() }
                try handle.truncate(atOffset: item.size)
                for range in ranges where range.length > 0 {
                    var offset = range.offset
                    let end = range.offset + range.length
                    while offset < end {
                        try Task.checkCancellation()
                        let chunk = try await backend.read(item, offset: offset, length: UInt32(min(end - offset, 1 << 20)))
                        guard !chunk.isEmpty else { break }
                        try handle.seek(toOffset: offset)
                        try handle.write(contentsOf: chunk)
                        offset += UInt64(chunk.count)
                    }
                }
            }
            // Quick Look picks a frame deep into a video, which the sparse copy doesn't have; the first frame only needs
            // the head of the file, so grab it directly and let Quick Look style it like Finder.
            if FileIcons.isMovie(item) {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: local))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: pixels * 2, height: pixels * 2)
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                let frame = try await generator.image(at: .zero).image
                let frameURL = workDir.appendingPathComponent("frame.png")
                guard let png = NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:]) else { return nil }
                try png.write(to: frameURL)
                return await quickLook(frameURL, pixels: pixels)
            }
            return await quickLook(local, pixels: pixels)
        } catch {
            return nil
        }
    }

    private func quickLook(_ url: URL, pixels: Int) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: pixels / 2, height: pixels / 2),
            scale: 2,
            representationTypes: .thumbnail
        )
        request.iconMode = true
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }

    private func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

/// One preview fetch at a time, newest request first: the cells on screen now matter more than ones scrolled past,
/// and a single slot keeps user transfers from queueing behind previews on the phone's one MTP session.
@MainActor
private final class FetchGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func acquire() async -> Bool {
        guard busy else {
            busy = true
            return true
        }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if let next = waiters.popLast() {
            next.resume(returning: true)
        } else {
            busy = false
        }
    }
}

extension Item {
    var modifiedSortKey: Date { modified ?? .distantPast }
    var kind: String { FileIcons.kind(for: self) }
}
