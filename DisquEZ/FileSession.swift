import AVFoundation
import Observation

@MainActor @Observable
final class FileSession {
    private(set) var candidates: [FileCandidate] = []
    private(set) var jobs: [FileJob] = []
    private(set) var busy = false
    private(set) var cancellable = false
    private(set) var scanning = false
    private(set) var activeID: UUID?
    private(set) var progress: Double?
    private(set) var processed = 0
    private(set) var total = 0
    private(set) var healthy = true
    var message: String?
    var videoPreset: CompressionPreset = .balanced
    var photoPreset: PhotoPreset = .original
    var encoding: VideoEncoding = .hevc
    var pdfPreset: PDFPreset = .detail
    @ObservationIgnored let store: FileTaskStore
    @ObservationIgnored private let hasProfessionalAccess: @MainActor () -> Bool
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var itemTask: Task<Void, Error>?
    @ObservationIgnored private var stoppedIDs: Set<UUID> = []
    @ObservationIgnored private var cancelledIDs: Set<UUID> = []

    init(store: FileTaskStore = .live, hasProfessionalAccess: @escaping @MainActor () -> Bool = { ProfessionalPurchase.live.unlocked }) {
        self.store = store
        self.hasProfessionalAccess = hasProfessionalAccess
        do {
            jobs = try store.load(); try store.save(jobs); try store.clean(keeping: jobs)
            try FileManager.default.createDirectory(at: URL.documentsDirectory.appending(path: "本机文件"), withIntermediateDirectories: true)
        }
        catch { healthy = false; message = "文件队列无法读取或保存，已有成品与恢复副本已保留。请检查空间后重开 App。" }
    }
    func job(_ id: UUID) -> FileJob? { jobs.first { $0.id == id } }

    func setProfessional(_ settings: ProfessionalVideoSettings?, for ids: Set<UUID>) {
        guard !busy, healthy else { return }
        if let settings {
            guard hasProfessionalAccess() else { message = "请先解锁或恢复专业视频买断。"; return }
            if let reason = settings.validation { message = reason; return }
        }
        var updated = jobs
        let selected = updated.indices.filter { ids.contains(updated[$0].id) && updated[$0].canConfigureVideo }
        guard !selected.isEmpty else { return }
        for index in selected { updated[index].professional = settings; updated[index].note = nil }
        do { try commit(updated); message = nil } catch { if healthy { message = error.localizedDescription } }
    }
    func scan(_ roots: [URL]) {
        guard !busy, healthy else { return }
        scanning = true; candidates = []
        run(cancellable: true) {
            defer { self.scanning = false }
            let result = try await FileAccess.scan(roots)
            try Task.checkCancellation()
            self.candidates = result.files
            self.message = "读到 \(result.files.count) 个文件，\(result.unreadable) 项无法访问。"
            if result.truncated { self.message? += " 本次达到 5000 项上限，请选择更小的目录继续。" }
        }
    }
    @discardableResult
    func enqueue(_ ids: Set<UUID>, defaults: CompressionDefaults? = nil,
                 professional: ProfessionalVideoSettings? = nil) -> [UUID] {
        guard !busy, healthy else { return [] }
        if let professional, !hasProfessionalAccess() || professional.validation != nil {
            message = professional.validation ?? "请先解锁或恢复专业视频买断。"
            return []
        }
        var additions: [FileJob] = []
        do {
            let existing = Set(jobs.map(\.id))
            for candidate in candidates where ids.contains(candidate.id) && !existing.contains(candidate.id) {
                var job = FileJob(candidate)
                job.preset = defaults?.video ?? videoPreset
                job.photoPreset = defaults?.photo ?? photoPreset
                job.encoding = defaults?.encoding ?? encoding
                job.pdfPreset = defaults?.pdf ?? pdfPreset
                if job.kind == .video { job.professional = professional }
                additions.append(job)
            }
            try commit(jobs + additions)
            return additions.map(\.id)
        } catch {
            message = error.localizedDescription
            return []
        }
    }
    func compress(_ ids: [UUID]) {
        let targets = ids.filter { id in
            guard let job = job(id) else { return false }
            return [.waiting, .failed, .skipped, .cancelled].contains(job.stage) && job.kind != .unsupported && job.result == nil
        }
        guard !targets.isEmpty, !busy, healthy else { message = "没有可处理的文件任务，或当前操作尚未完成。"; return }
        stoppedIDs = []; cancelledIDs = []
        run(cancellable: true) {
            self.processed = 0; self.total = targets.count
            for id in targets {
                try Task.checkCancellation()
                if self.stoppedIDs.contains(id) { self.processed += 1; continue }
                self.activeID = id; self.progress = nil
                do {
                    let item = Task { try await self.compressOne(id) }
                    self.itemTask = item
                    defer { self.itemTask = nil }
                    try await withTaskCancellationHandler { try await item.value } onCancel: { item.cancel() }
                }
                catch is CancellationError {
                    let cancelled = self.cancelledIDs.contains(id)
                    try self.change(id) { $0.stage = cancelled ? .cancelled : .waiting; $0.note = cancelled ? "任务已取消，原文件保留。" : "已暂停，可从当前文件重新开始。" }
                    if Task.isCancelled { throw CancellationError() }
                } catch CompressionError.noSavings(let original, let output) {
                    try self.change(id) { $0.stage = .skipped; $0.note = CompressionError.noSavings(original: original, output: output).localizedDescription }
                } catch CompressionError.unsupported(let reason) {
                    try self.change(id) { $0.stage = .skipped; $0.note = reason }
                } catch {
                    try self.change(id) { $0.stage = .failed; $0.note = error.localizedDescription }
                    if !self.stoppedIDs.contains(id), case CompressionError.insufficientSpace = error { throw error }
                }
                if self.stoppedIDs.contains(id), self.job(id)?.result == nil {
                    let cancelled = self.cancelledIDs.contains(id)
                    try self.change(id) { $0.stage = cancelled ? .cancelled : .waiting; $0.note = cancelled ? "任务已取消，原文件保留。" : "已暂停，可重新开始。" }
                }
                self.processed += 1
            }
        }
    }
    private func compressOne(_ id: UUID) async throws {
        guard let job = job(id) else { return }
        if job.professional != nil, !hasProfessionalAccess() {
            throw CompressionError.unsupported("这条任务使用专业参数。请恢复购买，或将任务切回标准参数。")
        }
        try change(id) { $0.stage = .importing; $0.note = nil }
        let fileExtension = (job.name as NSString).pathExtension.lowercased()
        let sourceName = UUID().uuidString + "." + (fileExtension.isEmpty ? "media" : fileExtension)
        let source = try store.file(sourceName)
        var keepSource = false
        defer { if !keepSource { try? FileManager.default.removeItem(at: source) } }
        let original = try await FileAccess.coordinated(job.reference) { url, cancel -> (ResourceDigest, Date?, Date?) in
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .creationDateKey, .contentModificationDateKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true else { throw FileWorkError.access }
            if let expected = job.selectedModified, let modified = info.contentModificationDate, expected != modified { throw FileWorkError.changed }
            if let bytes = job.reportedBytes, let current = info.fileSize, bytes != current { throw FileWorkError.changed }
            let digest = try FileAccess.copy(url, to: source, cancellation: cancel)
            let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard after.fileSize == info.fileSize, after.contentModificationDate == info.contentModificationDate else { throw FileWorkError.changed }
            return (digest, info.creationDate, info.contentModificationDate)
        }
        try Task.checkCancellation()
        try change(id) { $0.stage = .compressing }
        let result: FileResult
        if job.kind == .video {
            let asset = AVURLAsset(url: source)
            let input = try await VideoSource.inspect(asset)
            let metadata = try await asset.load(.metadata)
            let tracks = try await asset.load(.tracks)
            let hasOtherTracks = tracks.contains { $0.mediaType != .video && $0.mediaType != .audio }
            let output = try await VideoCompression.compress(input, preset: job.preset, encoding: job.encoding,
                                                            outputDirectory: store.media, professional: job.professional) { [weak self] value in
                self?.progress = value
            }
            result = FileResult(name: output.url.lastPathComponent, digest: ResourceDigest(bytes: output.bytes, hash: output.digest),
                width: Int(output.displaySize.width), height: Int(output.displaySize.height), videoFormat: output.format,
                copyOnlyReason: output.requiresCopy ? "此视频格式仅支持导出副本"
                    : !metadata.isEmpty || hasOtherTracks ? "原片含附加信息，当前仅导出副本" : nil)
        } else if job.kind == .pdf {
            let output = try await PDFCompression.optimize(source, preset: job.pdfPreset ?? .detail, directory: store.media)
            result = FileResult(name: output.url.lastPathComponent, digest: output.digest, width: 0, height: 0, videoFormat: nil, copyOnlyReason: output.copyOnlyReason, pdf: output.summary)
        } else {
            let output = try await PhotoCompression.compress(source, preset: job.photoPreset, directory: store.media)
            result = FileResult(name: output.fileName, digest: output.digest, width: output.width, height: output.height, videoFormat: nil, copyOnlyReason: nil)
        }
        var keepOutput = false
        defer { if !keepOutput, let url = try? result.url(in: store) { try? FileManager.default.removeItem(at: url) } }
        try Task.checkCancellation()
        try change(id) {
            $0.stage = .ready; $0.sourceName = sourceName; $0.sourceDigest = original.0
            $0.created = original.1; $0.modified = original.2; $0.result = result; $0.note = nil
        }
        keepSource = true; keepOutput = true
        try? store.clean(keeping: jobs)
    }
    func cancel() { if cancellable { task?.cancel() } }
    func stopSelected(_ ids: Set<UUID>, cancel: Bool) {
        guard !busy || cancellable else { return }
        let eligible = jobs.filter { ids.contains($0.id) && $0.result == nil
            && [.waiting, .importing, .compressing, .failed, .skipped].contains($0.stage) }.map(\.id)
        do {
            var next = jobs
            for i in next.indices where eligible.contains(next[i].id) {
                if cancel { next[i].stage = .cancelled }
                next[i].note = cancel ? "任务已取消，原文件保留。" : "已暂停，可重新开始。"
            }
            try commit(next)
            stoppedIDs.formUnion(eligible)
            if cancel { cancelledIDs.formUnion(eligible) }
            if let activeID, eligible.contains(activeID) { itemTask?.cancel() }
        } catch { message = error.localizedDescription }
    }
    func replace(_ id: UUID) {
        guard let job = job(id), FileReplacement.reason(job, store: store) == nil else { return }
        run {
            try self.change(id) { $0.stage = .replacing; $0.note = nil }
            do { try await FileReplacement.replace(job, store: self.store) }
            catch {
                try self.change(id) { $0.stage = .replacementPending; $0.note = "请先核对替换结果。\(error.localizedDescription)" }
                throw error
            }
            try self.change(id) { $0.stage = .replaced; $0.note = "原件恢复副本仍占空间，可恢复或确认清理。" }
        }
    }
    func recheck(_ id: UUID) {
        guard let job = job(id) else { return }
        run {
            let state = try await FileReplacement.state(job, store: self.store)
            try self.change(id) { $0.stage = state; $0.note = state == .replaced ? "当前文件与压缩件一致，原件恢复副本保留。" : "当前文件与原件一致，尚未替换。" }
        }
    }
    func restore(_ id: UUID) {
        guard let job = job(id) else { return }
        run {
            try self.change(id) { $0.stage = .replacing }
            do { try await FileReplacement.restore(job, store: self.store) }
            catch { try self.change(id) { $0.stage = .replacementPending; $0.note = error.localizedDescription }; throw error }
            try self.change(id) { $0.stage = .restored; $0.note = "已回读核对原文件内容，恢复副本保留至你清理任务。" }
        }
    }
    func exportURLs(_ ids: [UUID]) async throws -> [URL] {
        guard !busy else { throw FileWorkError.interrupted }
        return try await FileExports.prepare(jobs.filter { ids.contains($0.id) }, store: store)
    }
    func discard(_ ids: Set<UUID>) {
        let targets = jobs.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return }
        run {
            for job in targets {
                guard ![.replacing, .replacementPending].contains(job.stage) else { throw FileWorkError.interrupted }
                if job.stage == .replaced {
                    guard try await FileReplacement.state(job, store: self.store) == .replaced else { throw FileWorkError.changed }
                }
            }
            try self.commit(self.jobs.filter { !ids.contains($0.id) })
            try self.store.clean(keeping: self.jobs)
        }
    }
    private func commit(_ next: [FileJob]) throws {
        guard healthy else { throw CocoaError(.fileWriteUnknown) }
        do { try store.save(next); jobs = next }
        catch { healthy = false; message = "文件队列保存失败，已有成品与恢复副本已保留。"; throw error }
    }
    private func change(_ id: UUID, _ operation: (inout FileJob) -> Void) throws {
        var next = jobs
        guard let i = next.firstIndex(where: { $0.id == id }) else { throw FileWorkError.access }
        operation(&next[i]); try commit(next)
    }
    private func run(cancellable: Bool = false, _ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy, healthy else { return }
        busy = true; self.cancellable = cancellable; message = nil
        task = Task {
            defer { self.busy = false; self.cancellable = false; self.activeID = nil; self.progress = nil; self.task = nil }
            do { try await operation() }
            catch is CancellationError { self.message = "已停止，完成的文件成品可继续复核。" }
            catch { if self.healthy { self.message = error.localizedDescription } }
        }
    }
}
