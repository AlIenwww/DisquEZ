import CoreLocation
import Foundation
import Photos

struct PhotoSnapshot: Codable, Equatable {
    let identifier: String
    let creationDate: Date?
    let modificationDate: Date?
    let adjustmentDate: Date?
    let hasAdjustments: Bool
    let favorite: Bool
    let hidden: Bool
    let subtypes: UInt
    let duration: Double
    let width: Int
    let height: Int
    let location: Location?

    struct Location: Codable, Equatable {
        let latitude: Double
        let longitude: Double
        let altitude: Double

        var value: CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                       altitude: altitude, horizontalAccuracy: 0, verticalAccuracy: 0, timestamp: .now)
        }
    }

    init(_ photo: PHAsset) {
        identifier = photo.localIdentifier
        creationDate = photo.creationDate
        modificationDate = photo.modificationDate
        adjustmentDate = photo.adjustmentTimestamp
        hasAdjustments = photo.hasAdjustments
        favorite = photo.isFavorite
        hidden = photo.isHidden
        subtypes = photo.mediaSubtypes.rawValue
        duration = photo.duration
        width = photo.pixelWidth
        height = photo.pixelHeight
        location = photo.location.map {
            Location(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude, altitude: $0.altitude)
        }
    }

    func matches(_ photo: PHAsset) -> Bool {
        self == PhotoSnapshot(photo)
    }
}

struct OutputRecord: Codable {
    let fileName: String
    let bytes: Int64
    let displaySize: CGSize
    let digest: Data
    let format: VideoOutputFormat?

    init(_ video: CompressedVideo) {
        fileName = video.url.lastPathComponent
        bytes = video.bytes
        displaySize = video.displaySize
        digest = video.digest
        format = video.format
    }

    func video(in directory: URL = StorageCapacity.directory) throws -> CompressedVideo {
        let fileExtension = format?.encoding.fileExtension ?? "mov"
        guard UUID(uuidString: String(fileName.dropLast(4))) != nil, fileName.hasSuffix(".\(fileExtension)") else {
            throw CompressionError.invalidOutput
        }
        return CompressedVideo(url: directory.appending(path: fileName), bytes: bytes,
                               displaySize: displaySize, digest: digest, format: format)
    }
}

struct CompressionJob: Codable, Identifiable {
    enum DirectDeletion: String, Codable { case removing, pending, removed }
    enum Stage: String, Codable {
        case waiting, awaitingDownload, downloading, processing, ready, saving, savePending, saved, verified, failed, skipped, kept, removing, removalPending, removed, cancelled

        var isClosed: Bool { self == .kept || self == .removed }

        var label: String {
            switch self {
            case .waiting: "待压缩"
            case .cancelled: "已取消任务"
            case .awaitingDownload: "待下载 iCloud 原片"
            case .downloading: "正在下载原片"
            case .processing: "正在压缩"
            case .ready: "待预览和保存"
            case .saving: "正在保存"
            case .savePending: "保存结果待核对"
            case .saved: "已保存 · 待核验"
            case .verified: "已保存并核验"
            case .failed: "处理失败"
            case .skipped: "已跳过"
            case .kept: "已保留两份"
            case .removing: "正在移除原片"
            case .removalPending: "原片状态待核对"
            case .removed: "原片待清理"
            }
        }
    }

    let id: UUID
    var original: PhotoSnapshot
    var preset: CompressionPreset
    var outputEncoding: VideoEncoding?
    var professional: ProfessionalVideoSettings?
    var stage: Stage = .waiting
    var sourceBytes: Int64?
    var sourceSize: CGSize?
    var output: OutputRecord?
    var copy: SavedCopy?
    var note: String?
    var directDeletion: DirectDeletion?

    init(photo: PHAsset, preset: CompressionPreset, encoding: VideoEncoding = .hevc) {
        id = UUID()
        original = PhotoSnapshot(photo)
        self.preset = preset
        outputEncoding = encoding
    }

    var encoding: VideoEncoding { professional?.encoding ?? standardEncoding }
    var standardEncoding: VideoEncoding { outputEncoding ?? .hevc }
    var canConfigureVideo: Bool {
        output == nil && copy == nil && directDeletion == nil
            && [.waiting, .awaitingDownload, .failed, .skipped, .cancelled].contains(stage)
    }

    var title: String {
        original.creationDate?.formatted(.dateTime.year().month().day().hour().minute()) ?? "视频"
    }

    var difference: Int64? {
        guard let sourceBytes, let output else { return nil }
        return max(0, sourceBytes - output.bytes)
    }
}

// The queue journal and the PhotoKit creation receipt are independent durable checkpoints.
// A receipt written inside the change block prevents a successful save being repeated after a crash.
struct QueueStore {
    let directory: URL
    static let live = QueueStore(directory: StorageCapacity.directory.deletingLastPathComponent())
    private var journalURL: URL { directory.appending(path: "queue.json") }
    private var mediaDirectory: URL { directory.appending(path: "Media", directoryHint: .isDirectory) }

    private struct Journal: Codable {
        let version: Int
        let jobs: [CompressionJob]
    }

    func load() throws -> [CompressionJob] {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return [] }
        let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
        guard journal.version == 1, Set(journal.jobs.map(\.id)).count == journal.jobs.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try journal.jobs.map { stored in
            var job = stored
            if job.directDeletion == .removing { job.directDeletion = .pending; job.note = "上次直接删除未收到结果，请核对原片。" }
            if let receipt = try receipt(for: job.id) { job.copy = receipt }
            switch job.stage {
            case .downloading:
                job.stage = .awaitingDownload
                job.note = "上次下载已中断，可重新下载原片。"
            case .processing:
                job.stage = .waiting
                job.note = "上次处理已中断，可从这条视频重新压缩。"
            case .saving:
                job.stage = job.copy == nil ? .ready : .savePending
                job.note = job.copy == nil ? "上次保存尚未提交，可以重试。" : "上次保存已中断，请先核对照片库中的成品。"
            case .verified:
                job.stage = .saved
                job.note = "已恢复任务，请重新核验照片库中的压缩件。"
            case .removing:
                job.stage = .removalPending
                job.note = "上次移除操作已中断，请核对原片状态。"
            default: break
            }
            if let output = job.output {
                let video = try output.video(in: mediaDirectory)
                if !FileManager.default.fileExists(atPath: video.url.path), job.copy == nil {
                    job.output = nil
                    job.stage = .failed
                    job.note = "本机成品文件不可用，请重新压缩。"
                }
            }
            return job
        }
    }

    func save(_ jobs: [CompressionJob]) throws {
        try prepare()
        let data = try JSONEncoder().encode(Journal(version: 1, jobs: jobs))
        try data.write(to: journalURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func writeReceipt(_ copy: SavedCopy, for id: UUID) throws {
        try prepare()
        try JSONEncoder().encode(copy).write(to: receiptURL(for: id),
                                             options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func receipt(for id: UUID) throws -> SavedCopy? {
        let url = receiptURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(SavedCopy.self, from: Data(contentsOf: url))
    }

    func removeReceipt(for id: UUID) {
        try? FileManager.default.removeItem(at: receiptURL(for: id))
    }

    func removeFiles(for job: CompressionJob) {
        removeMedia(for: job)
        removeReceipt(for: job.id)
    }

    func removeMedia(for job: CompressionJob) {
        if let url = try? job.output?.video(in: mediaDirectory).url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func cleanUnfinishedFiles(keeping jobs: [CompressionJob]) throws {
        guard FileManager.default.fileExists(atPath: mediaDirectory.path) else { return }
        let retained = Set(jobs.filter { !$0.stage.isClosed }.compactMap { $0.output?.fileName })
        let extensions = Set(VideoEncoding.allCases.map(\.fileExtension))
        for url in try FileManager.default.contentsOfDirectory(at: mediaDirectory, includingPropertiesForKeys: nil)
            where extensions.contains(url.pathExtension) && !retained.contains(url.lastPathComponent) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private func receiptURL(for id: UUID) -> URL {
        directory.appending(path: id.uuidString).appendingPathExtension("receipt")
    }
}
