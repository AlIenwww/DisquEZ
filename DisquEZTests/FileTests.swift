import Foundation
import XCTest
@testable import DisquEZ

final class FileTests: XCTestCase {
    @MainActor
    func testVideoFilesKeepOriginalAndUseIsolatedOutputDirectory() async throws {
        let root = try directory()
        let store = FileTaskStore(root: URL.temporaryDirectory.appending(path: UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: store.root) }
        let generated = try await SyntheticVideo.make(size: CGSize(width: 640, height: 360), frames: 30)
        defer { try? FileManager.default.removeItem(at: generated) }
        let source = root.appending(path: "Movie.mov")
        try FileManager.default.copyItem(at: generated, to: source)
        let original = try FileAccess.digest(source)
        let session = FileSession(store: store)
        session.scan([source]); try await wait(session)
        var id = try XCTUnwrap(session.candidates.first?.id)
        session.enqueue([id]); session.compress([id]); try await wait(session)
        let job = try XCTUnwrap(session.job(id))
        XCTAssertEqual(job.stage, .ready, session.message ?? "")
        XCTAssertEqual(job.result?.videoFormat?.encoding, .hevc)
        XCTAssertEqual(try job.result?.url(in: store).deletingLastPathComponent().standardizedFileURL.path, store.media.standardizedFileURL.path)
        XCTAssertEqual(try FileAccess.digest(source), original)
        session.encoding = .h264
        session.scan([source]); try await wait(session)
        id = try XCTUnwrap(session.candidates.first?.id)
        session.enqueue([id]); session.compress([id]); try await wait(session)
        XCTAssertEqual(session.job(id)?.stage, .ready, session.message ?? "")
        XCTAssertEqual(session.job(id)?.result?.videoFormat?.encoding, .h264)
        XCTAssertNotNil(session.job(id)?.result?.copyOnlyReason)
        session.replace(id)
        XCTAssertFalse(session.busy)
        XCTAssertEqual(try FileAccess.digest(source), original)
    }
    @MainActor
    func testCancelSelectedFileBeforeQueueStartsPreservesOtherWork() async throws {
        let root = try directory()
        let store = FileTaskStore(root: URL.temporaryDirectory.appending(path: UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: store.root) }
        let first = try SyntheticPhoto.make(in: root, name: "A")
        let second = try SyntheticPhoto.make(in: root, name: "B")
        let before = try FileAccess.digest(first)
        let session = FileSession(store: store)
        session.scan([root]); try await wait(session)
        let ids = session.candidates.map(\.id)
        session.enqueue(Set(ids)); session.compress(ids)
        session.stopSelected([ids[0]], cancel: true)
        try await wait(session)
        XCTAssertEqual(session.job(ids[0])?.stage, .cancelled)
        XCTAssertEqual(session.job(ids[1])?.stage, .ready)
        XCTAssertEqual(try FileAccess.digest(first), before)
        XCTAssertEqual(try FileAccess.digest(second), before)
        XCTAssertEqual(try store.load().first { $0.id == ids[0] }?.stage, .cancelled)
    }
    @MainActor
    func testRecoveryCanRestoreMissingOriginal() async throws {
        let root = try directory()
        let store = FileTaskStore(root: URL.temporaryDirectory.appending(path: UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: store.root) }
        let source = try SyntheticPhoto.make(in: root)
        let original = try FileAccess.digest(source)
        let session = FileSession(store: store)
        session.scan([source]); try await wait(session)
        let id = try XCTUnwrap(session.candidates.first?.id)
        session.enqueue([id]); session.compress([id]); try await wait(session)
        session.replace(id); try await wait(session)
        XCTAssertEqual(session.job(id)?.stage, .replaced, session.message ?? "")
        try FileManager.default.removeItem(at: source)
        session.restore(id); try await wait(session)
        XCTAssertEqual(session.job(id)?.stage, .restored, session.message ?? "")
        XCTAssertEqual(try FileAccess.digest(source), original)
    }
    private func directory() throws -> URL {
        let url = URL.documentsDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @MainActor
    private func wait(_ session: FileSession) async throws {
        let deadline = Date().addingTimeInterval(30)
        while session.busy, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(session.busy, "File operation timed out")
    }
    func testDirectoryScanSortsSizesAndSkipsSymbolicLinks() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try SyntheticPhoto.make(in: root, name: "Photo")
        let note = root.appending(path: "Note.txt")
        try Data("short note".utf8).write(to: note)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "Alias.jpg"), withDestinationURL: image)
        let result = try await FileAccess.scan([root])
        XCTAssertEqual(result.files.map(\.name), ["Photo.jpg", "Note.txt"])
        XCTAssertEqual(result.files.map(\.kind), [.photo, .unsupported])
        XCTAssertFalse(result.truncated)
        let bytes = try result.files[0].reference.withAccess { try Data(contentsOf: $0) }
        XCTAssertEqual(bytes, try Data(contentsOf: image))
    }
    @MainActor
    func testPhotoCompressionReplacementAndRecoveryRoundTrip() async throws {
        let root = try directory()
        let store = FileTaskStore(root: URL.temporaryDirectory.appending(path: UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: store.root) }
        let image = try SyntheticPhoto.make(in: root, name: "Original")
        let original = try Data(contentsOf: image)
        let session = FileSession(store: store)
        session.scan([root]); try await wait(session)
        let id = try XCTUnwrap(session.candidates.first?.id)
        session.enqueue([id]); session.compress([id]); try await wait(session)
        let job = try XCTUnwrap(session.job(id))
        XCTAssertEqual(job.stage, .ready, session.message ?? job.note ?? "")
        XCTAssertEqual(try Data(contentsOf: image), original)
        XCTAssertNil(FileReplacement.reason(job, store: store))
        session.replace(id); try await wait(session)
        XCTAssertEqual(session.job(id)?.stage, .replaced, session.message ?? "")
        XCTAssertEqual(try FileAccess.digest(image), job.result?.digest)
        let restoredSession = FileSession(store: store)
        restoredSession.restore(id); try await wait(restoredSession)
        XCTAssertEqual(restoredSession.job(id)?.stage, .restored, restoredSession.message ?? "")
        XCTAssertEqual(try Data(contentsOf: image), original)
        restoredSession.discard([id]); try await wait(restoredSession)
        XCTAssertTrue(restoredSession.jobs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: image), original)
    }
    @MainActor
    func testChangedOriginalIsNeverOverwrittenAndBackupIsRetained() async throws {
        let root = try directory()
        let store = FileTaskStore(root: URL.temporaryDirectory.appending(path: UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: store.root) }
        let image = try SyntheticPhoto.make(in: root)
        let original = try Data(contentsOf: image)
        let session = FileSession(store: store)
        session.scan([image]); try await wait(session)
        let id = try XCTUnwrap(session.candidates.first?.id)
        session.enqueue([id]); session.compress([id]); try await wait(session)
        let later = Data("later user modification".utf8)
        try later.write(to: image)
        session.replace(id); try await wait(session)
        XCTAssertEqual(session.job(id)?.stage, .replacementPending)
        XCTAssertEqual(try Data(contentsOf: image), later)
        let job = try XCTUnwrap(session.job(id))
        XCTAssertEqual(try Data(contentsOf: store.file(XCTUnwrap(job.sourceName))), original)
        session.discard([id]); try await wait(session)
        XCTAssertEqual(session.jobs.count, 1, "Unresolved replacement must retain its recovery copy")
        XCTAssertEqual(try Data(contentsOf: image), later)
    }
    @MainActor
    func testRecoveryRefusesToOverwriteSubsequentEdits() async throws {
        let root = try directory()
        let store = FileTaskStore(root: URL.temporaryDirectory.appending(path: UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: store.root) }
        let image = try SyntheticPhoto.make(in: root)
        let session = FileSession(store: store)
        session.scan([image]); try await wait(session)
        let id = try XCTUnwrap(session.candidates.first?.id)
        session.enqueue([id]); session.compress([id]); try await wait(session)
        session.replace(id); try await wait(session)
        XCTAssertEqual(session.job(id)?.stage, .replaced, session.message ?? "")
        let edited = Data("a new user version".utf8)
        try edited.write(to: image)
        session.restore(id); try await wait(session)
        XCTAssertEqual(session.job(id)?.stage, .replacementPending)
        XCTAssertEqual(try Data(contentsOf: image), edited)
    }
    @MainActor
    func testExportUsesOriginalNamesAndDoesNotOverwriteSources() async throws {
        let root = try directory()
        let store = FileTaskStore(root: URL.temporaryDirectory.appending(path: UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: store.root) }
        let first = root.appending(path: "A"), second = root.appending(path: "B")
        let a = try SyntheticPhoto.make(in: first, name: "Same")
        let b = try SyntheticPhoto.make(in: second, name: "Same")
        let before = try FileAccess.digest(a)
        let session = FileSession(store: store)
        session.scan([root]); try await wait(session)
        let ids = Set(session.candidates.map(\.id))
        session.enqueue(ids); session.compress(Array(ids)); try await wait(session)
        XCTAssertTrue(session.jobs.allSatisfy { $0.stage == .ready }, session.message ?? "")
        let urls = try await session.exportURLs(Array(ids))
        defer { FileExports.clean(urls) }
        XCTAssertEqual(Set(urls.map(\.lastPathComponent)), ["Same-压缩.jpg", "Same-压缩-2.jpg"])
        XCTAssertEqual(try FileAccess.digest(a), before)
        XCTAssertEqual(try FileAccess.digest(b), before)
    }
    func testCancellationCleansPartialCopyAndDoesNotChangeOriginal() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try SyntheticPhoto.make(in: root)
        let digest = try FileAccess.digest(source)
        let target = root.appending(path: "partial.jpg")
        let cancellation = FileCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(try FileAccess.copy(source, to: target, cancellation: cancellation)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try FileAccess.digest(source), digest)
    }
    @MainActor
    func testCorruptJournalKeepsAllMedia() throws {
        let store = FileTaskStore(root: URL.temporaryDirectory.appending(path: UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: store.root) }
        try store.prepare()
        let file = try store.file(UUID().uuidString + ".jpg")
        let bytes = Data("recovery".utf8)
        try bytes.write(to: file)
        try Data("corrupt".utf8).write(to: store.root.appending(path: "queue.json"))
        let session = FileSession(store: store)
        XCTAssertFalse(session.healthy)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    func testUnknownOrSymbolicLocationsDoNotPermitReplacement() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try SyntheticPhoto.make(in: root)
        let link = root.appending(path: "Link.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertFalse(FileAccess.canReplace(link))
        XCTAssertFalse(FileAccess.canReplace(URL.temporaryDirectory.appending(path: "unknown.jpg")))
    }
    @MainActor
    func testInterruptedReplacementRecoversToManualReview() async throws {
        let root = try directory()
        let store = FileTaskStore(root: URL.temporaryDirectory.appending(path: UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: store.root) }
        _ = try SyntheticPhoto.make(in: root)
        let session = FileSession(store: store)
        session.scan([root]); try await wait(session)
        let id = try XCTUnwrap(session.candidates.first?.id)
        session.enqueue([id]); session.compress([id]); try await wait(session)
        var jobs = session.jobs
        jobs[0].stage = .replacing
        try store.save(jobs)
        let recovered = FileSession(store: store)
        XCTAssertEqual(recovered.job(id)?.stage, .replacementPending)
        XCTAssertFalse(recovered.busy)
        recovered.recheck(id); try await wait(recovered)
        XCTAssertEqual(recovered.job(id)?.stage, .ready, recovered.message ?? "")
    }
}
