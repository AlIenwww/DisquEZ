import AVKit
import SwiftUI

enum Graphite {
    static let background = Color(red: 22 / 255, green: 25 / 255, blue: 29 / 255)
    static let panel = Color(red: 32 / 255, green: 37 / 255, blue: 43 / 255)
    static let accent = Color(red: 214 / 255, green: 246 / 255, blue: 101 / 255)
}

struct GraphiteSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 0) { content }
                .background(Graphite.panel, in: RoundedRectangle(cornerRadius: 18))
        }
    }
}

struct GraphiteNavigationRow: View {
    let title: String
    var icon: String? = nil
    var value: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon).font(.body.weight(.medium))
                    .foregroundStyle(Graphite.accent).frame(width: 24)
                    .accessibilityHidden(true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    Text(title).foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    if let value { Text(value).foregroundStyle(.secondary) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).foregroundStyle(.primary)
                    if let value { Text(value).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary).accessibilityHidden(true)
        }
        .font(.body).frame(minHeight: 28).padding(16)
        .contentShape(Rectangle())
    }
}

struct PrimaryAction: View {
    let title: String
    let icon: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .foregroundStyle(Graphite.background)
                .background(Graphite.accent, in: RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

struct GraphiteParameterRow<Control: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String
    @ViewBuilder let control: Control

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                label
                control.frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack(spacing: 12) {
                label
                Spacer(minLength: 8)
                control
            }
        }
    }

    private var label: some View {
        Text(title).font(.body).accessibilityIdentifier("parameter-label-\(title)")
    }
}

struct SegmentedMeter: View {
    let value: Double

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<24, id: \.self) { index in
                let fill = min(1, max(0, value * 24 - Double(index)))
                GeometryReader { geometry in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white.opacity(0.12))
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Graphite.accent)
                                .frame(width: geometry.size.width * fill)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                }
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }
}

struct VideoEncodingPicker: View {
    @Binding var encoding: VideoEncoding
    var showHint = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GraphiteParameterRow(title: "输出格式") {
                Picker("输出格式", selection: $encoding) {
                    ForEach(VideoEncoding.allCases) { format in Text(format.title).tag(format) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(minHeight: 44)
                .accessibilityIdentifier("video-encoding")
            }
            if showHint {
                Text(encoding.hint).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

struct CompressionWorkProgress: View {
    let session: CompressionSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let percent = session.progress.formatted(.percent.precision(.fractionLength(0)))
            Text("本次已处理 \(session.batchCompleted)/\(session.batchTotal) 项").font(.subheadline.monospacedDigit())
            Text(session.cancelling ? "正在暂停…" : session.isDownloading ? "正在下载 iCloud 原片 \(percent)" : "正在压缩 \(percent)")
                .font(.body.monospacedDigit())
                .accessibilityIdentifier(session.isDownloading ? "download-progress" : "compression-progress")
            SegmentedMeter(value: session.progress)
            if session.canContinueInBackground {
                Label("后台可继续", systemImage: "checkmark.circle")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("background-compression")
            } else {
                Text("请保持 App 打开").font(.subheadline).foregroundStyle(.secondary)
            }
            Button(session.isDownloading ? "取消下载" : "暂停队列", action: session.cancelCompression)
                .buttonStyle(.bordered).disabled(session.cancelling)
                .accessibilityIdentifier(session.isDownloading ? "cancel-download" : "cancel-compression")
        }
    }
}

struct VideoComparison: View {
    private enum Version: String, CaseIterable, Identifiable {
        case original = "原片"
        case compressed = "压缩件"
        var id: Self { self }
    }

    let original: AVURLAsset?
    let output: URL
    @State private var version: Version = .compressed
    @State private var player = AVPlayer()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("对比预览")
                .font(.headline)
            Picker("对比预览", selection: $version) {
                ForEach(Version.allCases) { item in
                    Text(item.rawValue).tag(item).disabled(item == .original && original == nil)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("compare-video")
            VideoPlayer(player: player)
                .frame(height: 216)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("preview-player")
        }
        .onAppear { loadVersion(at: .zero) }
        .onChange(of: version) { _, _ in loadVersion(at: player.currentTime()) }
        .onDisappear {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
    }

    private func loadVersion(at time: CMTime) {
        player.pause()
        let item: AVPlayerItem
        if version == .original, let original { item = AVPlayerItem(asset: original) }
        else { item = AVPlayerItem(url: output) }
        player.replaceCurrentItem(with: item)
        if time.isNumeric && time > .zero { player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) }
    }
}

extension View {
    func graphitePanel() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Graphite.panel, in: RoundedRectangle(cornerRadius: 18))
    }
}
