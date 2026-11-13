import Foundation

struct StorageCapacity {
    let available: Int64
    let total: Int64

    static let reserve: Int64 = 32 * 1_024 * 1_024
    static let directory = URL.applicationSupportDirectory
        .appending(path: "CompressionQueue/Media", directoryHint: .isDirectory)

    static func read() -> Self? {
        guard let values = try? URL.cachesDirectory.resourceValues(forKeys: [
            .volumeAvailableCapacityKey, .volumeTotalCapacityKey
        ]), let available = values.volumeAvailableCapacity, let total = values.volumeTotalCapacity,
            total > 0 else { return nil }
        return Self(available: Int64(max(0, available)), total: Int64(total))
    }

    static func require(_ bytes: Int64) throws {
        if let capacity = read(), capacity.available < bytes {
            throw CompressionError.insufficientSpace(bytes)
        }
    }

    static func downloadRequirement(bytes: Int64?) -> Int64 {
        let bytes = max(0, bytes ?? 0)
        return bytes > Int64.max - reserve ? Int64.max : bytes + reserve
    }

    static func makeOutputURL(fileExtension: String = "mov") throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: UUID().uuidString).appendingPathExtension(fileExtension)
    }

    static func fileSize(_ url: URL) throws -> Int64 {
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
            throw CompressionError.unreadable
        }
        return Int64(size)
    }
}

extension Int64 {
    var storageDescription: String {
        formatted(.byteCount(style: .file, allowedUnits: [.mb, .gb, .kb], spellsOutZero: false,
                             includesActualByteCount: false).locale(Locale(identifier: "zh-Hans")))
    }
}
