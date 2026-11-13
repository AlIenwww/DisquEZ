import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct SystemFilePicker: UIViewControllerRepresentable {
    var folder = false
    var allowedTypes: [UTType] = [.item]
    var exporting: [URL]? = nil
    let selected: ([URL]) -> Void
    var cancelled: () -> Void = {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker: UIDocumentPickerViewController
        if let exporting {
            picker = UIDocumentPickerViewController(forExporting: exporting, asCopy: true)
            picker.directoryURL = URL.documentsDirectory
        }
        else {
            picker = UIDocumentPickerViewController(forOpeningContentTypes: folder ? [.folder] : allowedTypes, asCopy: false)
            picker.allowsMultipleSelection = !folder
        }
        picker.delegate = context.coordinator
        picker.shouldShowFileExtensions = true
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: SystemFilePicker
        init(_ parent: SystemFilePicker) { self.parent = parent }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { parent.selected(urls) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { parent.cancelled() }
    }
}

private enum FileViewFilter: String, CaseIterable, Identifiable {
    case all = "全部", videos = "视频", photos = "图片", pdf = "PDF", large = "大文件", other = "其他"
    var id: String { rawValue }
    func includes(_ candidate: FileCandidate) -> Bool {
        switch self {
        case .all: true
        case .videos: candidate.kind == .video
        case .photos: candidate.kind == .photo
        case .pdf: candidate.kind == .pdf
        case .large: (candidate.bytes ?? -1) >= 100_000_000
        case .other: candidate.kind == .unsupported
        }
    }
}

struct ExportSelection: Identifiable { let id = UUID(); let urls: [URL] }

struct FileIntakeView: View {
    let intake: CompressionIntake
    let pdfOnly: Bool
    @State private var choosingFiles = false
    @State private var choosingFolder = false
    @State private var filter = FileViewFilter.all
    @State private var selection: Set<UUID> = []
    @State private var draft: CompressionDraft?
    @State private var reviewing = false
    @State private var guide = false
    @State private var scanned = false

    private var session: FileSession { intake.files }
    private var visible: [FileCandidate] {
        guard scanned else { return [] }
        return session.candidates.filter { pdfOnly ? $0.kind == .pdf : filter.includes($0) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("选择文件") { choosingFiles = true }.accessibilityIdentifier("pick-files")
                    Button("选择目录") { choosingFolder = true }.accessibilityIdentifier("pick-folder")
                }.disabled(session.busy || !session.healthy)
                if session.scanning {
                    Section {
                        ProgressView("正在读取目录信息…")
                        Button("停止读取", action: session.cancel).accessibilityIdentifier("stop-file-work")
                    }
                }
                if let message = session.message, scanned || !session.healthy {
                    Text(message).font(.footnote).accessibilityIdentifier("file-message")
                }
                if scanned, !session.scanning {
                    Section {
                        if !pdfOnly {
                            Picker("文件筛选", selection: $filter) {
                                ForEach(FileViewFilter.allCases) { Text($0.rawValue).tag($0) }
                            }.accessibilityIdentifier("file-filter")
                        }
                        Button("全选当前范围") { selection.formUnion(visible.filter { $0.kind != .unsupported }.map(\.id)) }
                            .accessibilityIdentifier("select-visible-files")
                        if !selection.isEmpty { Button("取消选择") { selection.removeAll() } }
                        Text("已选 \(selection.count) 项").font(.footnote)
                    }
                    Section {
                        if visible.isEmpty { Text("当前范围没有可显示的文件。") }
                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                            let selected = selection.contains(item.id)
                            Button {
                                if !selection.insert(item.id).inserted { selection.remove(item.id) }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: item.kind == .unsupported ? "lock" : selected ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(Graphite.accent).accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.name).font(.body.weight(.medium))
                                        Text("\(item.kind.rawValue) · \(item.bytes?.storageDescription ?? "大小未知")")
                                            .font(.subheadline).foregroundStyle(.secondary)
                                        if item.kind == .unsupported { Text("暂不支持压缩").font(.subheadline).foregroundStyle(.secondary) }
                                        else if item.cloud { Label("云端原件", systemImage: "icloud").font(.subheadline).foregroundStyle(.secondary) }
                                    }
                                    Spacer(minLength: 0)
                                }.frame(minHeight: 44).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(item.kind == .unsupported)
                                .accessibilityAddTraits(selected ? .isSelected : [])
                                .accessibilityValue(selected ? "已选择" : "未选择")
                                .accessibilityIdentifier("file-candidate-\(index)")
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Graphite.background.ignoresSafeArea())
            .navigationTitle(pdfOnly ? "PDF 优化" : "选择文件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { session.cancel(); intake.close() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("下一步（\(selection.count)）", action: review)
                        .disabled(selection.isEmpty || session.busy)
                        .accessibilityIdentifier("enqueue-files")
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("iCloud Drive 帮助", systemImage: "questionmark.circle") { guide = true }
                }
            }
            .navigationDestination(isPresented: $reviewing) {
                if let draft { BatchConfirmation(draft: draft, intake: intake) }
            }
            .sheet(isPresented: $choosingFiles) {
                SystemFilePicker(allowedTypes: pdfOnly ? [.pdf] : [.item], selected: { urls in
                    choosingFiles = false; scan(urls)
                }, cancelled: { choosingFiles = false })
            }
            .sheet(isPresented: $choosingFolder) {
                SystemFilePicker(folder: true, selected: { urls in
                    choosingFolder = false; scan(urls)
                }, cancelled: { choosingFolder = false })
            }
            .sheet(isPresented: $guide) { ICloudFileGuide() }
        }
        .tint(Graphite.accent)
        .interactiveDismissDisabled(session.scanning)
    }

    private func scan(_ urls: [URL]) {
        selection.removeAll()
        scanned = true
        session.scan(urls)
    }

    private func review() {
        let items = session.candidates.filter { selection.contains($0.id) }
        guard !items.isEmpty else { return }
        let source = CompressionSource.files(items, pdfOnly: pdfOnly)
        if let draft { draft.source = source }
        else { draft = CompressionDraft(source: source, parameters: intake.defaults) }
        reviewing = true
    }
}

struct FileJobView: View {
    let session: FileSession
    let id: UUID
    @State private var confirmReplace = false
    @State private var confirmRestore = false
    @State private var exporting = false
    @State private var export: ExportSelection?
    @State private var comparing = false
    @State private var comparingPDF = false
    var body: some View {
        ScrollView {
            if let job = session.job(id) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(job.name).font(.headline)
                    Text(job.stage.label).foregroundStyle(Graphite.accent).accessibilityIdentifier("file-job-status")
                    if let note = job.note { Text(note).font(.footnote) }
                    if let message = session.message { Text(message).font(.footnote).accessibilityIdentifier("file-detail-message") }
                    if let result = job.result, let output = try? result.url(in: session.store) {
                        if job.kind == .video {
                            VideoComparison(original: job.sourceName.flatMap { try? session.store.file($0) }.map { AVURLAsset(url: $0) }, output: output)
                        } else if job.kind == .pdf {
                            Button("逐页放大对比 PDF") { comparingPDF = true }.buttonStyle(.bordered).accessibilityIdentifier("compare-file-pdf")
                        } else if let source = job.sourceName.flatMap({ try? session.store.file($0) }) {
                            HStack { PhotoPreviewTile(url: source, label: "原件"); PhotoPreviewTile(url: output, label: "成品") }
                            Button("放大对比") { comparing = true }.buttonStyle(.bordered).accessibilityIdentifier("compare-file-photo")
                        }
                        VStack(spacing: 10) {
                            LabeledContent("原文件", value: job.sourceDigest?.bytes.storageDescription ?? "未知")
                            LabeledContent("压缩件", value: result.digest.bytes.storageDescription)
                            if let details = result.videoFormat?.details { ProfessionalResultFields(details: details, actualBytes: result.digest.bytes) }
                            if let pdf = result.pdf {
                                LabeledContent("PDF 页数", value: "\(pdf.pages) 页").accessibilityIdentifier("pdf-page-count")
                                LabeledContent("保留文字页", value: "\(pdf.textPages) 页")
                                Text("已核对页数、页序、页面方向、文字及页面缩略内容，请再放大复核画质。")
                                    .font(.footnote).foregroundStyle(.secondary)
                                Text("PDF 内部的创建、修改日期和生成工具信息可能更新。完整的原文件保留在恢复副本中。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            } else { LabeledContent("成品尺寸", value: "\(result.width) × \(result.height)") }
                            if let source = job.sourceDigest {
                                LabeledContent("文件大小差额", value: (source.bytes - result.digest.bytes).storageDescription)
                                    .foregroundStyle(Graphite.accent).accessibilityIdentifier("file-savings")
                                Text("App 内原件恢复副本仍占 \(source.bytes.storageDescription)，本机可用空间以实际读数为准。").font(.footnote).foregroundStyle(.secondary)
                            }
                        }.graphitePanel()
                        Button("导出新副本") { prepareExport() }.buttonStyle(.borderedProminent).foregroundStyle(Graphite.background).accessibilityIdentifier("export-file-copy")
                        if job.stage == .ready {
                            if let reason = FileReplacement.reason(job, store: session.store) { Text(reason).font(.footnote).foregroundStyle(.secondary) }
                            else {
                                Button("确认替换原文件", role: .destructive) { confirmReplace = true }.buttonStyle(.bordered).tint(.red).accessibilityIdentifier("replace-file-original")
                            }
                        }
                        if [.replaced, .replacementPending].contains(job.stage) {
                            Button("恢复原文件") { confirmRestore = true }.buttonStyle(.bordered).accessibilityIdentifier("restore-file-original")
                        }
                        if job.stage == .replacementPending {
                            Button("核对替换结果") { session.recheck(id) }.buttonStyle(.bordered).accessibilityIdentifier("recheck-file-replacement")
                        }
                    } else if job.kind != .unsupported {
                        if let settings = job.professional { Text(settings.summary).font(.subheadline).foregroundStyle(Graphite.accent) }
                        if job.canConfigureVideo && !session.busy {
                            ProfessionalSettingsButton(initial: job.professional ?? .init(preset: job.preset, encoding: job.encoding),
                                                       targetCount: 1, canReset: job.professional != nil) {
                                session.setProfessional($0, for: [id])
                            }
                        }
                        Button("开始或重试压缩") { session.compress([id]) }.buttonStyle(.borderedProminent)
                    }
                    if session.busy { ProgressView("正在处理文件…").tint(Graphite.accent) }
                }.padding(16).frame(maxWidth: 680).frame(maxWidth: .infinity)
                    .disabled(session.busy || exporting)
            }
        }
        .background(Graphite.background.ignoresSafeArea()).navigationTitle("文件任务").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $export) { files in
            SystemFilePicker(exporting: files.urls, selected: { _ in FileExports.clean(files.urls); export = nil; exporting = false; session.message = "系统已完成副本导出，原件保留。" },
                             cancelled: { FileExports.clean(files.urls); export = nil; exporting = false }).interactiveDismissDisabled()
        }
        .sheet(isPresented: $comparing) {
            if let job = session.job(id), let source = job.sourceName.flatMap({ try? session.store.file($0) }),
               let output = try? job.result?.url(in: session.store) { PhotoCompareSheet(original: source, compressed: output) }
        }
        .sheet(isPresented: $comparingPDF) {
            if let job = session.job(id), let source = job.sourceName.flatMap({ try? session.store.file($0) }),
               let result = job.result, let output = try? result.url(in: session.store), let pdf = result.pdf {
                PDFCompareSheet(original: source, compressed: output, pages: pdf.pages)
            }
        }
        .alert("替换原位置文件？", isPresented: $confirmReplace) {
            Button("确认替换", role: .destructive) { session.replace(id) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("成品将重新核验，并在确认原件未变化后写入原位置。App 保留完整原件恢复副本，清理该任务后将无法通过 App 恢复。" + (session.job(id)?.kind == .pdf ? "PDF 内部的创建、修改日期和生成工具信息可能更新。" : ""))
        }
        .alert("恢复原文件？", isPresented: $confirmRestore) {
            Button("恢复原文件") { session.restore(id) }
            Button("取消", role: .cancel) {}
        } message: { Text("仅在原位置仍是本次压缩件、原件或文件缺失时恢复。检测到其他内容会停止，避免覆盖后续修改。") }
    }
    private func prepareExport() {
        exporting = true
        Task {
            do { export = ExportSelection(urls: try await session.exportURLs([id])) }
            catch { session.message = error.localizedDescription; exporting = false }
        }
    }
}

struct ICloudFileGuide: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("保留 iCloud Drive 原件，移除本机下载").font(.title2.bold())
                    Text("1. 打开系统「文件」，进入 iCloud Drive。\n\n2. 长按已下载的文件，选择「移除下载」。\n\n3. 原件继续保存在 iCloud，需要时可重新下载。")
                    Text("不要选择「删除」来代替移除下载。iCloud Drive 删除会同步到其他设备。第三方云盘按各自的离线文件设置处理。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Link("查看 Apple 文件与移除下载说明", destination: URL(string: "https://support.apple.com/en-gb/104953")!)
                }.padding(20)
            }.background(Graphite.background).navigationTitle("移除下载").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.tint(Graphite.accent)
    }
}
