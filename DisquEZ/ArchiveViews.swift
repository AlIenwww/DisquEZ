import Photos
import SwiftUI

private enum ArchivePicker: String, Identifiable {
    case files, folder, destination, connect
    var id: String { rawValue }
}
private struct ArchiveExport: Identifiable { let id = UUID(); let urls: [URL] }

struct ArchiveWorkspace: View {
    let session: ArchiveSession
    @State private var picker: ArchivePicker?
    @State private var photos = false
    @State private var selected: Set<UUID> = []
    @State private var network = false
    @State private var destination: URL?
    @State private var confirming = false
    @State private var search = ""
    init(session: ArchiveSession, preselected: Set<UUID> = []) {
        self.session = session
        _selected = State(initialValue: preselected)
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                DisclosureGroup("归档与恢复说明") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("将原始文件和清单保存到选定目录，完成后重新读取全部文件核对。归档保留源文件、原画质和音质。")
                        Text("外接盘需要连接后核验，iCloud 还需系统确认同步完成。第三方服务无法确认同步时，原件保留。")
                        Text("照片库支持普通单资源照片和视频。实况、RAW、已编辑及特殊拍摄素材先保护。人物标签、回忆和系统排列无法写回，清单保存可读取的时间、地点、收藏及普通相簿归属。")
                        Text("重新打开 App 后需重新核验，已归档大小不代表已释放空间。")
                    }.font(.body).foregroundStyle(.secondary).padding(.top, 8)
                }.font(.body)
                if let capacity = StorageCapacity.read() { Text("本机可用 \(capacity.available.storageDescription)").monospacedDigit() }
                if let message = session.message { Text(message).font(.footnote).accessibilityIdentifier("archive-message") }
                if session.busy {
                    VStack(alignment: .leading, spacing: 12) {
                        ProgressView("正在归档或核验…").tint(Graphite.accent)
                        if session.total > 0 { Text("已读取原件 \(session.completed)/\(session.total) 项").monospacedDigit().font(.caption) }
                        if let progress = session.progress { SegmentedMeter(value: progress) }
                        Text("请保持 App 打开。停止后不自动重试，源文件不会因归档中断而删除。")
                            .font(.footnote).foregroundStyle(.secondary)
                        if session.cancellable { Button("停止处理", action: session.cancel).buttonStyle(.bordered).accessibilityIdentifier("stop-archive") }
                    }.graphitePanel()
                }
                GraphiteSection(title: "添加素材") {
                    Button { photos = true } label: { GraphiteNavigationRow(title: "选择照片或视频", icon: "photo.on.rectangle") }
                        .accessibilityIdentifier("archive-pick-photos")
                    Divider().padding(.leading, 52)
                    Button { picker = .files } label: { GraphiteNavigationRow(title: "选择文件", icon: "doc") }
                        .accessibilityIdentifier("archive-pick-files")
                    Divider().padding(.leading, 52)
                    Button { picker = .folder } label: { GraphiteNavigationRow(title: "选择目录", icon: "folder") }
                        .accessibilityIdentifier("archive-pick-folder")
                }.buttonStyle(.plain).disabled(session.busy || !session.healthy)
                if !session.selections.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("待归档 · \(session.selections.count) 项").font(.headline)
                        HStack {
                            Button("全选可归档项") { selected = Set(session.selections.filter { $0.protection == nil }.map(\.id)) }.accessibilityIdentifier("archive-select-sources")
                            Button("取消选择") { selected = [] }
                        }.buttonStyle(.borderless)
                        Toggle("允许取回所选 iCloud 照片原件", isOn: $network).font(.subheadline).accessibilityIdentifier("archive-allow-network")
                        Text("文件服务可能自行下载选中的云盘文件；完整原片读取需要本机临时空间，归档结束后清理 App 临时副本。")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(session.selections.enumerated()), id: \.element.id) { index, item in
                            Button {
                                if !selected.insert(item.id).inserted { selected.remove(item.id) }
                            } label: {
                                HStack {
                                    Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(Graphite.accent)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(item.name).lineLimit(2)
                                        Text(item.protection ?? item.file?.bytes?.storageDescription ?? "原始照片库资源").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(item.protection != nil).accessibilityIdentifier("archive-source-\(index)")
                        }
                        Button("选择归档位置（\(selected.count) 项）") { picker = .destination }
                            .buttonStyle(.borderedProminent).foregroundStyle(Graphite.background).disabled(selected.isEmpty).accessibilityIdentifier("archive-choose-destination")
                    }.graphitePanel().disabled(session.busy || !session.healthy)
                }
                Button("连接已有归档目录") { picker = .connect }.buttonStyle(.bordered).disabled(session.busy || !session.healthy).accessibilityIdentifier("archive-connect")
                Text("归档清单 · \(session.records.count) 份").font(.headline)
                if !session.records.isEmpty {
                    TextField("搜索文件名或相簿名", text: $search)
                        .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                        .accessibilityIdentifier("archive-search")
                }
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, record in
                    NavigationLink { ArchiveDetailView(session: session, id: record.id) } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(record.manifest.created.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                            Text("\(record.manifest.entries.count) 项 · \(record.manifest.bytes.storageDescription)").font(.subheadline.monospacedDigit())
                            Text(record.stage == .verified ? record.destination.label : "归档待重新核验").font(.caption).foregroundStyle(Graphite.accent)
                            Text(record.locationName).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).graphitePanel()
                    }.buttonStyle(.plain).disabled(session.busy).accessibilityIdentifier("archive-record-\(index)")
                }
            }.padding(16).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
        .background(Graphite.background.ignoresSafeArea()).navigationTitle("原片归档").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $picker) { purpose in
            SystemFilePicker(folder: purpose != .files, selected: { urls in
                picker = nil
                guard let url = urls.first else { return }
                switch purpose {
                case .files, .folder: selected = []; session.addFiles(urls)
                case .connect: session.connect(url)
                case .destination: destination = url; confirming = true
                }
            }, cancelled: { picker = nil })
        }
        .sheet(isPresented: $photos) { ArchivePhotoPicker { assets in selected = []; session.addPhotos(assets) } }
        .alert("归档所选 \(selected.count) 项原件？", isPresented: $confirming) {
            Button("开始归档") { if let destination { session.create(selected, parent: destination, allowNetwork: network) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("保存到「\(destination?.lastPathComponent ?? "所选目录")」中的新归档文件夹。原始文件与包含时间、地点等信息的清单会写入该位置，请选用你信任的目录。源文件保留。" + (network ? "允许取回本次选中的 iCloud 照片原件，可能使用蜂窝数据。" : "不为照片库原件启用网络下载。"))
        }
    }
    private var visible: [ArchiveRecord] {
        session.records.reversed().filter { record in search.isEmpty || record.manifest.entries.contains { $0.name.localizedCaseInsensitiveContains(search) || $0.albums.contains { $0.title.localizedCaseInsensitiveContains(search) } } }
    }
}

struct ArchiveDetailView: View {
    let session: ArchiveSession
    let id: UUID
    @State private var selected: Set<UUID> = []
    @State private var removeConfirmation = false
    @State private var approved: Set<UUID> = []
    @State private var restoreEntry: ArchiveEntry?
    @State private var restoreConfirmation = false
    @State private var export: ArchiveExport?
    @State private var exporting = false
    init(session: ArchiveSession, id: UUID, preselected: Set<UUID> = []) {
        self.session = session
        self.id = id
        _selected = State(initialValue: preselected)
    }
    var body: some View {
        ScrollView {
            if let record = session.record(id) {
                LazyVStack(alignment: .leading, spacing: 16) {
                    Text("完整原片归档").font(.title2.bold())
                    Text("\(record.manifest.entries.count) 项 · \(record.manifest.bytes.storageDescription)").font(.headline.monospacedDigit())
                    Text(record.stage == .verified ? record.destination.label : "归档待重新核验").foregroundStyle(Graphite.accent).accessibilityIdentifier("archive-status")
                    Text("归档目录：\(record.manifest.directoryName)").font(.caption).textSelection(.enabled)
                    if let date = record.verifiedAt { Text("最近完整核验：\(date.formatted())").font(.caption) }
                    if let note = record.note { Text(note).font(.footnote).foregroundStyle(.secondary) }
                    if let message = session.message { Text(message).font(.footnote).accessibilityIdentifier("archive-detail-message") }
                    Button("重新读取并核验归档") { session.verify(id) }.buttonStyle(.bordered).accessibilityIdentifier("archive-verify")
                    Text("归档大小、原件移除状态及本机可用空间分别显示。归档目录会保留，App 不自动清理其中的文件。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let capacity = StorageCapacity.read() { Text("本机可用 \(capacity.available.storageDescription)").font(.subheadline.monospacedDigit()) }
                    HStack {
                        Button("全选归档项目") { selected = Set(record.manifest.entries.map(\.id)) }.accessibilityIdentifier("archive-select-entries")
                        Button("取消选择") { selected = [] }
                    }.buttonStyle(.borderless)
                    Button("导出所选原始文件（\(selected.count)）") { prepareExport() }
                        .buttonStyle(.borderedProminent).foregroundStyle(Graphite.background).disabled(selected.isEmpty).accessibilityIdentifier("archive-export")
                    let eligible = record.manifest.entries.filter { selected.contains($0.id) && session.removalReason(record, item: $0) == nil }
                    Button("复核移除本机原件（\(eligible.count)）", role: .destructive) {
                        approved = Set(eligible.map(\.id)); removeConfirmation = true
                    }.buttonStyle(.bordered).tint(.red).disabled(eligible.isEmpty).accessibilityIdentifier("archive-remove")
                    Text("无法确认外部保存、同步、权限或恢复信息的项目保留原件。移除前会再次核验归档和原件，照片库删除还需系统确认。")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(Array(record.manifest.entries.enumerated()), id: \.element.id) { index, entry in
                        entryView(entry, record: record, index: index)
                    }
                }.padding(16).frame(maxWidth: 680).frame(maxWidth: .infinity)
                    .disabled(session.busy || exporting || !session.healthy)
            }
            if session.busy || exporting {
                ProgressView("正在读取或核验…").tint(Graphite.accent).padding()
                if session.cancellable { Button("停止处理", action: session.cancel).buttonStyle(.bordered) }
            }
        }.background(Graphite.background.ignoresSafeArea()).navigationTitle("归档详情").navigationBarTitleDisplayMode(.inline)
            .sheet(item: $export) { files in
                SystemFilePicker(exporting: files.urls, selected: { _ in FileExports.clean(files.urls); export = nil; exporting = false; session.message = "所选原始文件已导出，归档保留。" },
                                 cancelled: { FileExports.clean(files.urls); export = nil; exporting = false }).interactiveDismissDisabled()
            }
            .alert("移除已归档的 \(approved.count) 项本机原件？", isPresented: $removeConfirmation) {
                Button("确认移除原件", role: .destructive) { session.remove(id, entries: approved) }
                Button("取消", role: .cancel) {}
            } message: {
                Text("仅处理下面列出的原件。照片库原件移到「最近删除」，iCloud 照片删除会同步到其他设备；DisquEZ 本机文件将移除，恢复需要连接完整归档。人物标签、回忆与系统排列不能从清单写回。\n" + (session.record(id)?.manifest.entries.filter { approved.contains($0.id) }.map(\.name).joined(separator: "\n") ?? ""))
            }
            .alert("恢复到照片库？", isPresented: $restoreConfirmation) {
                Button("恢复原片") { if let restoreEntry { session.restorePhoto(id, entry: restoreEntry.id) } }
                Button("取消", role: .cancel) {}
            } message: { Text("新建并核验原片副本，现有素材保留，可能出现重复项。保留可写的时间、地点和收藏，并加入仍可访问的普通相簿。缺失相簿、人物标签和系统排列不能完整恢复。") }
    }
    private func entryView(_ entry: ArchiveEntry, record: ArchiveRecord, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                if !selected.insert(entry.id).inserted { selected.remove(entry.id) }
            } label: {
                HStack {
                    Image(systemName: selected.contains(entry.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(Graphite.accent)
                    Text(entry.name).font(.headline).lineLimit(2)
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("archive-entry-\(index)")
            Text(entry.digest.bytes.storageDescription).font(.subheadline.monospacedDigit())
            if let path = entry.relativePath { Text("原目录路径：\(path)").font(.caption).foregroundStyle(.secondary) }
            if let metadata = entry.photo {
                if let date = metadata.creationDate { Text("拍摄时间：\(date.formatted())").font(.caption) }
                if metadata.location != nil { Text("地点已记录在归档清单").font(.caption) }
                Text(metadata.favorite ? "收藏已记录" : "未收藏").font(.caption)
            }
            if !entry.albums.isEmpty { Text("相簿：" + entry.albums.map(\.title).joined(separator: "、")).font(.caption) }
            if let state = record.states.first(where: { $0.id == entry.id }) {
                Text(state.removal == .removed ? "原件已移除 · 设备空间以系统读数为准" : state.removal == .pending ? "原件移除结果待核对" : state.fileOrigin == nil && state.photoOrigin == nil ? "源原件状态未关联" : "本次尚未移除原件").font(.footnote).foregroundStyle(.secondary)
                if state.removal == .present, let reason = session.removalReason(record, item: entry) { Text(reason).font(.caption).foregroundStyle(.secondary) }
                if entry.kind != .file {
                    if state.restoration == .none {
                        Button("恢复到照片库") { restoreEntry = entry; restoreConfirmation = true }.buttonStyle(.bordered).accessibilityIdentifier("archive-restore-\(index)")
                    } else { Text(state.restoration == .restored ? "原片副本已恢复并核验" : "恢复结果待核对").font(.footnote).foregroundStyle(Graphite.accent).accessibilityIdentifier("archive-restored-\(index)") }
                }
                if state.restoration == .pending || state.removal == .pending {
                    Button("核对上次操作结果") { session.recheck(id, entry: entry.id) }.buttonStyle(.bordered)
                }
                if let note = state.note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
        }.graphitePanel()
    }
    private func prepareExport() {
        exporting = true
        Task {
            do {
                let urls = try await session.export(id, entries: selected)
                if urls.isEmpty { exporting = false } else { export = ArchiveExport(urls: urls) }
            } catch { session.message = error.localizedDescription; exporting = false }
        }
    }
}

private struct ArchivePhotoPicker: View {
    let selected: ([PHAsset]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var assets: [PHAsset] = []
    @State private var chosen: Set<String> = []
    @State private var loaded = false
    @State private var filter = MediaFilter()
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    Text("只归档你选中的完整原片。照片权限仅用于读取、恢复和你另行确认的移除操作。")
                        .font(.footnote).foregroundStyle(.secondary)
                    MediaFilterControls(filter: $filter)
                    if !PhotoLibrary.canRead, loaded { Text("尚未允许照片访问。可返回使用文件入口，或在系统设置中调整权限。").font(.footnote) }
                    ForEach(Array(assets.filter(filter.includes).enumerated()), id: \.element.localIdentifier) { index, photo in
                        let protection = MediaLibrary.protectionReason(photo)
                        Button {
                            if !chosen.insert(photo.localIdentifier).inserted { chosen.remove(photo.localIdentifier) }
                        } label: {
                            HStack {
                                Image(systemName: chosen.contains(photo.localIdentifier) ? "checkmark.circle.fill" : "circle").foregroundStyle(Graphite.accent)
                                PhotoThumbnail(photo: photo)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(PHAssetResource.assetResources(for: photo).first?.originalFilename ?? "原片").lineLimit(2)
                                    Text(protection ?? "完整原文件").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(protection != nil).accessibilityIdentifier("archive-photo-\(index)")
                    }
                }.padding(16)
            }.background(Graphite.background).navigationTitle("选择原片").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("添加（\(chosen.count)）") { selected(assets.filter { chosen.contains($0.localIdentifier) }); dismiss() }
                            .disabled(chosen.isEmpty).accessibilityIdentifier("archive-confirm-photos")
                    }
                }
                .task {
                    if !PhotoLibrary.canRead { _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
                    assets = MediaLibrary.assets(); loaded = true
                }
        }.tint(Graphite.accent)
    }
}
