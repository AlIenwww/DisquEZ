import ImageIO
import os
import Photos
import UniformTypeIdentifiers

enum PhotoPreset: String, Codable, CaseIterable, Identifiable {
    case original = "原尺寸", balanced = "适度缩小", small = "更小尺寸"
    var id: Self { self }
    var longestEdge: Int? { switch self { case .original: nil; case .balanced: 2_560; case .small: 1_280 } }
    var quality: Double { self == .small ? 0.72 : 0.82 }
    var explanation: String {
        switch self {
        case .original: "保留原分辨率，降低图片文件大小。"
        case .balanced: "长边最多 2560 像素，保持比例，不放大原图。"
        case .small: "长边最多 1280 像素，适合屏幕浏览。"
        }
    }
}

struct PhotoOutput: Codable {
    let fileName: String
    let digest: ResourceDigest
    let width: Int
    let height: Int
    func url(in directory: URL = PhotoQueueStore.live.media) throws -> URL { try PhotoQueueStore.file(fileName, in: directory) }
}

enum PhotoCompression {
    static func compress(_ url: URL, preset: PhotoPreset, directory: URL) async throws -> PhotoOutput {
        try Task.checkCancellation()
        return try autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(source) == 1,
                  let type = CGImageSourceGetType(source) as String?, let format = UTType(type),
                  format.conforms(to: .jpeg) || format.conforms(to: .heic),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                  let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
                  width > 0, height > 0, Double(width) * Double(height) <= 100_000_000 else {
                throw CompressionError.unsupported("这张照片的格式或尺寸暂不支持，原片已保留。")
            }
            for auxiliary in [kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypeHDRGainMap] {
                if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, auxiliary) != nil {
                    throw CompressionError.unsupported("照片含景深或 HDR 附加信息，已作为保护项跳过。")
                }
            }
            let bytes = try StorageCapacity.fileSize(url)
            try StorageCapacity.require(StorageCapacity.downloadRequirement(bytes: bytes))
            let output = directory.appending(path: UUID().uuidString).appendingPathExtension(format.conforms(to: .jpeg) ? "jpg" : "heic")
            var succeeded = false
            defer { if !succeeded { try? FileManager.default.removeItem(at: output) } }
            guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type as CFString, 1, nil) else {
                throw CompressionError.encoderFailed
            }
            let orientation = properties[kCGImagePropertyOrientation as String] as? Int ?? 1
            let rotated = (5...8).contains(orientation)
            var expectedWidth = rotated ? height : width
            var expectedHeight = rotated ? width : height
            if let limit = preset.longestEdge, max(width, height) > limit {
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: limit
                ] as CFDictionary) else { throw CompressionError.unreadable }
                expectedWidth = image.width
                expectedHeight = image.height
                var metadata = properties
                metadata[kCGImagePropertyOrientation as String] = 1
                metadata[kCGImagePropertyPixelWidth as String] = image.width
                metadata[kCGImagePropertyPixelHeight as String] = image.height
                var exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
                exif[kCGImagePropertyExifPixelXDimension as String] = image.width
                exif[kCGImagePropertyExifPixelYDimension as String] = image.height
                metadata[kCGImagePropertyExifDictionary as String] = exif
                var tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
                tiff[kCGImagePropertyTIFFOrientation as String] = 1
                metadata[kCGImagePropertyTIFFDictionary as String] = tiff
                metadata[kCGImageDestinationLossyCompressionQuality as String] = preset.quality
                CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
            } else {
                CGImageDestinationAddImageFromSource(destination, source, 0, [
                    kCGImageDestinationLossyCompressionQuality: preset.quality
                ] as CFDictionary)
            }
            try Task.checkCancellation()
            guard CGImageDestinationFinalize(destination) else { throw CompressionError.encoderFailed }
            try Task.checkCancellation()
            let compressedBytes = try StorageCapacity.fileSize(output)
            guard compressedBytes < bytes else { throw CompressionError.noSavings(original: bytes, output: compressedBytes) }
            guard let check = CGImageSourceCreateWithURL(output as CFURL, nil), CGImageSourceGetCount(check) == 1,
                  let decoded = CGImageSourceCreateImageAtIndex(check, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                  let checkProperties = CGImageSourceCopyPropertiesAtIndex(check, 0, nil) as? [String: Any] else {
                throw CompressionError.invalidOutput
            }
            let checkRotated = (5...8).contains(checkProperties[kCGImagePropertyOrientation as String] as? Int ?? 1)
            guard (checkRotated ? decoded.height : decoded.width) == expectedWidth,
                  (checkRotated ? decoded.width : decoded.height) == expectedHeight else { throw CompressionError.invalidOutput }
            let digest = ResourceDigest(bytes: compressedBytes, hash: Data(try VideoCompression.fingerprint(output)))
            succeeded = true
            return PhotoOutput(fileName: output.lastPathComponent, digest: digest, width: expectedWidth, height: expectedHeight)
        }
    }
}

extension PhotoLibrary {
    static func savePhoto(_ output: PhotoOutput, directory: URL, original: PhotoSnapshot,
                          willCreate: @escaping (SavedCopy) throws -> Void) async throws -> SavedCopy {
        guard canRead else { throw CompressionError.noPermission }
        let url = try output.url(in: directory)
        try StorageCapacity.require(StorageCapacity.downloadRequirement(bytes: output.digest.bytes))
        guard try StorageCapacity.fileSize(url) == output.digest.bytes,
              Data(try VideoCompression.fingerprint(url)) == output.digest.hash else { throw CompressionError.invalidOutput }
        let albums = replaceableAlbums(for: original, resourceType: .photo)
        let creation = OSAllocatedUnfairLock(initialState: Optional<SavedCopy>.none)
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            guard let placeholder = request.placeholderForCreatedAsset else { return }
            let receipt = SavedCopy(identifier: placeholder.localIdentifier, albumIdentifiers: albums?.map(\.localIdentifier))
            do { try willCreate(receipt) } catch { return }
            creation.withLock { $0 = receipt }
            request.addResource(with: .photo, fileURL: url, options: nil)
            request.creationDate = original.creationDate
            request.location = original.location?.value
            request.isFavorite = original.favorite
            for album in albums ?? [] { PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray) }
        }
        guard let copy = creation.withLock({ $0 }) else { throw CompressionError.copyNotVerified }
        return copy
    }

    static func verifyPhoto(_ copy: SavedCopy, output: PhotoOutput, original: PhotoSnapshot) async throws -> VerifiedCopy {
        guard let identifier = copy.identifier, let photo = fetch(identifier) else { throw CompressionError.copyNotVerified }
        let snapshot = PhotoSnapshot(photo)
        let resource = try MediaLibrary.resource(photo)
        let digest = try await MediaResourceRead.read(resource)
        guard digest == output.digest, let current = fetch(identifier), snapshot.matches(current),
              current.pixelWidth == output.width, current.pixelHeight == output.height else {
            throw CompressionError.copyNotVerified
        }
        return VerifiedCopy(photo: current, canReplace: canReplace(original: original, copy: copy, savedPhoto: current))
    }
}
