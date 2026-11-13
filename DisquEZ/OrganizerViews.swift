import AVKit
import Photos
import SwiftUI
import UniformTypeIdentifiers

struct OrganizerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var session = OrganizerSession()
    @State private var filter = MediaFilter()
    @State private var photos: [PHAsset] = []
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DisclosureGroup("扫描范围与说明") {
                    VStack(alignment: .leading, spacing: 16) {
                        MediaFilterControls(filter: $filter)
                        Text("完全重复按原文件内容核对，可能相似的照片需逐张检查。扫描只读取本机原片，iCloud 项和保护项单独统计。")
                            .font(.body).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                }.font(.body).disabled(session.scanning || session.removing).graphitePanel()
                Text("当前范围 \(photos.filter(filter.includes).count) 项").font(.subheadline)
                    .accessibilityIdentifier("media-filter-count")
                if session.scanning {
                    Text(session.status).font(.subheadline.monospacedDigit())
                    SegmentedMeter(value: session.progress)
                    Button("停止扫描", action: session.cancel).buttonStyle(.bordered).accessibilityIdentifier("cancel-media-scan")
                } else {
                    PrimaryAction(title: "扫描当前范围", icon: "square.on.square", identifier: "scan-media") {
                        session.scan(photos.filter(filter.includes))
                    }.disabled(!PhotoLibrary.canRead || session.removing)
                }
                if let message = session.message { Text(message).font(.body).accessibilityIdentifier("organizer-message") }
                ForEach(Array(session.groups.enumerated()), id: \.element.id) { index, group in
                    NavigationLink {
                        GroupReviewView(session: session, group: group)
                    } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(group.kind.rawValue).font(.headline).foregroundStyle(Graphite.accent)
                                Spacer()
                                Text("\(group.members.count) 项").font(.subheadline)
                            }
                            HStack {
                                ForEach(group.members.prefix(3)) { member in
                                    if let photo = member.photo { PhotoThumbnail(photo: photo, size: CGSize(width: 100, height: 100)) }
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                            }
                        }.graphitePanel()
                    }.buttonStyle(.plain).disabled(session.removing).accessibilityIdentifier("media-group-\(index)")
                }
                if PhotoLibrary.access == .limited {
                    Text("当前只能扫描已授权的素材。移除整理项需要完整照片权限。").font(.footnote).foregroundStyle(.secondary)
                }
            }.padding(16).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
        .background(Graphite.background.ignoresSafeArea())
        .navigationTitle("重复与相似项").navigationBarTitleDisplayMode(.inline)
        .task {
            let access = PhotoLibrary.access == .notDetermined ? await PHPhotoLibrary.requestAuthorization(for: .readWrite) : PhotoLibrary.access
            if access == .authorized || access == .limited { photos = MediaLibrary.assets() }
            else { session.message = CompressionError.noPermission.localizedDescription }
        }
        .onChange(of: session.removing) { _, active in if !active { photos = MediaLibrary.assets() } }
        .onChange(of: filter) { _, _ in session.clearResults() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { session.cancel() }
            if phase == .active { photos = MediaLibrary.assets() }
        }
        .onDisappear { session.cancel() }
    }
}

struct GroupReviewView: View {
    @Environment(\.dismiss) private var dismiss
    let session: OrganizerSession
    let group: MediaGroup
    @State private var selection = GroupSelection()
    @State private var confirmation = false
    @State private var preview: MediaMember?
    var body: some View {
        let keeper = selection.keeper
        let removals = selection.removals
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(group.kind == .similar ? "这些照片可能相似，表情、清晰度和细节可能不同。请放大复核。" : "这些原文件的字节内容一致，拍摄信息和相簿归属仍可能不同。")
                    .font(.subheadline)
                Text("移除项目的收藏、相簿和拍摄信息不会合并到保留件。").font(.footnote).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)], alignment: .leading, spacing: 12) {
                    ForEach(Array(group.members.enumerated()), id: \.element.id) { index, member in
                        let kept = keeper == member.id
                        let marked = removals.contains(member.id)
                        VStack(alignment: .leading, spacing: 10) {
                            Button { preview = member } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    if let photo = member.photo { PhotoThumbnail(photo: photo) }
                                    Label(member.isVideo ? "播放原片" : "放大查看", systemImage: member.isVideo ? "play.circle" : "plus.magnifyingglass")
                                        .font(.caption)
                                }
                            }.buttonStyle(.plain).accessibilityIdentifier("preview-member-\(index)")
                            Text(member.snapshot.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "拍摄时间未知").font(.caption)
                            Text("\(member.snapshot.width) × \(member.snapshot.height)").font(.caption.monospacedDigit())
                            Text(member.digest.bytes.storageDescription).font(.subheadline.monospacedDigit())
                            if member.snapshot.favorite { Label("收藏", systemImage: "heart.fill").font(.caption) }
                            Button(kept ? "已选保留件" : "保留这项") { selection.keep(member.id) }
                                .buttonStyle(.bordered).accessibilityIdentifier("keep-member-\(index)")
                            if !kept {
                                Button {
                                    selection.toggle(member.id)
                                } label: {
                                    Label("勾选移除", systemImage: marked ? "checkmark.square.fill" : "square")
                                        .font(.subheadline)
                                }.buttonStyle(.plain).disabled(keeper == nil)
                                    .foregroundStyle(marked ? Graphite.accent : Color.primary)
                                    .accessibilityValue(marked ? "已勾选" : "未勾选")
                                    .accessibilityIdentifier("remove-member-\(index)")
                            }
                        }.graphitePanel()
                    }
                }.disabled(session.removing)
                if session.removing {
                    ProgressView("重新核对原件并等待系统确认…").tint(Graphite.accent)
                } else if session.groups.contains(where: { $0.id == group.id }) {
                    if selection.keeper == nil { Text("请先选择一项保留件。").font(.footnote) }
                    Button("移除已勾选的 \(selection.removals.count) 项", role: .destructive) { confirmation = true }
                        .buttonStyle(.bordered).tint(.red)
                        .disabled(!selection.isValid(for: group) || PhotoLibrary.access != .authorized)
                        .accessibilityIdentifier("remove-media-selection")
                } else { Button("完成") { dismiss() }.buttonStyle(.bordered) }
                if let message = session.message { Text(message).font(.footnote) }
            }.padding(16).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
        .background(Graphite.background.ignoresSafeArea()).navigationTitle(group.kind.rawValue).navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(session.removing)
        .sheet(item: $preview) { MediaPreviewSheet(member: $0) }
        .alert("将勾选的 \(selection.removals.count) 项移到「最近删除」？", isPresented: $confirmation) {
            Button("移到「最近删除」", role: .destructive) { session.remove(selection, group: group) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("保留件和未勾选项会保留。启用 iCloud 照片时，删除同步到其他设备；系统清理前仍可能占用空间。")
        }
    }
}

struct MediaPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let member: MediaMember
    @State private var url: URL?
    @State private var player: AVPlayer?
    @State private var message: String?
    var body: some View {
        NavigationStack {
            Group {
                if let player { VideoPlayer(player: player) }
                else if let url { ZoomPhoto(url: url) }
                else if let message { Text(message).padding() }
                else { ProgressView("正在读取本机原片…") }
            }
            .background(Graphite.background)
            .navigationTitle(member.isVideo ? "原片预览" : "放大查看").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task {
                var temporary: URL?
                do {
                    guard let photo = member.photo, member.snapshot.matches(photo) else { throw CompressionError.originalUnavailable }
                    let resource = try MediaLibrary.resource(photo)
                    let file = URL.temporaryDirectory.appending(path: UUID().uuidString)
                        .appendingPathExtension(UTType(resource.uniformTypeIdentifier)?.preferredFilenameExtension ?? "media")
                    temporary = file
                    let digest = try await MediaResourceRead.read(resource, to: file)
                    try Task.checkCancellation()
                    guard digest == member.digest else { throw CompressionError.originalUnavailable }
                    url = file
                    if member.isVideo { player = AVPlayer(url: file) }
                } catch {
                    if let temporary { try? FileManager.default.removeItem(at: temporary) }
                    message = error.localizedDescription
                }
            }
            .onDisappear { player?.pause(); player = nil; if let url { try? FileManager.default.removeItem(at: url) } }
        }.tint(Graphite.accent)
    }
}
