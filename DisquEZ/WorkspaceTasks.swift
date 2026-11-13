import Photos
import SwiftUI

enum WorkspaceTaskCategory: String, CaseIterable, Identifiable {
    case all = "全部", video = "视频", photo = "照片", file = "文件", pdf = "PDF"
    var id: Self { self }
}

struct WorkspaceTaskID: Hashable {
    let category: WorkspaceTaskCategory
    let id: UUID
}

struct TaskBatchFocus: Identifiable {
    let id = UUID()
    let keys: [WorkspaceTaskID]
}

private enum WorkspaceTaskFilter: String, CaseIterable, Identifiable {
    case all = "全部状态", waiting = "待开始", cloud = "待下载", active = "处理中"
    case result = "待保存或导出", review = "待核对", ended = "已结束"
    var id: Self { self }

    init(_ item: BatchTaskItem) {
        if let deletion = item.directDeletion {
            self = switch deletion {
            case .pending: .review
            case .removing: .active
            case .removed: .ended
            }
            return
        }
        self = switch item.stage {
        case .waiting: .waiting
        case .awaitingDownload: .cloud
        case .processing, .downloading, .saving, .removing: .active
        case .ready: .result
        case .savePending, .saved, .verified, .removalPending: .review
        case .failed, .skipped, .cancelled, .kept, .removed: .ended
        }
    }

    init(_ stage: FileJob.Stage) {
        self = switch stage {
        case .waiting: .waiting
        case .importing, .compressing, .replacing: .active
        case .ready: .result
        case .replacementPending: .review
        case .failed, .skipped, .replaced, .restored, .cancelled: .ended
        }
    }
}

private struct WorkspaceTask: Identifiable {
    let id: WorkspaceTaskID
    let title: String
    let status: String
    let filter: WorkspaceTaskFilter
    let original: PhotoSnapshot?

    init(_ item: BatchTaskItem, category: WorkspaceTaskCategory) {
        id = .init(category: category, id: item.id)
        title = item.title
        switch item.directDeletion {
        case .removed: status = "原片已直接删除 · 待系统清理"
        case .pending: status = "直接删除结果待核对"
        case .removing: status = "正在等待删除确认"
        case nil: status = item.stage.label
        }
        filter = WorkspaceTaskFilter(item)
        original = item.original
    }

    init(_ job: FileJob) {
        id = .init(category: job.kind == .pdf ? .pdf : .file, id: job.id)
        title = job.name
        status = job.stage.label
        filter = WorkspaceTaskFilter(job.stage)
        original = nil
    }
}

struct WorkspaceTasksView: View {
    let videos: CompressionSession
    let photos: PhotoSession
    let files: FileSession
    let archives: ArchiveSession
    let focus: TaskBatchFocus?
    @Binding var exporting: Bool
    let goHome: () -> Void
    @State private var path: [WorkspaceTaskID] = []
    @State private var category = WorkspaceTaskCategory.all
    @State private var filter = WorkspaceTaskFilter.all
    @State private var selected: Set<WorkspaceTaskID> = []
    @State private var currentBatch: Set<WorkspaceTaskID> = []
    @State private var showingBatch = false
    @State private var selecting = false
    @State private var scrollID: WorkspaceTaskID?
    @State private var review: Operation?
    @State private var directReview: DirectReview?
    @State private var afterReview: (() -> Void)?
    @State private var export: ExportSelection?
    @State private var operationMessage: String?

    private struct Operation: Identifiable {
        let id = UUID()
        let action: TaskBatchAction
        let category: WorkspaceTaskCategory
        let items: [WorkspaceTask]
    }

    private struct DirectReview: Identifiable {
        let id = UUID()
        let snapshots: [PhotoSnapshot]
    }

    private struct AvailableAction: Identifiable {
        let action: TaskBatchAction
        let count: Int
        var id: TaskBatchAction { action }
    }

    private var tasks: [WorkspaceTask] {
        let videoItems = videos.batchItems.map { item in
            WorkspaceTask(item, category: .video)
        }
        let photoItems = photos.batchItems.map { WorkspaceTask($0, category: .photo) }
        return videoItems + photoItems + files.jobs.map(WorkspaceTask.init)
    }

    var body: some View {
        let all = tasks
        let visible = all.filter {
            (category == .all || $0.id.category == category)
                && (filter == .all || $0.filter == filter)
                && (!showingBatch || currentBatch.contains($0.id))
        }
        let chosen = all.filter { selected.contains($0.id) }
        let hidden = selected.subtracting(Set(visible.map(\.id))).count

        NavigationStack(path: $path) {
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        controls(visible: visible)
                        progress
                        ForEach(messages, id: \.self) { Text($0).font(.body).accessibilityIdentifier("workspace-task-message") }
                        if visible.isEmpty {
                            ContentUnavailableView(all.isEmpty ? "还没有任务" : "当前范围没有任务",
                                                   systemImage: "tray", description: Text(all.isEmpty ? "从首页选择素材开始。" : "可以切换类型或状态筛选。"))
                            if all.isEmpty { Button("去首页选素材", action: goHome).buttonStyle(.bordered) }
                        }
                        LazyVStack(spacing: 0) {
                            ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                                if index > 0 { Divider().padding(.leading, 16) }
                                taskRow(item, checked: selected.contains(item.id), index: index)
                                    .id(item.id)
                            }
                        }
                        .background(Graphite.panel, in: RoundedRectangle(cornerRadius: 18))
                        .scrollTargetLayout()
                    }.padding(16).frame(maxWidth: 680).frame(maxWidth: .infinity)
                }
                .scrollPosition(id: $scrollID)
                .onChange(of: focus?.id, initial: true) { _, _ in
                    guard let focus else { return }
                    path = []
                    clearSelection()
                    let types = Set(focus.keys.map(\.category))
                    category = types.count == 1 ? (types.first ?? .all) : .all
                    filter = .all
                    currentBatch = Set(focus.keys)
                    showingBatch = true
                    scrollID = nil
                    reader.scrollTo("task-top", anchor: .top)
                }
            }
            .background(Graphite.background.ignoresSafeArea())
            .navigationTitle("任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if category != .all, !all.isEmpty {
                        Button(selecting ? "完成" : "多选") {
                            if selecting { clearSelection() } else { selecting = true }
                        }.accessibilityIdentifier("select-workspace-tasks")
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if selecting { actionBar(chosen, hidden: hidden) }
            }
            .onChange(of: all.map(\.id)) { _, ids in selected.formIntersection(ids) }
            .navigationDestination(for: WorkspaceTaskID.self) { detail($0) }
            .sheet(item: $review, onDismiss: {
                let next = afterReview
                afterReview = nil
                next?()
            }) { operation in
                WorkspaceOperationReview(action: operation.action, title: actionTitle(operation.action, category: operation.category),
                                         explanation: explanation(operation.action, category: operation.category),
                                         items: operation.items, reason: { reason($0, for: operation.action) }) { approved in
                    if operation.action == .deleteOriginal {
                        afterReview = { directReview = DirectReview(snapshots: approved.compactMap(\.original)) }
                    } else if operation.action == .export {
                        afterReview = { prepareExport(approved.map(\.id.id)) }
                    } else {
                        execute(operation, ids: approved.map(\.id.id))
                    }
                    review = nil
                }
            }
            .sheet(item: $directReview) { item in
                DirectVideoDeletionView(snapshots: item.snapshots, willSubmit: {
                    try videos.recordDirectDeletion($0, state: .removing)
                }, finished: { snapshots, success in
                    try? videos.recordDirectDeletion(snapshots, state: success ? .removed : .pending)
                })
            }
            .sheet(item: $export, onDismiss: { exporting = false }) { selection in
                SystemFilePicker(exporting: selection.urls, selected: { _ in
                    FileExports.clean(selection.urls)
                    operationMessage = "系统已完成副本导出。云盘同步状态可在「文件」中查看。"
                    export = nil
                }, cancelled: {
                    FileExports.clean(selection.urls)
                    export = nil
                })
                .interactiveDismissDisabled()
            }
        }
    }

    private func controls(visible: [WorkspaceTask]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack { categoryPicker; Spacer(); statusPicker }
                VStack(alignment: .leading) { categoryPicker; statusPicker }
            }
            if !currentBatch.isEmpty {
                HStack {
                    Text(showingBatch ? "本批任务" : "全部批次").foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button(showingBatch ? "显示全部" : "回到本批") { showingBatch.toggle() }
                        .accessibilityIdentifier("workspace-batch-scope")
                }.font(.subheadline)
            }
            if selecting {
                HStack {
                    Button("全选当前范围") { selected.formUnion(visible.map(\.id)) }
                        .disabled(visible.isEmpty).accessibilityIdentifier("batch-select-all")
                    Spacer()
                    Button("清空选择") { selected.removeAll() }.disabled(selected.isEmpty)
                }.buttonStyle(.borderless)
            }
        }.font(.body).padding(.bottom, 4).id("task-top")
    }

    private var categoryPicker: some View {
        Picker("任务类型", selection: Binding(get: { category }, set: { next in
            guard category != next else { return }
            clearSelection()
            category = next
            if !currentBatch.contains(where: { $0.category == next }) && next != .all { showingBatch = false }
        })) {
            ForEach(WorkspaceTaskCategory.allCases) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.menu).accessibilityLabel("任务类型").accessibilityValue(category.rawValue)
            .accessibilityIdentifier("workspace-category")
    }

    private var statusPicker: some View {
        Picker("任务状态", selection: $filter) {
            ForEach(WorkspaceTaskFilter.allCases) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.menu).accessibilityLabel("任务状态").accessibilityValue(filter.rawValue)
            .accessibilityIdentifier("batch-filter")
    }

    private func taskRow(_ item: WorkspaceTask, checked: Bool, index: Int) -> some View {
        Button {
            if selecting {
                if !selected.insert(item.id).inserted { selected.remove(item.id) }
            } else { path.append(item.id) }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                if selecting {
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(Graphite.accent).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).font(.body.weight(.medium)).lineLimit(2)
                    Text("\(item.id.category.rawValue) · \(item.status)").font(.subheadline)
                        .foregroundStyle(item.filter == .active || item.filter == .result ? Graphite.accent : .secondary)
                }
                Spacer(minLength: 0)
                if !selecting {
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                }
            }.frame(minHeight: 44).padding(16).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workspace-task-\(index)")
        .accessibilityValue(selecting ? (checked ? "已选择" : "未选择") : "")
        .accessibilityAddTraits(checked ? .isSelected : [])
    }

    @ViewBuilder private func detail(_ key: WorkspaceTaskID) -> some View {
        let unavailable = !tasks.contains { $0.id == key }
        if unavailable {
            ContentUnavailableView("这项任务已移除", systemImage: "tray")
        } else {
            switch key.category {
            case .video: CompressionJobView(session: videos, id: key.id).disabled(otherBusy(.video))
            case .photo: PhotoJobDetail(session: photos, id: key.id).disabled(otherBusy(.photo))
            case .file, .pdf: FileJobView(session: files, id: key.id).disabled(otherBusy(.file))
            case .all: EmptyView()
            }
        }
    }

    @ViewBuilder private var progress: some View {
        if videos.work == .compressing {
            CompressionWorkProgress(session: videos).graphitePanel()
        } else if videos.isBusy {
            ProgressView(videos.work == .replacing ? "等待原片移除结果…" : "正在保存或核验视频…").graphitePanel()
        } else if photos.busy {
            workProgress("照片", done: photos.batchCompleted, total: photos.batchTotal, fraction: photos.progress,
                         cancellable: photos.canCancel) { photos.cancel() }
        } else if files.busy {
            workProgress("文件", done: files.processed, total: files.total, fraction: files.progress,
                         cancellable: files.cancellable) { files.cancel() }
        } else if exporting {
            ProgressView("正在准备导出的副本…").graphitePanel()
        }
    }

    private func workProgress(_ title: String, done: Int, total: Int, fraction: Double?,
                              cancellable: Bool, cancel: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if cancellable {
                Text("\(title)处理中 · 已处理 \(done)/\(total) 项").font(.subheadline.monospacedDigit())
                if let fraction, fraction > 0 { SegmentedMeter(value: fraction) }
                Button("暂停当前处理", action: cancel).buttonStyle(.bordered)
            } else {
                ProgressView("正在保存或核对\(title)…")
            }
        }.graphitePanel()
    }

    private var messages: [String] {
        var seen: Set<String> = []
        return [operationMessage, videos.message, photos.message, files.message]
            .compactMap { $0 }.filter { seen.insert($0).inserted }
    }

    private func actionBar(_ items: [WorkspaceTask], hidden: Int) -> some View {
        let actions = actions(for: category).compactMap { action -> AvailableAction? in
            let count = items.count { reason($0, for: action) == nil }
            return count > 0 ? AvailableAction(action: action, count: count) : nil
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text(hidden == 0 ? "已选 \(items.count) 项" : "已选 \(items.count) 项 · 当前筛选隐藏 \(hidden) 项")
                .font(.subheadline.monospacedDigit()).accessibilityIdentifier("batch-selection-count")
            HStack {
                Menu {
                    ForEach(actions) { option in
                        let action = option.action
                        Button("\(actionTitle(action, category: category))（\(option.count)）", role: action.destructive ? .destructive : nil) {
                            operationMessage = nil
                            review = Operation(action: action, category: category, items: items)
                        }.accessibilityIdentifier("batch-action-\(String(describing: action))")
                    }
                } label: {
                    Label("操作所选任务", systemImage: "ellipsis.circle")
                }.buttonStyle(.borderedProminent)
                    .foregroundStyle(Graphite.background)
                    .disabled(actions.isEmpty).accessibilityIdentifier("batch-actions")
                if actions.isEmpty, !items.isEmpty { Text("当前没有可执行的操作").font(.caption) }
                professionalAction
            }
        }.padding(12).frame(maxWidth: 680).frame(maxWidth: .infinity).background(Graphite.background)
    }

    @ViewBuilder private var professionalAction: some View {
        if !otherBusy(category) {
            let ids = Set(selected.map(\.id))
            if category == .video, !videos.isBusy {
                let items = videos.jobs.filter { ids.contains($0.id) && $0.canConfigureVideo }
                if let first = items.first {
                    ProfessionalSettingsButton(initial: first.professional ?? .init(preset: first.preset, encoding: first.standardEncoding),
                                               targetCount: items.count, canReset: items.contains { $0.professional != nil }) {
                        videos.setProfessional($0, for: Set(items.map(\.id)))
                    }
                }
            } else if category == .file, !files.busy {
                let items = files.jobs.filter { ids.contains($0.id) && $0.canConfigureVideo }
                if let first = items.first {
                    ProfessionalSettingsButton(initial: first.professional ?? .init(preset: first.preset, encoding: first.encoding),
                                               targetCount: items.count, canReset: items.contains { $0.professional != nil }) {
                        files.setProfessional($0, for: Set(items.map(\.id)))
                    }
                }
            }
        }
    }

    private func actions(for category: WorkspaceTaskCategory) -> [TaskBatchAction] {
        switch category {
        case .all: []
        case .video: [.start, .download, .save, .verify, .replace, .pause, .cancel, .retry, .discard, .deleteOriginal]
        case .photo: [.start, .download, .save, .verify, .replace, .pause, .cancel, .retry, .discard]
        case .file, .pdf: [.start, .export, .pause, .cancel, .retry, .discard]
        }
    }

    private func otherBusy(_ category: WorkspaceTaskCategory) -> Bool {
        let isFile = category == .file || category == .pdf
        return exporting || archives.busy || (category != .video && videos.isBusy)
            || (category != .photo && photos.busy) || (!isFile && files.busy)
    }

    private func reason(_ item: WorkspaceTask, for action: TaskBatchAction) -> String? {
        let key = item.id
        if otherBusy(key.category) { return "请等待当前操作完成" }
        switch key.category {
        case .video:
            guard videos.persistenceAvailable else { return "视频任务记录暂不可用" }
            return photoTaskReason(item, action: action, session: videos)
        case .photo:
            guard photos.healthy else { return "照片任务记录暂不可用" }
            return photoTaskReason(item, action: action, session: photos)
        case .file, .pdf:
            guard files.healthy, let job = files.job(key.id) else { return "文件任务已移除或不可用" }
            if files.busy && (!files.cancellable || ![.pause, .cancel].contains(action)) { return "请等待文件操作完成" }
            switch action {
            case .start: return job.stage == .waiting && job.kind != .unsupported ? nil : "仅适用于可处理的待开始任务"
            case .retry:
                return [.failed, .skipped, .cancelled].contains(job.stage) && job.kind != .unsupported && job.result == nil
                    ? nil : "没有可重试的未完成文件任务"
            case .export: return job.result != nil ? nil : "没有可导出的成品"
            case .pause, .cancel:
                return [.waiting, .importing, .compressing, .failed, .skipped].contains(job.stage) && job.result == nil
                    ? nil : "任务已完成或已退出处理队列"
            case .discard: return [.replacing, .replacementPending].contains(job.stage) ? "请先核对替换结果或恢复原件" : nil
            default: return "文件任务不支持这项操作"
            }
        case .all: return "请先选择任务类型"
        }
    }

    private func photoTaskReason(_ item: WorkspaceTask, action: TaskBatchAction, session: any BatchTaskSession) -> String? {
        guard let current = session.batchItem(item.id.id) else { return "任务已移除" }
        return current.reason(for: action, busy: session.batchBusy, interruptible: session.batchInterruptible, video: session.batchVideo)
    }

    private func actionTitle(_ action: TaskBatchAction, category: WorkspaceTaskCategory) -> String {
        if action == .discard { return "清理任务和 App 内副本" }
        if action == .replace { return "复核并移除原片" }
        return action.rawValue
    }

    private func explanation(_ action: TaskBatchAction, category: WorkspaceTaskCategory) -> String {
        if category == .file || category == .pdf {
            switch action {
            case .start, .retry: return "系统可能取回所选云盘原文件。读取和压缩需要本机空间。"
            case .discard: return "清理任务及 App 内成品与恢复副本。已替换文件将失去 App 内原件恢复能力。"
            case .cancel: return "停止所选未完成项。已完成成品、恢复副本和原文件保留。"
            default: break
            }
        }
        return action.explanation
    }

    private func execute(_ operation: Operation, ids: [UUID]) {
        switch operation.category {
        case .video: videos.execute(operation.action, ids: ids)
        case .photo: photos.execute(operation.action, ids: ids)
        case .file, .pdf:
            switch operation.action {
            case .start, .retry: files.compress(ids)
            case .pause: files.stopSelected(Set(ids), cancel: false)
            case .cancel: files.stopSelected(Set(ids), cancel: true)
            case .discard: files.discard(Set(ids))
            default: break
            }
        case .all: break
        }
    }

    private func prepareExport(_ ids: [UUID]) {
        guard !files.busy, !exporting else { return }
        exporting = true
        Task {
            do {
                let urls = try await files.exportURLs(ids)
                guard !urls.isEmpty else { throw FileWorkError.access }
                export = ExportSelection(urls: urls)
            } catch {
                operationMessage = error.localizedDescription
                exporting = false
            }
        }
    }

    private func clearSelection() {
        selected.removeAll()
        selecting = false
    }
}

private struct WorkspaceOperationReview: View {
    @Environment(\.dismiss) private var dismiss
    let action: TaskBatchAction
    let title: String
    let explanation: String
    let items: [WorkspaceTask]
    let reason: (WorkspaceTask) -> String?
    let confirmed: ([WorkspaceTask]) -> Void
    @State private var checked: Set<WorkspaceTaskID> = []
    @State private var confirming = false
    @State private var approved: [WorkspaceTask] = []
    @State private var message: String?

    private struct ReviewedItem: Identifiable {
        let task: WorkspaceTask
        let reason: String?
        var id: WorkspaceTaskID { task.id }
    }

    var body: some View {
        let evaluated = items.map { ReviewedItem(task: $0, reason: reason($0)) }
        let eligible = evaluated.filter { $0.reason == nil }.map(\.task)
        let checks = checked
        let targets = action == .replace ? eligible.filter { checks.contains($0.id) } : eligible
        NavigationStack {
            List {
                Section {
                    Text(explanation).font(.subheadline)
                    Text("可处理 \(eligible.count) 项 · 不适用 \(items.count - eligible.count) 项")
                        .accessibilityIdentifier("batch-review-count")
                    if action == .replace {
                        Text("请逐项勾选原片。提交前会重新核验成品和原片。").font(.footnote)
                    }
                    if let message { Text(message).font(.footnote).foregroundStyle(.orange) }
                }
                Section {
                    ForEach(evaluated) { value in
                        let item = value.task
                        let unavailable = value.reason
                        if action == .replace, unavailable == nil {
                            let marked = checks.contains(item.id)
                            Button {
                                if !checked.insert(item.id).inserted { checked.remove(item.id) }
                            } label: {
                                HStack(spacing: 10) {
                                    row(item, note: "可复核原片")
                                    Spacer(minLength: 4)
                                    Image(systemName: marked ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(marked ? Graphite.accent : .secondary)
                                        .accessibilityHidden(true)
                                }.contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(marked ? .isSelected : [])
                            .accessibilityValue(marked ? "已勾选" : "未勾选")
                            .accessibilityIdentifier("workspace-check-original")
                        } else {
                            row(item, note: unavailable ?? "本次可处理")
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden).background(Graphite.background)
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                Button(action == .deleteOriginal ? "继续复核原片" : "确认处理（\(targets.count) 项）",
                       role: action.destructive ? .destructive : nil) {
                    approved = targets
                    if action.destructive && action != .deleteOriginal { confirming = true }
                    else { submit() }
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(action.destructive ? Color.white : Graphite.background)
                .controlSize(.large).disabled(targets.isEmpty).padding(12)
                .accessibilityIdentifier("confirm-batch-action")
                .frame(maxWidth: .infinity).background(Graphite.background)
            }
            .alert("确认\(title)？", isPresented: $confirming) {
                Button("确认 \(approved.count) 项", role: .destructive, action: submit)
                Button("取消", role: .cancel) {}
            } message: { Text(explanation) }
        }.tint(Graphite.accent)
    }

    private func row(_ item: WorkspaceTask, note: String) -> some View {
        HStack(spacing: 10) {
            if let original = item.original, let asset = PhotoLibrary.fetch(original.identifier) { PhotoThumbnail(photo: asset) }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                Text(item.status).font(.caption)
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
        }.frame(minHeight: 44)
    }

    private func submit() {
        guard !approved.isEmpty, approved.allSatisfy({ reason($0) == nil }) else {
            message = "部分任务已变化，请核对当前清单后重试。"
            return
        }
        confirmed(approved)
    }
}
