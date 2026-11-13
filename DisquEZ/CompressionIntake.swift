import Photos
import SwiftUI

struct CompressionDefaults: Codable, Equatable {
    var video: CompressionPreset = .balanced
    var encoding: VideoEncoding = .hevc
    var photo: PhotoPreset = .original
    var pdf: PDFPreset = .detail
}

@MainActor @Observable
final class CompressionDefaultStore {
    private(set) var values = CompressionDefaults()
    private(set) var message: String?
    private(set) var readable = true
    private let url: URL

    init(url: URL = URL.applicationSupportDirectory.appending(path: "CompressionDefaults/v1.json")) {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do { values = try JSONDecoder().decode(CompressionDefaults.self, from: Data(contentsOf: url)) }
        catch {
            readable = false
            message = "无法读取已保存的默认参数。现有记录已保留，本次可在确认页设置参数。"
        }
    }

    func save(_ next: CompressionDefaults) {
        guard readable, next != values else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            values = next
            message = nil
        } catch { message = "默认参数保存失败，请检查可用空间后重试。" }
    }
}

enum CompressionSource {
    case videos([PhotoSnapshot]), photos([PhotoSnapshot]), files([FileCandidate], pdfOnly: Bool)

    struct Item: Identifiable {
        let id: String
        let title: String
        var photoID: String? = nil
    }

    var kinds: Set<FileMediaKind> {
        switch self {
        case .videos: [.video]
        case .photos: [.photo]
        case .files(let items, _): Set(items.map(\.kind))
        }
    }

    var videoCount: Int {
        switch self {
        case .videos(let items): items.count
        case .photos: 0
        case .files(let items, _): items.count { $0.kind == .video }
        }
    }

    var items: [Item] {
        switch self {
        case .videos(let items): items.map { Self.item($0, fallback: "视频") }
        case .photos(let items): items.map { Self.item($0, fallback: "照片") }
        case .files(let items, _): items.map { Item(id: $0.id.uuidString, title: "\($0.name) · \($0.kind.rawValue)") }
        }
    }

    private static func item(_ photo: PhotoSnapshot, fallback: String) -> Item {
        let date = photo.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? fallback
        return Item(id: photo.identifier, title: "\(date) · \(photo.width) × \(photo.height)", photoID: photo.identifier)
    }
}

@MainActor @Observable
final class CompressionDraft {
    var source: CompressionSource
    var parameters: CompressionDefaults
    var professional: ProfessionalVideoSettings?

    init(source: CompressionSource, parameters: CompressionDefaults) {
        self.source = source
        self.parameters = parameters
    }
}

@MainActor
struct CompressionIntake {
    let videos: CompressionSession
    let photos: PhotoSession
    let files: FileSession
    let archives: ArchiveSession
    let defaults: CompressionDefaults
    let close: () -> Void
    let complete: ([WorkspaceTaskID]) -> Void

    var busy: Bool { videos.isBusy || photos.busy || files.busy || archives.busy }

    func submit(_ draft: CompressionDraft, start: Bool) async throws -> [WorkspaceTaskID] {
        guard !busy else { throw IntakeError("请等待当前任务完成，再提交这批素材。") }
        guard UIApplication.shared.applicationState != .background else {
            throw IntakeError("请返回 App 后重新确认这批素材。")
        }
        let parameters = draft.parameters
        let professional = draft.source.videoCount > 0 ? draft.professional : nil
        if let professional {
            guard ProfessionalPurchase.live.unlocked else { throw IntakeError("专业权限已变化，请恢复购买或切回标准参数。") }
            if let reason = professional.validation { throw IntakeError(reason) }
        }
        switch draft.source {
        case .videos(let snapshots):
            let assets = try originals(snapshots, existing: Set(videos.jobs.map(\.original.identifier)), type: .video)
            let ids = videos.enqueue(assets, preset: parameters.video, encoding: parameters.encoding, professional: professional)
            guard !ids.isEmpty else { throw IntakeError(videos.message ?? "无法保存这批视频任务。") }
            if start { videos.compress(ids) }
            return ids.map { .init(category: .video, id: $0) }
        case .photos(let snapshots):
            let assets = try originals(snapshots, existing: Set(photos.jobs.map(\.original.identifier)), type: .image)
            let ids = photos.enqueue(assets, using: parameters.photo)
            guard !ids.isEmpty else { throw IntakeError(photos.message ?? "无法保存这批照片任务。") }
            if start { photos.compress(ids) }
            return ids.map { .init(category: .photo, id: $0) }
        case .files(let candidates, let pdfOnly):
            let ids = Set(candidates.map(\.id))
            try checkFileSelection(ids, candidates: candidates, pdfOnly: pdfOnly)
            try await Task.detached(priority: .userInitiated) {
                for candidate in candidates {
                    try candidate.reference.withAccess { url in
                        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                        guard values.isRegularFile == true, FileMediaKind.detect(url) == candidate.kind,
                              candidate.modified == nil || candidate.modified == values.contentModificationDate,
                              candidate.bytes == nil || candidate.bytes == values.fileSize.map(Int64.init) else {
                            throw FileWorkError.changed
                        }
                    }
                }
            }.value
            guard UIApplication.shared.applicationState != .background else {
                throw IntakeError("请返回 App 后重新确认这批素材。")
            }
            try checkFileSelection(ids, candidates: candidates, pdfOnly: pdfOnly)
            let added = files.enqueue(ids, defaults: parameters, professional: professional)
            guard !added.isEmpty else { throw IntakeError(files.message ?? "无法保存这批文件任务。") }
            if start { files.compress(added) }
            return candidates.filter { added.contains($0.id) }.map { .init(category: $0.kind == .pdf ? .pdf : .file, id: $0.id) }
        }
    }

    private func originals(_ snapshots: [PhotoSnapshot], existing: Set<String>, type: PHAssetMediaType) throws -> [PHAsset] {
        guard PhotoLibrary.canRead, !snapshots.isEmpty else { throw CompressionError.noPermission }
        return try snapshots.map { snapshot in
            guard !existing.contains(snapshot.identifier) else { throw IntakeError("有素材已在任务页，请返回调整本次选择。") }
            guard let asset = PhotoLibrary.fetch(snapshot.identifier), snapshot.matches(asset), asset.mediaType == type else {
                throw IntakeError("有素材已变化或无法访问，请返回重新选择。")
            }
            return asset
        }
    }

    private func checkFileSelection(_ ids: Set<UUID>, candidates: [FileCandidate], pdfOnly: Bool) throws {
        guard !busy, files.healthy, !ids.isEmpty,
              ids.isSubset(of: Set(files.candidates.map(\.id))), ids.isDisjoint(with: Set(files.jobs.map(\.id))),
              candidates.allSatisfy({ pdfOnly ? $0.kind == .pdf : $0.kind != .unsupported }) else {
            throw IntakeError("文件选择或队列状态已变化，请返回重新核对。")
        }
    }
}

private struct IntakeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct BatchConfirmation: View {
    @Bindable var draft: CompressionDraft
    let intake: CompressionIntake
    @State private var submitting = false
    @State private var message: String?

    var body: some View {
        let items = draft.source.items
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                GraphiteSection(title: "本次素材") {
                    DisclosureGroup("已选 \(items.count) 项") {
                        LazyVStack(spacing: 0) {
                            ForEach(items) { item in
                                Divider()
                                sourceRow(item)
                            }
                        }
                    }.font(.body).padding(16).accessibilityIdentifier("intake-selected-items")
                }
                GraphiteSection(title: "压缩参数") {
                    VStack(alignment: .leading, spacing: 16) {
                        CompressionParameterFields(values: $draft.parameters, kinds: draft.source.kinds,
                                                   standardVideo: draft.professional == nil)
                        if draft.source.videoCount > 0 {
                            if let professional = draft.professional {
                                DisclosureGroup("已启用专业参数") {
                                    Text(professional.summary).font(.body).foregroundStyle(.secondary)
                                }.font(.body)
                                if let notice = professional.audioNotice { Text(notice).font(.body) }
                            }
                            Divider()
                            ProfessionalSettingsButton(initial: draft.professional ?? .init(preset: draft.parameters.video, encoding: draft.parameters.encoding),
                                                       targetCount: draft.source.videoCount, canReset: draft.professional != nil,
                                                       title: "专业视频参数") {
                                draft.professional = $0
                            }
                        }
                    }.padding(16)
                }.disabled(submitting)
                if case .files = draft.source {
                    Text("处理时系统可能取回云盘原文件，需要本机空间。").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text("iCloud 原片需在任务页另行确认下载。").font(.subheadline).foregroundStyle(.secondary)
                }
                if let message { Text(message).font(.body).foregroundStyle(.orange).accessibilityIdentifier("intake-message") }
            }.padding(16).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
        .background(Graphite.background.ignoresSafeArea())
        .navigationTitle("确认设置")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(submitting)
        .interactiveDismissDisabled(submitting)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if submitting { ProgressView("正在核对本批素材…") }
                PrimaryAction(title: "开始压缩", icon: "play.fill", identifier: "start-intake") { submit(start: true) }
                Button("仅加入任务") { submit(start: false) }
                    .font(.body).frame(maxWidth: .infinity, minHeight: 44)
                    .buttonStyle(.plain).accessibilityIdentifier("queue-intake")
            }.padding(.horizontal, 16).padding(.vertical, 8).background(Graphite.background)
                .disabled(submitting || items.isEmpty)
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("退出", action: intake.close).disabled(submitting).accessibilityIdentifier("exit-intake")
            }
        }
    }

    private func sourceRow(_ item: CompressionSource.Item) -> some View {
        HStack(spacing: 12) {
            if let id = item.photoID, let photo = PhotoLibrary.fetch(id) {
                PhotoThumbnail(photo: photo).accessibilityHidden(true)
            }
            Text(item.title).font(.body).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 12).padding(.horizontal, 16)
    }

    private func submit(start: Bool) {
        guard !submitting else { return }
        submitting = true
        message = nil
        Task {
            defer { submitting = false }
            do { intake.complete(try await intake.submit(draft, start: start)) }
            catch { message = error.localizedDescription }
        }
    }
}

struct CompressionParameterFields: View {
    @Binding var values: CompressionDefaults
    let kinds: Set<FileMediaKind>
    var standardVideo = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if kinds.contains(.video), standardVideo {
                GraphiteParameterRow(title: "视频档位") {
                    Picker("视频档位", selection: $values.video) {
                        ForEach(CompressionPreset.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.menu).labelsHidden().frame(minHeight: 44)
                        .accessibilityLabel("视频档位").accessibilityValue(values.video.rawValue)
                        .accessibilityIdentifier("default-video-preset")
                }
                Divider()
                VideoEncodingPicker(encoding: $values.encoding, showHint: false)
            }
            if kinds.contains(.photo) {
                if kinds.contains(.video), standardVideo { Divider() }
                GraphiteParameterRow(title: "照片尺寸") {
                    Picker("照片尺寸", selection: $values.photo) {
                        ForEach(PhotoPreset.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.menu).labelsHidden().frame(minHeight: 44)
                        .accessibilityLabel("照片尺寸").accessibilityValue(values.photo.rawValue)
                        .accessibilityIdentifier("default-photo-preset")
                }
            }
            if kinds.contains(.pdf) {
                if kinds.contains(.photo) || (kinds.contains(.video) && standardVideo) { Divider() }
                GraphiteParameterRow(title: "PDF 档位") {
                    Picker("PDF 档位", selection: $values.pdf) {
                        ForEach(PDFPreset.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.menu).labelsHidden().frame(minHeight: 44)
                        .accessibilityLabel("PDF 档位").accessibilityValue(values.pdf.rawValue)
                        .accessibilityIdentifier("default-pdf-preset")
                }
            }
            if standardVideo || kinds.contains(.photo) || kinds.contains(.pdf) {
                DisclosureGroup("参数说明") {
                    VStack(alignment: .leading, spacing: 12) {
                        if kinds.contains(.video), standardVideo {
                            Text(values.video.summary)
                            Text(values.encoding.hint)
                        }
                        if kinds.contains(.photo) { Text(values.photo.explanation) }
                        if kinds.contains(.pdf) { Text(values.pdf.explanation) }
                    }.font(.body).foregroundStyle(.secondary).padding(.top, 8)
                }.accessibilityIdentifier("parameter-help")
            }
        }.font(.body)
    }
}
