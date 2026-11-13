import Photos
import SwiftUI
import os

private struct DeletionRecorderKey: EnvironmentKey {
    static let defaultValue: CompressionSession? = nil
}
extension EnvironmentValues {
    var directDeletionRecorder: CompressionSession? {
        get { self[DeletionRecorderKey.self] }
        set { self[DeletionRecorderKey.self] = newValue }
    }
}

enum DirectVideoDeletion {
    static func reason(_ snapshot: PhotoSnapshot) -> String? {
        guard PhotoLibrary.canRead else { return "没有照片库读写权限" }
        guard let photo = PhotoLibrary.fetch(snapshot.identifier), snapshot.matches(photo) else { return "原片已变化或无法访问，请重新选择" }
        guard photo.mediaType == .video, photo.canPerform(.delete) else { return "系统不允许删除这项素材" }
        return nil
    }
    static func remove(_ snapshots: [PhotoSnapshot]) async throws {
        guard !snapshots.isEmpty, Set(snapshots.map(\.identifier)).count == snapshots.count,
              snapshots.allSatisfy({ reason($0) == nil }) else { throw CompressionError.directDeletionUnavailable }
        let submitted = OSAllocatedUnfairLock(initialState: false)
        try await PHPhotoLibrary.shared().performChanges {
            var assets: [PHAsset] = []
            for snapshot in snapshots {
                guard reason(snapshot) == nil, let photo = PhotoLibrary.fetch(snapshot.identifier) else { return }
                assets.append(photo)
            }
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
            submitted.withLock { $0 = true }
        }
        guard submitted.withLock({ $0 }) else { throw CompressionError.directDeletionUnavailable }
    }
}

struct DirectVideoDeletionView: View {
    let snapshots: [PhotoSnapshot]
    var willSubmit: ([PhotoSnapshot]) throws -> Void = { _ in }
    var finished: ([PhotoSnapshot], Bool) -> Void = { _, _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false
    @State private var busy = false
    @State private var completed = false
    @State private var message: String?
    @State private var approved: [PhotoSnapshot] = []
    @State private var removedIDs: Set<String> = []
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("直接删除原视频", systemImage: "trash").font(.headline).foregroundStyle(.red)
                    Text("此操作未经过压缩件核验，也不保证已有备份。只删除下面确认的原片。")
                    Text("启用 iCloud 照片时，删除同步到其他设备。原片先移到「最近删除」，设备可用空间以系统读数为准。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let message { Text(message).font(.subheadline).accessibilityIdentifier("direct-delete-message") }
                    if let capacity = StorageCapacity.read() { Text("本机可用 \(capacity.available.storageDescription)").font(.caption.monospacedDigit()) }
                }
                ForEach(snapshots, id: \.identifier) { snapshot in
                    HStack {
                        if let photo = PhotoLibrary.fetch(snapshot.identifier) { PhotoThumbnail(photo: photo) }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(snapshot.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "视频")
                            Text(verbatim: "\(snapshot.width) × \(snapshot.height)").font(.caption)
                            Text(removedIDs.contains(snapshot.identifier) ? "原片已直接删除 · 待系统清理" : DirectVideoDeletion.reason(snapshot) ?? "将删除这条原视频")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                if busy { ProgressView("等待系统删除确认…") }
                else if !completed {
                    Button("确认删除可处理的 \(eligible.count) 条原视频", role: .destructive) {
                        approved = eligible
                        confirming = true
                    }.disabled(eligible.isEmpty).accessibilityIdentifier("confirm-direct-delete")
                }
            }.scrollContentBackground(.hidden).background(Graphite.background)
                .navigationTitle("复核直接删除").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(busy).accessibilityIdentifier("finish-direct-delete") } }
                .interactiveDismissDisabled(busy)
                .alert("直接删除 \(approved.count) 条原视频？", isPresented: $confirming) {
                    Button("移到「最近删除」", role: .destructive) { remove() }
                    Button("取消", role: .cancel) {}
                } message: { Text("这些原片没有经过压缩件核验。启用 iCloud 照片时，删除同步到其他设备。") }
        }.tint(Graphite.accent)
    }
    private var eligible: [PhotoSnapshot] { snapshots.filter { DirectVideoDeletion.reason($0) == nil } }
    private func remove() {
        let targets = approved
        guard !busy, !targets.isEmpty else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                guard targets.allSatisfy({ DirectVideoDeletion.reason($0) == nil }) else { throw CompressionError.directDeletionUnavailable }
                try willSubmit(targets)
                try await DirectVideoDeletion.remove(targets)
                completed = true
                removedIDs = Set(targets.map(\.identifier))
                message = "\(targets.count) 条原视频已移到「最近删除」。"
                finished(targets, true)
            } catch {
                message = "直接删除未完成。\(error.localizedDescription)"
                finished(targets, false)
            }
        }
    }
}
