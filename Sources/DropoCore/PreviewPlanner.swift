import Foundation

/// Works out which byte ranges of a phone file Quick Look needs to draw a preview, so Dropo can fetch a few hundred KB
/// over MTP instead of the whole file. The ranges are written into a sparse local stand-in file of the full size.
public enum PreviewPlanner {
    public struct Range: Equatable, Sendable {
        public let offset: UInt64
        public let length: UInt64
    }

    public enum Plan: Equatable, Sendable {
        /// Small enough to copy whole.
        case whole
        /// Fetch these ranges into a sparse file.
        case ranges([Range])
        /// Nothing worth previewing.
        case none
    }

    static let wholeFileLimit: UInt64 = 10 << 20
    private static let mpeg4Extensions: Set<String> = ["mp4", "m4v", "mov", "m4a", "m4b", "3gp", "3g2", "qt"]
    private static let documentExtensions: Set<String> = [
        "pdf", "txt", "md", "rtf", "csv", "json", "xml", "html", "htm", "log", "srt",
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "epub", "odt", "ods", "odp",
        "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "bmp", "tif", "tiff", "dng", "svg",
    ]
    private static let streamingExtensions: Set<String> = ["mp3", "aac", "flac", "wav", "ogg", "opus", "m4r"]

    public typealias Reader = @Sendable (_ offset: UInt64, _ length: UInt32) async throws -> Data

    public static func plan(for item: Item, read: Reader) async throws -> Plan {
        guard !item.isFolder, item.size > 0 else { return .none }
        let ext = item.fileExtension
        if mpeg4Extensions.contains(ext) { return try await mpeg4Plan(size: item.size, read: read) }
        if ext == "mp3" { return try await id3Plan(size: item.size, read: read) }
        if streamingExtensions.contains(ext) { return .ranges([clamp(0, 2 << 20, size: item.size)]) }
        if documentExtensions.contains(ext) { return item.size <= wholeFileLimit ? .whole : .none }
        return .none
    }

    /// ID3v2 puts album art at the very start; its header says exactly how long the tag is.
    static func id3Plan(size: UInt64, read: Reader) async throws -> Plan {
        let header = try await read(0, 10)
        guard header.count == 10, header.starts(with: Array("ID3".utf8)) else {
            return .ranges([clamp(0, 256 << 10, size: size)])
        }
        let bytes = [UInt8](header)
        let tagSize = bytes[6...9].reduce(UInt64(0)) { ($0 << 7) | UInt64($1 & 0x7F) }
        let footer: UInt64 = bytes[5] & 0x10 != 0 ? 10 : 0
        // A little audio after the tag lets the decoder confirm the format.
        return .ranges([clamp(0, 10 + tagSize + footer + (64 << 10), size: size)])
    }

    /// MP4/MOV: the `moov` index can sit at either end (Android cameras write it last), and the first keyframe is near
    /// the start of `mdat`. Walk the top-level boxes to find `moov`, then take it plus the head of the file.
    static func mpeg4Plan(size: UInt64, read: Reader) async throws -> Plan {
        var ranges = [clamp(0, 4 << 20, size: size)]
        var offset: UInt64 = 0
        for _ in 0..<64 where offset + 8 <= size {
            let header = [UInt8](try await read(offset, 16))
            guard header.count >= 8 else { break }
            let size32 = header[0..<4].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let type = String(decoding: header[4..<8], as: UTF8.self)
            var boxSize = size32
            if size32 == 1, header.count >= 16 {
                boxSize = header[8..<16].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            } else if size32 == 0 {
                boxSize = size - offset
            }
            guard boxSize >= 8 else { break }
            if type == "moov" {
                ranges.append(clamp(offset, min(boxSize, 32 << 20), size: size))
                break
            }
            offset += boxSize
        }
        return .ranges(ranges)
    }

    private static func clamp(_ offset: UInt64, _ length: UInt64, size: UInt64) -> Range {
        Range(offset: offset, length: min(length, size - min(offset, size)))
    }
}
