import AVFoundation
import Photos
import os
import XCTest
@testable import DisquEZ

final class QueueRecoveryTests: XCTestCase {
    func testDirectDeletionRejectsChangedVideoBeforeRequestingDeletion() async throws {
        _ = try fixturePhoto()
        let file = try await SyntheticVideo.make(size: CGSize(width: 320, height: 240), frames: 8)
        defer { try? FileManager.default.removeItem(at: file) }
        let identifier = OSAllocatedUnfairLock(initialState: Optional<String>.none)
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: file, options: nil)
            identifier.withLock { $0 = request.placeholderForCreatedAsset?.localIdentifier }
        }
        let photo = try XCTUnwrap(identifier.withLock { $0 }.flatMap(PhotoLibrary.fetch))
        let snapshot = PhotoSnapshot(photo)
        try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest(for: photo).isFavorite = true }
        XCTAssertNotNil(DirectVideoDeletion.reason(snapshot))
        do { try await DirectVideoDeletion.remove([snapshot]); XCTFail("Changed video must not enter a deletion request") }
        catch { XCTAssertNotNil(PhotoLibrary.fetch(photo.localIdentifier)) }
    }

    @MainActor
    func testBatchDownloadAuthorizationIsLimitedToConfirmedTasks() async throws {
        let photo = try fixturePhoto()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(directory: directory)
        var jobs = (0..<3).map { _ in CompressionJob(photo: photo, preset: .balanced) }
        for i in jobs.indices { jobs[i].stage = .awaitingDownload }
        try store.save(jobs)
        var calls = 0
        let session = CompressionSession(store: store) { _, progress in
            XCTAssertNotNil(progress)
            calls += 1
            throw CompressionError.unsupported("Fixture reached the selected download")
        }
        session.downloadAndCompressMany([jobs[0].id, jobs[1].id])
        try await waitUntil { !session.isBusy }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(session.job(jobs[2].id)?.stage, .awaitingDownload)
        XCTAssertEqual(session.batchTotal, 2)
        XCTAssertEqual(session.batchCompleted, 2)
    }

    @MainActor
    func testSelectedCancelAndPauseAllowOtherTasksToContinue() async throws {
        for cancel in [true, false] {
            let photo = try fixturePhoto()
            let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = QueueStore(directory: directory)
            let jobs = (0..<3).map { _ in CompressionJob(photo: photo, preset: .balanced) }
            try store.save(jobs)
            var calls = 0
            let session = CompressionSession(store: store) { _, _ in
                calls += 1
                if calls == 1 {
                    do { try await Task.sleep(for: .seconds(30)) }
                    catch { throw CompressionError.downloadFailed }
                }
                throw CompressionError.unsupported("Other selected tasks continued")
            }
            session.compress()
            try await waitUntil { calls == 1 }
            session.stopSelected([jobs[0].id, jobs[2].id], cancel: cancel)
            try await waitUntil { !session.isBusy }
            XCTAssertEqual(calls, 2)
            XCTAssertEqual(session.job(jobs[0].id)?.stage, cancel ? .cancelled : .waiting)
            XCTAssertEqual(session.job(jobs[1].id)?.stage, .skipped)
            XCTAssertEqual(session.job(jobs[2].id)?.stage, cancel ? .cancelled : .waiting)
            XCTAssertEqual(try store.load().first?.stage, cancel ? .cancelled : .waiting)
            XCTAssertNotNil(PhotoLibrary.fetch(photo.localIdentifier))
        }
    }

    @MainActor
    func testCancelBeforeQueueStartsDoesNotStartCancelledTask() async throws {
        let photo = try fixturePhoto()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(directory: directory)
        let jobs = (0..<2).map { _ in CompressionJob(photo: photo, preset: .balanced) }
        try store.save(jobs)
        var calls = 0
        let session = CompressionSession(store: store) { _, _ in calls += 1; throw CompressionError.unreadable }
        session.compress()
        session.stopSelected([jobs[0].id], cancel: true)
        try await waitUntil { !session.isBusy }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(session.job(jobs[0].id)?.stage, .cancelled)
    }

    @MainActor
    func testMixedBatchActionsAndInterruptedDirectDeletionStaySeparate() throws {
        let photo = try fixturePhoto()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(directory: directory)
        var job = CompressionJob(photo: photo, preset: .balanced)
        job.directDeletion = .removing
        try store.save([job])
        let session = CompressionSession(store: store)
        XCTAssertEqual(session.job(job.id)?.directDeletion, .pending)
        XCTAssertTrue(session.waitingIDs.isEmpty)
        session.compress([job.id])
        XCTAssertFalse(session.isBusy)
        let ready = BatchTaskItem(id: UUID(), original: PhotoSnapshot(photo), stage: .ready,
                                  hasOutput: true, hasCopy: false, copyOnly: false, note: nil)
        XCTAssertNil(ready.reason(for: .save, busy: false, interruptible: false, video: true))
        XCTAssertNotNil(ready.reason(for: .cancel, busy: false, interruptible: false, video: true))
        XCTAssertNotNil(ready.reason(for: .replace, busy: false, interruptible: false, video: true))
        XCTAssertNotNil(ready.reason(for: .discard, busy: true, interruptible: false, video: true))
    }

    @MainActor
    func testBatchDiscardDoesNotRemovePhotosLibraryOriginals() throws {
        let photo = try fixturePhoto()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = CompressionSession(store: QueueStore(directory: directory))
        let ids = session.enqueue([photo])
        session.execute(.discard, ids: ids)
        XCTAssertTrue(session.jobs.isEmpty)
        XCTAssertNotNil(PhotoLibrary.fetch(photo.localIdentifier))
    }

    @MainActor
    func testRecoveryKeepsFinishedFilesAndRestoresSaveReceipt() throws {
        let photo = try fixturePhoto()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = directory.appending(path: "Media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let store = QueueStore(directory: directory)
        var ready = CompressionJob(photo: photo, preset: .quality)
        let file = media.appending(path: UUID().uuidString).appendingPathExtension("mov")
        let bytes = Data("finished-video-fixture".utf8)
        try bytes.write(to: file)
        ready.output = OutputRecord(CompressedVideo(url: file, bytes: Int64(bytes.count),
                                                    displaySize: CGSize(width: 640, height: 360), digest: Data()))
        ready.stage = .ready
        var interrupted = CompressionJob(photo: photo, preset: .space)
        interrupted.stage = .processing
        var downloading = CompressionJob(photo: photo, preset: .balanced)
        downloading.stage = .downloading
        var saving = CompressionJob(photo: photo, preset: .balanced)
        saving.output = ready.output
        saving.stage = .saving
        var verified = CompressionJob(photo: photo, preset: .balanced)
        verified.output = ready.output
        verified.stage = .verified
        verified.copy = SavedCopy(identifier: "saved-copy", albumIdentifiers: [])
        var removing = CompressionJob(photo: photo, preset: .balanced)
        removing.stage = .removing
        removing.copy = verified.copy
        removing.output = ready.output
        try store.save([ready, interrupted, saving, verified, removing, downloading])
        try store.writeReceipt(SavedCopy(identifier: "committed-before-crash", albumIdentifiers: []), for: saving.id)
        let partial = media.appending(path: UUID().uuidString).appendingPathExtension("mov")
        try Data("partial".utf8).write(to: partial)
        let session = CompressionSession(store: store)
        XCTAssertTrue(session.persistenceAvailable)
        XCTAssertEqual(session.job(ready.id)?.stage, .ready)
        XCTAssertEqual(session.job(interrupted.id)?.stage, .waiting)
        XCTAssertEqual(session.job(interrupted.id)?.preset, .space)
        XCTAssertEqual(session.job(downloading.id)?.stage, .awaitingDownload)
        XCTAssertFalse(session.waitingIDs.contains(downloading.id))
        XCTAssertFalse(session.failedIDs.contains(downloading.id))
        XCTAssertEqual(session.downloadCount, 1)
        XCTAssertEqual(session.job(saving.id)?.stage, .savePending)
        XCTAssertEqual(session.job(saving.id)?.copy?.identifier, "committed-before-crash")
        XCTAssertEqual(session.job(verified.id)?.stage, .saved)
        XCTAssertEqual(session.job(removing.id)?.stage, .removalPending)
        XCTAssertFalse(session.canReplace(verified.id))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertTrue(try XCTUnwrap(session.job(ready.id)).original.matches(photo))
    }

    @MainActor
    func testRecoveredDownloadRequiresExplicitAction() throws {
        let photo = try fixturePhoto()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(directory: directory)
        var job = CompressionJob(photo: photo, preset: .balanced)
        job.stage = .downloading
        try store.save([job])
        let session = CompressionSession(store: store)
        session.compress()
        session.retry([job.id])
        XCTAssertFalse(session.isBusy, "Recovered downloads must not silently start network access")
        XCTAssertEqual(session.job(job.id)?.stage, .awaitingDownload)
        session.updatePreset(.space, for: job.id)
        session.updateEncoding(.h264, for: job.id)
        XCTAssertEqual(session.job(job.id)?.preset, .space)
        XCTAssertEqual(session.job(job.id)?.encoding, .h264)
        XCTAssertEqual(try store.load().first?.stage, .awaitingDownload)
    }

    func testDownloadCapacityHandlesUnknownSizeAndOverflow() {
        XCTAssertEqual(StorageCapacity.downloadRequirement(bytes: nil), StorageCapacity.reserve)
        XCTAssertEqual(StorageCapacity.downloadRequirement(bytes: 1_024), StorageCapacity.reserve + 1_024)
        XCTAssertEqual(StorageCapacity.downloadRequirement(bytes: Int64.max), Int64.max)
    }

    @MainActor
    func testCloudItemDoesNotBlockBatchOrStartNetworkAccess() async throws {
        let photo = try fixturePhoto()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(directory: directory)
        let cloud = CompressionJob(photo: photo, preset: .balanced)
        let next = CompressionJob(photo: photo, preset: .balanced)
        try store.save([cloud, next])
        var requests = 0
        let session = CompressionSession(store: store) { _, downloadProgress in
            XCTAssertNil(downloadProgress, "Batch processing must request local media only")
            requests += 1
            if requests == 1 { throw CompressionError.cloudOnly }
            throw CompressionError.unsupported("Test fixture reached the next item")
        }
        session.compress()
        try await waitUntil { !session.isBusy }
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(session.job(cloud.id)?.stage, .awaitingDownload)
        XCTAssertEqual(session.job(next.id)?.stage, .skipped)
        XCTAssertNotNil(PhotoLibrary.fetch(photo.localIdentifier))
    }

    @MainActor
    func testExplicitDownloadCancelsOnBackgroundAndCanRetryAfterFailure() async throws {
        let photo = try fixturePhoto()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueStore(directory: directory)
        var cloud = CompressionJob(photo: photo, preset: .balanced)
        cloud.stage = .awaitingDownload
        try store.save([cloud])
        var requests = 0
        let session = CompressionSession(store: store) { _, downloadProgress in
            requests += 1
            let progress = try XCTUnwrap(downloadProgress)
            progress(0.4)
            progress(0.2)
            if requests == 1 { try await Task.sleep(for: .seconds(30)) }
            throw CompressionError.downloadFailed
        }
        session.downloadAndCompress(cloud.id)
        try await waitUntil { session.progress == 0.4 }
        XCTAssertTrue(session.isDownloading)
        XCTAssertFalse(session.canContinueInBackground)
        session.appDidEnterBackground()
        try await waitUntil { !session.isBusy }
        XCTAssertEqual(session.job(cloud.id)?.stage, .awaitingDownload)
        XCTAssertEqual(try store.load().first?.stage, .awaitingDownload)
        session.downloadAndCompress(cloud.id)
        try await waitUntil { !session.isBusy }
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(session.job(cloud.id)?.stage, .awaitingDownload)
        XCTAssertEqual(session.job(cloud.id)?.note, CompressionError.downloadFailed.localizedDescription)
        XCTAssertNil(session.job(cloud.id)?.copy)
        XCTAssertNotNil(PhotoLibrary.fetch(photo.localIdentifier))
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "Timed out waiting for the queue state")
    }

    func testPhotoRequestCancellationBeforeRegistration() async {
        let cancelled = OSAllocatedUnfairLock(initialState: [PHImageRequestID]())
        let request = PhotoVideoRequest { id in cancelled.withLock { $0.append(id) } }
        request.finish(.failure(CancellationError()), cancelUnderlying: true)
        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                XCTAssertFalse(request.prepare(continuation))
            } as AVURLAsset
            XCTFail("An already cancelled request must throw")
        } catch { XCTAssertTrue(error is CancellationError) }
        request.setRequestID(42)
        request.finish(.success(AVURLAsset(url: URL(fileURLWithPath: "/tmp/unused.mov"))))
        XCTAssertEqual(cancelled.withLock { $0 }, [42])
    }

    func testPhotoRequestCancellationResumesOnceAndIgnoresLateResult() async {
        let cancelled = OSAllocatedUnfairLock(initialState: [PHImageRequestID]())
        let request = PhotoVideoRequest { id in cancelled.withLock { $0.append(id) } }
        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                XCTAssertTrue(request.prepare(continuation))
                request.setRequestID(43)
                request.finish(.failure(CancellationError()), cancelUnderlying: true)
                request.finish(.success(AVURLAsset(url: URL(fileURLWithPath: "/tmp/unused.mov"))))
                request.finish(.failure(CancellationError()), cancelUnderlying: true)
            } as AVURLAsset
            XCTFail("Cancellation must win over a late success callback")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(cancelled.withLock { $0 }, [43])
    }

    @MainActor
    func testCorruptJournalPreservesExistingMedia() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = directory.appending(path: "Media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let file = media.appending(path: UUID().uuidString).appendingPathExtension("mov")
        let bytes = Data("keep-this-file".utf8)
        try bytes.write(to: file)
        let journal = directory.appending(path: "queue.json")
        let invalid = Data("interrupted invalid journal".utf8)
        try invalid.write(to: journal)
        let session = CompressionSession(store: QueueStore(directory: directory))
        XCTAssertFalse(session.persistenceAvailable)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(try Data(contentsOf: journal), invalid)
    }

    func testFailedSaveReceiptDoesNotCreatePhoto() async throws {
        let photo = try fixturePhoto()
        let input = try await SyntheticVideo.make(size: CGSize(width: 640, height: 360))
        defer { try? FileManager.default.removeItem(at: input) }
        let source = try await VideoSource.inspect(AVURLAsset(url: input))
        let output = try await VideoCompression.compress(source, preset: .balanced) { _ in }
        defer { try? FileManager.default.removeItem(at: output.url) }
        let count = PhotoLibrary.videos().count
        do {
            _ = try await PhotoLibrary.save(output, original: PhotoSnapshot(photo)) { _ in
                throw CocoaError(.fileWriteOutOfSpace)
            }
            XCTFail("Saving without a durable receipt must fail")
        } catch {}
        XCTAssertEqual(PhotoLibrary.videos().count, count)
        XCTAssertNotNil(PhotoLibrary.fetch(photo.localIdentifier))
    }

    private func fixturePhoto() throws -> PHAsset {
        guard ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"]?.hasPrefix("DisquEZ") == true,
              PhotoLibrary.access == .authorized, let photo = PhotoLibrary.videos().firstObject else {
            throw XCTSkip("Requires a DisquEZ fixture simulator with Photos access and synthetic videos")
        }
        return photo
    }
}
