import Observation
import Photos

struct ArchiveSelection: Identifiable {
    let id: UUID
    let name: String
    let file: FileCandidate?
    let photo: PhotoSnapshot?
    let protection: String?
}

@MainActor @Observable
final class ArchiveSession {
    private(set) var selections: [ArchiveSelection] = []
    private(set) var records: [ArchiveRecord] = []
    private(set) var busy = false
    private(set) var cancellable = false
    private(set) var healthy = true
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var progress: Double?
    var message: String?
    @ObservationIgnored let store: ArchiveStore
    @ObservationIgnored private var task: Task<Void, Never>?
    init(store: ArchiveStore = .live) {
        self.store = store
        do { records = try store.load(); try store.save(records); try store.cleanStaging() }
        catch { healthy = false; message = "归档清单无法读取或保存，已有归档和临时原件已保留。请检查空间后重开 App。" }
    }
    func record(_ id: UUID) -> ArchiveRecord? { records.first { $0.id == id } }
    static func reference(_ url: URL) throws -> FileReference {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard scoped || FileAccess.isInsideDocuments(url) else { throw ArchiveError.destination }
        return try FileReference(root: url, child: url)
    }
    func addFiles(_ urls: [URL]) {
        run(cancellable: true) {
            let result = try await FileAccess.scan(urls)
            self.selections = result.files.map { ArchiveSelection(id: $0.id, name: $0.name, file: $0, photo: nil, protection: nil) }
            self.message = "已读取 \(result.files.count) 个文件，\(result.unreadable) 项无法访问。" + (result.truncated ? "已达 5000 项上限，请选择更小目录。" : "")
        }
    }
    func addPhotos(_ assets: [PHAsset]) {
        guard !busy else { return }
        message = nil
        selections = assets.map { photo in
            ArchiveSelection(id: UUID(), name: PHAssetResource.assetResources(for: photo).first?.originalFilename ?? "原片",
                             file: nil, photo: PhotoSnapshot(photo), protection: MediaLibrary.protectionReason(photo))
        }
    }
    func create(_ ids: Set<UUID>, parent: URL, allowNetwork: Bool) {
        let selected = selections.filter { ids.contains($0.id) && $0.protection == nil }
        guard !selected.isEmpty, selected.count <= 5_000 else { message = "请选择 1 至 5000 项可归档原件。"; return }
        let reference: FileReference
        do { reference = try Self.reference(parent) } catch { message = error.localizedDescription; return }
        run(cancellable: true) {
            let id = UUID(), directory = try self.staging()
            defer { try? FileManager.default.removeItem(at: directory) }
            self.total = selected.count; self.completed = 0
            var entries: [ArchiveEntry] = [], states: [ArchiveItemState] = [], sources: [UUID: URL] = [:]
            for selection in selected {
                try Task.checkCancellation(); self.progress = nil
                let ext = (selection.name as NSString).pathExtension
                let safeExtension = ext.isEmpty || !ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) ? "original" : ext
                let name = UUID().uuidString + "." + safeExtension
                let target = directory.appending(path: name)
                let entry: ArchiveEntry
                if let file = selection.file {
                    let read = try await FileAccess.coordinated(file.reference) { url, cancel -> (ResourceDigest, Date?, Date?) in
                        let before = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey, .isRegularFileKey])
                        guard before.isRegularFile == true,
                              file.modified == nil || file.modified == before.contentModificationDate,
                              file.bytes == nil || file.bytes == before.fileSize.map(Int64.init) else { throw ArchiveError.changed }
                        let digest = try FileAccess.copy(url, to: target, cancellation: cancel)
                        let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                        guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else { throw ArchiveError.changed }
                        return (digest, before.creationDate, before.contentModificationDate)
                    }
                    entry = ArchiveEntry(id: selection.id, name: selection.name, fileName: name, kind: .file, digest: read.0, created: read.1, modified: read.2, photo: nil, albums: [], relativePath: file.reference.relativePath)
                } else if let snapshot = selection.photo {
                    let photo = try ArchiveLibrary.current(snapshot), albums = ArchiveLibrary.albums(photo)
                    let resource = try MediaLibrary.resource(photo)
                    let download: (@MainActor (Double) -> Void)?
                    if allowNetwork { download = { value in self.progress = value } }
                    else { download = nil }
                    let digest = try await MediaResourceRead.read(resource, to: target, progress: download)
                    let latest = try ArchiveLibrary.current(snapshot)
                    guard ArchiveLibrary.albums(latest) == albums else { throw ArchiveError.changed }
                    entry = ArchiveEntry(id: selection.id, name: selection.name, fileName: name, kind: photo.mediaType == .video ? .video : .photo, digest: digest, created: snapshot.creationDate, modified: snapshot.modificationDate, photo: snapshot, albums: albums)
                } else { throw ArchiveError.invalid }
                guard try await ArchiveIO.digest(target) == entry.digest else { throw ArchiveError.invalid }
                entries.append(entry); sources[entry.id] = target
                states.append(ArchiveItemState(id: entry.id, fileOrigin: selection.file?.reference, photoOrigin: selection.photo))
                self.completed += 1
            }
            let manifest = ArchiveManifest(version: 1, id: id, created: .now, entries: entries)
            try manifest.validate(); try Task.checkCancellation()
            let location = try await ArchiveIO.createFolder(parent: reference, manifest: manifest)
            let record = ArchiveRecord(manifest: manifest, location: location, locationName: parent.lastPathComponent, states: states)
            try self.commit(self.records + [record])
            do {
                try await ArchiveIO.write(manifest, sources: sources, to: location)
                let destination = try await ArchiveIO.verify(manifest, at: location)
                try self.change(id) { $0.stage = .verified; $0.destination = destination; $0.verifiedAt = .now; $0.note = "已重新读取并核对全部原件，源文件保留。" }
                self.message = "归档完成，\(entries.count) 项原件已回读核验。源文件尚未移除。"
            } catch {
                try self.change(id) { $0.stage = .needsVerification; $0.verifiedAt = nil; $0.note = "归档未完成或校验中断，源文件保留；请重新核验。" }
                throw error
            }
        }
    }
    func verify(_ id: UUID) {
        guard let record = record(id) else { return }
        run(cancellable: true) { try await self.verifyRecord(record) }
    }
    private func verifyRecord(_ record: ArchiveRecord) async throws {
        try change(record.id) { $0.stage = .needsVerification; $0.verifiedAt = nil }
        let status = try await ArchiveIO.verify(record.manifest, at: record.location)
        try change(record.id) { $0.stage = .verified; $0.destination = status; $0.verifiedAt = .now; $0.note = "全部归档内容已重新读取核验。" }
    }
    func connect(_ url: URL) {
        let reference: FileReference
        do { reference = try Self.reference(url) } catch { message = error.localizedDescription; return }
        run(cancellable: true) {
            let manifest = try await ArchiveIO.readManifest(reference)
            if let existing = self.record(manifest.id) {
                guard existing.manifest == manifest else { throw ArchiveError.changed }
                try self.change(manifest.id) { $0.location = reference; $0.locationName = url.lastPathComponent; $0.stage = .needsVerification; $0.verifiedAt = nil }
            } else {
                let states = manifest.entries.map { ArchiveItemState(id: $0.id) }
                try self.commit(self.records + [ArchiveRecord(manifest: manifest, location: reference, locationName: url.lastPathComponent, states: states)])
            }
            if let record = self.record(manifest.id) { try await self.verifyRecord(record) }
        }
    }
    func removalReason(_ record: ArchiveRecord, item: ArchiveEntry) -> String? {
        guard record.stage == .verified else { return "请先重新读取核验归档" }
        guard record.destination.permitsRemoval else { return record.destination.label }
        guard let state = record.states.first(where: { $0.id == item.id }), state.removal == .present else { return "原件已移除或结果待核对" }
        if let file = state.fileOrigin {
            return (try? file.withAccess { FileAccess.canReplace($0) && ArchiveIO.originalInfoMatches(item, url: $0) }) == true ? nil : "原文件已变化，或不在 DisquEZ 本机可写文档目录内"
        }
        if state.photoOrigin != nil { return ArchiveLibrary.removalReason(item, state: state) }
        return "此清单没有本机原件关联，只提供恢复"
    }
    func remove(_ id: UUID, entries ids: Set<UUID>) {
        guard let record = record(id) else { return }
        let entries = record.manifest.entries.filter { ids.contains($0.id) }
        guard !entries.isEmpty, entries.allSatisfy({ removalReason(record, item: $0) == nil }) else { message = "部分原件不能安全移除，请逐项复核。"; return }
        run {
            // Re-read target and current originals for this exact confirmation. Never reuse a previous check.
            try await self.verifyRecord(record)
            guard let latest = self.record(id), latest.destination.permitsRemoval else { throw ArchiveError.notExternal }
            for entry in entries {
                guard let state = latest.states.first(where: { $0.id == entry.id }), self.removalReason(latest, item: entry) == nil else { throw ArchiveError.changed }
                if let file = state.fileOrigin {
                    try await FileAccess.coordinated(file) { url, cancel in
                        guard ArchiveIO.originalInfoMatches(entry, url: url), try FileAccess.digest(url, cancellation: cancel) == entry.digest else { throw ArchiveError.changed }
                    }
                } else if let photo = state.photoOrigin { try await ArchiveLibrary.originalMatches(entry, snapshot: photo) }
            }
            let photos = entries.compactMap { entry -> (ArchiveEntry, ArchiveItemState)? in
                guard let state = latest.states.first(where: { $0.id == entry.id }), state.photoOrigin != nil else { return nil }
                return (entry, state)
            }
            do {
                if !photos.isEmpty {
                    try self.change(id) { record in for i in record.states.indices where photos.contains(where: { $0.0.id == record.states[i].id }) { record.states[i].removal = .removing } }
                    try await ArchiveLibrary.remove(photos)
                    try self.change(id) { record in for i in record.states.indices where photos.contains(where: { $0.0.id == record.states[i].id }) { record.states[i].removal = .removed } }
                }
                for entry in entries where entry.kind == .file {
                    guard let state = latest.states.first(where: { $0.id == entry.id }), let reference = state.fileOrigin else { throw ArchiveError.changed }
                    try self.item(id, entry.id) { $0.removal = .removing }
                    try await FileAccess.coordinated(reference, writing: true, writingOptions: .forDeleting) { url, cancel in
                        guard FileAccess.canReplace(url), ArchiveIO.originalInfoMatches(entry, url: url),
                              try FileAccess.digest(url, cancellation: cancel) == entry.digest else { throw ArchiveError.changed }
                        try FileManager.default.removeItem(at: url)
                    }
                    try self.item(id, entry.id) { $0.removal = .removed }
                }
                self.message = "所选原件已处理。照片库原件进入「最近删除」，本机可用空间以系统读数为准。"
            } catch {
                try self.change(id) { record in for i in record.states.indices where record.states[i].removal == .removing { record.states[i].removal = .pending } }
                throw error
            }
        }
    }
    func restorePhoto(_ id: UUID, entry entryID: UUID) {
        guard let record = record(id), let entry = record.manifest.entries.first(where: { $0.id == entryID }), entry.kind != .file,
              let state = record.states.first(where: { $0.id == entryID }), state.restoration == .none else { return }
        run {
            let directory = try self.staging(); defer { try? FileManager.default.removeItem(at: directory) }
            let sources = try await ArchiveIO.stage([entry], from: record, directory: directory)
            guard let source = sources[entry.id] else { throw ArchiveError.invalid }
            try self.item(id, entryID) { $0.restoration = .restoring }
            do {
                let copy = try await ArchiveLibrary.restore(entry, source: source, store: self.store, record: id)
                try self.item(id, entryID) { $0.restoredCopy = copy; $0.restoration = .pending }
                try await ArchiveLibrary.verifyRestored(copy, entry: entry)
                try self.item(id, entryID) { $0.restoration = .restored; $0.note = "原始内容已恢复并回读核验，缺失或不可写相簿不会自动重建。" }
            } catch { try self.item(id, entryID) { $0.restoration = .pending }; throw error }
        }
    }
    func recheck(_ id: UUID, entry entryID: UUID) {
        guard let record = record(id), let entry = record.manifest.entries.first(where: { $0.id == entryID }),
              let state = record.states.first(where: { $0.id == entryID }) else { return }
        run(cancellable: true) {
            if state.restoration == .pending {
                guard let copy = try state.restoredCopy ?? self.store.receipt(id, entryID) else { throw ArchiveError.restorePending }
                try await ArchiveLibrary.verifyRestored(copy, entry: entry)
                try self.item(id, entryID) { $0.restoredCopy = copy; $0.restoration = .restored }
            } else if state.removal == .pending {
                if let reference = state.fileOrigin {
                    try await FileAccess.coordinated(reference) { url, cancel in
                        guard ArchiveIO.originalInfoMatches(entry, url: url), try FileAccess.digest(url, cancellation: cancel) == entry.digest else { throw ArchiveError.changed }
                    }
                } else if let photo = state.photoOrigin { try await ArchiveLibrary.originalMatches(entry, snapshot: photo) }
                else { throw ArchiveError.changed }
                try self.item(id, entryID) { $0.removal = .present }
            }
        }
    }
    func export(_ id: UUID, entries ids: Set<UUID>) async throws -> [URL] {
        guard let record = record(id), !busy, healthy else { throw ArchiveError.destination }
        busy = true
        defer { busy = false }
        let items = record.manifest.entries.filter { ids.contains($0.id) }
        let directory = try staging(); defer { try? FileManager.default.removeItem(at: directory) }
        let sources = try await ArchiveIO.stage(items, from: record, directory: directory)
        return try await ArchiveIO.exports(items, sources: sources)
    }
    func cancel() { if cancellable { task?.cancel() } }
    private func staging() throws -> URL {
        try store.prepare()
        let url = store.staging.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    private func commit(_ next: [ArchiveRecord]) throws {
        guard healthy else { throw ArchiveError.invalid }
        do { try store.save(next); records = next }
        catch { healthy = false; message = "归档清单保存失败，已有归档保留。"; throw error }
    }
    private func change(_ id: UUID, _ operation: (inout ArchiveRecord) -> Void) throws {
        var next = records; guard let i = next.firstIndex(where: { $0.id == id }) else { throw ArchiveError.invalid }
        operation(&next[i]); try commit(next)
    }
    private func item(_ id: UUID, _ entry: UUID, _ operation: (inout ArchiveItemState) -> Void) throws {
        try change(id) { record in if let i = record.states.firstIndex(where: { $0.id == entry }) { operation(&record.states[i]) } }
    }
    private func run(cancellable: Bool = false, _ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy, healthy else { return }
        busy = true; self.cancellable = cancellable; message = nil; completed = 0; total = 0
        task = Task {
            defer { self.busy = false; self.cancellable = false; self.task = nil; self.progress = nil }
            do { try await operation() }
            catch is CancellationError { self.message = "已停止，已有归档保留；未完成归档需重新核验。" }
            catch { if self.healthy { self.message = error.localizedDescription } }
        }
    }
}
