import AVKit
import SwiftUI

struct CompressionJobView: View {
    @Environment(\.dismiss) private var dismiss
    let session: CompressionSession
    let id: UUID
    @State private var original: AVURLAsset?
    @State private var previewURL: URL?
    @State private var confirmingReplacement = false
    @State private var confirmingDiscard = false
    @State private var directDelete = false

    var body: some View {
        ScrollView {
            if let job = session.job(id) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(job.title).font(.headline)
                    Text(job.stage.label).font(.subheadline).foregroundStyle(Graphite.accent)
                    if let state = job.directDeletion {
                        Text(state == .removed ? "原片已直接删除 · 待系统清理" : "直接删除状态待核对，请在照片库检查。")
                            .font(.subheadline).foregroundStyle(Graphite.accent)
                    }
                    if let note = job.note { Text(note).font(.footnote).foregroundStyle(.secondary) }
                    if let message = session.message {
                        Label(message, systemImage: "info.circle").font(.footnote)
                            .accessibilityIdentifier("session-message")
                    }
                    if job.stage == .removed {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("原片待清理", systemImage: "clock").font(.headline)
                                .foregroundStyle(Graphite.accent).accessibilityIdentifier("original-in-recently-deleted")
                            Text("压缩件已保存在照片库。原片已移到「最近删除」，可用空间以设备读数为准。")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Button("完成") { dismiss() }.buttonStyle(.bordered)
                        }
                        .graphitePanel()
                    } else if job.stage == .kept {
                        Label("已保留原片和压缩件", systemImage: "checkmark.circle").foregroundStyle(Graphite.accent)
                        Button("完成") { dismiss() }.buttonStyle(.bordered)
                    } else if let output = job.output {
                        if let previewURL {
                            VideoComparison(original: original, output: previewURL).graphitePanel()
                        } else {
                            Text("成品预览暂不可用，可重试核验已保存的压缩件。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        sizes(job, output)
                        resultActions(job)
                    } else if job.directDeletion == nil {
                        preparation(job)
                    }
                    if let previewURL, !job.stage.isClosed, !session.isBusy {
                        ShareLink(item: previewURL) { Label("导出副本", systemImage: "square.and.arrow.up") }
                            .buttonStyle(.bordered).accessibilityIdentifier("share-copy")
                    }
                }
                .padding(16)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
                .task(id: job.stage.isClosed ? nil : job.output?.fileName) { await loadPreview(job) }
            }
        }
        .background(Graphite.background.ignoresSafeArea())
        .navigationTitle("视频任务")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if !session.isBusy, let job = session.job(id) {
                    Menu {
                        if job.directDeletion == nil, job.stage != .removed, DirectVideoDeletion.reason(job.original) == nil {
                            Button("直接删除原视频", role: .destructive) { directDelete = true }
                                .accessibilityIdentifier("direct-delete-video")
                        }
                        Button("清理任务和 App 内副本", role: .destructive) { confirmingDiscard = true }
                            .accessibilityIdentifier("discard-job")
                    } label: {
                        Label("更多", systemImage: "ellipsis.circle")
                    }.accessibilityIdentifier("video-task-more")
                }
            }
        }
        .sheet(isPresented: $directDelete) {
            if let job = session.job(id) {
                DirectVideoDeletionView(snapshots: [job.original], willSubmit: {
                    try session.recordDirectDeletion($0, state: .removing)
                }, finished: { snapshots, success in
                    try? session.recordDirectDeletion(snapshots, state: success ? .removed : .pending)
                })
            }
        }
        .alert("将原片移到「最近删除」？", isPresented: $confirmingReplacement) {
            Button("移到「最近删除」", role: .destructive) { session.removeOriginals([id]) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("压缩件已保存并核验。如果启用了 iCloud 照片，移除原片也会同步到其他设备。原片在系统清理前可能仍占用空间。")
        }
        .alert("移除这条任务？", isPresented: $confirmingDiscard) {
            Button("移除任务", role: .destructive) { session.discard(id); dismiss() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此任务及 App 内的成品文件会被清理。照片库中的原片和已保存的压缩件继续保留。")
        }
    }

    private func preparation(_ job: CompressionJob) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(job.original.width) × \(job.original.height)").font(.subheadline.monospacedDigit())
            if let bytes = job.sourceBytes { Text("原片 \(bytes.storageDescription)").font(.subheadline.monospacedDigit()) }
            if job.stage == .awaitingDownload || job.stage == .downloading {
                if let capacity = session.capacity {
                    Text("本机可用 \(capacity.available.storageDescription)").font(.subheadline.monospacedDigit())
                }
                Text(job.sourceBytes == nil
                     ? "原片大小待下载后核对。下载和压缩都需要本机空间，空间不足时会停止。"
                     : "下载需要至少 \(StorageCapacity.downloadRequirement(bytes: job.sourceBytes).storageDescription) 可用空间，压缩时还需存放成品。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("点按后通过系统从 iCloud 下载这条原片，可能使用蜂窝数据。请保持 App 打开，下载完成后开始压缩。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if job.professional == nil {
                Picker("压缩档位", selection: Binding(get: { session.job(id)?.preset ?? .balanced },
                                                set: { session.updatePreset($0, for: id) })) {
                    ForEach(CompressionPreset.allCases) { preset in Text(preset.rawValue).tag(preset) }
                }
                .pickerStyle(.segmented).disabled(session.isBusy)
                VideoEncodingPicker(encoding: Binding(get: { session.job(id)?.encoding ?? .hevc },
                                                      set: { session.updateEncoding($0, for: id) }), showHint: false)
                    .disabled(session.isBusy)
                DisclosureGroup("参数说明") {
                    Text(job.preset.summary).font(.body)
                    Text(job.standardEncoding.hint).font(.body)
                }.foregroundStyle(.secondary)
            } else if let settings = job.professional {
                Text(settings.summary).font(.subheadline).foregroundStyle(Graphite.accent)
                if let notice = settings.audioNotice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
            }
            if job.canConfigureVideo && !session.isBusy {
                ProfessionalSettingsButton(initial: job.professional ?? .init(preset: job.preset, encoding: job.standardEncoding),
                                           targetCount: 1, canReset: job.professional != nil) {
                    session.setProfessional($0, for: [id])
                }
            }
            if session.work == .compressing, session.activeJobID == id {
                CompressionWorkProgress(session: session)
            } else if !session.isBusy, job.stage == .awaitingDownload {
                PrimaryAction(title: "下载原片并压缩", icon: "icloud.and.arrow.down", identifier: "download-original") {
                    session.downloadAndCompress(id)
                }
                .disabled(!session.persistenceAvailable)
            } else if !session.isBusy {
                PrimaryAction(title: job.stage == .waiting ? "开始压缩" : "重试压缩", icon: "arrow.down.right.and.arrow.up.left",
                              identifier: "compress-video") {
                    if job.stage == .waiting { session.compress([id]) } else { session.execute(.retry, ids: [id]) }
                }
                .disabled(!session.persistenceAvailable)
            }
        }
        .graphitePanel()
    }

    @ViewBuilder
    private func resultActions(_ job: CompressionJob) -> some View {
        if session.isBusy {
            ProgressView(session.work == .replacing ? "正在等待照片库确认…" : "正在保存或核验…").tint(Graphite.accent)
        } else if job.stage == .ready {
            PrimaryAction(title: job.output?.format?.requiresCopy == true ? "保存副本" : "保存压缩件",
                          icon: "square.and.arrow.down", identifier: "save-copy") { session.save([id]) }
                .disabled(!session.persistenceAvailable)
        } else if job.stage == .verified {
            Label("压缩件已保存并核验", systemImage: "checkmark.circle")
                .foregroundStyle(Graphite.accent).accessibilityIdentifier("verified-copy")
            if session.canReplace(id) {
                Button("确认替换原片", role: .destructive) { confirmingReplacement = true }
                    .buttonStyle(.bordered).tint(.red).accessibilityIdentifier("replace-original")
            }
            Button("保留两份") { session.keepOriginal(id); dismiss() }
                .buttonStyle(.bordered).accessibilityIdentifier("keep-both")
        } else if job.copy != nil {
            Button(job.stage == .removalPending ? "核对原片状态" : "核验照片库中的压缩件") { session.verify([id]) }
                .buttonStyle(.bordered).accessibilityIdentifier("retry-verification")
        }
    }

    private func sizes(_ job: CompressionJob, _ output: OutputRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("实际文件大小").font(.headline)
            if let bytes = job.sourceBytes {
                LabeledContent("原片", value: bytes.storageDescription)
            }
            LabeledContent("压缩件", value: output.bytes.storageDescription)
            Divider()
            if let difference = job.difference {
                Text("大小差额 \(difference.storageDescription)")
                    .font(.title3.weight(.bold).monospacedDigit()).foregroundStyle(Graphite.accent)
                    .accessibilityIdentifier("size-savings")
            }
            if output.format?.requiresCopy == true {
                Label("仅保存副本 · 原片保留", systemImage: "lock")
                    .font(.body).foregroundStyle(.secondary).accessibilityIdentifier("copy-only-format")
            }
            DisclosureGroup("详细信息") {
                VStack(alignment: .leading, spacing: 12) {
                    if let format = output.format {
                        LabeledContent("成品格式", value: "\(format.encoding == .hevc ? "HEVC / MOV" : "H.264 / MP4") · \(format.range.title)")
                            .accessibilityIdentifier("output-format")
                        if let details = format.details { ProfessionalResultFields(details: details, actualBytes: output.bytes) }
                    }
                    if let size = job.sourceSize {
                        LabeledContent("原片尺寸", value: "\(Int(size.width)) × \(Int(size.height))")
                    }
                    LabeledContent("成品尺寸", value: "\(Int(output.displaySize.width)) × \(Int(output.displaySize.height))")
                }.font(.body).padding(.top, 8)
            }.font(.body)
        }
        .graphitePanel()
    }

    private func loadPreview(_ job: CompressionJob) async {
        original = nil
        previewURL = nil
        guard let output = job.output, !job.stage.isClosed else { return }
        if let url = try? output.video().url,
           FileManager.default.fileExists(atPath: url.path) { previewURL = url }
        if previewURL == nil, let copy = job.copy {
            let url = try? await PhotoLibrary.savedVideo(copy).url
            if !Task.isCancelled { previewURL = url }
        }
        if !Task.isCancelled, let photo = PhotoLibrary.fetch(job.original.identifier) {
            let asset = try? await PhotoLibrary.select(photo).source.asset
            if !Task.isCancelled { original = asset }
        }
    }
}
