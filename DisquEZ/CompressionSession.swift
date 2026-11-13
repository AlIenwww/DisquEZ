import Foundation
import BackgroundTasks
import Observation
import Photos
import UIKit

@MainActor @Observable
final class CompressionSession {
    enum Work { case compressing, saving, verifying, replacing }
    typealias VideoSelection = @MainActor (PHAsset, (@MainActor (Double) -> Void)?) async throws -> SelectedVideo

    private(set) var jobs: [CompressionJob] = []
    private(set) var work: Work?
    private(set) var activeJobID: UUID?
    private(set) var progress = 0.0
    private(set) var cancelling = false
    private(set) var canContinueInBackground = false
    private(set) var capacity = StorageCapacity.read()
    private(set) var persistenceAvailable = true
    var preset: CompressionPreset = .balanced
    private(set) var encoding: VideoEncoding = .hevc
    var message: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var backgroundRun: CompressionBackgroundRun?
    @ObservationIgnored private var verifiedCopies: [UUID: VerifiedCopy] = [:]
    @ObservationIgnored private let store: QueueStore
    @ObservationIgnored private let selectVideo: VideoSelection
    @ObservationIgnored private var itemTask: Task<Void, Error>?
    @ObservationIgnored private var stoppedIDs: Set<UUID> = []
    @ObservationIgnored private var cancelledIDs: Set<UUID> = []
    private(set) var batchCompleted = 0
    private(set) var batchTotal = 0

    init(store: QueueStore = .live, selectVideo: @escaping VideoSelection = {
        try await PhotoLibrary.select($0, downloadProgress: $1)
    }) {
        self.store = store
        self.selectVideo = selectVideo
        do {
            jobs = try store.load()
            try store.save(jobs)
            try store.cleanUnfinishedFiles(keeping: jobs)
            preset = jobs.first(where: { $0.stage == .waiting })?.preset ?? .balanced
            encoding = jobs.first(where: { $0.stage == .waiting })?.standardEncoding ?? .hevc
            if !jobs.isEmpty { message = "已恢复 \(jobs.count) 条任务，可继续处理或复核成品。" }
        } catch {
            persistenceAvailable = false
            message = "队列记录暂时无法读取或保存。请检查可用空间后重新打开 App，已有成品已保留。"
        }
    }

    var isBusy: Bool { work != nil }
    var isDownloading: Bool { activeJobID.flatMap(job)?.stage == .downloading }
    var downloadCount: Int { jobs.filter { $0.stage == .awaitingDownload }.count }
    var waitingIDs: [UUID] { jobs.filter { $0.stage == .waiting && $0.directDeletion == nil }.map(\.id) }
    var readyIDs: [UUID] { jobs.filter { $0.stage == .ready }.map(\.id) }
    var failedIDs: [UUID] { jobs.filter { $0.stage == .failed && $0.copy == nil }.map(\.id) }
    func job(_ id: UUID) -> CompressionJob? { jobs.first { $0.id == id } }
    func canReplace(_ id: UUID) -> Bool { job(id)?.stage == .verified && verifiedCopies[id]?.canReplace == true }
    func refreshCapacity() {
        capacity = StorageCapacity.read()
        guard !isBusy, persistenceAvailable else { return }
        var next = jobs
        var changed = false
        for i in next.indices where next[i].directDeletion == .pending {
            if let photo = PhotoLibrary.fetch(next[i].original.identifier), next[i].original.matches(photo) {
                next[i].directDeletion = nil
                next[i].note = "原片仍可访问，可重新选择操作。"
                changed = true
            }
        }
        if changed { do { try commit(next) } catch { persistenceFailed(error) } }
    }

    @discardableResult
    func enqueue(_ photos: [PHAsset], preset selectedPreset: CompressionPreset? = nil,
                 encoding selectedEncoding: VideoEncoding? = nil,
                 professional: ProfessionalVideoSettings? = nil) -> [UUID] {
        guard !isBusy, persistenceAvailable else { return [] }
        if let professional, !ProfessionalPurchase.live.unlocked || professional.validation != nil {
            message = professional.validation ?? "请先解锁或恢复专业视频买断。"
            return []
        }
        let existing = Set(jobs.map { $0.original.identifier })
        var seen = existing
        let additions = photos.filter { seen.insert($0.localIdentifier).inserted }
            .map { photo in
                var job = CompressionJob(photo: photo, preset: selectedPreset ?? preset, encoding: selectedEncoding ?? encoding)
                job.professional = professional
                return job
            }
        do {
            try commit(jobs + additions)
            message = additions.isEmpty ? "选中的视频已在任务列表中。" : nil
            return additions.map(\.id)
        } catch { persistenceFailed(error); return [] }
    }

    func updatePreset(_ value: CompressionPreset, for id: UUID? = nil) {
        updatePendingJobs(for: id) { if $0.professional == nil { $0.preset = value } }
    }

    func updateEncoding(_ value: VideoEncoding, for id: UUID? = nil) {
        let updated = updatePendingJobs(for: id) { if $0.professional == nil { $0.outputEncoding = value } }
        if updated, id == nil { encoding = value }
    }

    func setProfessional(_ settings: ProfessionalVideoSettings?, for ids: Set<UUID>) {
        guard !isBusy, persistenceAvailable else { return }
        if let settings {
            guard ProfessionalPurchase.live.unlocked else { message = "请先解锁或恢复专业视频买断。"; return }
            if let reason = settings.validation { message = reason; return }
        }
        var updated = jobs
        let selected = updated.indices.filter { ids.contains(updated[$0].id) && updated[$0].canConfigureVideo }
        guard !selected.isEmpty else { return }
        for index in selected { updated[index].professional = settings; updated[index].note = nil }
        do { try commit(updated); message = nil } catch { persistenceFailed(error) }
    }

    @discardableResult
    private func updatePendingJobs(for id: UUID?, change: (inout CompressionJob) -> Void) -> Bool {
        guard !isBusy, persistenceAvailable else { return false }
        do {
            var updated = jobs
            for index in updated.indices where (id == nil || updated[index].id == id)
                && [.waiting, .awaitingDownload, .failed, .skipped].contains(updated[index].stage) {
                change(&updated[index])
            }
            try commit(updated)
            return true
        } catch {
            persistenceFailed(error)
            return false
        }
    }

    func compress(_ ids: [UUID]? = nil) {
        let targets = (ids ?? waitingIDs).filter { job($0)?.stage == .waiting && job($0)?.directDeletion == nil }
        startCompression(targets)
    }

    func downloadAndCompress(_ id: UUID) {
        guard job(id)?.stage == .awaitingDownload, job(id)?.directDeletion == nil else { return }
        startCompression([id], downloading: id)
    }

    func downloadAndCompressMany(_ ids: [UUID]) {
        let targets = ids.filter { (job($0)?.stage == .awaitingDownload || job($0)?.stage == .waiting) && job($0)?.directDeletion == nil }
        startCompression(targets, downloads: Set(targets))
    }

    private func startCompression(_ targets: [UUID], downloading: UUID? = nil, downloads: Set<UUID> = []) {
        guard !targets.isEmpty, !isBusy, persistenceAvailable else { return }
        stoppedIDs = []; cancelledIDs = []
        let authorizedDownloads = downloads.union(downloading.map { [$0] } ?? [])
        run(.compressing) { [self] in
            batchTotal = targets.count; batchCompleted = 0
            for (index, id) in targets.enumerated() {
                try Task.checkCancellation()
                if stoppedIDs.contains(id) { batchCompleted += 1; continue }
                if authorizedDownloads.contains(id), UIApplication.shared.applicationState == .background { throw CancellationError() }
                activeJobID = id
                progress = 0
                do {
                    let child = Task { try await self.compressOne(id, downloading: authorizedDownloads.contains(id), index: index, total: targets.count) }
                    itemTask = child
                    defer { itemTask = nil }
                    try await withTaskCancellationHandler { try await child.value } onCancel: { child.cancel() }
                } catch is CancellationError {
                    let interruptedDownload = authorizedDownloads.contains(id)
                    let cancelled = cancelledIDs.contains(id)
                    try update(id) {
                        $0.stage = cancelled ? .cancelled : interruptedDownload ? .awaitingDownload : .waiting
                        $0.note = cancelled ? "任务已取消，原片保留。" : "已暂停，可从这条视频重新处理。"
                    }
                    if Task.isCancelled { throw CancellationError() }
                } catch CompressionError.cloudOnly {
                    let bytes = job(id).flatMap { PhotoLibrary.fetch($0.original.identifier) }.flatMap(PhotoLibrary.reportedVideoSize)
                    try update(id) { $0.stage = .awaitingDownload; $0.sourceBytes = bytes; $0.note = nil }
                } catch CompressionError.noSavings(let original, let output) {
                    try update(id) {
                        $0.stage = .skipped
                        $0.note = CompressionError.noSavings(original: original, output: output).localizedDescription
                    }
                } catch CompressionError.unsupported(let reason) {
                    try update(id) { $0.stage = .skipped; $0.note = reason }
                } catch {
                    let interruptedDownload = isDownloading
                    try update(id) {
                        $0.stage = interruptedDownload ? .awaitingDownload : .failed
                        $0.note = error.localizedDescription
                    }
                    if !stoppedIDs.contains(id), case CompressionError.insufficientSpace = error { throw error }
                }
                if stoppedIDs.contains(id), job(id)?.output == nil, job(id)?.copy == nil {
                    let cancelled = cancelledIDs.contains(id)
                    try update(id) {
                        $0.stage = cancelled ? .cancelled : authorizedDownloads.contains(id) ? .awaitingDownload : .waiting
                        $0.note = cancelled ? "任务已取消，原片保留。" : "已暂停，可重新开始。"
                    }
                }
                backgroundRun?.report(completed: Double(index + 1))
                batchCompleted += 1
            }
        }
    }

    func stopSelected(_ ids: Set<UUID>, cancel: Bool) {
        guard !isBusy || work == .compressing else { return }
        let eligible = ids.filter { id in
            guard let job = job(id) else { return false }
            return [.waiting, .awaitingDownload, .processing, .downloading, .failed, .skipped].contains(job.stage)
                && job.output == nil && job.copy == nil
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
            if let id = activeJobID, eligible.contains(id) { itemTask?.cancel() }
        } catch { persistenceFailed(error) }
    }

    func retry(_ ids: [UUID]) {
        guard !isBusy, persistenceAvailable else { return }
        let eligible = ids.filter { id in
            guard let job = job(id) else { return false }
            return [.failed, .skipped].contains(job.stage) && job.copy == nil && job.output == nil && job.directDeletion == nil
        }
        do {
            var updated = jobs
            for index in updated.indices where eligible.contains(updated[index].id) {
                updated[index].stage = .waiting
                updated[index].note = nil
            }
            try commit(updated)
            compress(eligible)
        } catch { persistenceFailed(error) }
    }

    func cancelCompression() {
        guard work == .compressing else { return }
        cancelling = true
        canContinueInBackground = false
        backgroundRun?.cancelPending()
        task?.cancel()
    }

    func appDidEnterBackground() {
        if isDownloading || !canContinueInBackground { cancelCompression() }
    }

    func save(_ ids: [UUID]) {
        let targets = ids.filter { job($0)?.stage == .ready }
        guard !targets.isEmpty else { return }
        run(.saving) { [self] in
            for id in targets {
                activeJobID = id
                do { try await saveOne(id) }
                catch {
                    try update(id) { $0.note = error.localizedDescription }
                    if case CompressionError.insufficientSpace = error { throw error }
                }
            }
        }
    }

    func verify(_ ids: [UUID]) {
        run(.verifying) { [self] in
            for id in ids {
                activeJobID = id
                do { try await verifyOne(id) }
                catch { try update(id) { $0.note = "无法核验压缩件。请核对照片库或重试核验。" } }
            }
        }
    }

    func removeOriginals(_ ids: Set<UUID>, reverify: Bool = false) {
        guard !ids.isEmpty else { return }
        run(.replacing) { [self] in
            if reverify { for id in ids { try await verifyOne(id) } }
            let replacements = try ids.map { id -> OriginalReplacement in
                guard let job = job(id), job.stage == .verified, let copy = job.copy,
                      let verified = verifiedCopies[id], verified.canReplace else {
                    throw CompressionError.replacementUnavailable
                }
                return OriginalReplacement(original: job.original, copy: copy, verified: verified)
            }
            var updated = jobs
            for index in updated.indices where ids.contains(updated[index].id) { updated[index].stage = .removing }
            try commit(updated)
            do {
                try await PhotoLibrary.moveOriginalsToRecentlyDeleted(replacements)
            } catch {
                var reverted = jobs
                for index in reverted.indices where ids.contains(reverted[index].id) {
                    reverted[index].stage = .saved
                    reverted[index].note = "移除未完成，请重新核验并确认。"
                    verifiedCopies[reverted[index].id] = nil
                }
                try commit(reverted)
                throw error
            }
            var completed = jobs
            for index in completed.indices where ids.contains(completed[index].id) {
                completed[index].stage = .removed
                completed[index].note = nil
                verifiedCopies[completed[index].id] = nil
            }
            try commit(completed)
            for job in completed where ids.contains(job.id) { store.removeMedia(for: job) }
        }
    }

    func keepOriginal(_ id: UUID) {
        guard !isBusy, let completed = job(id), completed.stage == .verified else { return }
        do {
            try update(id) { $0.stage = .kept; $0.note = nil }
            verifiedCopies[id] = nil
            store.removeMedia(for: completed)
            refreshCapacity()
        } catch { persistenceFailed(error) }
    }

    func discard(_ id: UUID) {
        guard !isBusy, let old = job(id) else { return }
        do {
            try commit(jobs.filter { $0.id != id })
            verifiedCopies[id] = nil
            store.removeFiles(for: old)
        } catch { persistenceFailed(error) }
    }

    private func compressOne(_ id: UUID, downloading: Bool, index: Int, total: Int) async throws {
        guard let queued = job(id) else { return }
        if queued.professional != nil, !ProfessionalPurchase.live.unlocked {
            throw CompressionError.unsupported("这条任务使用专业参数。请恢复购买，或将任务切回标准参数。")
        }
        try update(id) { $0.stage = downloading ? .downloading : .processing; $0.note = nil }
        guard let photo = PhotoLibrary.fetch(queued.original.identifier) else { throw CompressionError.originalUnavailable }
        var downloadProgress: (@MainActor (Double) -> Void)?
        if downloading {
            downloadProgress = { [weak self] value in
                guard let self, self.activeJobID == id, self.isDownloading, !self.cancelling else { return }
                self.progress = max(self.progress, value)
                self.refreshCapacity()
            }
        }
        let selection = try await selectVideo(photo, downloadProgress)
        try Task.checkCancellation()
        try update(id) {
            $0.stage = .processing
            $0.original = PhotoSnapshot(selection.photo)
            $0.sourceBytes = selection.source.bytes
            $0.sourceSize = selection.source.displaySize
        }
        progress = 0
        if backgroundRun == nil, #available(iOS 26.0, *), UIApplication.shared.applicationState == .active {
            let background = CompressionBackgroundRun(total: total, onAccepted: { [weak self] in
                self?.canContinueInBackground = true
            }, onExpiration: { [weak self] in self?.cancelCompression() })
            backgroundRun = background
            background.start()
        }
        backgroundRun?.report(completed: Double(index))
        let output = try await VideoCompression.compress(selection.source, preset: queued.preset,
                                                         encoding: queued.encoding, professional: queued.professional) { [weak self] value in
            self?.progress = value
            self?.backgroundRun?.report(completed: Double(index) + value)
        }
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: output.url)
            throw CancellationError()
        }
        try update(id) { $0.output = OutputRecord(output); $0.stage = .ready }
    }

    private func saveOne(_ id: UUID) async throws {
        guard let job = job(id), let record = job.output else { return }
        if let previous = try store.receipt(for: id) {
            try update(id) { $0.copy = previous; $0.stage = .savePending }
            try await verifyOne(id)
            return
        }
        let output = try record.video()
        if !FileManager.default.fileExists(atPath: output.url.path) {
            try update(id) { $0.output = nil; $0.stage = .failed }
            throw CompressionError.invalidOutput
        }
        try update(id) { $0.stage = .saving; $0.note = nil }
        let copy: SavedCopy
        do {
            let store = self.store
            copy = try await PhotoLibrary.save(output, original: job.original) { receipt in
                try store.writeReceipt(receipt, for: id)
            }
        } catch CompressionError.invalidOutput {
            try update(id) { $0.output = nil; $0.stage = .failed }
            store.removeMedia(for: job)
            throw CompressionError.invalidOutput
        } catch {
            store.removeReceipt(for: id)
            try update(id) { $0.stage = .ready }
            throw error
        }
        try update(id) { $0.copy = copy; $0.stage = .saved }
        try await verifyOne(id)
    }

    private func verifyOne(_ id: UUID) async throws {
        guard let job = job(id), let copy = job.copy, let output = job.output else {
            throw CompressionError.copyNotVerified
        }
        // Downgrade the durable status before verification, so a failed recheck cannot retain deletion eligibility.
        if job.stage == .verified {
            try update(id) { $0.stage = .saved }
        }
        verifiedCopies[id] = nil
        let verified = try await PhotoLibrary.verify(copy, video: output.video(), original: job.original)
        if job.stage == .removalPending, !verified.canReplace {
            try update(id) { $0.note = "上次移除未收到系统确认，请在「照片」中核对原片和「最近删除」。" }
        } else {
            try update(id) {
                $0.stage = .verified
                $0.note = verified.canReplace || output.format?.requiresCopy == true
                    ? nil : "压缩件已核验。当前无法核对原片替换条件。"
            }
            verifiedCopies[id] = verified
        }
    }

    private func update(_ id: UUID, change: (inout CompressionJob) -> Void) throws {
        var updated = jobs
        guard let index = updated.firstIndex(where: { $0.id == id }) else { throw CompressionError.originalUnavailable }
        change(&updated[index])
        try commit(updated)
    }

    private func commit(_ updated: [CompressionJob]) throws {
        guard persistenceAvailable else { throw CocoaError(.fileWriteUnknown) }
        do { try store.save(updated) }
        catch { persistenceFailed(error); throw error }
        jobs = updated
    }

    private func persistenceFailed(_ error: Error) {
        persistenceAvailable = false
        message = "队列记录暂时无法保存。请检查可用空间后重新打开 App，已有成品已保留。"
    }

    private func run(_ phase: Work, operation: @escaping @MainActor () async throws -> Void) {
        guard !isBusy, persistenceAvailable else { return }
        work = phase
        message = nil
        task = Task { [self] in
            var succeeded = false
            defer {
                backgroundRun?.finish(success: succeeded && !Task.isCancelled)
                backgroundRun = nil
                canContinueInBackground = false
                work = nil
                activeJobID = nil
                task = nil
                cancelling = false
                refreshCapacity()
            }
            do { try await operation(); succeeded = true }
            catch is CancellationError { message = "已暂停队列，完成的成品可继续复核。" }
            catch {
                if persistenceAvailable { message = error.localizedDescription }
            }
        }
    }
}

extension CompressionSession: BatchTaskSession {
    var batchItems: [BatchTaskItem] { jobs.map(makeBatchItem) }
    func batchItem(_ id: UUID) -> BatchTaskItem? { job(id).map(makeBatchItem) }
    private func makeBatchItem(_ job: CompressionJob) -> BatchTaskItem {
        BatchTaskItem(id: job.id, original: job.original, stage: job.stage, hasOutput: job.output != nil,
                      hasCopy: job.copy != nil, copyOnly: job.output?.format?.requiresCopy == true,
                      directDeletion: job.directDeletion, note: job.note, professionalSummary: job.professional?.summary)
    }
    var batchBusy: Bool { isBusy }
    var batchInterruptible: Bool { work == .compressing }
    var batchVideo: Bool { true }
    func execute(_ action: TaskBatchAction, ids: [UUID]) {
        let targets = batchItems.filter { ids.contains($0.id) && $0.reason(for: action, busy: isBusy, interruptible: batchInterruptible, video: true) == nil }.map(\.id)
        guard !targets.isEmpty else { message = "当前没有符合操作条件的任务。"; return }
        switch action {
        case .start: compress(targets)
        case .download: downloadAndCompressMany(targets)
        case .save: save(targets)
        case .verify: verify(targets)
        case .replace: removeOriginals(Set(targets), reverify: true)
        case .pause: stopSelected(Set(targets), cancel: false)
        case .cancel: stopSelected(Set(targets), cancel: true)
        case .retry:
            do {
                var next = jobs
                for i in next.indices where targets.contains(next[i].id) { next[i].stage = .waiting; next[i].note = nil }
                try commit(next); compress(targets)
            } catch { persistenceFailed(error) }
        case .discard:
            do {
                let removed = jobs.filter { targets.contains($0.id) }
                try commit(jobs.filter { !targets.contains($0.id) })
                for job in removed { verifiedCopies[job.id] = nil; store.removeFiles(for: job) }
                refreshCapacity()
            } catch { persistenceFailed(error) }
        case .deleteOriginal, .export: break
        }
    }
    func recordDirectDeletion(_ snapshots: [PhotoSnapshot], state: CompressionJob.DirectDeletion) throws {
        guard !isBusy else { throw CompressionError.replacementUnavailable }
        let originals = Set(snapshots.map(\.identifier))
        var next = jobs
        for i in next.indices where originals.contains(next[i].original.identifier) {
            next[i].directDeletion = state
            if state == .removed, next[i].output == nil { next[i].stage = .cancelled }
            next[i].note = state == .removed ? "原片已直接删除，等待系统清理。" : "直接删除结果待核对，请在系统照片库检查原片。"
            verifiedCopies[next[i].id] = nil
        }
        try commit(next)
        refreshCapacity()
    }
}

@MainActor
private final class CompressionBackgroundRun {
    private let identifier = (Bundle.main.bundleIdentifier ?? "com.wuyuchen.disquez") + ".compression." + UUID().uuidString
    private let total: Int
    private let onAccepted: () -> Void
    private let onExpiration: () -> Void
    private var systemTask: BGTask?
    private var completed = 0.0
    private var finished = false
    private var cancelled = false

    init(total: Int, onAccepted: @escaping () -> Void, onExpiration: @escaping () -> Void) {
        self.total = total
        self.onAccepted = onAccepted
        self.onExpiration = onExpiration
    }

    @available(iOS 26.0, *)
    func start() {
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self, !self.finished, !self.cancelled, let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.systemTask = task
                task.progress.totalUnitCount = Int64(self.total) * 1_000
                task.expirationHandler = { [weak self] in
                    Task { @MainActor in
                        guard let self, !self.finished, !self.cancelled else { return }
                        self.onExpiration()
                    }
                }
                self.report(completed: self.completed)
                self.onAccepted()
            }
        }
        guard registered else { return }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "压缩视频", subtitle: "共 \(total) 条视频")
        request.strategy = .fail
        Task {
            guard !finished, !cancelled, UIApplication.shared.applicationState == .active else { return }
            do {
                if #available(iOS 27.0, *) { try await BGTaskScheduler.shared.submitTaskRequest(request) }
                else { try BGTaskScheduler.shared.submit(request) }
            } catch {
                // Foreground processing continues when the system cannot grant background time.
            }
            if finished || cancelled { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
        }
    }

    func report(completed: Double) {
        guard !finished, !cancelled, completed.isFinite else { return }
        self.completed = min(Double(total), max(self.completed, completed))
        if #available(iOS 26.0, *), let task = systemTask as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = Int64(self.completed * 1_000)
        }
    }

    func cancelPending() {
        cancelled = true
        if systemTask == nil { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
    }

    func finish(success: Bool) {
        guard !finished else { return }
        finished = true
        systemTask?.expirationHandler = nil
        systemTask?.setTaskCompleted(success: success)
        systemTask = nil
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}
