import Photos
import PhotosUI
import SwiftUI

struct VideoPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var filter: VideoFilter
    @State private var sort: VideoSort
    @State private var selectedIDs: [String] = []
    @State private var sections: [CatalogSection] = []
    @State private var measurementTargets: [CatalogVideo] = []
    @State private var measurementTask: Task<Void, Never>?
    @State private var measurementProgress: (done: Int, total: Int)?
    @State private var stoppingMeasurement = false
    @State private var notice: String?
    @State private var draft: CompressionDraft?
    @State private var reviewing = false
    @State private var directSnapshots: [PhotoSnapshot] = []
    @State private var directReview = false
    @State private var showingInformation = false
    @State private var showingDetails = false
    @Environment(\.directDeletionRecorder) private var deletionRecorder

    let catalog: VideoCatalog
    let preset: CompressionPreset
    let encoding: VideoEncoding
    let excludedIDs: Set<String>
    let reload: () -> Void
    let deletingMode: Bool
    let intake: CompressionIntake

    init(catalog: VideoCatalog, initialFilter: VideoFilter, preset: CompressionPreset, encoding: VideoEncoding,
         excludedIDs: Set<String>, deletingMode: Bool = false,
         reload: @escaping () -> Void, intake: CompressionIntake) {
        self.catalog = catalog
        self.preset = preset
        self.encoding = encoding
        self.excludedIDs = excludedIDs
        self.reload = reload
        self.deletingMode = deletingMode
        self.intake = intake
        _filter = State(initialValue: initialFilter)
        _sort = State(initialValue: initialFilter == .large ? .size : .recent)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        controls.id("catalog-top")
                        if catalog.isLoading && catalog.items.isEmpty {
                            ProgressView("正在读取照片库…").frame(maxWidth: .infinity).padding(24)
                        } else if catalog.items.isEmpty {
                            ContentUnavailableView("没有可访问的视频", systemImage: "film",
                                                   description: Text("请确认照片库中有视频，或调整已允许访问的项目。"))
                        } else if sections.isEmpty {
                            ContentUnavailableView("没有符合条件的视频", systemImage: "line.3.horizontal.decrease",
                                                   description: Text("试试切换筛选条件。"))
                        } else {
                            ForEach(sections) { section in
                                Section {
                                    ForEach(section.videoIDs, id: \.self) { id in
                                        CatalogVideoRow(id: id, catalog: catalog, preset: preset, encoding: encoding,
                                                        sort: sort, isQueued: !deletingMode && excludedIDs.contains(id), deleting: deletingMode,
                                                        detailed: showingDetails,
                                                        selectedIDs: $selectedIDs)
                                    }
                                } header: {
                                    sectionHeader(section.id)
                                }
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: 680)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: filter) { _, _ in
                    notice = nil
                    rebuild()
                    scroll.scrollTo("catalog-top", anchor: .top)
                }
                .onChange(of: sort) { _, _ in
                    rebuild()
                    scroll.scrollTo("catalog-top", anchor: .top)
                }
                .onChange(of: catalog.version, initial: true) { _, _ in rebuild() }
            }
            .background(Graphite.background.ignoresSafeArea())
            .navigationTitle(deletingMode ? "直接删除原视频" : "选择视频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(deletingMode ? "复核删除（\(selectedIDs.count)）" : "下一步（\(selectedIDs.count)）", role: deletingMode ? .destructive : nil, action: confirm)
                    .disabled(selectedIDs.isEmpty)
                    .accessibilityIdentifier("confirm-selection")
                }
                if PhotoLibrary.access == .limited {
                    ToolbarItem(placement: .primaryAction) {
                        Button("管理权限", action: manageAccess)
                    }
                }
            }
            .navigationDestination(isPresented: $reviewing) {
                if let draft { BatchConfirmation(draft: draft, intake: intake) }
            }
            .sheet(isPresented: $directReview, onDismiss: { reload(); Task { await catalog.refresh() } }) {
                DirectVideoDeletionView(snapshots: directSnapshots, willSubmit: {
                    try deletionRecorder?.recordDirectDeletion($0, state: .removing)
                }, finished: { snapshots, success in
                    try? deletionRecorder?.recordDirectDeletion(snapshots, state: success ? .removed : .pending)
                    if success { selectedIDs.removeAll() }
                })
            }
            .sheet(isPresented: $showingInformation) {
                NavigationStack {
                    List {
                        if let caption = filter.caption { Section("当前筛选") { Text(caption) } }
                        Section("测量本机视频") {
                            Text("读取当前筛选内的本机视频信息，不下载 iCloud 原片。")
                            Text("大小或帧率未知的素材会单独列出，测量后可重新判断。")
                        }
                        Section("预计收益") {
                            Text("按\(preset.rawValue)档和 \(encoding.title) 估算，实际大小以压缩结果为准。")
                        }
                    }.navigationTitle("视频信息说明").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingInformation = false } } }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { stopMeasurement() }
            }
            .onDisappear { measurementTask?.cancel() }
        }
        .tint(Graphite.accent)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 9) {
            if deletingMode {
                Text("下一步逐项复核要删除的原视频。").font(.body).foregroundStyle(.secondary)
                Button("全选当前范围") {
                    selectedIDs = sections.flatMap(\.videoIDs).filter { id in
                        guard let photo = PhotoLibrary.fetch(id) else { return false }
                        return photo.canPerform(.delete)
                    }
                }.accessibilityIdentifier("catalog-delete-select-all")
            }
            ViewThatFits(in: .horizontal) {
                HStack {
                    filterMenu
                    Spacer(minLength: 10)
                    sortMenu
                }
                VStack(alignment: .leading, spacing: 8) {
                    filterMenu
                    sortMenu
                }
            }
            HStack {
                if measurementTask != nil {
                    measurementAction
                }
                Spacer(minLength: 8)
                Menu {
                    Toggle("显示详细参数", isOn: $showingDetails).accessibilityIdentifier("catalog-details")
                    if measurementTask == nil { measurementAction }
                    Button("筛选与测量说明", systemImage: "info.circle") { showingInformation = true }
                } label: {
                    Label("更多", systemImage: "ellipsis.circle").frame(minHeight: 44)
                }.accessibilityIdentifier("catalog-more")
            }
            if let progress = measurementProgress {
                ProgressView(value: Double(progress.done), total: Double(progress.total)) {
                    Text(stoppingMeasurement ? "正在停止测量…" : "测量本机视频 \(progress.done)/\(progress.total)")
                        .font(.subheadline.monospacedDigit())
                }
            }
            if let notice {
                Text(notice).font(.body).foregroundStyle(.secondary)
                    .accessibilityIdentifier("catalog-notice")
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            ForEach(VideoFilter.allCases) { item in
                Button {
                    filter = item
                } label: {
                    if filter == item { Label(item.title, systemImage: "checkmark") }
                    else { Text(item.title) }
                }.accessibilityIdentifier("catalog-filter-\(item.rawValue)")
            }
        } label: {
            Label(filter.title, systemImage: "line.3.horizontal.decrease").font(.body).frame(minHeight: 44)
        }.accessibilityLabel("视频筛选").accessibilityValue(filter.title)
            .accessibilityIdentifier("catalog-filters")
    }

    private var sortMenu: some View {
        Menu {
            ForEach(VideoSort.allCases) { item in
                Button { sort = item } label: {
                    if sort == item { Label(item.title, systemImage: "checkmark") }
                    else { Text(item.title) }
                }
                .accessibilityIdentifier("catalog-sort-\(item.rawValue)")
            }
        } label: {
            Label(sort.title, systemImage: "arrow.up.arrow.down").font(.body)
                .frame(minHeight: 44)
        }
        .accessibilityLabel("排序")
        .accessibilityValue(sort.title)
        .accessibilityIdentifier("catalog-sort")
    }

    @ViewBuilder
    private var measurementAction: some View {
        if measurementTask != nil {
            Button("停止测量", action: stopMeasurement)
                .buttonStyle(.bordered).disabled(stoppingMeasurement)
                .accessibilityIdentifier("stop-measuring")
        } else {
            Button("测量本机视频", action: startMeasurement)
                .buttonStyle(.bordered)
                .disabled(measurementTargets.isEmpty || catalog.isLoading)
                .accessibilityHint("读取当前筛选中的视频信息，不下载 iCloud 原片。")
                .accessibilityIdentifier("measure-catalog")
        }
    }

    private func sectionHeader(_ section: CatalogVideo.Section) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(section.title).font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("catalog-section-\(section.rawValue)")
            if section == .unknownSize, filter == .large {
                Text("测量后可判断这些视频是否符合大视频条件。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if section == .unknownFrameRate {
                Text("测量本机视频后可判断帧率。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 5)
        .padding(.horizontal, 4)
    }

    private func rebuild() {
        sections = CatalogSection.make(catalog.items, filter: filter, sort: sort, preset: preset, encoding: encoding)
        measurementTargets = sections.flatMap(\.videoIDs)
            .compactMap { catalog.item(with: $0)?.video }.filter(\.needsMeasurement)
        if !selectedIDs.isEmpty, !catalog.isLoading {
            let accessible = Set(catalog.items.map(\.id))
            selectedIDs.removeAll { !accessible.contains($0) }
        }
    }

    private func startMeasurement() {
        guard measurementTask == nil, !measurementTargets.isEmpty else { return }
        let targets = measurementTargets
        notice = nil
        measurementProgress = (0, targets.count)
        measurementTask = Task {
            var results: [String: (CatalogVideo.Revision, VideoMeasurement)] = [:]
            var localCount = 0
            for video in targets {
                guard !Task.isCancelled, let result = try? await PhotoLibrary.measureVideo(video),
                      !Task.isCancelled else { break }
                if case .local = result { localCount += 1 }
                results[video.id] = (video.revision, result)
                measurementProgress = (results.count, targets.count)
            }
            catalog.apply(results)
            if !results.isEmpty {
                let remaining = results.count - localCount
                notice = remaining > 0 ? "已测 \(localCount) 条，\(remaining) 条未读到本机信息。" : "已测 \(localCount) 条本机视频。"
            }
            measurementProgress = nil
            measurementTask = nil
            stoppingMeasurement = false
        }
    }

    private func stopMeasurement() {
        guard let measurementTask else { return }
        stoppingMeasurement = true
        measurementTask.cancel()
    }

    private func confirm() {
        let photos = selectedIDs.compactMap(PhotoLibrary.fetch)
        if photos.count == selectedIDs.count, !photos.isEmpty {
            if deletingMode { directSnapshots = photos.map(PhotoSnapshot.init); directReview = true }
            else {
                let source = CompressionSource.videos(photos.map(PhotoSnapshot.init))
                if let draft { draft.source = source }
                else { draft = CompressionDraft(source: source, parameters: intake.defaults) }
                reviewing = true
            }
        } else {
            selectedIDs = photos.map(\.localIdentifier)
            notice = "部分视频已无法访问，请检查剩余选项后再添加。"
            reload()
        }
    }

    private func manageAccess() {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard var presenter = scene?.keyWindow?.rootViewController else { return }
        while let presented = presenter.presentedViewController { presenter = presented }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: presenter) { _ in
            Task { @MainActor in
                stopMeasurement()
                catalog.invalidateLimitedAccess()
                reload()
            }
        }
    }
}

private struct CatalogVideoRow: View {
    let id: String
    let catalog: VideoCatalog
    let preset: CompressionPreset
    let encoding: VideoEncoding
    let sort: VideoSort
    let isQueued: Bool
    var deleting = false
    var detailed = false
    @Binding var selectedIDs: [String]

    var body: some View {
        // Read the live record by ID, including when a measurement moves this row to another section.
        if let item = catalog.item(with: id) { row(item) }
    }

    private func row(_ item: CatalogItem) -> some View {
        let video = item.video
        let isSelected = selectedIDs.contains(video.id)
        let isProtected = deleting ? !item.photo.canPerform(.delete) : video.protectedCaptureEffect != nil
        return Button {
            if let index = selectedIDs.firstIndex(of: video.id) { selectedIDs.remove(at: index) }
            else { selectedIDs.append(video.id) }
        } label: {
            HStack(spacing: 10) {
                PhotoThumbnail(photo: item.photo)
                VStack(alignment: .leading, spacing: 4) {
                    if let date = video.created {
                        Text(date, format: .dateTime.year().month().day().hour().minute())
                            .font(.body.weight(.medium))
                    } else {
                        Text("视频").font(.body.weight(.medium))
                    }
                    let resolution = "\(video.revision.width) × \(video.revision.height)"
                    Text(verbatim: "\(resolution) · \(video.durationLabel)")
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    if detailed {
                        if let fps = video.frameRate {
                            Text("\(fps.formatted(.number.precision(.fractionLength(0...2)))) fps")
                                .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        if let range = video.range, range != .sdr {
                            Text(range.title).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    videoReadouts(video)
                    if isQueued {
                        Text("已在队列").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: isProtected ? "lock" : isSelected || isQueued ? "checkmark.circle.fill" : "circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? Graphite.accent : .secondary)
                    .accessibilityHidden(true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Graphite.panel, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isQueued || isProtected)
        .accessibilityValue(isProtected ? "已保护" : isQueued ? "已在队列" : isSelected ? "已选择" : "未选择")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("video-row-\(video.id)")
    }

    @ViewBuilder
    private func videoReadouts(_ video: CatalogVideo) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let bytes = video.fileBytes {
                Text("文件大小 \(bytes.storageDescription)").monospacedDigit()
            } else {
                Text("文件大小未知")
            }
            if let effect = video.protectedCaptureEffect {
                Text("\(effect) · 跳过压缩")
            } else if sort == .savings, let savings = video.savings(preset: preset, encoding: encoding) {
                Text(savings > 0 ? "预计可省 \(savings.storageDescription)" : "预计收益较小")
                    .foregroundStyle(Graphite.accent).monospacedDigit()
            } else {
                switch video.measurement {
                case .local: EmptyView()
                case .cloudOnly: Text("原片未下载")
                case .unavailable: EmptyView()
                case nil: if sort == .savings { Text("预计收益待测") }
                }
            }
        }
        .font(.subheadline).foregroundStyle(.secondary)
    }
}

struct PhotoThumbnail: View {
    let photo: PHAsset
    var allowLocalFrame = false
    var size = CGSize(width: 82, height: 50)
    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        ZStack {
            Color.white.opacity(0.08)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: photo.mediaType == .image ? "photo" : "film").foregroundStyle(.secondary)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityHidden(true)
        .task(id: photo.localIdentifier) {
            if allowLocalFrame, image == nil, let frame = try? await PhotoLibrary.thumbnailFrame(for: photo),
               !Task.isCancelled, image == nil {
                image = UIImage(cgImage: frame)
            }
        }
        .onAppear {
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = false
            requestID = PHImageManager.default().requestImage(for: photo,
                                                              targetSize: CGSize(width: size.width * 3, height: size.height * 3),
                                                              contentMode: .aspectFill, options: options) { thumbnail, _ in
                guard let thumbnail else { return }
                Task { @MainActor in image = thumbnail }
            }
        }
        .onDisappear {
            if let requestID { PHImageManager.default().cancelImageRequest(requestID) }
        }
    }
}
