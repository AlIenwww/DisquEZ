import Observation
import Photos

@MainActor @Observable
final class SpacePlanner {
    private(set) var preferences = SpacePreferences()
    private(set) var options: [SpaceProposal] = []
    private(set) var scanning = false
    private(set) var progress = 0.0
    private(set) var status = ""
    private(set) var ready = false
    private(set) var healthy = true
    private(set) var capacity = StorageCapacity.read()
    var message: String?
    @ObservationIgnored private let store: SpacePreferenceStore
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var authorization: PHAuthorizationStatus?

    init(store: SpacePreferenceStore = .live) {
        self.store = store
        do { preferences = try store.load() }
        catch { healthy = false; message = "清单偏好无法读取，已有记录保留。" }
    }

    var plan: SpacePlan { SpacePlan.make(options, preferences: preferences) }

    func update(_ change: (inout SpacePreferences) -> Void) {
        guard healthy, !scanning else { return }
        var next = preferences
        change(&next)
        guard next.valid else { message = "空间目标须为 1–1000000 MB。"; return }
        do {
            try store.save(next)
            if next.excludeFavorites != preferences.excludeFavorites || next.albumIDs != preferences.albumIDs
                || next.scanLimit != preferences.scanLimit {
                options = []
                ready = false
                message = "筛选已更新，请重新扫描。"
            } else { message = nil }
            let oldIgnored = Set(preferences.ignored.map(\.id))
            if !oldIgnored.isSubset(of: Set(next.ignored.map(\.id))) {
                ready = false
                options = []
                message = "已重新纳入，下一次扫描会检查这些素材。"
            }
            preferences = next
        } catch { message = "无法保存清单偏好。请检查本机空间后重试。" }
    }

    func ignore(_ proposal: SpaceProposal) {
        update { preferences in
            let existing = Set(preferences.ignored.map(\.id))
            let titles = Dictionary(uniqueKeysWithValues: proposal.members.map { (SpaceRestrictions.photoKey($0.id), Self.title($0)) })
            preferences.ignored += proposal.keys.subtracting(existing).sorted().map {
                SpaceIgnored(id: $0, title: titles[$0] ?? proposal.title)
            }
        }
    }

    func refreshAccess() {
        capacity = StorageCapacity.read()
        if let authorization, authorization != PhotoLibrary.access {
            cancel()
            options.removeAll { !$0.members.isEmpty }
            ready = false
            message = "照片访问范围已变化，请重新扫描。"
        }
    }

    func cancel() { task?.cancel() }

    func current(_ member: MediaMember) -> PHAsset? {
        guard authorization == PhotoLibrary.access, let photo = PhotoLibrary.fetch(member.id),
              member.snapshot.matches(photo), preferences.restrictions.allows(photo) else { return nil }
        return photo
    }

    func finishedReview(_ proposal: SpaceProposal, videos: CompressionSession, photos: PhotoSession, files: FileSession) {
        capacity = StorageCapacity.read()
        if proposal.members.contains(where: { current($0) == nil }) {
            options.removeAll { !$0.keys.isDisjoint(with: proposal.keys) }
            message = "素材已变化，已从当前清单移除。可重新扫描更新收益。"
        } else if case .file(let id) = proposal.route, files.job(id)?.stage != .ready {
            options.removeAll { !$0.keys.isDisjoint(with: proposal.keys) }
        } else if case .video(let member) = proposal.route,
                  videos.jobs.contains(where: { $0.original.identifier == member.id && $0.stage.isClosed }) {
            options.removeAll { !$0.keys.isDisjoint(with: proposal.keys) }
        } else if case .photo(let member) = proposal.route,
                  photos.jobs.contains(where: { $0.original.identifier == member.id && $0.stage.isClosed }) {
            options.removeAll { !$0.keys.isDisjoint(with: proposal.keys) }
        }
    }

    static func albums() -> [SpaceAlbum] {
        guard PhotoLibrary.access == .authorized else { return [] }
        let found = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        return (0..<found.count).map { index in
            let album = found.object(at: index)
            return SpaceAlbum(id: album.localIdentifier, title: album.localizedTitle ?? "未命名相簿")
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func scan(videos: CompressionSession, photos: PhotoSession, files: FileSession, archives: ArchiveSession) {
        guard !scanning, healthy else { return }
        let preferences = self.preferences
        let restrictions = preferences.restrictions
        scanning = true
        ready = false
        options = []
        message = nil
        status = "准备扫描"
        progress = 0
        task = Task {
            defer { scanning = false; task = nil; capacity = StorageCapacity.read() }
            do {
                let access = PhotoLibrary.access == .notDetermined
                    ? await PHPhotoLibrary.requestAuthorization(for: .readWrite) : PhotoLibrary.access
                try Task.checkCancellation()
                authorization = access
                let fileOptions = fileProposals(files)
                guard PhotoLibrary.canRead, access == .authorized || restrictions.albumIDs.isEmpty else {
                    options = fileOptions
                    ready = true
                    message = PhotoLibrary.canRead ? "有限访问下无法核对指定相簿，照片库建议暂停。" : "未取得照片库访问，只显示已核验的文件任务。"
                    return
                }
                let assets = await Self.scannableAssets(limit: preferences.scanLimit, restrictions: restrictions)
                let result = try await MediaAnalysis.scan(assets) { done, total, label in
                    self.status = "\(label) \(done)/\(total)"
                    self.progress = total == 0 ? 0 : 0.55 * Double(done) / Double(total)
                }
                let photoOptions = try await photoProposals(result, videos: videos, photos: photos, archives: archives)
                try Task.checkCancellation()
                guard access == PhotoLibrary.access else { throw CompressionError.noPermission }
                options = photoOptions + fileOptions
                ready = true
                progress = 1
                let excluded = preferences.scanLimit - assets.count
                message = "已检查 \(assets.count) 项照片库素材。\(result.protectedCount) 项受保护，\(result.cloudCount) 项仅在 iCloud，\(result.unreadableCount) 项未读取。"
                if access == .limited { message? += " 当前只扫描获准访问的素材。" }
                if excluded == 0 { message? += " 本次已达扫描范围上限。" }
            } catch is CancellationError { message = "已停止扫描，可重新开始。" }
            catch { message = error.localizedDescription }
        }
    }

    private nonisolated static func scannableAssets(limit: Int, restrictions: SpaceRestrictions) async -> [PHAsset] {
        let options = PHFetchOptions()
        options.fetchLimit = limit
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let favorites = restrictions.excludeFavorites ? " AND favorite == NO" : ""
        options.predicate = NSPredicate(format: "(mediaType == 1 OR mediaType == 2)" + favorites)
        let fetched = PHAsset.fetchAssets(with: options)
        var result: [PHAsset] = []
        for i in 0..<fetched.count {
            if Task.isCancelled { return [] }
            let asset = fetched.object(at: i)
            if restrictions.allows(asset) { result.append(asset) }
        }
        return result
    }

    private func photoProposals(_ result: MediaScanResult, videos: CompressionSession, photos: PhotoSession,
                                archives: ArchiveSession) async throws -> [SpaceProposal] {
        let videoJobs = Dictionary(videos.jobs.map { ($0.original.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        let photoJobs = Dictionary(photos.jobs.map { ($0.original.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        let savedCopies = Set(videos.jobs.compactMap { $0.copy?.identifier } + photos.jobs.compactMap { $0.copy?.identifier })
        let members = result.members.filter { !savedCopies.contains($0.id) && current($0) != nil }
        let liveIDs = Set(members.map(\.id))
        let duplicates = result.groups.compactMap { group -> SpaceProposal? in
            let candidates = group.members.filter { liveIDs.contains($0.id) }
            guard candidates.count > 1 else { return nil }
            let group = MediaGroup(kind: group.kind, members: candidates)
            let keys = Set(candidates.map { SpaceRestrictions.photoKey($0.id) })
            let removable = PhotoLibrary.access == .authorized && candidates.allSatisfy { member in
                guard let photo = current(member) else { return false }
                return photo.canPerform(.delete) && photo.sourceType == .typeUserLibrary
            }
            let estimate = group.kind == .exact && removable ? SpacePlan.duplicateBytes(candidates) : nil
            let note = group.kind == .exact ? "预留一项保留件，具体移除范围由你复核。" : "逐张核对相似照片，复核前不估算收益。"
            return SpaceProposal(id: "group:" + keys.sorted().joined(separator: "|"), action: .duplicates,
                                 title: "\(group.kind.rawValue) · \(candidates.count) 项", note: note,
                                 keys: keys, bytes: estimate, route: .group(group))
        }
        var proposals = duplicates
        var verifiedArchives: [String: (ArchiveRecord, ArchiveEntry)] = [:]
        for record in archives.records.reversed() where record.stage == .verified && record.destination.permitsRemoval {
            let entries = Dictionary(uniqueKeysWithValues: record.manifest.entries.map { ($0.id, $0) })
            for state in record.states where state.removal == .present {
                guard let origin = state.photoOrigin, let entry = entries[state.id],
                      verifiedArchives[origin.identifier] == nil else { continue }
                verifiedArchives[origin.identifier] = (record, entry)
            }
        }

        for (index, member) in members.enumerated() {
            try Task.checkCancellation()
            status = "估算收益 \(index + 1)/\(members.count)"
            progress = 0.55 + 0.45 * Double(index) / Double(max(1, members.count))
            guard let photo = current(member) else { continue }
            if let (record, entry) = verifiedArchives[member.id], entry.digest == member.digest,
               archives.removalReason(record, item: entry) == nil {
                proposals.append(Self.proposal(member, action: .archive, bytes: entry.digest.bytes,
                    note: "已有核验归档，处理前仍会重新读取目标和原件。", route: .archive(record.id, entry.id, member)))
            } else {
                let removable = PhotoLibrary.access == .authorized && photo.sourceType == .typeUserLibrary
                    && photo.creationDate != nil && photo.canPerform(.delete) && ArchiveLibrary.hasRestorableAlbums(photo)
                proposals.append(Self.proposal(member, action: .archive, bytes: removable ? member.digest.bytes : nil,
                    note: "完整归档后需确认外接盘或云端同步，才能另行复核原件。", route: .newArchive(member)))
            }
            if member.isVideo {
                if let job = videoJobs[member.id], job.stage.isClosed || job.directDeletion != nil { continue }
                let original = member.snapshot
                guard PhotoLibrary.replaceableAlbums(for: original) != nil else { continue }
                let existing = videoJobs[member.id]
                if let output = existing?.output {
                    guard existing?.original == original, output.format?.requiresCopy != true else { continue }
                    proposals.append(Self.proposal(member, action: .compression, bytes: Self.gain(member.digest.bytes, output.bytes),
                        note: "已有成品，核对后可进入原片处理流程。", route: .video(member)))
                } else {
                    guard existing?.professional == nil, (existing?.standardEncoding ?? videos.encoding) == .hevc else { continue }
                    let item = CatalogVideo(id: member.id, created: photo.creationDate, revision: PhotoLibrary.catalogRevision(photo), resourceBytes: member.digest.bytes)
                    if case .local(let bytes, _, let estimate) = try await PhotoLibrary.measureVideo(item),
                       let estimate, estimate.range == .sdr, bytes == member.digest.bytes,
                       let saving = estimate.savings(originalBytes: bytes, preset: existing?.preset ?? videos.preset, encoding: .hevc), saving > 0 {
                        proposals.append(Self.proposal(member, action: .compression, bytes: saving,
                            note: "按视频档位估算，实际收益以成品为准。", route: .video(member)))
                    }
                }
            } else if PhotoLibrary.replaceableAlbums(for: member.snapshot, resourceType: .photo) != nil {
                if let existing = photoJobs[member.id], existing.stage.isClosed { continue }
                if let output = photoJobs[member.id]?.output, photoJobs[member.id]?.original == member.snapshot {
                    proposals.append(Self.proposal(member, action: .compression, bytes: Self.gain(member.digest.bytes, output.digest.bytes),
                        note: "已有成品，仍需复核与确认。", route: .photo(member)))
                } else {
                    let preset = photoJobs[member.id]?.preset ?? .balanced
                    let long = max(member.snapshot.width, member.snapshot.height)
                    if let bound = preset.longestEdge, long > bound {
                        let scale = Double(bound) / Double(long)
                        let retained = max(0.25, scale * scale)
                        let estimate = Int64(Double(member.digest.bytes) * (1 - retained))
                        if estimate > 0 {
                            proposals.append(Self.proposal(member, action: .compression, bytes: estimate,
                                note: "按缩小后的像素数粗估，实际收益以成品为准。", route: .photo(member)))
                        }
                    }
                }
            }
        }
        return proposals
    }

    private func fileProposals(_ files: FileSession) -> [SpaceProposal] {
        files.jobs.compactMap { job in
            guard job.stage == .ready, let source = job.sourceDigest, let result = job.result,
                  FileReplacement.reason(job, store: files.store) == nil,
                  let key = try? job.reference.withAccess({ url -> String in
                      let root = URL.documentsDirectory.resolvingSymlinksInPath().path + "/"
                      let path = url.resolvingSymlinksInPath().path
                      guard path.hasPrefix(root), try StorageCapacity.fileSize(url) == source.bytes else { throw FileWorkError.changed }
                      return "file:" + String(path.dropFirst(root.count))
                  }) else { return nil }
            return SpaceProposal(id: "file-task:\(job.id)", action: .compression, title: job.name,
                note: "已有文件成品，需确认替换并清理恢复副本后才可能释放空间。",
                keys: [key], bytes: Self.gain(source.bytes, result.digest.bytes), route: .file(job.id))
        }
    }

    private static func proposal(_ member: MediaMember, action: SpaceAction, bytes: Int64?, note: String, route: SpaceProposal.Route) -> SpaceProposal {
        let key = SpaceRestrictions.photoKey(member.id)
        return SpaceProposal(id: "\(action.rawValue):\(key)", action: action, title: title(member), note: note,
                             keys: [key], bytes: bytes, route: route)
    }

    private static func gain(_ original: Int64, _ output: Int64) -> Int64? { original > output ? original - output : nil }

    private static func title(_ member: MediaMember) -> String {
        let kind = member.isVideo ? "视频" : "照片"
        return member.snapshot.creationDate.map { "\(kind) · \($0.formatted(date: .abbreviated, time: .shortened))" } ?? kind
    }
}
