import CoreGraphics
import Foundation
import Observation
import Photos

enum VideoFilter: String, CaseIterable, Identifiable {
    case all, large, long, fourK, highFrameRate, screenRecording

    static let largeThreshold: Int64 = 100_000_000
    static let longThreshold: TimeInterval = 5 * 60
    var id: Self { self }

    var title: String {
        switch self {
        case .all: "全部"
        case .large: "大视频"
        case .long: "长视频"
        case .fourK: "4K"
        case .highFrameRate: "高帧率"
        case .screenRecording: "录屏"
        }
    }

    var caption: String? {
        switch self {
        case .all: nil
        case .large: "文件大小至少 \(Self.largeThreshold.storageDescription)"
        case .long: "时长至少 5 分钟"
        case .fourK: "长边至少 3,840 像素"
        case .highFrameRate: "约 60 fps 及以上，含系统标记的慢动作"
        case .screenRecording: "系统标记的屏幕录制"
        }
    }
}

enum VideoSort: String, CaseIterable, Identifiable {
    case recent, size, savings
    var id: Self { self }

    var title: String {
        switch self {
        case .recent: "拍摄时间"
        case .size: "文件大小"
        case .savings: "预计收益"
        }
    }
}

struct VideoEstimate {
    let size: CGSize
    let duration: TimeInterval
    let frameRate: Double
    let videoBitrate: Double
    let audioBitrate: Double
    var range: VideoRange = .sdr

    func savings(originalBytes: Int64, preset: CompressionPreset, encoding: VideoEncoding) -> Int64? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              frameRate.isFinite, frameRate > 0, videoBitrate.isFinite, videoBitrate > 0,
              audioBitrate.isFinite, audioBitrate >= 0 else { return nil }
        let output = preset.dimensions(for: size)
        guard output.width >= 16, output.height >= 16 else { return nil }
        let videoRate = preset.bitrate(videoBitrate: videoBitrate, frameRate: frameRate, output: output)
        let outputAudioRate = encoding == .h264 && audioBitrate > 0 ? max(audioBitrate, 160_000) : audioBitrate
        let estimatedBytes = (Double(videoRate) + outputAudioRate) * duration / 8
        guard estimatedBytes.isFinite, estimatedBytes > 0 else { return nil }
        guard estimatedBytes < Double(originalBytes) else { return 0 }
        return originalBytes - Int64(estimatedBytes.rounded(.up))
    }
}

enum VideoMeasurement {
    case local(bytes: Int64, frameRate: Double?, estimate: VideoEstimate?)
    case cloudOnly
    case unavailable
}

struct CatalogVideo: Identifiable {
    struct Revision: Equatable {
        let modified: Date?
        let width: Int
        let height: Int
        let duration: TimeInterval
        let subtypes: PHAssetMediaSubtype
        let adjusted: Bool
    }

    let id: String
    let created: Date?
    let revision: Revision
    let resourceBytes: Int64?
    var measurement: VideoMeasurement?

    var durationLabel: String {
        let duration = revision.duration
        let seconds = duration.isFinite ? Int(min(Double(Int32.max), max(0, duration.rounded()))) : 0
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    var fileBytes: Int64? {
        if case .local(let bytes, _, _) = measurement { return bytes }
        return resourceBytes
    }

    var frameRate: Double? {
        if case .local(_, let rate, _) = measurement { return rate }
        return nil
    }

    var needsMeasurement: Bool {
        if case .local = measurement { return false }
        return true
    }

    var protectedCaptureEffect: String? { PhotoLibrary.protectedCaptureEffect(revision.subtypes) }

    var range: VideoRange? {
        if case .local(_, _, let estimate) = measurement { return estimate?.range }
        return nil
    }

    func savings(preset: CompressionPreset, encoding: VideoEncoding = .hevc) -> Int64? {
        guard case .local(let bytes, _, let estimate) = measurement else { return nil }
        return estimate?.savings(originalBytes: bytes, preset: preset, encoding: encoding)
    }

    enum Section: String, CaseIterable, Identifiable {
        case knownSize, unknownSize, unknownFrameRate
        var id: Self { self }
        var title: String {
            switch self {
            case .knownSize: "文件大小已知"
            case .unknownSize: "大小未知"
            case .unknownFrameRate: "帧率待测"
            }
        }
    }

    func section(for filter: VideoFilter) -> Section? {
        switch filter {
        case .all: break
        case .large:
            guard let fileBytes else { return .unknownSize }
            guard fileBytes >= VideoFilter.largeThreshold else { return nil }
        case .long:
            guard revision.duration >= VideoFilter.longThreshold else { return nil }
        case .fourK:
            guard max(revision.width, revision.height) >= 3_840 else { return nil }
        case .highFrameRate:
            if !revision.subtypes.contains(.videoHighFrameRate) {
                guard let frameRate else { return .unknownFrameRate }
                guard frameRate >= 59.5 else { return nil }
            }
        case .screenRecording:
            guard revision.subtypes.contains(.videoScreenRecording) else { return nil }
        }
        return fileBytes == nil ? .unknownSize : .knownSize
    }
}

struct CatalogItem: Identifiable {
    let photo: PHAsset
    var video: CatalogVideo
    var id: String { video.id }
}

struct CatalogSection: Identifiable {
    let id: CatalogVideo.Section
    let videoIDs: [String]

    static func make(_ items: [CatalogItem], filter: VideoFilter, sort: VideoSort,
                     preset: CompressionPreset, encoding: VideoEncoding) -> [Self] {
        let matching = items.compactMap { item in
            item.video.section(for: filter).map { (section: $0, item: item) }
        }
        let grouped = Dictionary(grouping: matching, by: \.section)
        return CatalogVideo.Section.allCases.compactMap { section in
            guard let group = grouped[section] else { return nil }
            let items = ordered(group.map(\.item), sort: sort, preset: preset, encoding: encoding, video: \.video)
            return Self(id: section, videoIDs: items.map(\.id))
        }
    }

    static func ordered<T>(_ items: [T], sort: VideoSort, preset: CompressionPreset, encoding: VideoEncoding = .hevc,
                           video: (T) -> CatalogVideo) -> [T] {
        // Calculate each score once, before comparing rows in the sort.
        items.map { item in
            let entry = video(item)
            let score: Int64? = switch sort {
            case .recent: nil
            case .size: entry.fileBytes
            case .savings: entry.savings(preset: preset, encoding: encoding)
            }
            return (item: item, score: score, date: entry.created ?? .distantPast, id: entry.id)
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return (lhs.score ?? -1) > (rhs.score ?? -1) }
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            return lhs.id < rhs.id
        }
        .map(\.item)
    }
}

@MainActor @Observable
final class VideoCatalog {
    private(set) var items: [CatalogItem] = []
    private(set) var largest: [CatalogItem] = []
    private(set) var isLoading = false
    private(set) var version = 0
    private var itemsByID: [String: CatalogItem] = [:]
    @ObservationIgnored private var loadID = UUID()
    @ObservationIgnored private var lastAccess: PHAuthorizationStatus?

    func refresh() async {
        let id = UUID()
        loadID = id
        let access = PhotoLibrary.access
        if lastAccess != access {
            replaceItems([])
            lastAccess = access
        }
        guard access == .authorized || access == .limited else {
            isLoading = false
            return
        }
        isLoading = true
        let task = Task.detached(priority: .userInitiated) { PhotoLibrary.catalogItems() }
        let fresh = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard id == loadID else { return }
        isLoading = false
        guard !Task.isCancelled, PhotoLibrary.access == access else { return }
        let previous = itemsByID
        replaceItems(fresh.map { item in
            var item = item
            if let cached = previous[item.id]?.video, cached.revision == item.video.revision {
                item.video.measurement = cached.measurement
            }
            return item
        })
    }

    func invalidateLimitedAccess() {
        if PhotoLibrary.access == .limited {
            loadID = UUID()
            replaceItems([])
        }
    }

    func apply(_ results: [String: (CatalogVideo.Revision, VideoMeasurement)]) {
        guard !results.isEmpty, PhotoLibrary.canRead, PhotoLibrary.access == lastAccess else { return }
        replaceItems(items.map { item in
            guard let (revision, measurement) = results[item.id], revision == item.video.revision else { return item }
            var item = item
            item.video.measurement = measurement
            return item
        })
    }

    func item(with id: String) -> CatalogItem? { itemsByID[id] }

    private func replaceItems(_ items: [CatalogItem]) {
        self.items = items
        itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let large = items.filter { $0.video.section(for: .large) == .knownSize }
        largest = Array(CatalogSection.ordered(large, sort: .size, preset: .balanced, video: \.video).prefix(3))
        version += 1
    }
}
