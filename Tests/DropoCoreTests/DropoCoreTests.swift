import Foundation
import Testing
@testable import DropoCore

@Suite struct NamingTests {
    @Test func keepsFreeName() {
        #expect(Naming.unique("photo.jpg", avoiding: ["other.jpg"]) == "photo.jpg")
    }

    @Test func appendsCounterLikeFinder() {
        #expect(Naming.unique("photo.jpg", avoiding: ["photo.jpg"]) == "photo 2.jpg")
        #expect(Naming.unique("photo.jpg", avoiding: ["photo.jpg", "photo 2.jpg"]) == "photo 3.jpg")
        #expect(Naming.unique("photo 2.jpg", avoiding: ["photo 2.jpg"]) == "photo 3.jpg")
        #expect(Naming.unique("Camera", avoiding: ["camera"]) == "Camera 2")
    }

    @Test func rejectsInvalidNames() {
        #expect(Naming.validationError(for: "  ") != nil)
        #expect(Naming.validationError(for: "a/b") != nil)
        #expect(Naming.validationError(for: "..") != nil)
        #expect(Naming.validationError(for: "Holiday 2026") == nil)
    }
}

@Suite struct TransferEngineTests {
    private func makeDemo() throws -> (DemoDevice, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dropo-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("DCIM/Camera"), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 3_000_000).write(to: root.appendingPathComponent("DCIM/Camera/IMG_0001.jpg"))
        try Data("hello".utf8).write(to: root.appendingPathComponent("note.txt"))
        return (DemoDevice(root: root), root)
    }

    @Test func downloadsFoldersRecursivelyWithUniqueNames() async throws {
        let (device, _) = try makeDemo()
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("dropo-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data().write(to: target.appendingPathComponent("note.txt"))

        let top = try await device.contents(of: .root(0x0001_0001))
        let progress = BatchProgress { _, _ in }
        let urls = try await TransferEngine.download(top, from: device, into: target, progress: progress)

        #expect(Set(urls.map(\.lastPathComponent)) == ["DCIM", "note 2.txt"])
        #expect(progress.total == 3_000_005)
        let copied = try Data(contentsOf: target.appendingPathComponent("DCIM/Camera/IMG_0001.jpg"))
        #expect(copied.count == 3_000_000)
    }

    @Test func uploadsFolderTree() async throws {
        let (device, root) = try makeDemo()
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("dropo-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("inner"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: source.appendingPathComponent("inner/a.txt"))

        let progress = BatchProgress { _, _ in }
        let items = try await TransferEngine.upload([.init(source: source, name: "Backup")], to: device, into: .root(0x0001_0001), progress: progress)

        #expect(items.first?.isFolder == true)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Backup/inner/a.txt").path))
    }

    @Test func cancellationStopsTransfer() async throws {
        let (device, _) = try makeDemo()
        let camera = try await device.contents(of: .root(0x0001_0001)).first { $0.name == "DCIM" }!
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("dropo-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        let progress = BatchProgress { _, _ in }
        progress.cancel()
        await #expect(throws: DropoError.self) {
            _ = try await TransferEngine.download([camera], from: device, into: target, progress: progress)
        }
    }
}

@Suite struct PreviewPlannerTests {
    private func reader(_ data: Data) -> PreviewPlanner.Reader {
        { offset, length in
            let start = Int(min(offset, UInt64(data.count)))
            return data.subdata(in: start..<min(start + Int(length), data.count))
        }
    }

    private func item(_ name: String, size: Int) -> Item {
        Item(id: 1, parentID: 0, storageID: 1, name: name, size: UInt64(size), modified: nil, isFolder: false)
    }

    @Test func mp3FetchesOnlyTheID3Tag() async throws {
        // ID3v2.4 header with a syncsafe size of 300_000 bytes, followed by 5 MB of "audio".
        var bytes: [UInt8] = Array("ID3".utf8) + [4, 0, 0]
        let tag = 300_000
        bytes += [UInt8((tag >> 21) & 0x7F), UInt8((tag >> 14) & 0x7F), UInt8((tag >> 7) & 0x7F), UInt8(tag & 0x7F)]
        let data = Data(bytes) + Data(count: 5_000_000)
        let plan = try await PreviewPlanner.plan(for: item("song.mp3", size: data.count), read: reader(data))
        #expect(plan == .ranges([.init(offset: 0, length: UInt64(10 + tag + (64 << 10)))]))
    }

    @Test func mp4FindsMoovAtTheEnd() async throws {
        func box(_ type: String, _ payload: Int) -> Data {
            let size = UInt32(8 + payload)
            return Data([UInt8(size >> 24), UInt8((size >> 16) & 0xFF), UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF)])
                + Data(type.utf8) + Data(count: payload)
        }
        let data = box("ftyp", 24) + box("mdat", 20_000_000) + box("moov", 50_000)
        let plan = try await PreviewPlanner.plan(for: item("VID.mp4", size: data.count), read: reader(data))
        let moovOffset = UInt64(32 + 20_000_008)
        #expect(plan == .ranges([.init(offset: 0, length: 4 << 20), .init(offset: moovOffset, length: 50_008)]))
    }

    @Test func largeDocumentsAndUnknownTypesAreSkipped() async throws {
        let empty = reader(Data())
        #expect(try await PreviewPlanner.plan(for: item("big.pdf", size: 50 << 20), read: empty) == .none)
        #expect(try await PreviewPlanner.plan(for: item("small.pdf", size: 200_000), read: empty) == .whole)
        #expect(try await PreviewPlanner.plan(for: item("app.apk", size: 1000), read: empty) == .none)
    }
}
