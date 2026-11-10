import Compression
import Foundation
import zlib

/// The zip container of a `.milashare`, read and written in-process.
///
/// The Mac app zips and unzips through `ditto` (`ZipArchiver`), which iOS
/// does not have — there are no subprocesses there. This covers exactly what
/// a bundle needs and no more: writing a handful of STORED entries (audio is
/// already compressed or barely shrinks, and a stored zip is what every
/// unzipper reads), and reading stored or deflated entries, which is what
/// `ditto -c -k` produces. No ZIP64: a bundle over 4 GB is refused, the same
/// ceiling `RecordingShareImporter.maxBundleBytes` sets on the Mac.
///
/// Unlike `ditto -x`, extraction here inflates one named entry at a time
/// with a byte budget — the entry's declared size — so a header that lies
/// small about a large deflate stream is caught after one chunk over, not
/// after the disk fills.
public enum ShareZip {

    public struct Failure: LocalizedError, Equatable, Sendable {
        /// Structural, never a quote of the archive's contents.
        public let reason: String
        public init(_ reason: String) { self.reason = reason }
        public var errorDescription: String? { "The archive isn't a zip file Mila can read (\(reason))." }
    }

    /// One central-directory record.
    public struct Entry: Equatable, Sendable {
        public let name: String
        public let method: UInt16
        public let crc32: UInt32
        public let compressedSize: UInt64
        public let uncompressedSize: UInt64
        public let localHeaderOffset: UInt64
        /// False for directories and symlinks (Unix type bits, or the MS-DOS
        /// directory bit on other hosts).
        public let isRegularFile: Bool
    }

    private static let chunkSize = 1 << 20

    // MARK: - Writing

    /// Write `files` as stored entries named `name`, in order, to `archive`
    /// (replaced if present). Entries are marked as Unix regular files
    /// (mode 0644), which is what `ZipArchiver.listEntries` reads the type from.
    public static func write(_ files: [(name: String, url: URL)], to archive: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: archive)
        guard fm.createFile(atPath: archive.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: archive])
        }
        let out = try FileHandle(forWritingTo: archive)
        defer { try? out.close() }

        var central = Data()
        var offset: UInt64 = 0
        for file in files {
            let size = try fileSize(file.url)
            let name = Data(file.name.utf8)
            guard size < 0xFFFF_FFFF, offset + size < 0xFFFF_FFFF, name.count < 0xFFFF else {
                throw Failure("too large for a zip without ZIP64")
            }
            let crc = try crc32(of: file.url)

            var local = Data()
            local.appendLE32(0x0403_4b50)
            local.appendLE16(20)          // version needed: 2.0
            local.appendLE16(0)           // flags
            local.appendLE16(0)           // method: stored
            local.appendLE16(0)           // mod time 00:00
            local.appendLE16(0x21)        // mod date 1980-01-01
            local.appendLE32(crc)
            local.appendLE32(UInt32(size))
            local.appendLE32(UInt32(size))
            local.appendLE16(UInt16(name.count))
            local.appendLE16(0)           // extra length
            local.append(name)
            try out.write(contentsOf: local)
            try copy(file.url, to: out)

            central.appendLE32(0x0201_4b50)
            central.appendLE16(3 << 8 | 20) // made by: Unix, 2.0
            central.appendLE16(20)
            central.appendLE16(0)
            central.appendLE16(0)
            central.appendLE16(0)
            central.appendLE16(0x21)
            central.appendLE32(crc)
            central.appendLE32(UInt32(size))
            central.appendLE32(UInt32(size))
            central.appendLE16(UInt16(name.count))
            central.appendLE16(0)         // extra length
            central.appendLE16(0)         // comment length
            central.appendLE16(0)         // disk number
            central.appendLE16(0)         // internal attributes
            central.appendLE32(UInt32(0o100644) << 16)
            central.appendLE32(UInt32(offset))
            central.append(name)

            offset += UInt64(local.count) + size
        }
        var end = Data()
        end.appendLE32(0x0605_4b50)
        end.appendLE16(0)
        end.appendLE16(0)
        end.appendLE16(UInt16(files.count))
        end.appendLE16(UInt16(files.count))
        end.appendLE32(UInt32(central.count))
        end.appendLE32(UInt32(offset))
        end.appendLE16(0)
        try out.write(contentsOf: central + end)
    }

    // MARK: - Reading

    /// The archive's central directory, without inflating anything.
    public static func entries(of archive: URL) throws -> [Entry] {
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()

        // End-of-central-directory: 22 bytes plus a comment of at most 65535.
        // Accept only a signature whose comment length ends exactly at EOF —
        // a bare match could be bytes inside the comment.
        let tailLength = min(fileSize, 22 + 65_535)
        guard tailLength >= 22 else { throw Failure("too short") }
        try handle.seek(toOffset: fileSize - tailLength)
        let tail = try read(handle, Int(tailLength))
        var eocd = tail.count - 22
        while eocd >= 0 {
            if tail.le32(eocd) == 0x0605_4b50, Int(tail.le16(eocd + 20)) == tail.count - eocd - 22 { break }
            eocd -= 1
        }
        guard eocd >= 0 else { throw Failure("no end-of-central-directory record") }
        let count = Int(tail.le16(eocd + 10))
        let directorySize = UInt64(tail.le32(eocd + 12))
        let directoryOffset = UInt64(tail.le32(eocd + 16))
        guard count != 0xFFFF, directorySize != 0xFFFF_FFFF, directoryOffset != 0xFFFF_FFFF else {
            throw Failure("ZIP64 is not supported")
        }
        guard directorySize <= 1 << 20, directoryOffset + directorySize <= fileSize,
              count <= Int(directorySize) / 46 else {
            throw Failure("central directory out of bounds")
        }
        try handle.seek(toOffset: directoryOffset)
        let directory = try read(handle, Int(directorySize))

        var entries: [Entry] = []
        var p = 0
        while p < directory.count {
            guard directory.count - p >= 46, directory.le32(p) == 0x0201_4b50 else {
                throw Failure("bad central directory header")
            }
            let madeBy = directory.le16(p + 4)
            let compressed = UInt64(directory.le32(p + 20))
            let uncompressed = UInt64(directory.le32(p + 24))
            let nameLength = Int(directory.le16(p + 28))
            let next = p + 46 + nameLength + Int(directory.le16(p + 30)) + Int(directory.le16(p + 32))
            let external = directory.le32(p + 38)
            let localOffset = UInt64(directory.le32(p + 42))
            guard next <= directory.count else { throw Failure("truncated central directory header") }
            guard compressed != 0xFFFF_FFFF, uncompressed != 0xFFFF_FFFF, localOffset != 0xFFFF_FFFF else {
                throw Failure("ZIP64 is not supported")
            }
            let name = String(decoding: directory[directory.startIndex + p + 46
                                                  ..< directory.startIndex + p + 46 + nameLength],
                              as: UTF8.self)
            let host = madeBy >> 8
            let isUnix = host == 3 || host == 19
            let unixType = (external >> 16) & 0o170000
            let isRegular = !name.hasSuffix("/") && (isUnix
                ? (unixType == 0 || unixType == 0o100000)
                : external & 0x10 == 0)
            entries.append(Entry(name: name, method: directory.le16(p + 10), crc32: directory.le32(p + 16),
                                 compressedSize: compressed, uncompressedSize: uncompressed,
                                 localHeaderOffset: localOffset, isRegularFile: isRegular))
            p = next
        }
        guard entries.count == count else { throw Failure("entry count disagrees with the directory") }
        return entries
    }

    /// Extract one entry to `destination` (replaced if present), refusing it
    /// the moment it inflates past its declared size, and verifying the
    /// declared size and CRC-32 at the end.
    public static func extract(_ entry: Entry, from archive: URL, to destination: URL) throws {
        guard entry.method == 0 || entry.method == 8 else { throw Failure("unsupported compression") }
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        try handle.seek(toOffset: entry.localHeaderOffset)
        let header = try read(handle, 30)
        guard header.le32(0) == 0x0403_4b50 else { throw Failure("bad local header") }
        try handle.seek(toOffset: entry.localHeaderOffset + 30
                        + UInt64(header.le16(26)) + UInt64(header.le16(28)))

        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        guard fm.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: destination])
        }
        let out = try FileHandle(forWritingTo: destination)
        var written: UInt64 = 0
        var crc = zlib.crc32(0, nil, 0)
        func sink(_ data: Data) throws {
            written += UInt64(data.count)
            guard written <= entry.uncompressedSize else { throw Failure("entry larger than declared") }
            crc = data.withUnsafeBytes { zlib.crc32(crc, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
            try out.write(contentsOf: data)
        }
        do {
            defer { try? out.close() }
            var remaining = entry.compressedSize
            if entry.method == 0 {
                guard entry.compressedSize == entry.uncompressedSize else { throw Failure("stored sizes disagree") }
                while remaining > 0 {
                    let chunk = try read(handle, Int(min(remaining, UInt64(chunkSize))))
                    remaining -= UInt64(chunk.count)
                    try sink(chunk)
                }
            } else {
                // `.zlib` in Compression is raw DEFLATE (RFC 1951) — what zip stores.
                let filter = try OutputFilter(.decompress, using: .zlib) { data in
                    if let data { try sink(data) }
                }
                while remaining > 0 {
                    let chunk = try read(handle, Int(min(remaining, UInt64(chunkSize))))
                    remaining -= UInt64(chunk.count)
                    try filter.write(chunk)
                }
                try filter.finalize()
            }
            guard written == entry.uncompressedSize else { throw Failure("entry smaller than declared") }
            guard UInt32(crc) == entry.crc32 else { throw Failure("checksum mismatch") }
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }

    // MARK: - Helpers

    private static func fileSize(_ url: URL) throws -> UInt64 {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private static func crc32(of url: URL) throws -> UInt32 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var crc = zlib.crc32(0, nil, 0)
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            crc = chunk.withUnsafeBytes { zlib.crc32(crc, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
        }
        return UInt32(crc)
    }

    private static func copy(_ url: URL, to out: FileHandle) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }
    }

    private static func read(_ handle: FileHandle, _ count: Int) throws -> Data {
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw Failure("truncated")
        }
        return data
    }
}

private extension Data {
    func le16(_ offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }
    func le32(_ offset: Int) -> UInt32 { UInt32(le16(offset)) | UInt32(le16(offset + 2)) << 16 }
    mutating func appendLE16(_ v: UInt16) { append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)]) }
    mutating func appendLE32(_ v: UInt32) { appendLE16(UInt16(v & 0xFFFF)); appendLE16(UInt16(v >> 16)) }
}
