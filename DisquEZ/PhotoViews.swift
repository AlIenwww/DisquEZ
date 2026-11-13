import AVKit
import ImageIO
import Photos
import SwiftUI

struct MediaFilterControls: View {
    @Binding var filter: MediaFilter
    var photosOnly = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("素材类型", selection: $filter.kind) {
                ForEach(photosOnly ? [MediaKind.all, .screenshots] : MediaKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu).frame(minHeight: 44).accessibilityIdentifier("media-kind")
            Toggle("只看收藏", isOn: $filter.favoritesOnly).frame(minHeight: 44).accessibilityIdentifier("media-favorites")
            Toggle("限定拍摄时间", isOn: $filter.datesEnabled).frame(minHeight: 44).accessibilityIdentifier("media-date-range")
            if filter.datesEnabled {
                DatePicker("开始", selection: $filter.start, displayedComponents: .date)
                    .accessibilityIdentifier("media-start-date")
                DatePicker("结束", selection: $filter.end, displayedComponents: .date)
                    .accessibilityIdentifier("media-end-date")
            }
        }
        .font(.body).tint(Graphite.accent)
    }
}

struct PhotoSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    let excludedIDs: Set<String>
    let intake: CompressionIntake
    @State private var draft: CompressionDraft?
    @State private var reviewing = false
    @State private var photos: [PHAsset] = []
    @State private var selected: Set<String> = []
    @State private var filter = MediaFilter()
    @State private var message: String?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    DisclosureGroup("筛选照片") {
                        MediaFilterControls(filter: $filter, photosOnly: true)
                    }
                    if let message { Text(message).font(.body) }
                }
                Section {
                    ForEach(photos.filter(filter.includes), id: \.localIdentifier) { photo in
                        let reason = excludedIDs.contains(photo.localIdentifier) ? "已在任务队列中" : MediaLibrary.photoCompressionProtection(photo)
                        Button {
                            if !selected.insert(photo.localIdentifier).inserted { selected.remove(photo.localIdentifier) }
                        } label: {
                            HStack {
                                PhotoThumbnail(photo: photo)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(photo.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "照片")
                                    Text(verbatim: "\(photo.pixelWidth) × \(photo.pixelHeight)")
                                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                                    if let reason { Text(reason).font(.subheadline).foregroundStyle(.secondary) }
                                }
                                Spacer(minLength: 0)
                                Image(systemName: reason != nil ? "lock" : selected.contains(photo.localIdentifier) ? "checkmark.circle.fill" : "circle")
                            }.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).disabled(reason != nil)
                        .accessibilityValue(selected.contains(photo.localIdentifier) ? "已选择" : "未选择")
                        .accessibilityIdentifier("photo-picker-\(photo.localIdentifier)")
                    }
                }
            }
            .scrollContentBackground(.hidden).background(Graphite.background)
            .navigationTitle("选择照片").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("下一步（\(selected.count)）") {
                        let assets = photos.filter { selected.contains($0.localIdentifier) }
                        let source = CompressionSource.photos(assets.map(PhotoSnapshot.init))
                        if let draft { draft.source = source }
                        else { draft = CompressionDraft(source: source, parameters: intake.defaults) }
                        reviewing = true
                    }
                        .disabled(selected.isEmpty).accessibilityIdentifier("confirm-photos")
                }
            }
            .navigationDestination(isPresented: $reviewing) {
                if let draft { BatchConfirmation(draft: draft, intake: intake) }
            }
            .task {
                let access = PhotoLibrary.access == .notDetermined ? await PHPhotoLibrary.requestAuthorization(for: .readWrite) : PhotoLibrary.access
                if access == .authorized || access == .limited { photos = MediaLibrary.assets(photosOnly: true) }
                else { message = CompressionError.noPermission.localizedDescription }
            }
        }.tint(Graphite.accent)
    }
}

struct PhotoJobDetail: View {
    let session: PhotoSession
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReplace = false
    @State private var confirmDiscard = false
    @State private var zoom = false
    var body: some View {
        ScrollView {
            if let job = session.job(id) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(job.title).font(.headline)
                    Text(job.stage.label).foregroundStyle(Graphite.accent)
                    if let message = session.message { Text(message).font(.footnote) }
                    if let note = job.note { Text(note).font(.footnote).foregroundStyle(.secondary) }
                    if job.stage.isClosed {
                        Text(job.stage == .removed ? "原片已移到「最近删除」。压缩件保存在照片库，可用空间以系统读数为准。" : "已保留原片和压缩件。")
                    } else if let output = job.output {
                        if let original = session.file(job.sourceFileName), let compressed = try? output.url(in: session.store.media) {
                            HStack(alignment: .top) {
                                PhotoPreviewTile(url: original, label: "原片")
                                PhotoPreviewTile(url: compressed, label: "压缩件")
                            }.onTapGesture { zoom = true }
                            Button("放大对比") { zoom = true }.buttonStyle(.bordered).accessibilityIdentifier("compare-photos")
                        }
                        VStack(spacing: 10) {
                            LabeledContent("原片文件", value: job.sourceBytes?.storageDescription ?? "未知")
                            LabeledContent("压缩件", value: output.digest.bytes.storageDescription)
                            LabeledContent("成品尺寸", value: "\(output.width) × \(output.height)")
                            if let source = job.sourceBytes {
                                LabeledContent("文件大小差额", value: (source - output.digest.bytes).storageDescription)
                                    .foregroundStyle(Graphite.accent).accessibilityIdentifier("photo-savings")
                            }
                        }.monospacedDigit().graphitePanel()
                        if !session.busy {
                            if job.stage == .ready {
                                PrimaryAction(title: "保存压缩照片", icon: "square.and.arrow.down", identifier: "save-photo") { session.save([id]) }
                            } else if job.stage == .verified {
                                Label("照片已保存并核验", systemImage: "checkmark.circle").foregroundStyle(Graphite.accent)
                                    .accessibilityIdentifier("photo-verified")
                                if session.canReplace(id) {
                                    Button("确认替换原片", role: .destructive) { confirmReplace = true }
                                        .buttonStyle(.bordered).tint(.red).accessibilityIdentifier("replace-photo")
                                }
                                Button("保留两份") { session.keep(id) }.buttonStyle(.bordered).accessibilityIdentifier("keep-photos")
                            } else if job.copy != nil {
                                Button("重新核验照片库成品") { session.verify(id) }.buttonStyle(.bordered).accessibilityIdentifier("verify-photo")
                            }
                            if let url = try? output.url(in: session.store.media), FileManager.default.fileExists(atPath: url.path) {
                                ShareLink(item: url) { Label("导出副本", systemImage: "square.and.arrow.up") }.buttonStyle(.bordered)
                            }
                        }
                    } else if !session.busy {
                        Picker("压缩尺寸", selection: Binding(get: { job.preset }, set: { session.setPreset($0, id: id) })) {
                            ForEach(PhotoPreset.allCases) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented)
                        Text(job.preset.explanation).font(.footnote)
                        if job.stage == .awaitingDownload {
                            Text("原片大小需下载后核对。下载与成品均需本机空间，可能使用蜂窝数据。下载期间请保持 App 打开。")
                                .font(.footnote).foregroundStyle(.secondary)
                            if let capacity = session.capacity { Text("本机可用 \(capacity.available.storageDescription)") }
                            Button("下载照片并压缩") { session.compress([id], download: id) }
                                .buttonStyle(.borderedProminent).accessibilityIdentifier("download-photo")
                        } else {
                            Button(job.stage == .waiting ? "压缩这张照片" : "重试压缩") {
                                if job.stage == .waiting { session.compress([id]) } else { session.execute(.retry, ids: [id]) }
                            }.buttonStyle(.borderedProminent).accessibilityIdentifier("compress-photo")
                        }
                    }
                    if session.busy {
                        ProgressView(job.stage == .downloading ? "正在下载照片…" : "正在处理照片…").tint(Graphite.accent)
                        if job.stage == .downloading { SegmentedMeter(value: session.progress) }
                        if session.canCancel { Button("暂停处理", action: session.cancel).buttonStyle(.bordered) }
                    } else {
                        Button("移除任务", role: .destructive) { confirmDiscard = true }.buttonStyle(.bordered)
                    }
                }.padding(16).frame(maxWidth: 680).frame(maxWidth: .infinity)
            }
        }
        .background(Graphite.background.ignoresSafeArea()).navigationTitle("照片任务").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $zoom) {
            if let job = session.job(id), let original = session.file(job.sourceFileName),
               let output = try? job.output?.url(in: session.store.media) {
                PhotoCompareSheet(original: original, compressed: output)
            }
        }
        .alert("将照片原片移到「最近删除」？", isPresented: $confirmReplace) {
            Button("移到「最近删除」", role: .destructive) { session.replace(id) }
            Button("取消", role: .cancel) {}
        } message: { Text("压缩件已保存并核验。启用 iCloud 照片时，删除会同步到其他设备。原片在系统清理前仍可能占用空间。") }
        .alert("移除这条照片任务？", isPresented: $confirmDiscard) {
            Button("移除任务", role: .destructive) { session.discard(id); dismiss() }
            Button("取消", role: .cancel) {}
        } message: { Text("将清理任务和 App 内的临时文件，系统照片库中的原片与已保存成品保留。") }
    }
}

struct PhotoPreviewTile: View {
    let url: URL
    let label: String
    @State private var preview: UIImage?
    var body: some View {
        VStack {
            if let preview { Image(uiImage: preview).resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 160) }
            else { Color.clear.frame(height: 160).overlay(Image(systemName: "photo")) }
            Text(label).font(.caption)
        }
        .task(id: url) {
            let image = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 600
                      ] as CFDictionary) else { return nil as UIImage? }
                return UIImage(cgImage: image)
            }.value
            if !Task.isCancelled { preview = image }
        }
    }
}

struct PhotoCompareSheet: View {
    @Environment(\.dismiss) private var dismiss
    let original: URL
    let compressed: URL
    @State private var showOriginal = false
    var body: some View {
        NavigationStack {
            VStack {
                Picker("照片版本", selection: $showOriginal) {
                    Text("原片").tag(true); Text("压缩件").tag(false)
                }.pickerStyle(.segmented).padding()
                ZoomPhoto(url: showOriginal ? original : compressed).accessibilityIdentifier("photo-zoom")
                Text("双指缩放，拖动查看；切换版本会回到全图。").font(.footnote).foregroundStyle(.secondary).padding()
            }
            .background(Graphite.background).navigationTitle("放大对比").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.tint(Graphite.accent)
    }
}

struct ZoomPhoto: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> PhotoScrollView { PhotoScrollView() }
    func updateUIView(_ view: PhotoScrollView, context: Context) { view.load(url) }
}

final class PhotoScrollView: UIScrollView, UIScrollViewDelegate {
    private let photo = UIImageView()
    private var url: URL?
    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self; minimumZoomScale = 1; maximumZoomScale = 8
        photo.contentMode = .scaleAspectFit; addSubview(photo)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func load(_ url: URL) {
        guard self.url != url else { return }
        self.url = url; setZoomScale(1, animated: false)
        photo.image = UIImage(contentsOfFile: url.path)
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale == 1 { photo.frame = CGRect(origin: .zero, size: bounds.size); contentSize = bounds.size }
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { photo }
}
