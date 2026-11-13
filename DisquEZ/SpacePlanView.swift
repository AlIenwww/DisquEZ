import Photos
import SwiftUI

struct SpacePlanView: View {
    let videos: CompressionSession
    let photos: PhotoSession
    let files: FileSession
    let archives: ArchiveSession
    @Environment(\.scenePhase) private var scenePhase
    @State private var planner = SpacePlanner()
    @State private var goal = ""
    @State private var action: SpaceAction?
    @State private var review: Review?
    @State private var opened: SpaceProposal?
    @State private var showingExclusions = false
    @State private var albums: [SpaceAlbum] = []
    @FocusState private var editingGoal: Bool

    private struct Review: Identifiable {
        enum Destination {
            case group(MediaGroup, OrganizerSession)
            case video(UUID), photo(UUID), file(UUID)
            case newArchive(Set<UUID>), archive(UUID, UUID)
        }
        let id = UUID()
        let destination: Destination
    }

    var body: some View {
        let plan = planner.plan
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                totals(plan)
                controls
                if planner.scanning {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(planner.status).monospacedDigit()
                        SegmentedMeter(value: planner.progress)
                        Button("停止扫描", action: planner.cancel).buttonStyle(.bordered).accessibilityIdentifier("stop-space-scan")
                    }.graphitePanel()
                }
                if let message = planner.message { Text(message).font(.footnote).accessibilityIdentifier("space-message") }
                if planner.ready {
                    Picker("显示操作", selection: $action) {
                        Text("全部").tag(Optional<SpaceAction>.none)
                        ForEach(SpaceAction.allCases) { Text($0.rawValue).tag(Optional($0)) }
                    }.pickerStyle(.menu).accessibilityIdentifier("space-action-filter")
                    let visible = plan.proposals.filter { action == nil || action == $0.action }
                    if visible.isEmpty {
                        ContentUnavailableView("当前没有候选", systemImage: "checklist",
                            description: Text("可调整筛选范围，或先在文件压缩中生成成品。"))
                    }
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, proposal in
                        proposalRow(proposal, suggested: plan.suggestedIDs.contains(proposal.id), index: index)
                    }
                }
            }.padding(16).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Graphite.background.ignoresSafeArea())
        .navigationTitle("统一空间清单")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { goal = String(planner.preferences.goalMB); planner.refreshAccess() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { planner.cancel() }
            if phase == .active { planner.refreshAccess() }
        }
        .onDisappear { planner.cancel() }
        .sheet(isPresented: $showingExclusions) { exclusions }
        .sheet(item: $review, onDismiss: {
            if let opened { planner.finishedReview(opened, videos: videos, photos: photos, files: files) }
            opened = nil
        }) { value in
            NavigationStack {
                reviewPage(value).toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("返回清单") { review = nil }.disabled(reviewBusy(value)) }
                }
            }.tint(Graphite.accent).interactiveDismissDisabled(reviewBusy(value))
        }
    }

    private func totals(_ plan: SpacePlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("清单预计收益").font(.headline)
            Text(plan.totalBytes.storageDescription).font(.system(.largeTitle, design: .monospaced).weight(.bold))
                .foregroundStyle(Graphite.accent).accessibilityIdentifier("space-estimated-total")
            SegmentedMeter(value: min(1, Double(plan.suggestedBytes) / Double(planner.preferences.goalBytes)))
            LabeledContent("目标", value: planner.preferences.goalBytes.storageDescription)
            LabeledContent("建议处理 \(plan.suggestedIDs.count) 项", value: plan.suggestedBytes.storageDescription)
                .accessibilityIdentifier("space-suggested-total")
            if let capacity = planner.capacity {
                LabeledContent("本机可用空间", value: capacity.available.storageDescription).accessibilityIdentifier("space-current-capacity")
            }
            DisclosureGroup("收益说明") {
                Text("收益按原文件大小估算。同一素材只计一次，实际空间取决于系统储存、最近删除及恢复副本。")
                    .font(.body).foregroundStyle(.secondary).padding(.top, 8)
            }.font(.body)
        }.graphitePanel()
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("希望腾出空间（MB）").font(.subheadline.weight(.semibold))
            HStack {
                TextField("希望腾出多少 MB", text: $goal).keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder).focused($editingGoal)
                    .accessibilityLabel("希望腾出空间，单位 MB").accessibilityIdentifier("space-goal-mb")
                Button("保存目标") {
                    guard let value = Int(goal), SpacePreferences.goalRange.contains(value) else {
                        planner.message = "请输入 1–1000000 MB 的目标。"
                        return
                    }
                    planner.update { $0.goalMB = value }
                    editingGoal = false
                }.buttonStyle(.bordered).accessibilityIdentifier("save-space-goal")
            }
            Picker("优先方式", selection: Binding(get: { planner.preferences.strategy }, set: { value in planner.update { $0.strategy = value } })) {
                ForEach(SpaceStrategy.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("space-strategy")
            DisclosureGroup("扫描范围与排除项") {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle("排除收藏", isOn: Binding(get: { planner.preferences.excludeFavorites }, set: { value in planner.update { $0.excludeFavorites = value } }))
                        .accessibilityIdentifier("space-exclude-favorites")
                    Picker("照片库扫描范围", selection: Binding(get: { planner.preferences.scanLimit }, set: { value in planner.update { $0.scanLimit = value } })) {
                        ForEach(SpacePreferences.scanLimits, id: \.self) { Text("最近 \($0) 项").tag($0) }
                    }.pickerStyle(.menu).accessibilityIdentifier("space-scan-limit")
                    Button("排除相簿（\(planner.preferences.albumIDs.count)）与忽略项（\(planner.preferences.ignored.count)）") {
                        albums = SpacePlanner.albums()
                        showingExclusions = true
                    }.buttonStyle(.bordered).accessibilityIdentifier("space-exclusions")
                    Text("仅读取获准访问的本机素材和已完成的文件任务。")
                        .font(.body).foregroundStyle(.secondary)
                }.padding(.top, 8)
            }.font(.body)
            PrimaryAction(title: planner.ready ? "重新生成清单" : "生成空间清单", icon: "list.bullet.rectangle", identifier: "scan-space-plan") {
                planner.scan(videos: videos, photos: photos, files: files, archives: archives)
            }
        }.graphitePanel().disabled(planner.scanning || !planner.healthy)
    }

    private var exclusions: some View {
        NavigationStack {
            List {
                Section("排除指定相簿") {
                    if PhotoLibrary.access != .authorized { Text("核对指定相簿需要完整照片访问。") }
                    ForEach(albums) { album in
                        Toggle(album.title, isOn: Binding(get: { planner.preferences.albumIDs.contains(album.id) }, set: { excluded in
                            planner.update { value in
                                if excluded { value.albumIDs.insert(album.id) }
                                else { value.albumIDs.remove(album.id) }
                            }
                        })).accessibilityIdentifier("space-album-\(album.title)")
                    }
                    if !planner.preferences.albumIDs.isEmpty {
                        Button("清空相簿排除") { planner.update { $0.albumIDs = [] } }
                    }
                }
                Section("已忽略素材") {
                    if planner.preferences.ignored.isEmpty { Text("暂无忽略项").foregroundStyle(.secondary) }
                    ForEach(planner.preferences.ignored) { item in
                        HStack {
                            Text(item.title)
                            Spacer()
                            Button("重新纳入") { planner.update { $0.ignored.removeAll { $0.id == item.id } } }
                                .buttonStyle(.borderless).accessibilityIdentifier("include-space-item")
                        }
                    }
                }
            }.scrollContentBackground(.hidden).background(Graphite.background)
                .navigationTitle("清单筛选").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingExclusions = false } } }
        }.tint(Graphite.accent)
    }

    private func proposalRow(_ proposal: SpaceProposal, suggested: Bool, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(proposal.action.rawValue).foregroundStyle(Graphite.accent)
                if suggested { Text("建议处理").font(.caption).padding(.horizontal, 7).padding(.vertical, 3).background(Graphite.accent.opacity(0.15), in: Capsule()) }
                Spacer()
                Text(proposal.bytes.map { "约 \($0.storageDescription)" } ?? "待复核").monospacedDigit()
            }.font(.subheadline.weight(.semibold))
            Text(proposal.title).font(.headline)
            Text(proposal.note).font(.footnote).foregroundStyle(.secondary)
            HStack {
                Button("打开复核") { open(proposal) }.buttonStyle(.bordered).accessibilityIdentifier("space-review-\(index)")
                Button(proposal.members.count > 1 ? "忽略本组" : "忽略") { planner.ignore(proposal) }.buttonStyle(.borderless)
                    .accessibilityIdentifier("space-ignore-\(index)")
            }
        }.graphitePanel()
    }

    private func open(_ proposal: SpaceProposal) {
        guard !planner.scanning, !videos.isBusy, !photos.busy, !files.busy, !archives.busy else { return }
        let current = proposal.members.compactMap(planner.current)
        guard current.count == proposal.members.count else {
            planner.finishedReview(proposal, videos: videos, photos: photos, files: files)
            return
        }
        let destination: Review.Destination
        switch proposal.route {
        case .group(let group):
            let restrictions = planner.preferences.restrictions
            let organizer = OrganizerSession(groups: [group]) { restrictions.allows($0) }
            destination = .group(group, organizer)
        case .video(let member):
            let existing = videos.jobs.first { $0.original.identifier == member.id }
            guard let id = existing?.id ?? videos.enqueue(current).first else { planner.message = "暂时无法加入视频任务。"; return }
            destination = .video(id)
        case .photo(let member):
            if !photos.jobs.contains(where: { $0.original.identifier == member.id }) { photos.enqueue(current, using: .balanced) }
            guard let job = photos.jobs.first(where: { $0.original.identifier == member.id }) else { planner.message = "暂时无法加入照片任务。"; return }
            destination = .photo(job.id)
        case .newArchive:
            archives.addPhotos(current)
            destination = .newArchive(Set(archives.selections.filter { $0.protection == nil }.map(\.id)))
        case .archive(let record, let item, _):
            guard archives.record(record) != nil else { planner.message = "找不到归档记录，请重新扫描。"; return }
            destination = .archive(record, item)
        case .file(let id):
            guard let job = files.job(id), FileReplacement.reason(job, store: files.store) == nil else {
                planner.message = "文件任务已变化，请重新扫描。"
                return
            }
            destination = .file(id)
        }
        opened = proposal
        review = Review(destination: destination)
    }

    @ViewBuilder private func reviewPage(_ value: Review) -> some View {
        switch value.destination {
        case .group(let group, let session): GroupReviewView(session: session, group: group)
        case .video(let id): CompressionJobView(session: videos, id: id)
        case .photo(let id): PhotoJobDetail(session: photos, id: id)
        case .file(let id): FileJobView(session: files, id: id)
        case .newArchive(let selected): ArchiveWorkspace(session: archives, preselected: selected)
        case .archive(let id, let selected): ArchiveDetailView(session: archives, id: id, preselected: [selected])
        }
    }

    private func reviewBusy(_ value: Review) -> Bool {
        if case .group(_, let session) = value.destination { return session.removing }
        return videos.isBusy || photos.busy || files.busy || archives.busy
    }
}
