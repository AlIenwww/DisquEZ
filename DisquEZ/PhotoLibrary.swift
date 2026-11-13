import AVFoundation
import os
import Photos

struct SelectedVideo {
    let photo: PHAsset
    let source: VideoSource
}

struct SavedCopy: Codable {
    let identifier: String?
    let albumIdentifiers: [String]?
}

struct VerifiedCopy {
    let photo: PHAsset
    let canReplace: Bool
}

struct OriginalReplacement {
    let original: PhotoSnapshot
    let copy: SavedCopy
    let verified: VerifiedCopy
}

enum PhotoLibrary {
    static var access: PHAuthorizationStatus { PHPhotoLibrary.authorizationStatus(for: .readWrite) }
    static var canRead: Bool { access == .authorized || access == .limited }

    static func protectedCaptureEffect(_ subtypes: PHAssetMediaSubtype) -> String? {
        if subtypes.contains(.spatialMedia) { return "空间视频" }
        if subtypes.contains(.videoCinematic) { return "电影效果" }
        if subtypes.contains(.videoHighFrameRate) { return "慢动作" }
        return nil
    }

    static func videos() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return PHAsset.fetchAssets(with: .video, options: options)
    }

    static func catalogItems() -> [CatalogItem] {
        guard canRead else { return [] }
        let photos = videos()
        var items: [CatalogItem] = []
        items.reserveCapacity(photos.count)
        for index in 0..<photos.count {
            guard !Task.isCancelled else { return [] }
            let photo = photos.object(at: index)
            let revision = catalogRevision(photo)
            let bytes = reportedVideoSize(photo)
            let video = CatalogVideo(id: photo.localIdentifier, created: photo.creationDate, revision: revision,
                                     resourceBytes: bytes)
            items.append(CatalogItem(photo: photo, video: video))
        }
        return items
    }

    static func measureVideo(_ video: CatalogVideo) async throws -> VideoMeasurement {
        try Task.checkCancellation()
        guard let photo = fetch(video.id), catalogRevision(photo) == video.revision else {
            return .unavailable
        }
        let asset: AVURLAsset
        do { asset = try await localVideo(photo) }
        catch CompressionError.cloudOnly { return .cloudOnly }
        catch { return .unavailable }
        try Task.checkCancellation()
        if video.protectedCaptureEffect == nil, let source = try? await VideoSource.inspect(asset) {
            try Task.checkCancellation()
            let estimate = VideoEstimate(size: source.size, duration: source.duration.seconds,
                                         frameRate: source.frameRate, videoBitrate: source.videoBitrate,
                                         audioBitrate: source.audioBitrate, range: source.range)
            return .local(bytes: source.bytes, frameRate: source.frameRate, estimate: estimate)
        }
        // Videos outside this release's compression scope may still have readable size and frame rate.
        guard let bytes = try? StorageCapacity.fileSize(asset.url) else { return .unavailable }
        let track = try? await asset.loadTracks(withMediaType: .video).first
        let fps = try? await track?.load(.nominalFrameRate)
        try Task.checkCancellation()
        return .local(bytes: bytes, frameRate: fps.flatMap { $0.isFinite && $0 > 0 ? Double($0) : nil },
                      estimate: nil)
    }

    static func catalogRevision(_ photo: PHAsset) -> CatalogVideo.Revision {
        CatalogVideo.Revision(modified: photo.modificationDate, width: photo.pixelWidth, height: photo.pixelHeight,
                              duration: photo.duration, subtypes: photo.mediaSubtypes, adjusted: photo.hasAdjustments)
    }

    static func fetch(_ identifier: String) -> PHAsset? {
        guard canRead else { return nil }
        return PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
    }

    static func reportedVideoSize(_ photo: PHAsset) -> Int64? {
        if #available(iOS 27.0, *), !photo.hasAdjustments {
            let resources = PHAssetResource.assetResources(for: photo)
            if resources.count == 1, let resource = resources.first, resource.type == .video,
               let size = resource.dataSize, size > 0 { return Int64(size) }
        }
        return nil
    }

    static func select(_ photo: PHAsset, downloadProgress: (@MainActor (Double) -> Void)? = nil) async throws -> SelectedVideo {
        try Task.checkCancellation()
        guard let latest = fetch(photo.localIdentifier) else { throw CompressionError.originalUnavailable }
        if let effect = protectedCaptureEffect(latest.mediaSubtypes) {
            throw CompressionError.unsupported("\(effect)已跳过，拍摄效果保留在原片。")
        }
        if downloadProgress != nil {
            try StorageCapacity.require(StorageCapacity.downloadRequirement(bytes: reportedVideoSize(latest)))
        }
        let local = try await localVideo(latest, downloadProgress: downloadProgress)
        try Task.checkCancellation()
        let source = try await VideoSource.inspect(local)
        guard let current = fetch(latest.localIdentifier), PhotoSnapshot(latest).matches(current) else {
            throw CompressionError.originalUnavailable
        }
        return SelectedVideo(photo: latest, source: source)
    }

    static func savedVideo(_ copy: SavedCopy) async throws -> AVURLAsset {
        guard let identifier = copy.identifier, let photo = fetch(identifier) else {
            throw CompressionError.copyNotVerified
        }
        return try await localVideo(photo)
    }

    static func thumbnailFrame(for photo: PHAsset) async throws -> CGImage {
        let asset = try await localVideo(photo)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 246, height: 150)
        return try await generator.image(at: .zero).image
    }

    static func save(_ video: CompressedVideo, from selection: SelectedVideo) async throws -> SavedCopy {
        try await save(video, original: PhotoSnapshot(selection.photo))
    }

    static func save(_ video: CompressedVideo, original: PhotoSnapshot,
                     willCreate: @escaping (SavedCopy) throws -> Void = { _ in }) async throws -> SavedCopy {
        guard canRead else { throw CompressionError.noPermission }
        try StorageCapacity.require(video.bytes + StorageCapacity.reserve)
        guard try matchesFile(video.url, video: video) else { throw CompressionError.invalidOutput }
        let albums = video.requiresCopy ? nil : replaceableAlbums(for: original)
        let creation = OSAllocatedUnfairLock(initialState: Optional<SavedCopy>.none)
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            guard let placeholder = request.placeholderForCreatedAsset else { return }
            let receipt = SavedCopy(identifier: placeholder.localIdentifier,
                                    albumIdentifiers: albums?.map(\.localIdentifier))
            // Leave the empty creation request invalid if the durable receipt cannot be written.
            // PhotoKit then rejects the whole transaction before any video is created.
            do { try willCreate(receipt) } catch { return }
            creation.withLock { $0 = receipt }
            request.addResource(with: .video, fileURL: video.url, options: nil)
            request.creationDate = original.creationDate
            request.location = original.location?.value
            request.isFavorite = original.favorite
            for album in albums ?? [] where album.canPerform(.addContent) {
                PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
            }
        }
        guard let copy = creation.withLock({ $0 }) else { throw CompressionError.copyNotVerified }
        return copy
    }

    static func verify(_ copy: SavedCopy, video: CompressedVideo, original: PHAsset) async throws -> VerifiedCopy {
        try await verify(copy, video: video, original: PhotoSnapshot(original))
    }

    static func verify(_ copy: SavedCopy, video: CompressedVideo, original: PhotoSnapshot) async throws -> VerifiedCopy {
        guard let identifier = copy.identifier, let photo = fetch(identifier) else {
            throw CompressionError.copyNotVerified
        }
        let before = PhotoSnapshot(photo)
        let local = try await localVideo(photo)
        guard try matchesFile(local.url, video: video),
              let latest = fetch(identifier), before.matches(latest) else {
            throw CompressionError.copyNotVerified
        }
        return VerifiedCopy(photo: latest, canReplace: !video.requiresCopy
            && canReplace(original: original, copy: copy, savedPhoto: latest))
    }

    private static func matchesFile(_ url: URL, video: CompressedVideo) throws -> Bool {
        guard let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(bytes) == video.bytes else {
            return false
        }
        return Data(try VideoCompression.fingerprint(url)) == video.digest
    }

    static func moveOriginalToRecentlyDeleted(_ original: PHAsset, copy: SavedCopy, verified: VerifiedCopy) async throws {
        try await moveOriginalsToRecentlyDeleted([
            OriginalReplacement(original: PhotoSnapshot(original), copy: copy, verified: verified)
        ])
    }

    static func moveOriginalsToRecentlyDeleted(_ replacements: [OriginalReplacement]) async throws {
        let originalIDs = Set(replacements.map { $0.original.identifier })
        let copyIDs = Set(replacements.compactMap { $0.copy.identifier })
        guard !replacements.isEmpty, originalIDs.count == replacements.count, copyIDs.count == replacements.count,
              originalIDs.isDisjoint(with: copyIDs), replacements.allSatisfy({
                  $0.verified.canReplace && $0.copy.identifier == $0.verified.photo.localIdentifier
              }) else {
            throw CompressionError.replacementUnavailable
        }
        let requested = OSAllocatedUnfairLock(initialState: false)
        try await PHPhotoLibrary.shared().performChanges {
            var originals: [PHAsset] = []
            for replacement in replacements {
                guard let original = fetch(replacement.original.identifier), replacement.original.matches(original),
                      let saved = fetch(replacement.verified.photo.localIdentifier),
                      PhotoSnapshot(replacement.verified.photo).matches(saved),
                      canReplace(original: replacement.original, copy: replacement.copy, savedPhoto: saved) else { return }
                originals.append(original)
            }
            PHAssetChangeRequest.deleteAssets(originals as NSArray)
            requested.withLock { $0 = true }
        }
        guard requested.withLock({ $0 }) else { throw CompressionError.replacementUnavailable }
    }

    private static func localVideo(_ photo: PHAsset, downloadProgress: (@MainActor (Double) -> Void)? = nil) async throws -> AVURLAsset {
        let options = PHVideoRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = downloadProgress != nil
        let request = PhotoVideoRequest()
        if let downloadProgress {
            options.progressHandler = { value, error, stop, _ in
                guard !request.isFinished else { stop.pointee = true; return }
                do {
                    if let error { throw videoRequestError(error, downloading: true) }
                    try StorageCapacity.require(StorageCapacity.reserve)
                    guard value.isFinite else { return }
                    Task { @MainActor in
                        if !request.isFinished { downloadProgress(min(1, max(0, value))) }
                    }
                } catch {
                    stop.pointee = true
                    request.finish(.failure(error), cancelUnderlying: true)
                }
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard request.prepare(continuation) else { return }
                let id = PHImageManager.default().requestAVAsset(forVideo: photo, options: options) { asset, mix, info in
                    let result: Result<AVURLAsset, Error>
                    if info?[PHImageCancelledKey] as? Bool == true {
                        result = .failure(CancellationError())
                    } else if asset == nil, info?[PHImageResultIsInCloudKey] as? Bool == true, downloadProgress == nil {
                        result = .failure(CompressionError.cloudOnly)
                    } else if let error = info?[PHImageErrorKey] as? Error {
                        result = .failure(videoRequestError(error, downloading: downloadProgress != nil))
                    } else if let asset = asset as? AVURLAsset, asset.url.isFileURL, mix == nil {
                        result = .success(asset)
                    } else if asset != nil {
                        result = .failure(CompressionError.unsupported("暂时无法压缩包含此类编辑效果的视频。"))
                    } else {
                        result = .failure(downloadProgress == nil ? CompressionError.unreadable : CompressionError.downloadFailed)
                    }
                    request.finish(result)
                }
                request.setRequestID(id)
            }
        } onCancel: {
            request.finish(.failure(CancellationError()), cancelUnderlying: true)
        }
    }

    private static func videoRequestError(_ error: Error, downloading: Bool) -> Error {
        let nsError = error as NSError
        if nsError.domain == PHPhotosErrorDomain {
            switch nsError.code {
            case PHPhotosError.Code.userCancelled.rawValue: return CancellationError()
            case PHPhotosError.Code.notEnoughSpace.rawValue: return CompressionError.insufficientSpace(StorageCapacity.reserve)
            case PHPhotosError.Code.accessUserDenied.rawValue, PHPhotosError.Code.accessRestricted.rawValue:
                return CompressionError.noPermission
            case PHPhotosError.Code.networkAccessRequired.rawValue:
                return downloading ? CompressionError.downloadFailed : CompressionError.cloudOnly
            default: break
            }
        }
        return downloading ? CompressionError.downloadFailed : CompressionError.unreadable
    }

    static func replaceableAlbums(for snapshot: PhotoSnapshot, resourceType: PHAssetResourceType = .video) -> [PHAssetCollection]? {
        guard access == .authorized, let original = fetch(snapshot.identifier), snapshot.matches(original),
              original.sourceType == .typeUserLibrary, original.canPerform(.delete),
              protectedCaptureEffect(original.mediaSubtypes) == nil,
              !original.hasAdjustments, !original.isHidden, original.creationDate != nil,
              PHAssetResource.assetResources(for: original).map(\.type) == [resourceType] else { return nil }
        if resourceType == .photo, MediaLibrary.photoCompressionProtection(original) != nil { return nil }
        let result = PHAssetCollection.fetchAssetCollectionsContaining(original, with: .album, options: nil)
        let albums = (0..<result.count).map { result.object(at: $0) }
        guard albums.allSatisfy({ $0.assetCollectionSubtype == .albumRegular && $0.canPerform(.addContent) }) else { return nil }
        return albums
    }

    static func canReplace(original: PhotoSnapshot, copy: SavedCopy, savedPhoto: PHAsset) -> Bool {
        guard original.identifier != savedPhoto.localIdentifier, let expected = copy.albumIdentifiers,
              let latest = replaceableAlbums(for: original, resourceType: savedPhoto.mediaType == .image ? .photo : .video),
              Set(expected) == Set(latest.map(\.localIdentifier)),
              let originalDate = original.creationDate, let savedDate = savedPhoto.creationDate,
              abs(originalDate.timeIntervalSince(savedDate)) < 1,
              locationsMatch(original.location?.value, savedPhoto.location), original.favorite == savedPhoto.isFavorite,
              !savedPhoto.isHidden, !savedPhoto.hasAdjustments else { return false }
        return latest.allSatisfy { album in
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "localIdentifier == %@", savedPhoto.localIdentifier)
            return PHAsset.fetchAssets(in: album, options: options).count == 1
        }
    }

    private static func locationsMatch(_ before: CLLocation?, _ after: CLLocation?) -> Bool {
        switch (before, after) {
        case (nil, nil): true
        case let (before?, after?): before.distance(from: after) < 1 && abs(before.altitude - after.altitude) < 1
        default: false
        }
    }
}

// Cancellation may arrive before PhotoKit returns its request ID, or race its result callback.
final class PhotoVideoRequest: @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<AVURLAsset, Error>?
        var requestID: PHImageRequestID?
        var result: Result<AVURLAsset, Error>?
        var cancelUnderlying = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let cancel: @Sendable (PHImageRequestID) -> Void

    init(cancel: @escaping @Sendable (PHImageRequestID) -> Void = { PHImageManager.default().cancelImageRequest($0) }) {
        self.cancel = cancel
    }

    var isFinished: Bool { state.withLock { $0.result != nil } }

    func prepare(_ continuation: CheckedContinuation<AVURLAsset, Error>) -> Bool {
        let result = state.withLock { state -> Result<AVURLAsset, Error>? in
            if let result = state.result { return result }
            state.continuation = continuation
            return nil
        }
        if let result { continuation.resume(with: result); return false }
        return true
    }

    func setRequestID(_ id: PHImageRequestID) {
        let shouldCancel = state.withLock { state in
            state.requestID = id
            return state.cancelUnderlying
        }
        if shouldCancel { cancel(id) }
    }

    func finish(_ result: Result<AVURLAsset, Error>, cancelUnderlying: Bool = false) {
        let completion = state.withLock { state -> (CheckedContinuation<AVURLAsset, Error>?, PHImageRequestID?) in
            guard state.result == nil else { return (nil, nil) }
            state.result = result
            state.cancelUnderlying = cancelUnderlying
            let continuation = state.continuation
            state.continuation = nil
            return (continuation, cancelUnderlying ? state.requestID : nil)
        }
        if let id = completion.1 { cancel(id) }
        completion.0?.resume(with: result)
    }
}
