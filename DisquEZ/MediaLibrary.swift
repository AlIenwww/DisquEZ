import CryptoKit
import ImageIO
import os
import Photos
import UniformTypeIdentifiers

enum MediaKind: String, CaseIterable, Identifiable {
    case all = "全部", photos = "照片", videos = "视频", screenshots = "截图", recordings = "录屏"
    var id: Self { self }
}

struct MediaFilter: Equatable {
    var kind: MediaKind = .all
    var favoritesOnly = false
    var datesEnabled = false
    var start = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    var end = Date.now

    func includes(_ photo: PHAsset) -> Bool {
        if favoritesOnly && !photo.isFavorite { return false }
        if datesEnabled {
            let lower = Calendar.current.startOfDay(for: min(start, end))
            let upper = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: max(start, end)))!
            guard let date = photo.creationDate, date >= lower, date < upper else { return false }
        }
        switch kind {
        case .all: return true
        case .photos: return photo.mediaType == .image
        case .videos: return photo.mediaType == .video
        case .screenshots: return photo.mediaSubtypes.contains(.photoScreenshot)
        case .recordings: return photo.mediaSubtypes.contains(.videoScreenRecording)
        }
    }
}

enum MediaLibrary {
    static func assets(photosOnly: Bool = false) -> [PHAsset] {
        guard PhotoLibrary.canRead else { return [] }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: photosOnly ? "mediaType == 1" : "mediaType == 1 OR mediaType == 2")
        let result = PHAsset.fetchAssets(with: options)
        return (0..<result.count).map { result.object(at: $0) }
    }

    static func protectionReason(_ photo: PHAsset) -> String? {
        if photo.mediaSubtypes.contains(.photoLive) { return "实况照片已保护" }
        if photo.burstIdentifier != nil { return "连拍照片已保护" }
        if photo.mediaSubtypes.contains(.photoDepthEffect) { return "人像景深照片已保护" }
        if photo.mediaSubtypes.contains(.spatialMedia) { return "空间素材已保护" }
        if photo.mediaType == .video, let effect = PhotoLibrary.protectedCaptureEffect(photo.mediaSubtypes) { return "\(effect)已保护" }
        if photo.hasAdjustments { return "已编辑素材已保护" }
        let resources = PHAssetResource.assetResources(for: photo)
        if resources.contains(where: { UTType($0.uniformTypeIdentifier)?.conforms(to: .rawImage) == true }) { return "RAW 照片已保护" }
        if resources.count != 1 { return "含附加拍摄资源，已保护" }
        return nil
    }

    static func resource(_ photo: PHAsset) throws -> PHAssetResource {
        guard let current = PhotoLibrary.fetch(photo.localIdentifier), PhotoSnapshot(photo).matches(current) else {
            throw CompressionError.originalUnavailable
        }
        if let reason = protectionReason(current) { throw CompressionError.unsupported(reason) }
        let resources = PHAssetResource.assetResources(for: current)
        let type: PHAssetResourceType = current.mediaType == .image ? .photo : .video
        guard resources.count == 1, let resource = resources.first, resource.type == type else { throw CompressionError.unreadable }
        return resource
    }

    static func photoCompressionProtection(_ photo: PHAsset) -> String? {
        if let reason = protectionReason(photo) { return reason }
        if photo.mediaSubtypes.contains(.photoHDR) { return "HDR 拍摄效果已保护" }
        guard let resource = try? resource(photo), let type = UTType(resource.uniformTypeIdentifier),
              type.conforms(to: .jpeg) || type.conforms(to: .heic) else { return "仅支持 JPEG、HEIC 压缩" }
        return nil
    }
}

struct ResourceDigest: Equatable, Codable {
    let bytes: Int64
    let hash: Data
}

// Streams large resources without keeping full videos in memory. Network access is opt-in per request.
final class MediaResourceRead: @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<ResourceDigest, Error>?
        var result: Result<ResourceDigest, Error>?
        var requestID: PHAssetResourceDataRequestID?
        var cancelled = false
        var hasher = SHA256()
        var bytes: Int64 = 0
        var checkedBytes: Int64 = 0
        var file: FileHandle?
    }
    private let state: OSAllocatedUnfairLock<State>
    private init(file: FileHandle?) { state = OSAllocatedUnfairLock(initialState: State(file: file)) }

    static func read(_ resource: PHAssetResource, to url: URL? = nil,
                     progress: (@MainActor (Double) -> Void)? = nil) async throws -> ResourceDigest {
        try Task.checkCancellation()
        var file: FileHandle?
        if let url {
            var bytes: Int64?
            if #available(iOS 27.0, *), let size = resource.dataSize, size > 0 { bytes = Int64(size) }
            try StorageCapacity.require(StorageCapacity.downloadRequirement(bytes: bytes))
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            file = try FileHandle(forWritingTo: url)
        }
        let read = MediaResourceRead(file: file)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = progress != nil
        options.progressHandler = { value in
            if value.isFinite, let progress {
                Task { @MainActor in
                    if !read.state.withLock({ $0.result != nil }) { progress(min(1, max(0, value))) }
                }
            }
        }
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let previous = read.state.withLock { state -> Result<ResourceDigest, Error>? in
                        if let result = state.result { return result }
                        state.continuation = continuation
                        return nil
                    }
                    if let previous { continuation.resume(with: previous); return }
                    let id = PHAssetResourceManager.default().requestData(for: resource, options: options) { data in
                        do {
                            try read.state.withLock { state in
                                guard state.result == nil else { return }
                                if state.file != nil, state.bytes - state.checkedBytes >= 8 * 1_024 * 1_024 {
                                    try StorageCapacity.require(StorageCapacity.reserve)
                                    state.checkedBytes = state.bytes
                                }
                                try state.file?.write(contentsOf: data)
                                state.hasher.update(data: data)
                                state.bytes += Int64(data.count)
                            }
                        } catch { read.finish(error: error, cancel: true) }
                    } completionHandler: { error in
                        read.finish(error: error.map { Self.translate($0, network: progress != nil) })
                    }
                    let cancel = read.state.withLock { state in state.requestID = id; return state.cancelled }
                    if cancel { PHAssetResourceManager.default().cancelDataRequest(id) }
                }
            } onCancel: { read.finish(error: CancellationError(), cancel: true) }
        } catch {
            if let url { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    private func finish(error: Error?, cancel: Bool = false) {
        let completion = state.withLock { state -> (CheckedContinuation<ResourceDigest, Error>?, Result<ResourceDigest, Error>?, PHAssetResourceDataRequestID?) in
            guard state.result == nil else { return (nil, nil, nil) }
            var error = error
            do { try state.file?.close() } catch let closingError { error = error ?? closingError }
            state.file = nil
            let result: Result<ResourceDigest, Error> = error.map { .failure($0) }
                ?? (state.bytes > 0 ? .success(ResourceDigest(bytes: state.bytes, hash: Data(state.hasher.finalize()))) : .failure(CompressionError.unreadable))
            state.result = result
            state.cancelled = cancel
            let continuation = state.continuation
            state.continuation = nil
            return (continuation, result, cancel ? state.requestID : nil)
        }
        if let id = completion.2 { PHAssetResourceManager.default().cancelDataRequest(id) }
        if let result = completion.1 { completion.0?.resume(with: result) }
    }

    private static func translate(_ error: Error, network: Bool) -> Error {
        let error = error as NSError
        if error.domain == PHPhotosErrorDomain {
            switch error.code {
            case PHPhotosError.Code.networkAccessRequired.rawValue: return network ? CompressionError.downloadFailed : CompressionError.cloudOnly
            case PHPhotosError.Code.notEnoughSpace.rawValue: return CompressionError.insufficientSpace(StorageCapacity.reserve)
            case PHPhotosError.Code.userCancelled.rawValue: return CancellationError()
            case PHPhotosError.Code.accessUserDenied.rawValue, PHPhotosError.Code.accessRestricted.rawValue: return CompressionError.noPermission
            default: break
            }
        }
        return error
    }
}
