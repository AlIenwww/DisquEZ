import Observation
import Photos
import UniformTypeIdentifiers

struct PhotoJob: Identifiable, Codable {
    let id: UUID
    var original: PhotoSnapshot
    var preset: PhotoPreset
    var stage: CompressionJob.Stage = .waiting
    var sourceFileName: String?
    var sourceBytes: Int64?
    var output: PhotoOutput?
    var copy: SavedCopy?
    var note: String?
    init(photo: PHAsset, preset: PhotoPreset) {
        id = UUID()
        original = PhotoSnapshot(photo)
        self.preset = preset
    }
    var title: String { original.creationDate?.formatted(.dateTime.year().month().day().hour().minute()) ?? "照片" }
}

extension PhotoSession: BatchTaskSession {
    var batchItems: [BatchTaskItem] { jobs.map(makeBatchItem) }
    func batchItem(_ id: UUID) -> BatchTaskItem? { job(id).map(makeBatchItem) }
    private func makeBatchItem(_ job: PhotoJob) -> BatchTaskItem {
        BatchTaskItem(id: job.id, original: job.original, stage: job.stage, hasOutput: job.output != nil,
                      hasCopy: job.copy != nil, copyOnly: false, note: job.note)
    }
    var batchBusy: Bool { busy }
    var batchInterruptible: Bool { canCancel }
    var batchVideo: Bool { false }
    func execute(_ action: TaskBatchAction, ids: [UUID]) {
        let targets = batchItems.filter { ids.contains($0.id) && $0.reason(for: action, busy: busy, interruptible: canCancel, video: false) == nil }.map(\.id)
        guard !targets.isEmpty else { message = "当前没有符合操作条件的任务。"; return }
        switch action {
        case .start: compress(targets)
        case .download: compress(targets, authorizedDownloads: Set(targets))
        case .save: save(targets)
        case .verify: verifyMany(targets)
        case .replace: replaceMany(targets)
        case .pause: stopSelected(Set(targets), cancel: false)
        case .cancel: stopSelected(Set(targets), cancel: true)
        case .retry:
            do {
                var next = jobs
                for i in next.indices where targets.contains(next[i].id) { next[i].stage = .waiting; next[i].note = nil }
                try commit(next); compress(targets)
            } catch { message = error.localizedDescription }
        case .discard:
            do {
                try commit(jobs.filter { !targets.contains($0.id) })
                for id in targets { verified[id] = nil; store.clearReceipt(id) }
                try store.clean(keeping: jobs); refreshCapacity()
            } catch { message = error.localizedDescription }
        case .deleteOriginal, .export: break
        }
    }
}

struct PhotoQueueStore {
    let directory: URL
    static let live = PhotoQueueStore(directory: URL.applicationSupportDirectory.appending(path: "PhotoQueue"))
    var media: URL { directory.appending(path: "Media") }
    private var journal: URL { directory.appending(path: "queue.json") }
    private struct Journal: Codable { let version: Int; var jobs: [PhotoJob] }

    static func file(_ name: String, in directory: URL) throws -> URL {
        let url = directory.appending(path: name)
        guard url.lastPathComponent == name, ["jpg", "heic"].contains(url.pathExtension),
              UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else { throw CompressionError.invalidOutput }
        return url
    }
    func prepare() throws {
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        var root = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
    }
    func save(_ jobs: [PhotoJob]) throws {
        try prepare()
        try JSONEncoder().encode(Journal(version: 1, jobs: jobs))
            .write(to: journal, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func load() throws -> [PhotoJob] {
        guard FileManager.default.fileExists(atPath: journal.path) else { return [] }
        let stored = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journal))
        guard stored.version == 1, Set(stored.jobs.map(\.id)).count == stored.jobs.count else { throw CocoaError(.fileReadCorruptFile) }
        return try stored.jobs.map { job in
            var job = job
            if let receipt = try receipt(job.id) { job.copy = receipt }
            if let name = job.sourceFileName { _ = try Self.file(name, in: media) }
            switch job.stage {
            case .processing: job.stage = .waiting; job.note = "上次处理已中断，可重新压缩。"
            case .downloading: job.stage = .awaitingDownload; job.note = "下载已中断，可重新下载。"
            case .saving: job.stage = job.copy == nil ? .ready : .savePending
            case .verified: job.stage = .saved
            case .removing: job.stage = .removalPending; job.note = "上次移除未收到确认，请核对系统照片库。"
            default: break
            }
            if let output = job.output, !FileManager.default.fileExists(atPath: try output.url(in: media).path), job.copy == nil {
                job.output = nil; job.stage = .failed; job.note = "成品文件不可用，可重试压缩。"
            }
            return job
        }
    }
    func receipt(_ id: UUID) throws -> SavedCopy? {
        let url = directory.appending(path: "\(id).receipt")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(SavedCopy.self, from: Data(contentsOf: url))
    }
    func receipt(_ copy: SavedCopy, for id: UUID) throws {
        try JSONEncoder().encode(copy).write(to: directory.appending(path: "\(id).receipt"),
                                            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func clearReceipt(_ id: UUID) { try? FileManager.default.removeItem(at: directory.appending(path: "\(id).receipt")) }
    func clean(keeping jobs: [PhotoJob]) throws {
        try prepare()
        let kept = Set(jobs.filter { !$0.stage.isClosed }.flatMap { [$0.sourceFileName, $0.output?.fileName].compactMap { $0 } })
        for url in try FileManager.default.contentsOfDirectory(at: media, includingPropertiesForKeys: nil)
            where !kept.contains(url.lastPathComponent) {
            _ = try Self.file(url.lastPathComponent, in: media)
            try FileManager.default.removeItem(at: url)
        }
    }
}

@MainActor @Observable
final class PhotoSession {
    private(set) var jobs: [PhotoJob] = []
    private(set) var busy = false
    private(set) var canCancel = false
    private(set) var activeID: UUID?
    private(set) var progress = 0.0
    private(set) var healthy = true
    private(set) var capacity = StorageCapacity.read()
    var message: String?
    var preset: PhotoPreset = .original
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var verified: [UUID: VerifiedCopy] = [:]
    @ObservationIgnored private var stoppedIDs: Set<UUID> = []
    @ObservationIgnored private var cancelledIDs: Set<UUID> = []
    private(set) var batchCompleted = 0
    private(set) var batchTotal = 0
    @ObservationIgnored let store: PhotoQueueStore

    init(store: PhotoQueueStore = .live) {
        self.store = store
        do { jobs = try store.load(); try store.save(jobs); try store.clean(keeping: jobs) }
        catch { healthy = false; message = "照片队列无法读取或保存，已有成品已保留。请检查空间后重开 App。" }
    }
    func job(_ id: UUID) -> PhotoJob? { jobs.first { $0.id == id } }
    var waiting: [UUID] { jobs.filter { $0.stage == .waiting }.map(\.id) }
    var ready: [UUID] { jobs.filter { $0.stage == .ready }.map(\.id) }
    var retryable: [UUID] { jobs.filter { [.failed, .skipped].contains($0.stage) && $0.copy == nil && $0.output == nil }.map(\.id) }
    func canReplace(_ id: UUID) -> Bool { job(id)?.stage == .verified && verified[id]?.canReplace == true }
    func file(_ name: String?) -> URL? { name.flatMap { try? PhotoQueueStore.file($0, in: store.media) } }
    func refreshCapacity() { capacity = StorageCapacity.read() }
    @discardableResult
    func enqueue(_ photos: [PHAsset], using selectedPreset: PhotoPreset? = nil) -> [UUID] {
        guard !busy, healthy else { return [] }
        var ids = Set(jobs.map { $0.original.identifier })
        let new = photos.filter { $0.mediaType == .image && ids.insert($0.localIdentifier).inserted }
            .map { PhotoJob(photo: $0, preset: selectedPreset ?? preset) }
        do {
            try commit(jobs + new)
            return new.map(\.id)
        } catch {
            message = error.localizedDescription
            return []
        }
    }
    func setPreset(_ value: PhotoPreset, id: UUID) {
        guard !busy, let job = job(id), job.output == nil, job.copy == nil,
              [.waiting, .awaitingDownload, .failed, .skipped].contains(job.stage) else { return }
        try? change(id) { $0.preset = value }
    }
    func compress(_ ids: [UUID]? = nil, download: UUID? = nil, authorizedDownloads: Set<UUID> = []) {
        let downloads = authorizedDownloads.union(download.map { [$0] } ?? [])
        let targets = (ids ?? waiting).filter {
            job($0)?.stage == .waiting || (downloads.contains($0) && job($0)?.stage == .awaitingDownload)
        }
        guard !targets.isEmpty, !busy, healthy else { return }
        stoppedIDs = []; cancelledIDs = []
        run(cancellable: true) {
            self.batchTotal = targets.count; self.batchCompleted = 0
            for id in targets {
                try Task.checkCancellation()
                if self.stoppedIDs.contains(id) { self.batchCompleted += 1; continue }
                self.activeID = id; self.progress = 0
                do {
                    let child = Task { try await self.compressOne(id, download: downloads.contains(id)) }
                    self.compressionTask = child
                    defer { self.compressionTask = nil }
                    try await withTaskCancellationHandler { try await child.value } onCancel: { child.cancel() }
                }
                catch is CancellationError {
                    let downloading = downloads.contains(id)
                    let cancelled = self.cancelledIDs.contains(id)
                    try self.change(id) { $0.stage = cancelled ? .cancelled : downloading ? .awaitingDownload : .waiting; $0.note = cancelled ? "任务已取消，原片保留。" : "已暂停，可重试当前照片。" }
                    if Task.isCancelled { throw CancellationError() }
                } catch CompressionError.cloudOnly {
                    try self.change(id) { $0.stage = .awaitingDownload; $0.note = "原片只在 iCloud，点按下载后继续。" }
                } catch CompressionError.unsupported(let reason) {
                    try self.change(id) { $0.stage = .skipped; $0.note = reason }
                } catch CompressionError.noSavings(let original, let output) {
                    try self.change(id) { $0.stage = .skipped; $0.note = CompressionError.noSavings(original: original, output: output).localizedDescription }
                } catch {
                    let downloading = self.job(id)?.stage == .downloading
                    try self.change(id) { $0.stage = downloading ? .awaitingDownload : .failed; $0.note = error.localizedDescription }
                    if !self.stoppedIDs.contains(id), case CompressionError.insufficientSpace = error { throw error }
                }
                if self.stoppedIDs.contains(id), self.job(id)?.output == nil, self.job(id)?.copy == nil {
                    let cancelled = self.cancelledIDs.contains(id)
                    try self.change(id) {
                        $0.stage = cancelled ? .cancelled : downloads.contains(id) ? .awaitingDownload : .waiting
                        $0.note = cancelled ? "任务已取消，原片保留。" : "已暂停，可重新开始。"
                    }
                }
                self.batchCompleted += 1
            }
        }
    }
    private func compressOne(_ id: UUID, download: Bool) async throws {
        guard let queued = job(id), let photo = PhotoLibrary.fetch(queued.original.identifier) else { throw CompressionError.originalUnavailable }
        if let reason = MediaLibrary.photoCompressionProtection(photo) { throw CompressionError.unsupported(reason) }
        let resource = try MediaLibrary.resource(photo)
        let name = UUID().uuidString + (UTType(resource.uniformTypeIdentifier)?.conforms(to: .jpeg) == true ? ".jpg" : ".heic")
        let source = try PhotoQueueStore.file(name, in: store.media)
        try change(id) { $0.stage = download ? .downloading : .processing; $0.note = nil }
        var progress: (@MainActor (Double) -> Void)?
        if download {
            progress = { [weak self] value in
                guard let self, self.activeID == id, self.job(id)?.stage == .downloading else { return }
                self.progress = max(self.progress, value); self.refreshCapacity()
            }
        }
        var keepSource = false
        defer { if !keepSource { try? FileManager.default.removeItem(at: source) } }
        let digest = try await MediaResourceRead.read(resource, to: source, progress: progress)
        try Task.checkCancellation()
        guard let current = PhotoLibrary.fetch(photo.localIdentifier), PhotoSnapshot(photo).matches(current) else { throw CompressionError.originalUnavailable }
        try change(id) { $0.stage = .processing; $0.sourceBytes = digest.bytes }
        let output = try await PhotoCompression.compress(source, preset: queued.preset, directory: store.media)
        var keepOutput = false
        defer { if !keepOutput, let url = try? output.url(in: store.media) { try? FileManager.default.removeItem(at: url) } }
        try Task.checkCancellation()
        try change(id) {
            $0.original = PhotoSnapshot(current); $0.sourceFileName = name; $0.output = output; $0.stage = .ready
        }
        keepSource = true; keepOutput = true
        do { try store.clean(keeping: jobs) }
        catch { message = "成品已就绪，部分临时文件暂未清理。可继续预览和保存。" }
    }
    func retry(_ ids: [UUID]) {
        guard !busy, healthy else { return }
        let eligible = ids.filter { retryable.contains($0) }
        do {
            var next = jobs
            for i in next.indices where eligible.contains(next[i].id) { next[i].stage = .waiting; next[i].note = nil }
            try commit(next); compress(eligible)
        } catch { message = error.localizedDescription }
    }
    func cancel() { if canCancel { task?.cancel() } }

    func save(_ ids: [UUID]) {
        let targets = ids.filter { job($0)?.stage == .ready }
        guard !targets.isEmpty else { return }
        run {
            for id in targets {
                try Task.checkCancellation()
                self.activeID = id
                guard let job = self.job(id), let output = job.output else { continue }
                do {
                    if let receipt = try self.store.receipt(id) {
                        try self.change(id) { $0.copy = receipt; $0.stage = .savePending }
                    } else {
                        try self.change(id) { $0.stage = .saving; $0.note = nil }
                        let copy: SavedCopy
                        do {
                            copy = try await PhotoLibrary.savePhoto(output, directory: self.store.media, original: job.original) {
                                try self.store.receipt($0, for: id)
                            }
                        } catch {
                            self.store.clearReceipt(id)
                            try self.change(id) { $0.stage = .ready }
                            throw error
                        }
                        try self.change(id) { $0.copy = copy; $0.stage = .saved }
                    }
                    try await self.verifyOne(id)
                } catch {
                    try self.change(id) { $0.note = error.localizedDescription }
                    if case CompressionError.insufficientSpace = error { throw error }
                }
            }
        }
    }
    func verify(_ id: UUID) { verifyMany([id]) }
    func verifyMany(_ ids: [UUID]) {
        run {
            for id in ids {
                do { try await self.verifyOne(id) }
                catch { try self.change(id) { $0.note = error.localizedDescription } }
            }
        }
    }
    private func verifyOne(_ id: UUID) async throws {
        guard let job = job(id), let output = job.output, let copy = job.copy else { throw CompressionError.copyNotVerified }
        verified[id] = nil
        try change(id) { $0.stage = .saved; $0.note = nil }
        let value = try await PhotoLibrary.verifyPhoto(copy, output: output, original: job.original)
        try change(id) {
            $0.stage = .verified
            $0.note = value.canReplace ? nil : "压缩件已核验，当前仅支持保留两份或导出副本。"
        }
        verified[id] = value
    }
    func replace(_ id: UUID) {
        guard canReplace(id) else { return }
        replaceMany([id])
    }
    func replaceMany(_ ids: [UUID]) {
        run {
            var replacements: [OriginalReplacement] = []
            for id in ids {
                try await self.verifyOne(id)
                guard let job = self.job(id), let copy = job.copy, let verified = self.verified[id], verified.canReplace else { throw CompressionError.replacementUnavailable }
                replacements.append(OriginalReplacement(original: job.original, copy: copy, verified: verified))
            }
            try Task.checkCancellation()
            var next = self.jobs
            for i in next.indices where ids.contains(next[i].id) { next[i].stage = .removing }
            try self.commit(next)
            do {
                try await PhotoLibrary.moveOriginalsToRecentlyDeleted(replacements)
            } catch {
                for id in ids { try self.change(id) { $0.stage = .saved }; self.verified[id] = nil }
                throw error
            }
            for id in ids { try self.change(id) { $0.stage = .removed; $0.note = nil }; self.verified[id] = nil }
            try self.store.clean(keeping: self.jobs)
        }
    }
    func stopSelected(_ ids: Set<UUID>, cancel: Bool) {
        guard !busy || canCancel else { return }
        let eligible = ids.filter { id in
            guard let stage = job(id)?.stage else { return false }
            return [.waiting, .awaitingDownload, .processing, .downloading, .failed, .skipped].contains(stage)
                && job(id)?.output == nil && job(id)?.copy == nil
        }
        do {
            var next = jobs
            for i in next.indices where eligible.contains(next[i].id) {
                if cancel { next[i].stage = .cancelled }
                next[i].note = cancel ? "任务已取消，原片保留。" : "已暂停，可重新开始。"
            }
            try commit(next)
            stoppedIDs.formUnion(eligible)
            if cancel { cancelledIDs.formUnion(eligible) }
            if let id = activeID, eligible.contains(id) {
                if let request = compressionTask { request.cancel() }
            }
        } catch { message = error.localizedDescription }
    }
    @ObservationIgnored private var compressionTask: Task<Void, Error>?
    func keep(_ id: UUID) {
        guard !busy, job(id)?.stage == .verified else { return }
        do { try change(id) { $0.stage = .kept }; verified[id] = nil; try store.clean(keeping: jobs); refreshCapacity() }
        catch { message = error.localizedDescription }
    }
    func discard(_ id: UUID) {
        guard !busy else { return }
        do {
            try commit(jobs.filter { $0.id != id }); verified[id] = nil
            store.clearReceipt(id); try store.clean(keeping: jobs); refreshCapacity()
        } catch { message = error.localizedDescription }
    }
    private func commit(_ values: [PhotoJob]) throws {
        guard healthy else { throw CocoaError(.fileWriteUnknown) }
        do { try store.save(values); jobs = values }
        catch { healthy = false; message = "照片队列保存失败，已有成品已保留。请检查空间后重新打开 App。"; throw error }
    }
    private func change(_ id: UUID, _ update: (inout PhotoJob) -> Void) throws {
        var next = jobs
        guard let i = next.firstIndex(where: { $0.id == id }) else { throw CompressionError.originalUnavailable }
        update(&next[i]); try commit(next)
    }
    private func run(cancellable: Bool = false, _ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy, healthy else { return }
        busy = true; canCancel = cancellable; message = nil
        task = Task {
            defer { self.busy = false; self.canCancel = false; self.activeID = nil; self.task = nil; self.refreshCapacity() }
            do { try await operation() }
            catch is CancellationError { self.message = "已暂停，完成的照片可继续复核。" }
            catch { if self.healthy { self.message = error.localizedDescription } }
        }
    }
}
