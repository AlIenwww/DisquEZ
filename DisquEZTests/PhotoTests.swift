import CoreLocation
import ImageIO
import os
import Photos
import XCTest
@testable import DisquEZ

final class PhotoTests: XCTestCase {
    @MainActor
    func testPhotoBatchCancelOnlySelectedAndPersists() async throws {
        let photo = try await fixturePhoto()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PhotoQueueStore(directory: directory)
        let jobs = (0..<3).map { _ in PhotoJob(photo: photo, preset: .original) }
        try store.save(jobs)
        let session = PhotoSession(store: store)
        session.execute(.cancel, ids: [jobs[0].id, jobs[2].id])
        XCTAssertEqual(session.job(jobs[0].id)?.stage, .cancelled)
        XCTAssertEqual(session.job(jobs[1].id)?.stage, .waiting)
        XCTAssertEqual(session.job(jobs[2].id)?.stage, .cancelled)
        XCTAssertEqual(try store.load().filter { $0.stage == .cancelled }.count, 2)
        XCTAssertNotNil(PhotoLibrary.fetch(photo.localIdentifier))
    }

    func testDirectVideoDeletionRejectsPhotoWithoutDeletingIt() async throws {
        let photo = try await fixturePhoto()
        let snapshot = PhotoSnapshot(photo)
        XCTAssertNotNil(DirectVideoDeletion.reason(snapshot))
        do { try await DirectVideoDeletion.remove([snapshot]); XCTFail("Direct video deletion must reject a photo") }
        catch { XCTAssertNotNil(PhotoLibrary.fetch(photo.localIdentifier)) }
    }

    func testJPEGAndHEICCompressionPreserveOrientationAndMetadata() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for heic in [false, true] {
            let input = try SyntheticPhoto.make(in: directory, heic: heic, orientation: 6)
            let before = try Data(contentsOf: input)
            let output = try await PhotoCompression.compress(input, preset: .original, directory: directory)
            XCTAssertEqual(output.width, 600); XCTAssertEqual(output.height, 800)
            XCTAssertLessThan(output.digest.bytes, Int64(before.count))
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(output.url(in: directory) as CFURL, nil))
            let metadata = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
            let exif = try XCTUnwrap(metadata[kCGImagePropertyExifDictionary as String] as? [String: Any])
            XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal as String] as? String, "2020:06:01 12:00:00")
            let gps = try XCTUnwrap(metadata[kCGImagePropertyGPSDictionary as String] as? [String: Any])
            XCTAssertEqual(try XCTUnwrap(gps[kCGImagePropertyGPSLatitude as String] as? Double), 31.2, accuracy: 0.0001)
            XCTAssertEqual(try Data(contentsOf: input), before)
        }
    }

    func testResizeKeepsAspectRatioAndCancellationKeepsSource() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try SyntheticPhoto.make(in: directory, width: 3200, height: 2400, orientation: 6)
        let digest = Data(try VideoCompression.fingerprint(input))
        for preset in [PhotoPreset.balanced, .small] {
            let output = try await PhotoCompression.compress(input, preset: preset, directory: directory)
            XCTAssertEqual(output.height, preset.longestEdge)
            XCTAssertEqual(Double(output.width) / Double(output.height), 0.75, accuracy: 0.002)
        }
        let task = Task { try await PhotoCompression.compress(input, preset: .small, directory: directory) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled compression must not return a finished image") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(Data(try VideoCompression.fingerprint(input)), digest)
    }

    func testVisualSimilaritySurvivesJPEGRecompression() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = try SyntheticPhoto.make(in: directory)
        let b = try SyntheticPhoto.make(in: directory, quality: 0.9)
        XCTAssertNotEqual(Data(try VideoCompression.fingerprint(a)), Data(try VideoCompression.fingerprint(b)))
        XCTAssertTrue(try VisualSignature.make(a).resembles(VisualSignature.make(b)))
        let portrait = try SyntheticPhoto.make(in: directory, width: 600, height: 800)
        XCTAssertFalse(try VisualSignature.make(a).resembles(VisualSignature.make(portrait)))
    }

    func testExactVideoDuplicatesAreGroupedByFullResource() async throws {
        guard ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"]?.hasPrefix("DisquEZ") == true,
              PhotoLibrary.access == .authorized else { throw XCTSkip("Requires fixture simulator") }
        let file = try await SyntheticVideo.make(size: CGSize(width: 320, height: 240), frames: 8)
        defer { try? FileManager.default.removeItem(at: file) }
        let identifiers = OSAllocatedUnfairLock(initialState: [String]())
        try await PHPhotoLibrary.shared().performChanges {
            for _ in 0..<2 {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: file, options: nil)
                if let id = request.placeholderForCreatedAsset?.localIdentifier { identifiers.withLock { $0.append(id) } }
            }
        }
        let photos = identifiers.withLock { $0 }.compactMap(PhotoLibrary.fetch)
        XCTAssertEqual(photos.count, 2)
        let result = try await MediaAnalysis.scan(photos) { _, _, _ in }
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups.first?.kind, .exact)
        XCTAssertTrue(result.groups.first?.members.allSatisfy(\.isVideo) == true)
        let fingerprint = Data(try VideoCompression.fingerprint(file))
        XCTAssertEqual(result.groups.first?.members.first?.digest.hash, fingerprint)
    }

    func testUnsupportedImageLeavesSourceUntouched() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "malformed.heic")
        let bytes = Data("not an image".utf8)
        try bytes.write(to: input)
        do { _ = try await PhotoCompression.compress(input, preset: .original, directory: directory); XCTFail("Invalid image must be rejected") }
        catch { if case CompressionError.unsupported = error {} else { XCTFail("\(error)") } }
        XCTAssertEqual(try Data(contentsOf: input), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count, 1)
    }

    func testNoSavingsDoesNotLeaveOutput() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try SyntheticPhoto.make(in: directory, quality: 0.08)
        let before = try Data(contentsOf: input)
        do { _ = try await PhotoCompression.compress(input, preset: .original, directory: directory); XCTFail("Already small file should not grow") }
        catch { if case CompressionError.noSavings = error {} else { XCTFail("\(error)") } }
        XCTAssertEqual(try Data(contentsOf: input), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count, 1)
    }

    @MainActor
    func testCorruptPhotoJournalPreservesMedia() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PhotoQueueStore(directory: directory)
        try store.prepare()
        let file = try SyntheticPhoto.make(in: store.media)
        let before = try Data(contentsOf: file)
        try Data("invalid queue".utf8).write(to: directory.appending(path: "queue.json"))
        let session = PhotoSession(store: store)
        XCTAssertFalse(session.healthy)
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    @MainActor
    func testPhotoSessionSavesVerifiesAndPreservesLibraryMetadata() async throws {
        let photo = try await fixturePhoto()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = PhotoSession(store: PhotoQueueStore(directory: directory))
        session.enqueue([photo])
        let id = try XCTUnwrap(session.jobs.first?.id)
        session.compress()
        XCTAssertTrue(session.canCancel)
        try await waitUntil { !session.busy }
        XCTAssertEqual(session.job(id)?.stage, .ready, session.job(id)?.note ?? "")
        session.save([id])
        XCTAssertFalse(session.canCancel, "PhotoKit save must settle before another action")
        try await waitUntil { !session.busy }
        XCTAssertEqual(session.job(id)?.stage, .verified, session.message ?? session.job(id)?.note ?? "")
        XCTAssertTrue(session.canReplace(id))
        let savedID = try XCTUnwrap(session.job(id)?.copy?.identifier)
        let saved = try XCTUnwrap(PhotoLibrary.fetch(savedID))
        XCTAssertEqual(saved.isFavorite, photo.isFavorite)
        XCTAssertEqual(try XCTUnwrap(saved.creationDate).timeIntervalSince1970, try XCTUnwrap(photo.creationDate).timeIntervalSince1970, accuracy: 1)
        XCTAssertLessThan(try XCTUnwrap(saved.location).distance(from: XCTUnwrap(photo.location)), 1)
        let albums = PHAssetCollection.fetchAssetCollectionsContaining(saved, with: .album, options: nil)
        XCTAssertGreaterThan(albums.count, 0)
        session.save([id])
        try await waitUntil { !session.busy }
        XCTAssertEqual(session.job(id)?.copy?.identifier, savedID)
        session.keep(id)
        XCTAssertEqual(session.job(id)?.stage, .kept)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: session.store.media, includingPropertiesForKeys: nil).isEmpty)
        XCTAssertNotNil(PhotoLibrary.fetch(photo.localIdentifier))
    }

    @MainActor
    func testPhotoRecoveryDoesNotAuthorizeRemovalOrRepeatSave() async throws {
        let photo = try await fixturePhoto()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PhotoQueueStore(directory: directory)
        var downloading = PhotoJob(photo: photo, preset: .original); downloading.stage = .downloading
        var saving = PhotoJob(photo: photo, preset: .small); saving.stage = .saving
        var verified = PhotoJob(photo: photo, preset: .original); verified.stage = .verified
        var removing = PhotoJob(photo: photo, preset: .original); removing.stage = .removing
        try store.save([downloading, saving, verified, removing])
        try store.receipt(SavedCopy(identifier: "completed-before-interruption", albumIdentifiers: []), for: saving.id)
        let session = PhotoSession(store: store)
        XCTAssertEqual(session.job(downloading.id)?.stage, .awaitingDownload)
        XCTAssertEqual(session.job(saving.id)?.stage, .savePending)
        XCTAssertEqual(session.job(saving.id)?.copy?.identifier, "completed-before-interruption")
        XCTAssertEqual(session.job(verified.id)?.stage, .saved)
        XCTAssertEqual(session.job(removing.id)?.stage, .removalPending)
        XCTAssertFalse(session.canReplace(verified.id))
        XCTAssertTrue(session.waiting.isEmpty)
    }

    @MainActor
    func testOrganizerSelectionAndStaleOriginalProtection() async throws {
        let first = try await fixturePhoto()
        let second = try await fixturePhoto()
        let result = try await MediaAnalysis.scan([first, second]) { _, _, _ in }
        let group = try XCTUnwrap(result.groups.first { $0.kind == .exact })
        XCTAssertEqual(group.members.count, 2)
        var selection = GroupSelection()
        selection.toggle(second.localIdentifier)
        XCTAssertTrue(selection.removals.isEmpty)
        selection.keep(first.localIdentifier)
        selection.toggle(first.localIdentifier)
        XCTAssertFalse(selection.isValid(for: group))
        selection.toggle(second.localIdentifier)
        XCTAssertTrue(selection.isValid(for: group))
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: second).isFavorite = !second.isFavorite
        }
        do { try await MediaAnalysis.remove(selection, from: group); XCTFail("Changed original must not be removed") }
        catch { XCTAssertNotNil(PhotoLibrary.fetch(first.localIdentifier)); XCTAssertNotNil(PhotoLibrary.fetch(second.localIdentifier)) }
        selection.keep(second.localIdentifier)
        XCTAssertTrue(selection.removals.isEmpty)
    }

    @MainActor
    func testMediaFiltersUseTypeFavoriteAndDate() async throws {
        let photo = try await fixturePhoto()
        var filter = MediaFilter()
        XCTAssertTrue(filter.includes(photo))
        filter.kind = .videos; XCTAssertFalse(filter.includes(photo))
        filter.kind = .photos; filter.favoritesOnly = true; XCTAssertTrue(filter.includes(photo))
        filter.kind = .recordings; XCTAssertFalse(filter.includes(photo))
        filter.kind = .photos; filter.datesEnabled = true
        XCTAssertFalse(filter.includes(photo))
        filter.start = photo.creationDate!; filter.end = photo.creationDate!
        XCTAssertTrue(filter.includes(photo))
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(45)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(predicate(), "Photo operation timed out")
    }

    private func fixturePhoto() async throws -> PHAsset {
        guard ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"]?.hasPrefix("DisquEZ") == true,
              PhotoLibrary.access == .authorized else { throw XCTSkip("Requires an authorized DisquEZ fixture simulator") }
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try SyntheticPhoto.make(in: directory)
        let identifier = OSAllocatedUnfairLock(initialState: Optional<String>.none)
        try await PHPhotoLibrary.shared().performChanges {
            let create = PHAssetCreationRequest.forAsset()
            create.addResource(with: .photo, fileURL: file, options: nil)
            create.creationDate = Date(timeIntervalSince1970: 1_590_969_600)
            create.location = CLLocation(latitude: 31.2, longitude: 121.5)
            create.isFavorite = true
            if let placeholder = create.placeholderForCreatedAsset {
                identifier.withLock { $0 = placeholder.localIdentifier }
                let album = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: "DisquEZ Photo Test")
                album.addAssets([placeholder] as NSArray)
            }
        }
        return try XCTUnwrap(identifier.withLock { $0 }.flatMap(PhotoLibrary.fetch))
    }
}
