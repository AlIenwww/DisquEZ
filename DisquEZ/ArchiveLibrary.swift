import Photos
import os

enum ArchiveLibrary {
    static func albums(_ photo: PHAsset) -> [ArchiveAlbum] {
        let found = PHAssetCollection.fetchAssetCollectionsContaining(photo, with: .album, options: nil)
        return (0..<found.count).map { ArchiveAlbum(identifier: found.object(at: $0).localIdentifier, title: found.object(at: $0).localizedTitle ?? "相簿") }
            .sorted { $0.identifier < $1.identifier }
    }
    static func current(_ snapshot: PhotoSnapshot) throws -> PHAsset {
        guard let photo = PhotoLibrary.fetch(snapshot.identifier), snapshot.matches(photo),
              MediaLibrary.protectionReason(photo) == nil else { throw ArchiveError.changed }
        return photo
    }
    static func originalMatches(_ entry: ArchiveEntry, snapshot: PhotoSnapshot) async throws {
        let photo = try current(snapshot)
        guard albums(photo) == entry.albums else { throw ArchiveError.changed }
        let resource = try MediaLibrary.resource(photo)
        guard try await MediaResourceRead.read(resource) == entry.digest,
              let latest = PhotoLibrary.fetch(snapshot.identifier), snapshot.matches(latest),
              albums(latest) == entry.albums else { throw ArchiveError.changed }
    }
    static func removalReason(_ entry: ArchiveEntry, state: ArchiveItemState) -> String? {
        guard PhotoLibrary.access == .authorized, let snapshot = state.photoOrigin,
              let photo = try? current(snapshot), photo.sourceType == .typeUserLibrary,
              photo.canPerform(.delete), !photo.isHidden, snapshot.creationDate != nil,
              albums(photo) == entry.albums else { return "原片权限或信息已变化，原片保留" }
        guard hasRestorableAlbums(photo) else {
            return "含无法恢复归属的特殊相簿，原片保留"
        }
        return nil
    }
    static func hasRestorableAlbums(_ photo: PHAsset) -> Bool {
        let found = PHAssetCollection.fetchAssetCollectionsContaining(photo, with: .album, options: nil)
        return (0..<found.count).allSatisfy { index in
            let album = found.object(at: index)
            return album.assetCollectionSubtype == .albumRegular && album.canPerform(.addContent)
        }
    }
    static func remove(_ entries: [(ArchiveEntry, ArchiveItemState)]) async throws {
        guard !entries.isEmpty, entries.allSatisfy({ removalReason($0.0, state: $0.1) == nil }) else { throw ArchiveError.changed }
        let submitted = OSAllocatedUnfairLock(initialState: false)
        try await PHPhotoLibrary.shared().performChanges {
            guard entries.allSatisfy({ removalReason($0.0, state: $0.1) == nil }) else { return }
            let photos = entries.compactMap { $0.1.photoOrigin.flatMap { PhotoLibrary.fetch($0.identifier) } }
            guard photos.count == entries.count else { return }
            PHAssetChangeRequest.deleteAssets(photos as NSArray)
            submitted.withLock { $0 = true }
        }
        guard submitted.withLock({ $0 }) else { throw ArchiveError.changed }
    }
    static func restore(_ entry: ArchiveEntry, source: URL, store: ArchiveStore, record: UUID) async throws -> SavedCopy {
        guard PhotoLibrary.canRead, let metadata = entry.photo,
              try FileAccess.digest(source) == entry.digest else { throw ArchiveError.invalid }
        try StorageCapacity.require(StorageCapacity.downloadRequirement(bytes: entry.digest.bytes))
        let found = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: entry.albums.map(\.identifier), options: nil)
        let albums = (0..<found.count).map { found.object(at: $0) }.filter { $0.assetCollectionSubtype == .albumRegular && $0.canPerform(.addContent) }
        let created = OSAllocatedUnfairLock(initialState: Optional<SavedCopy>.none)
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            guard let placeholder = request.placeholderForCreatedAsset else { return }
            let receipt = SavedCopy(identifier: placeholder.localIdentifier, albumIdentifiers: albums.map(\.localIdentifier))
            do { try store.saveReceipt(receipt, record: record, entry: entry.id) } catch { return }
            created.withLock { $0 = receipt }
            let options = PHAssetResourceCreationOptions(); options.originalFilename = entry.name
            request.addResource(with: entry.kind == .photo ? .photo : .video, fileURL: source, options: options)
            request.creationDate = metadata.creationDate; request.location = metadata.location?.value
            request.isFavorite = metadata.favorite; request.isHidden = metadata.hidden
            for album in albums { PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray) }
        }
        guard let receipt = created.withLock({ $0 }) else { throw ArchiveError.restorePending }
        return receipt
    }
    static func verifyRestored(_ copy: SavedCopy, entry: ArchiveEntry) async throws {
        guard let id = copy.identifier, let photo = PhotoLibrary.fetch(id), let expected = entry.photo,
              PHAssetResource.assetResources(for: photo).count == 1,
              let resource = PHAssetResource.assetResources(for: photo).first,
              photo.mediaType == (entry.kind == .photo ? .image : .video),
              photo.pixelWidth == expected.width, photo.pixelHeight == expected.height,
              photo.isFavorite == expected.favorite, photo.isHidden == expected.hidden,
              datesMatch(photo.creationDate, expected.creationDate),
              locationsMatch(photo, expected: expected) else { throw ArchiveError.restorePending }
        let before = PhotoSnapshot(photo)
        guard try await MediaResourceRead.read(resource) == entry.digest,
              let latest = PhotoLibrary.fetch(id), before.matches(latest) else { throw ArchiveError.restorePending }
        let actualAlbums = Set(albums(latest).map(\.identifier))
        guard Set(copy.albumIdentifiers ?? []).isSubset(of: actualAlbums) else { throw ArchiveError.restorePending }
    }
    private static func datesMatch(_ first: Date?, _ second: Date?) -> Bool {
        switch (first, second) { case (nil, nil): true; case let (a?, b?): abs(a.timeIntervalSince(b)) < 1; default: false }
    }
    private static func locationsMatch(_ photo: PHAsset, expected: PhotoSnapshot) -> Bool {
        switch (photo.location, expected.location) {
        case (nil, nil): true
        case let (a?, b?): a.distance(from: b.value) < 1 && abs(a.altitude - b.altitude) < 1
        default: false
        }
    }
}
