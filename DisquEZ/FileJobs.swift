import AVFoundation
import Foundation

struct FileResult: Codable {
    let name: String
    let digest: ResourceDigest
    let width: Int
    let height: Int
    let videoFormat: VideoOutputFormat?
    let copyOnlyReason: String?
    var pdf: PDFSummary? = nil
    func url(in store: FileTaskStore) throws -> URL { try store.file(name) }
}

struct FileJob: Codable, Identifiable {
    enum Stage: String, Codable {
        case waiting, importing, compressing, ready, failed, skipped, replacing, replacementPending, replaced, restored, cancelled
        var label: String {
            switch self {
            case .waiting: "待处理"
            case .importing: "读取原文件"
            case .compressing: "正在压缩"
            case .ready: "成品待复核"
            case .failed: "处理失败"
            case .skipped: "已跳过"
            case .replacing: "正在替换"
            case .replacementPending: "替换结果待核对"
            case .replaced: "已替换 · 可恢复原件"
            case .restored: "原件已恢复"
            case .cancelled: "已取消任务"
            }
        }
    }
    let id: UUID
    let reference: FileReference
    let name: String
    let kind: FileMediaKind
    let reportedBytes: Int64?
    let selectedModified: Date?
    var stage: Stage = .waiting
    var sourceName: String?
    var sourceDigest: ResourceDigest?
    var created: Date?
    var modified: Date?
    var result: FileResult?
    var note: String?
    var preset: CompressionPreset = .balanced
    var photoPreset: PhotoPreset = .original
    var encoding: VideoEncoding = .hevc
    var professional: ProfessionalVideoSettings?
    var pdfPreset: PDFPreset? = nil
    var canConfigureVideo: Bool {
        kind == .video && result == nil && [.waiting, .failed, .skipped, .cancelled].contains(stage)
    }
    init(_ candidate: FileCandidate) {
        id = candidate.id; reference = candidate.reference; name = candidate.name; kind = candidate.kind
        reportedBytes = candidate.bytes; selectedModified = candidate.modified
        if kind == .unsupported { stage = .skipped; note = FileWorkError.unsupported.localizedDescription }
    }
}

struct FileTaskStore {
    let root: URL
    static let live = FileTaskStore(root: URL.applicationSupportDirectory.appending(path: "FileQueue"))
    var media: URL { root.appending(path: "Media") }
    private var journal: URL { root.appending(path: "queue.json") }
    private struct Journal: Codable { let version: Int; let jobs: [FileJob] }
    func prepare() throws {
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        var directory = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }
    func file(_ name: String) throws -> URL {
        let url = media.appending(path: name)
        guard url.lastPathComponent == name, UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
              !url.pathExtension.isEmpty, url.pathExtension.allSatisfy({ $0.isASCII && $0.isLetter || $0.isNumber }) else {
            throw CompressionError.invalidOutput
        }
        return url
    }
    func save(_ jobs: [FileJob]) throws {
        try prepare()
        try JSONEncoder().encode(Journal(version: 1, jobs: jobs))
            .write(to: journal, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func load() throws -> [FileJob] {
        guard FileManager.default.fileExists(atPath: journal.path) else { return [] }
        let stored = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journal))
        guard stored.version == 1, Set(stored.jobs.map(\.id)).count == stored.jobs.count else { throw CocoaError(.fileReadCorruptFile) }
        return try stored.jobs.map { original in
            var job = original
            if let name = job.sourceName { _ = try file(name) }
            if let result = job.result { _ = try result.url(in: self) }
            if [.importing, .compressing].contains(job.stage) { job.stage = .waiting; job.note = "上次处理已中断，可重新开始。" }
            if job.stage == .replacing { job.stage = .replacementPending; job.note = "上次替换未收到结果，请先核对或恢复原件。" }
            if let result = job.result, !FileManager.default.fileExists(atPath: try result.url(in: self).path),
               ![.replaced, .replacementPending].contains(job.stage) {
                job.stage = .failed; job.note = "本机成品文件不可用，可重新压缩。"
                job.result = nil
            }
            return job
        }
    }
    func clean(keeping jobs: [FileJob]) throws {
        try prepare()
        let keep = Set(jobs.flatMap { [$0.sourceName, $0.result?.name].compactMap { $0 } })
        for url in try FileManager.default.contentsOfDirectory(at: media, includingPropertiesForKeys: nil)
            where !keep.contains(url.lastPathComponent) {
            // Only clean our own generated files.
            if (try? file(url.lastPathComponent)) != nil { try FileManager.default.removeItem(at: url) }
        }
    }
}

enum FileReplacement {
    static func reason(_ job: FileJob, store: FileTaskStore) -> String? {
        guard job.stage == .ready || job.stage == .replacementPending else { return "请先压缩并复核成品" }
        guard let result = job.result, let source = job.sourceDigest, let sourceName = job.sourceName,
              let backup = try? store.file(sourceName), FileManager.default.fileExists(atPath: backup.path),
              source.bytes > result.digest.bytes else { return "缺少可核验的恢复副本" }
        if let reason = result.copyOnlyReason { return reason }
        do {
            return try job.reference.withAccess { url in
                guard FileAccess.canReplace(url) else { return "位置无法确认可安全替换，请导出副本" }
                return compatibleExtension(original: url, result: try result.url(in: store)) ? nil : "输出封装或扩展名不同，请导出副本"
            }
        } catch { return error.localizedDescription }
    }
    private static func compatibleExtension(original: URL, result: URL) -> Bool {
        let left = original.pathExtension.lowercased(), right = result.pathExtension.lowercased()
        return left == right || (["jpg", "jpeg"].contains(left) && ["jpg", "jpeg"].contains(right))
    }
    static func replace(_ job: FileJob, store: FileTaskStore) async throws {
        guard reason(job, store: store) == nil, let result = job.result,
              let source = job.sourceDigest, let sourceName = job.sourceName else { throw FileWorkError.unsafeReplacement }
        guard try FileAccess.digest(store.file(sourceName)) == source,
              try FileAccess.digest(result.url(in: store)) == result.digest else { throw FileWorkError.corruptRecovery }
        try await FileAccess.coordinated(job.reference, writing: true) { original, cancel in
            guard FileAccess.canReplace(original), try FileAccess.digest(original, cancellation: cancel) == source else { throw FileWorkError.changed }
            let staging = original.deletingLastPathComponent().appending(path: ".DisquEZ-\(UUID().uuidString)").appendingPathExtension(original.pathExtension)
            defer { try? FileManager.default.removeItem(at: staging) }
            guard try FileAccess.copy(result.url(in: store), to: staging, cancellation: cancel) == result.digest else { throw CompressionError.invalidOutput }
            try cancel.check()
            _ = try FileManager.default.replaceItemAt(original, withItemAt: staging)
            guard try FileAccess.digest(original) == result.digest else { throw CompressionError.invalidOutput }
        }
    }
    static func state(_ job: FileJob, store: FileTaskStore) async throws -> FileJob.Stage {
        guard let result = job.result, let source = job.sourceDigest else { throw FileWorkError.corruptRecovery }
        return try await FileAccess.coordinated(job.reference) { url, cancel in
            let current = try FileAccess.digest(url, cancellation: cancel)
            if current == source { return .ready }
            if current == result.digest { return .replaced }
            throw FileWorkError.changed
        }
    }
    static func restore(_ job: FileJob, store: FileTaskStore) async throws {
        guard [.replaced, .replacementPending].contains(job.stage), let result = job.result,
              let source = job.sourceDigest, let sourceName = job.sourceName,
              try FileAccess.digest(store.file(sourceName)) == source else { throw FileWorkError.corruptRecovery }
        try await FileAccess.coordinated(job.reference, writing: true) { original, cancel in
            guard FileAccess.canReplace(original, allowMissing: true) else { throw FileWorkError.unsafeReplacement }
            let exists = FileManager.default.fileExists(atPath: original.path)
            if exists {
                let current = try FileAccess.digest(original, cancellation: cancel)
                guard current == result.digest || current == source else { throw FileWorkError.changed }
            }
            let staging = original.deletingLastPathComponent().appending(path: ".DisquEZ-\(UUID().uuidString)").appendingPathExtension(original.pathExtension)
            defer { try? FileManager.default.removeItem(at: staging) }
            guard try FileAccess.copy(store.file(sourceName), to: staging, cancellation: cancel) == source else { throw FileWorkError.corruptRecovery }
            var attributes: [FileAttributeKey: Any] = [:]
            if let created = job.created { attributes[.creationDate] = created }
            if let modified = job.modified { attributes[.modificationDate] = modified }
            try FileManager.default.setAttributes(attributes, ofItemAtPath: staging.path)
            try cancel.check()
            if exists { _ = try FileManager.default.replaceItemAt(original, withItemAt: staging) }
            else { try FileManager.default.moveItem(at: staging, to: original) }
            guard try FileAccess.digest(original) == source else { throw FileWorkError.corruptRecovery }
        }
    }
}
