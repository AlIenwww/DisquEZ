import SwiftUI

struct ProfessionalSettingsButton: View {
    let initial: ProfessionalVideoSettings
    let targetCount: Int
    var canReset = false
    var title: String? = nil
    var apply: (ProfessionalVideoSettings?) -> Void = { _ in }
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            HStack(spacing: 12) {
                Text(title ?? (targetCount == 0 ? "专业视频" : targetCount == 1 ? "专业参数" : "所选视频的专业参数"))
                    .font(.body).foregroundStyle(.primary).multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary).accessibilityHidden(true)
            }.frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("professional-video-options")
        .sheet(isPresented: $showing) {
            NavigationStack {
                ProfessionalVideoEditor(initial: initial, targetCount: targetCount, canReset: canReset, apply: apply)
            }.tint(Graphite.accent)
        }
    }
}

private struct ProfessionalVideoEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ProfessionalPurchase.self) private var purchase
    @Environment(ProfessionalPresets.self) private var presets
    @State private var settings: ProfessionalVideoSettings
    @State private var presetName = ""
    @State private var savingPreset = false
    @State private var confirming = false
    @State private var removingPreset: ProfessionalPreset?
    let targetCount: Int
    let canReset: Bool
    let apply: (ProfessionalVideoSettings?) -> Void

    init(initial: ProfessionalVideoSettings, targetCount: Int, canReset: Bool, apply: @escaping (ProfessionalVideoSettings?) -> Void) {
        _settings = State(initialValue: initial)
        self.targetCount = targetCount
        self.canReset = canReset
        self.apply = apply
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                purchasePanel
                if purchase.unlocked {
                    presetPanel
                    picturePanel
                    audioPanel
                    if let reason = settings.validation { Text(reason).font(.footnote).foregroundStyle(.orange) }
                    if targetCount > 0 {
                        if targetCount > 1 {
                            Text("将同一组设置应用到所选 \(targetCount) 条未完成视频任务。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        PrimaryAction(title: "应用到 \(targetCount) 条任务", icon: "checkmark", identifier: "apply-professional-video") {
                            if settings.audioNotice == nil { finish(settings) }
                            else { confirming = true }
                        }.disabled(settings.validation != nil)
                    } else {
                        Text("在视频任务详情或多选管理中应用预设。每条任务会保存自己的参数，可与标准任务一起压缩。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if canReset {
                    Button("切回标准参数") { finish(nil) }
                        .buttonStyle(.bordered).accessibilityIdentifier("reset-professional-video")
                }
            }.padding(16).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Graphite.background.ignoresSafeArea())
        .navigationTitle("专业视频")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() }.disabled(purchase.busy) } }
        .interactiveDismissDisabled(purchase.busy)
        .task { if !purchase.unlocked { await purchase.loadProduct() } }
        .alert("应用音轨设置？", isPresented: $confirming) {
            Button("确认应用") { finish(settings) }
            Button("取消", role: .cancel) {}
        } message: { Text(settings.audioNotice ?? "") }
        .alert("保存为本机预设", isPresented: $savingPreset) {
            TextField("预设名称", text: $presetName)
            Button("保存") { presets.save(presetName, settings: settings) }
            Button("取消", role: .cancel) {}
        } message: { Text(settings.summary) }
        .alert("移除预设？", isPresented: Binding(get: { removingPreset != nil }, set: { if !$0 { removingPreset = nil } }), presenting: removingPreset) { item in
            Button("移除", role: .destructive) { presets.remove(item.id) }
            Button("取消", role: .cancel) {}
        } message: { item in Text("从本机预设清单移除「\(item.name)」。") }
    }

    private var purchasePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(purchase.unlocked ? "专业视频已解锁" : "专业视频一次性买断", systemImage: purchase.unlocked ? "checkmark.circle" : "slider.horizontal.3")
                .font(.headline).foregroundStyle(Graphite.accent).accessibilityIdentifier("professional-entitlement")
            if !purchase.unlocked {
                Text("解锁目标大小、视频码率、分辨率、帧率、音轨设置和自定义预设。标准压缩及批量任务继续免费。")
                    .font(.subheadline)
                if let product = purchase.product {
                    PrimaryAction(title: "买断 · \(product.displayPrice)", icon: "lock.open", identifier: "purchase-professional-video") {
                        Task { await purchase.buy() }
                    }.disabled(purchase.busy)
                } else if purchase.loadingProduct {
                    ProgressView("正在读取买断价格…")
                } else {
                    Button("重新读取商品") { Task { await purchase.loadProduct() } }.buttonStyle(.bordered)
                }
            }
            Button("恢复购买") { Task { await purchase.restore() } }.buttonStyle(.bordered)
                .disabled(purchase.busy).accessibilityIdentifier("restore-professional-purchase")
            if let message = purchase.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        }.graphitePanel()
    }

    private var presetPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("本机预设").font(.headline)
            ForEach(presets.items) { item in
                HStack(alignment: .top) {
                    Button {
                        settings = item.settings
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(.subheadline.weight(.semibold))
                            Text(item.settings.summary).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Button { removingPreset = item } label: {
                        Image(systemName: "trash").frame(width: 44, height: 44)
                    }.buttonStyle(.plain).foregroundStyle(.red).accessibilityLabel("移除预设 \(item.name)")
                }
            }
            Button("保存当前设置为预设") { presetName = ""; savingPreset = true }
                .buttonStyle(.bordered).disabled(settings.validation != nil).accessibilityIdentifier("save-professional-preset")
            if let message = presets.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        }.graphitePanel()
    }

    private var picturePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("画面与文件大小").font(.headline)
            VideoEncodingPicker(encoding: $settings.encoding)
            Picker("基础档位", selection: $settings.preset) {
                ForEach(CompressionPreset.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.menu)
            Toggle("指定分辨率上限", isOn: $settings.customResolution)
            if settings.customResolution {
                numberField("长边像素上限", value: $settings.longEdge, range: "256–3840", identifier: "professional-resolution")
                Text("保持原比例和方向，长边及短边最多 3840 和 2160 像素，原片较小时保持原尺寸。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("降低帧率", isOn: $settings.limitFrameRate)
            if settings.limitFrameRate {
                numberField("帧率上限（fps）", value: $settings.framesPerSecond, range: "1–120", identifier: "professional-frame-rate")
                Text("按原时间线减少帧，保持播放速度和时长。原帧率更低时沿用原帧率。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("码率策略", selection: $settings.rateMode) {
                ForEach(ProfessionalVideoSettings.RateMode.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("professional-rate-mode")
            if settings.rateMode == .bitrate {
                numberField("视频码率（kbps）", value: $settings.videoKbps, range: "100–60000", identifier: "professional-bitrate")
            } else if settings.rateMode == .target {
                numberField("目标大小（MB）", value: $settings.targetMB, range: "1–20000", identifier: "professional-target-size")
                Text("按片长和音轨预算估算。超出目标时最多重试一次，结果显示实际大小和达标状态。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.graphitePanel()
    }

    private var audioPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("音轨").font(.headline)
            Picker("音轨处理", selection: $settings.audioMode) {
                ForEach(ProfessionalVideoSettings.AudioMode.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.menu).accessibilityIdentifier("professional-audio-mode")
            if settings.audioMode == .compress {
                Picker("声道", selection: $settings.audioChannels) {
                    Text("单声道").tag(1)
                    Text("双声道").tag(2)
                }.pickerStyle(.menu)
                .onChange(of: settings.audioChannels) { _, count in
                    if !ProfessionalVideoSettings.audioBitrates(channels: count).contains(settings.audioKbps) { settings.audioKbps = 96 }
                }
                Picker("采样率", selection: $settings.audioSampleRate) {
                    ForEach(ProfessionalVideoSettings.audioSampleRates, id: \.self) { rate in
                        Text("\((Double(rate) / 1_000).formatted(.number.precision(.fractionLength(0...1)))) kHz").tag(rate)
                    }
                }.pickerStyle(.menu)
                Picker("音频码率", selection: $settings.audioKbps) {
                    ForEach(ProfessionalVideoSettings.audioBitrates(channels: settings.audioChannels), id: \.self) { value in Text("\(value) kbps").tag(value) }
                }.pickerStyle(.menu)
            }
            if let notice = settings.audioNotice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
        }.graphitePanel()
    }

    private func numberField(_ title: String, value: Binding<Int>, range: String, identifier: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            TextField(range, text: Binding(get: { value.wrappedValue > 0 ? String(value.wrappedValue) : "" },
                                          set: { value.wrappedValue = Int($0) ?? 0 }))
                .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 130).accessibilityLabel(title)
                .accessibilityIdentifier(identifier)
        }
    }

    private func finish(_ value: ProfessionalVideoSettings?) {
        guard value == nil || (purchase.unlocked && value?.validation == nil) else { return }
        apply(value)
        dismiss()
    }
}

struct ProfessionalResultFields: View {
    let details: VideoOutputDetails
    let actualBytes: Int64

    var body: some View {
        LabeledContent("成品帧率", value: "\(details.framesPerSecond.formatted(.number.precision(.fractionLength(0...2)))) fps")
        LabeledContent("视频平均码率", value: "约 \((details.videoBitrate / 1_000).formatted(.number.precision(.fractionLength(0)))) kbps")
        LabeledContent("音轨处理", value: details.audioDescription).accessibilityIdentifier("output-audio-treatment")
        if let target = details.targetBytes {
            LabeledContent("目标大小", value: target.storageDescription)
            Label(actualBytes <= target ? "已达到目标" : "成品超过目标大小", systemImage: actualBytes <= target ? "checkmark.circle" : "info.circle")
                .font(.footnote).foregroundStyle(actualBytes <= target ? Graphite.accent : .orange)
                .accessibilityIdentifier("output-target-status")
        }
    }
}
