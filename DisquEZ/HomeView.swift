import Photos
import SwiftUI

struct HomeView: View {
    let session: CompressionSession
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var photos = PhotoSession()
    @State private var files = FileSession()
    @State private var archives = ArchiveSession()
    @State private var defaults = CompressionDefaultStore()
    @State private var catalog = VideoCatalog()
    @State private var catalogReload = 0
    @State private var tab = RootTab.home
    @State private var picker: IntakeRoute?
    @State private var focus: TaskBatchFocus?
    @State private var exporting = false
    @State private var requestingPermission = false
    @State private var homeMessage: String?

    private enum RootTab { case home, tasks, settings }
    private enum IntakeRoute: String, Identifiable {
        case videos, large, photos, files, pdf, delete
        var id: Self { self }
    }

    private var busy: Bool { session.isBusy || photos.busy || files.busy || archives.busy || exporting }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { dashboard }
                .tabItem { Label("首页", systemImage: "house") }.tag(RootTab.home)
            WorkspaceTasksView(videos: session, photos: photos, files: files, archives: archives, focus: focus, exporting: $exporting) {
                tab = .home
            }
            .tabItem { Label("任务", systemImage: "tray.full") }.tag(RootTab.tasks)
            NavigationStack { settings }
                .tabItem { Label("设置", systemImage: "gearshape") }.tag(RootTab.settings)
        }
        .tint(Graphite.accent)
        .sheet(item: $picker) { route in
            let intake = CompressionIntake(videos: session, photos: photos, files: files, archives: archives,
                                           defaults: defaults.values, close: { picker = nil }, complete: showBatch)
            switch route {
            case .photos:
                PhotoSelectionView(excludedIDs: Set(photos.jobs.map(\.original.identifier)), intake: intake)
            case .files, .pdf:
                FileIntakeView(intake: intake, pdfOnly: route == .pdf)
            case .videos, .large, .delete:
                VideoPicker(catalog: catalog, initialFilter: route == .large ? .large : .all,
                            preset: defaults.values.video, encoding: defaults.values.encoding,
                            excludedIDs: Set(session.jobs.map(\.original.identifier)), deletingMode: route == .delete,
                            reload: reloadCatalog, intake: intake)
                    .environment(\.directDeletionRecorder, session)
            }
        }
        .task(id: catalogReload) { await catalog.refresh() }
        .onChange(of: session.work) { previous, current in
            if current == nil, previous == .saving || previous == .replacing { reloadCatalog() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                session.refreshCapacity()
                photos.refreshCapacity()
                reloadCatalog()
            }
            if phase == .background {
                session.appDidEnterBackground()
                photos.cancel()
                files.cancel()
                archives.cancel()
            }
        }
    }

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                capacityPanel
                if let homeMessage {
                    Text(homeMessage).font(.body).accessibilityIdentifier("session-message")
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("压缩").font(.headline).accessibilityAddTraits(.isHeader).padding(.horizontal, 4)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12),
                                             count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                        compressionTile("视频压缩", icon: "film", identifier: "choose-video") { openVideo(.videos) }
                            .disabled(busy || requestingPermission || !session.persistenceAvailable)
                        compressionTile("照片压缩", icon: "photo", identifier: "open-photos") { picker = .photos }
                            .disabled(busy || requestingPermission || !photos.healthy)
                        compressionTile("文件压缩", icon: "folder", identifier: "open-files") { picker = .files }
                            .disabled(busy || !files.healthy)
                        compressionTile("PDF 优化", icon: "doc.richtext", identifier: "open-pdf") { picker = .pdf }
                            .disabled(busy || !files.healthy)
                    }
                }
                VStack(spacing: 0) {
                    NavigationLink {
                        organizationTools
                    } label: { GraphiteNavigationRow(title: "整理与清理", icon: "square.grid.2x2") }
                        .accessibilityIdentifier("open-organization")
                    Divider().padding(.leading, 52)
                    NavigationLink {
                        ArchiveWorkspace(session: archives).toolbar(.hidden, for: .tabBar)
                    } label: { GraphiteNavigationRow(title: "原片归档", icon: "externaldrive") }
                        .disabled(busy).accessibilityIdentifier("open-archives")
                }.background(Graphite.panel, in: RoundedRectangle(cornerRadius: 18))
                if pendingCount > 0 || busy {
                    Button { tab = .tasks } label: {
                        GraphiteNavigationRow(title: busy ? "查看处理进度" : "待处理任务", icon: "tray.full",
                                              value: "\(pendingCount) 项")
                    }.accessibilityIdentifier("open-tasks")
                }
            }.buttonStyle(.plain).padding(16).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
        .background(Graphite.background.ignoresSafeArea())
        .navigationTitle("首页")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var pendingCount: Int {
        session.jobs.filter { !$0.stage.isClosed && $0.stage != .cancelled }.count
            + photos.jobs.filter { !$0.stage.isClosed && $0.stage != .cancelled }.count
            + files.jobs.filter { ![.restored, .replaced, .cancelled].contains($0.stage) }.count
    }

    private func compressionTile(_ title: String, icon: String, identifier: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: icon).font(.title2).foregroundStyle(Graphite.accent).accessibilityHidden(true)
                Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .padding(18).background(Graphite.panel, in: RoundedRectangle(cornerRadius: 18))
            .contentShape(Rectangle())
        }.accessibilityIdentifier(identifier)
    }

    private var organizationTools: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                GraphiteSection(title: "查找与整理") {
                    Button { openVideo(.large) } label: { GraphiteNavigationRow(title: "大视频", icon: "film.stack") }
                        .disabled(busy || requestingPermission || !session.persistenceAvailable)
                        .accessibilityIdentifier("browse-large-videos")
                    Divider().padding(.leading, 52)
                    NavigationLink {
                        OrganizerView()
                    } label: { GraphiteNavigationRow(title: "重复与相似项", icon: "square.on.square") }
                        .disabled(busy).accessibilityIdentifier("open-organizer")
                    Divider().padding(.leading, 52)
                    NavigationLink {
                        SpacePlanView(videos: session, photos: photos, files: files, archives: archives)
                    } label: { GraphiteNavigationRow(title: "统一空间清单", icon: "list.bullet.rectangle") }
                        .disabled(busy).accessibilityIdentifier("open-space-plan")
                }
                GraphiteSection(title: "移除原片") {
                    Button { openVideo(.delete) } label: { GraphiteNavigationRow(title: "直接删除原视频", icon: "trash") }
                        .disabled(busy || requestingPermission || !session.persistenceAvailable)
                        .accessibilityIdentifier("open-direct-delete")
                }
                if let homeMessage { Text(homeMessage).font(.body) }
            }.buttonStyle(.plain).padding(16).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
        .background(Graphite.background.ignoresSafeArea()).navigationTitle("整理与清理")
        .navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar)
    }

    private var capacityPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("本机可用空间").font(.body).foregroundStyle(.secondary)
            if let capacity = session.capacity {
                Text(capacity.available.storageDescription)
                    .font(.system(.largeTitle, weight: .bold)).monospacedDigit().accessibilityIdentifier("available-space")
                let used = max(0, 1 - Double(capacity.available) / Double(capacity.total))
                SegmentedMeter(value: used)
            } else { Text("暂时无法读取容量").font(.headline) }
        }.graphitePanel()
    }

    private var settings: some View {
        List {
            Section {
                defaultSettingsLink("视频", kind: .video, value: defaults.values.video.rawValue, identifier: "video-defaults")
                defaultSettingsLink("照片", kind: .photo, value: defaults.values.photo.rawValue, identifier: "photo-defaults")
                defaultSettingsLink("PDF", kind: .pdf, value: defaults.values.pdf.rawValue, identifier: "pdf-defaults")
            } header: { Text("默认压缩参数") } footer: { Text("用于新建任务，每批可单独调整。") }
            Section {
                ProfessionalSettingsButton(initial: .init(preset: defaults.values.video, encoding: defaults.values.encoding),
                                           targetCount: 0, title: "专业视频与预设")
            }
            Section("权限与应用") {
                NavigationLink("照片访问") { PhotoAccessSettings() }
                    .accessibilityIdentifier("photo-access-settings")
                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                   let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                    LabeledContent("版本", value: "\(version)（\(build)）").accessibilityIdentifier("app-version")
                }
            }
            if let message = defaults.message { Text(message).font(.body) }
        }
        .listRowBackground(Graphite.panel)
        .scrollContentBackground(.hidden).background(Graphite.background.ignoresSafeArea())
        .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
    }

    private func defaultSettingsLink(_ title: String, kind: FileMediaKind, value: String, identifier: String) -> some View {
        NavigationLink {
            ScrollView {
                CompressionParameterFields(values: Binding(get: { defaults.values }, set: { defaults.save($0) }), kinds: [kind])
                    .disabled(!defaults.readable).graphitePanel().padding(16)
            }
            .background(Graphite.background.ignoresSafeArea()).navigationTitle("\(title)默认参数")
            .navigationBarTitleDisplayMode(.inline)
        } label: { LabeledContent(title, value: value) }
            .accessibilityIdentifier(identifier)
    }

    private func showBatch(_ keys: [WorkspaceTaskID]) {
        guard !keys.isEmpty else { return }
        picker = nil
        focus = TaskBatchFocus(keys: keys)
        tab = .tasks
    }

    private func reloadCatalog() { catalogReload += 1 }

    private func openVideo(_ route: IntakeRoute) {
        guard !requestingPermission, !busy, session.persistenceAvailable else { return }
        requestingPermission = true
        Task {
            defer { requestingPermission = false }
            let access = PhotoLibrary.access == .notDetermined
                ? await PHPhotoLibrary.requestAuthorization(for: .readWrite) : PhotoLibrary.access
            if access == .authorized || access == .limited {
                homeMessage = nil
                reloadCatalog()
                picker = route
            } else {
                homeMessage = "需要照片库访问权限。可在「设置」中管理照片权限。"
            }
        }
    }
}

private struct PhotoAccessSettings: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var access = PhotoLibrary.access
    @State private var requesting = false

    var body: some View {
        List {
            Section {
                Text(status).font(.body).foregroundStyle(.secondary)
                Button(access == .notDetermined ? "请求照片权限" : "打开系统设置") {
                    if access == .notDetermined {
                        requesting = true
                        Task {
                            access = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                            requesting = false
                        }
                    } else if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }.buttonStyle(.bordered).disabled(requesting).accessibilityIdentifier("manage-photo-access")
            }
        }.scrollContentBackground(.hidden).background(Graphite.background)
            .navigationTitle("照片访问").navigationBarTitleDisplayMode(.inline)
            .onAppear { access = PhotoLibrary.access }
            .onChange(of: scenePhase) { _, phase in if phase == .active { access = PhotoLibrary.access } }
    }

    private var status: String {
        switch access {
        case .authorized: "已允许访问照片库"
        case .limited: "仅可访问你允许的照片和视频"
        case .notDetermined: "尚未请求访问"
        default: "当前无法访问照片库"
        }
    }
}
