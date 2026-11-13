import CryptoKit
import Foundation
import os
import UniformTypeIdentifiers

enum FileWorkError: LocalizedError {
    case access, changed, unsupported, unsafeReplacement, corruptRecovery, interrupted
    var errorDescription: String? {
        switch self {
        case .access: "文件访问已失效，请重新选择文件或目录。"
        case .changed: "文件内容或位置已变化，请重新选择并复核。原件未被覆盖。"
        case .unsupported: "当前仅处理支持的视频、JPEG/HEIC 图片和普通 PDF，其他文件保留。"
        case .unsafeReplacement: "无法确认本机位置、写入条件或恢复副本，请导出新副本。"
        case .corruptRecovery: "恢复副本核验失败，已停止替换，请保留原件。"
        case .interrupted: "操作已中断，请先核对原件和成品。"
        }
    }
}

struct FileReference: Codable {
    let bookmark: Data
    let relativePath: String?
    let localURL: URL?
    let documentPath: String?

    init(root: URL, child: URL) throws {
        bookmark = try root.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let isFolder = (try root.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
        let same = root.standardizedFileURL.resolvingSymlinksInPath() == child.standardizedFileURL.resolvingSymlinksInPath()
        guard same || (isFolder && FileAccess.isDescendant(child, of: root)) else { throw FileWorkError.access }
        relativePath = isFolder && !same ? String(child.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(root.standardizedFileURL.resolvingSymlinksInPath().path.count + 1)) : nil
        // Only our own document container has a location we can independently establish as local.
        localURL = FileAccess.isInsideDocuments(root) ? root : nil
        let documents = URL.documentsDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let normalized = root.standardizedFileURL.resolvingSymlinksInPath().path
        documentPath = localURL == nil ? nil : normalized == documents ? "" : String(normalized.dropFirst(documents.count + 1))
    }

    func withAccess<T>(_ operation: (URL) throws -> T) throws -> T {
        var stale = false
        let root: URL
        if let documentPath {
            guard !documentPath.hasPrefix("/"), !documentPath.split(separator: "/").contains("..") else { throw FileWorkError.access }
            root = URL.documentsDirectory.appending(path: documentPath)
            guard FileAccess.isInsideDocuments(root) else { throw FileWorkError.access }
        } else if let localURL, FileAccess.isInsideDocuments(localURL) { root = localURL }
        else { root = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) }
        guard !stale else { throw FileWorkError.access }
        let accessed = root.startAccessingSecurityScopedResource()
        defer { if accessed { root.stopAccessingSecurityScopedResource() } }
        guard accessed || FileAccess.isInsideDocuments(root) || (localURL == root && FileAccess.isInsideDocuments(root)) else {
            throw FileWorkError.access
        }
        let file: URL
        if let relativePath {
            guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
                  !relativePath.split(separator: "/").contains("..") else { throw FileWorkError.access }
            file = root.appending(path: relativePath).standardizedFileURL
            guard FileAccess.isDescendant(file, of: root) else { throw FileWorkError.access }
        } else { file = root }
        guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw FileWorkError.access }
        return try operation(file)
    }
}

struct FileCandidate: Identifiable {
    let id = UUID()
    let reference: FileReference
    let name: String
    let folder: String
    let bytes: Int64?
    let kind: FileMediaKind
    let cloud: Bool
    let modified: Date?
}

enum FileMediaKind: String, Codable {
    case video = "视频", photo = "图片", pdf = "PDF", unsupported = "其他文件"
    static func detect(_ url: URL) -> Self {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return .unsupported }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .jpeg) || type.conforms(to: .heic) { return .photo }
        if type.conforms(to: .pdf) { return .pdf }
        return .unsupported
    }
}

struct FileScanResult { let files: [FileCandidate]; let unreadable: Int; let truncated: Bool }

final class FileCancellation: @unchecked Sendable {
    private let cancelled = OSAllocatedUnfairLock(initialState: false)
    let coordinator = NSFileCoordinator()
    func cancel() { cancelled.withLock { $0 = true }; coordinator.cancel() }
    func check() throws { if cancelled.withLock({ $0 }) || Task.isCancelled { throw CancellationError() } }
}

enum FileAccess {
    static func isDescendant(_ child: URL, of root: URL) -> Bool {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        return child.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(base + "/")
    }
    static func isInsideDocuments(_ url: URL) -> Bool {
        let root = URL.documentsDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
        return normalized == root || isDescendant(normalized, of: root)
    }
    static func canReplace(_ url: URL, allowMissing: Bool = false) -> Bool {
        guard isInsideDocuments(url),
              !url.pathComponents.contains("Inbox") else { return false }
        let checkURL = allowMissing && !FileManager.default.fileExists(atPath: url.path) ? url.deletingLastPathComponent() : url
        guard let values = try? checkURL.resourceValues(forKeys: [.isUbiquitousItemKey, .volumeIsLocalKey, .isWritableKey, .isRegularFileKey, .isSymbolicLinkKey]),
              values.isUbiquitousItem != true, values.volumeIsLocal == true, values.isWritable == true,
              values.isSymbolicLink != true else { return false }
        return allowMissing || values.isRegularFile == true
    }
    static func scan(_ roots: [URL]) async throws -> FileScanResult {
        try Task.checkCancellation()
        var files: [FileCandidate] = []
        var unreadable = 0
        var truncated = false
        var seen: Set<String> = []
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isUbiquitousItemKey, .fileSizeKey, .contentModificationDateKey]
        for root in roots {
            try Task.checkCancellation()
            let accessed = root.startAccessingSecurityScopedResource()
            defer { if accessed { root.stopAccessingSecurityScopedResource() } }
            guard accessed || isInsideDocuments(root) else { unreadable += 1; continue }
            let values = try root.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { unreadable += 1; continue }
            var urls: [URL] = []
            if values.isDirectory == true {
                guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in unreadable += 1; return true }) else {
                    unreadable += 1; continue
                }
                while let file = enumerator.nextObject() as? URL {
                    try Task.checkCancellation()
                    if urls.count + files.count >= 5_000 { truncated = true; break }
                    if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { enumerator.skipDescendants(); continue }
                    urls.append(file)
                }
            } else { urls = [root] }
            for file in urls {
                try Task.checkCancellation()
                do {
                    let info = try file.resourceValues(forKeys: keys)
                    guard info.isRegularFile == true, info.isSymbolicLink != true,
                          seen.insert(file.standardizedFileURL.path).inserted else { continue }
                    files.append(FileCandidate(reference: try FileReference(root: root, child: file), name: file.lastPathComponent,
                        folder: root.lastPathComponent, bytes: info.fileSize.map(Int64.init), kind: .detect(file),
                        cloud: info.isUbiquitousItem == true, modified: info.contentModificationDate))
                } catch { unreadable += 1 }
            }
        }
        return FileScanResult(files: files.sorted { ($0.bytes ?? -1) > ($1.bytes ?? -1) }, unreadable: unreadable, truncated: truncated)
    }
    static func coordinated<T>(_ reference: FileReference, writing: Bool = false,
                               writingOptions: NSFileCoordinator.WritingOptions = .forReplacing,
                               _ operation: (URL, FileCancellation) throws -> T) async throws -> T {
        let cancellation = FileCancellation()
        return try await withTaskCancellationHandler {
            try cancellation.check()
            return try reference.withAccess { url in
                var result: Result<T, Error>?
                var error: NSError?
                let accessor: (URL) -> Void = { coordinated in
                    result = Result { try cancellation.check(); return try operation(coordinated, cancellation) }
                }
                if writing { cancellation.coordinator.coordinate(writingItemAt: url, options: writingOptions, error: &error, byAccessor: accessor) }
                else { cancellation.coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &error, byAccessor: accessor) }
                if let error { throw error }
                guard let result else { throw FileWorkError.access }
                return try result.get()
            }
        } onCancel: { cancellation.cancel() }
    }
    static func digest(_ url: URL, cancellation: FileCancellation? = nil) throws -> ResourceDigest {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hash = SHA256()
        var count: Int64 = 0
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try cancellation?.check(); try Task.checkCancellation()
            hash.update(data: chunk); count += Int64(chunk.count)
        }
        guard count > 0 else { throw CompressionError.unreadable }
        return ResourceDigest(bytes: count, hash: Data(hash.finalize()))
    }
    static func copy(_ source: URL, to target: URL, cancellation: FileCancellation? = nil, checkingLocalSpace: Bool = true) throws -> ResourceDigest {
        let bytes = try StorageCapacity.fileSize(source)
        if checkingLocalSpace { try StorageCapacity.require(StorageCapacity.downloadRequirement(bytes: bytes)) }
        guard !FileManager.default.fileExists(atPath: target.path), FileManager.default.createFile(atPath: target.path, contents: nil) else {
            throw CocoaError(.fileWriteFileExists)
        }
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: target) } }
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: target)
        defer { try? input.close(); try? output.close() }
        var hash = SHA256(); var count: Int64 = 0
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try cancellation?.check(); try Task.checkCancellation()
            if checkingLocalSpace { try StorageCapacity.require(StorageCapacity.reserve) }
            try output.write(contentsOf: chunk)
            hash.update(data: chunk); count += Int64(chunk.count)
        }
        try output.synchronize()
        guard count == bytes else { throw FileWorkError.changed }
        success = true
        return ResourceDigest(bytes: count, hash: Data(hash.finalize()))
    }
}
