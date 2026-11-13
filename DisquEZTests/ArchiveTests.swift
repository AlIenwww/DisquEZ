import CoreLocation
import Photos
import XCTest
import os
@testable import DisquEZ

final class ArchiveTests: XCTestCase {
    @MainActor
    func testFullFileArchiveAndNamedExportsPreserveAllBytes() async throws {
        let (root, store, session) = try context()
        defer { clean(root, store) }
        let input = root.appending(path: "Input")
        for child in ["A", "B"] {
            let folder = input.appending(path: child); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: child == "A" ? 41 : 77, count: 250_000).write(to: folder.appending(path: "Same.bin"))
        }
        session.addFiles([input]); try await wait(session)
        let ids = Set(session.selections.map(\.id))
        session.create(ids, parent: root, allowNetwork: false); try await wait(session)
        let record = try XCTUnwrap(session.records.first, session.message ?? "")
        XCTAssertEqual(record.stage, .verified)
        XCTAssertEqual(record.destination, .local)
        XCTAssertEqual(Set(record.manifest.entries.compactMap(\.relativePath)), ["A/Same.bin", "B/Same.bin"])
        let urls = try await session.export(record.id, entries: ids)
        defer { FileExports.clean(urls) }
        XCTAssertEqual(Set(urls.map(\.lastPathComponent)), ["Same.bin", "Same-2.bin"])
        XCTAssertEqual(Set(try urls.map { try FileAccess.digest($0).hash }), Set(record.manifest.entries.map { $0.digest.hash }))
        session.remove(record.id, entries: ids)
        XCTAssertFalse(session.busy)
        for entry in record.manifest.entries {
            XCTAssertNotNil(session.removalReason(record, item: entry))
            XCTAssertEqual(try FileAccess.digest(input.appending(path: entry.relativePath!)), entry.digest)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.staging.path).isEmpty)
    }
    @MainActor
    func testDamagedArchiveCannotBeExportedAndInvalidatesVerification() async throws {
        let (root, store, session) = try context(); defer { clean(root, store) }
        let source = root.appending(path: "Original.txt")
        try Data("A complete synthetic original".utf8).write(to: source)
        let before = try FileAccess.digest(source)
        let record = try await archive(source, in: root, session: session)
        let entry = record.manifest.entries[0]
        try record.location.withAccess { folder in try Data("modified archive".utf8).write(to: ArchiveIO.file(entry, in: folder)) }
        session.verify(record.id); try await wait(session)
        XCTAssertEqual(session.record(record.id)?.stage, .needsVerification)
        XCTAssertNil(session.record(record.id)?.verifiedAt)
        do { _ = try await session.export(record.id, entries: [entry.id]); XCTFail("A changed archive cannot restore") } catch { }
        XCTAssertEqual(try FileAccess.digest(source), before)
    }
    @MainActor
    func testMovedArchiveReconnectsAndImportsWithoutSourceRemovalAuthority() async throws {
        let (root, store, session) = try context(); defer { clean(root, store) }
        let source = root.appending(path: "Original.txt"); try Data("synthetic original".utf8).write(to: source)
        let record = try await archive(source, in: root, session: session)
        let moved = root.appending(path: "MovedArchive")
        try record.location.withAccess { try FileManager.default.moveItem(at: $0, to: moved) }
        let resumed = ArchiveSession(store: store)
        XCTAssertEqual(resumed.records[0].stage, .needsVerification)
        resumed.connect(moved); try await wait(resumed)
        XCTAssertEqual(resumed.records.count, 1)
        XCTAssertEqual(resumed.records[0].stage, .verified, resumed.message ?? "")
        let importedStore = ArchiveStore(root: URL.temporaryDirectory.appending(path: UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: importedStore.root) }
        let imported = ArchiveSession(store: importedStore)
        imported.connect(moved); try await wait(imported)
        let value = try XCTUnwrap(imported.records.first)
        XCTAssertTrue(value.states.allSatisfy { $0.fileOrigin == nil && $0.photoOrigin == nil })
        XCTAssertNotNil(imported.removalReason(value, item: value.manifest.entries[0]))
        let urls = try await imported.export(value.id, entries: Set(value.manifest.entries.map(\.id)))
        defer { FileExports.clean(urls) }
        XCTAssertEqual(try FileAccess.digest(urls[0]), try FileAccess.digest(source))
    }
    @MainActor
    func testInterruptedRemovalAndRestoreReceiptNeedManualReview() async throws {
        let (root, store, session) = try context(); defer { clean(root, store) }
        let source = root.appending(path: "Original.txt"); try Data("synthetic original".utf8).write(to: source)
        var record = try await archive(source, in: root, session: session)
        record.states[0].removal = .removing; record.states[0].restoration = .restoring
        try store.save([record])
        let receipt = SavedCopy(identifier: "synthetic-uncommitted-identifier", albumIdentifiers: [])
        try store.saveReceipt(receipt, record: record.id, entry: record.manifest.entries[0].id)
        let resumed = ArchiveSession(store: store)
        XCTAssertFalse(resumed.busy)
        XCTAssertEqual(resumed.records[0].stage, .needsVerification)
        XCTAssertEqual(resumed.records[0].states[0].removal, .pending)
        XCTAssertEqual(resumed.records[0].states[0].restoration, .pending)
        XCTAssertEqual(resumed.records[0].states[0].restoredCopy?.identifier, receipt.identifier)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
    @MainActor
    func testCancelledArchiveKeepsOriginalAndCleansStaging() async throws {
        let (root, store, session) = try context(); defer { clean(root, store) }
        let source = root.appending(path: "Original.txt"); try Data(repeating: 55, count: 100_000).write(to: source)
        let before = try FileAccess.digest(source)
        session.addFiles([source]); try await wait(session)
        session.create(Set(session.selections.map(\.id)), parent: root, allowNetwork: false)
        session.cancel(); try await wait(session)
        XCTAssertEqual(try FileAccess.digest(source), before)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.staging.path).isEmpty)
        XCTAssertTrue(session.records.allSatisfy { $0.stage != .verified })
    }
    @MainActor
    func testCorruptPrivateIndexRetainsStagingAndDisablesActions() throws {
        let (root, store, _) = try context(); defer { clean(root, store) }
        let folder = store.staging.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "Original.bin"); try Data([1, 2, 3]).write(to: file)
        try Data("invalid private index".utf8).write(to: store.root.appending(path: "archives.json"))
        let reopened = ArchiveSession(store: store)
        XCTAssertFalse(reopened.healthy)
        XCTAssertEqual(try Data(contentsOf: file), Data([1, 2, 3]))
    }
    @MainActor
    func testSymlinkEscapeAndChangedManifestAreRefused() async throws {
        let (root, store, session) = try context(); defer { clean(root, store) }
        let source = root.appending(path: "Original.txt"); try Data("original".utf8).write(to: source)
        let record = try await archive(source, in: root, session: session)
        try record.location.withAccess { folder in
            let originals = folder.appending(path: "Originals")
            try FileManager.default.removeItem(at: originals)
            try FileManager.default.createSymbolicLink(at: originals, withDestinationURL: root)
        }
        do { _ = try await ArchiveIO.verify(record.manifest, at: record.location); XCTFail("Symlink escape must fail") } catch { }
        let entry = record.manifest.entries[0]
        let changed = ArchiveEntry(id: entry.id, name: "../outside", fileName: "../../outside.bin", kind: .file, digest: entry.digest, created: nil, modified: nil, photo: nil, albums: [])
        let malicious = ArchiveManifest(version: 1, id: record.id, created: .now, entries: [changed])
        XCTAssertThrowsError(try malicious.validate())
        XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
    }
    func testOnlyConfirmedExternalOrSyncedCloudCanAuthorizeRemoval() {
        for destination in [ArchiveDestination.local, .unknown, .cloudPending] { XCTAssertFalse(destination.permitsRemoval) }
        XCTAssertTrue(ArchiveDestination.external.permitsRemoval)
        XCTAssertTrue(ArchiveDestination.cloudSynced.permitsRemoval)
    }
    @MainActor
    func testOriginalMetadataChangeBlocksFileRemoval() async throws {
        let (root, store, session) = try context(); defer { clean(root, store) }
        let source = root.appending(path: "Original.txt"); try Data("original".utf8).write(to: source)
        let record = try await archive(source, in: root, session: session), entry = record.manifest.entries[0]
        XCTAssertTrue(ArchiveIO.originalInfoMatches(entry, url: source))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1234)], ofItemAtPath: source.path)
        XCTAssertFalse(ArchiveIO.originalInfoMatches(entry, url: source))
    }
    @MainActor
    func testPhotoArchiveRestoresBytesMetadataAndAlbumWithoutRepeatingCreation() async throws {
        guard ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"]?.hasPrefix("DisquEZ") == true,
              PhotoLibrary.access == .authorized else { throw XCTSkip("Requires authorized DisquEZ synthetic library") }
        let (root, store, session) = try context(); defer { clean(root, store) }
        let file = try SyntheticPhoto.make(in: root)
        let identifier = OSAllocatedUnfairLock(initialState: Optional<String>.none)
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset(); request.addResource(with: .photo, fileURL: file, options: nil)
            request.creationDate = date; request.location = CLLocation(latitude: 31.2, longitude: 121.5); request.isFavorite = true
            if let placeholder = request.placeholderForCreatedAsset {
                identifier.withLock { $0 = placeholder.localIdentifier }
                PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: "DisquEZ Archive Test").addAssets([placeholder] as NSArray)
            }
        }
        let original = try XCTUnwrap(identifier.withLock { $0 }.flatMap(PhotoLibrary.fetch))
        session.addPhotos([original]); let ids = Set(session.selections.map(\.id))
        session.create(ids, parent: root, allowNetwork: false); try await wait(session)
        let record = try XCTUnwrap(session.records.first, session.message ?? ""), entry = record.manifest.entries[0]
        XCTAssertEqual(entry.digest, try FileAccess.digest(file))
        XCTAssertEqual(entry.albums.map(\.title), ["DisquEZ Archive Test"])
        session.restorePhoto(record.id, entry: entry.id); try await wait(session)
        let state = try XCTUnwrap(session.record(record.id)?.states[0])
        XCTAssertEqual(state.restoration, .restored, session.message ?? "")
        let saved = try XCTUnwrap(state.restoredCopy?.identifier.flatMap(PhotoLibrary.fetch))
        XCTAssertEqual(saved.creationDate, date); XCTAssertTrue(saved.isFavorite)
        XCTAssertLessThan(try XCTUnwrap(saved.location).distance(from: CLLocation(latitude: 31.2, longitude: 121.5)), 1)
        let savedDigest = try await MediaResourceRead.read(MediaLibrary.resource(saved))
        XCTAssertEqual(savedDigest, entry.digest)
        var interrupted = try XCTUnwrap(session.record(record.id))
        interrupted.states[0].restoration = .restoring; interrupted.states[0].restoredCopy = nil
        try store.save([interrupted])
        let resumed = ArchiveSession(store: store)
        XCTAssertEqual(resumed.records[0].states[0].restoration, .pending)
        resumed.recheck(record.id, entry: entry.id); try await wait(resumed)
        XCTAssertEqual(resumed.records[0].states[0].restoration, .restored, resumed.message ?? "")
        XCTAssertEqual(resumed.records[0].states[0].restoredCopy?.identifier, saved.localIdentifier)
        session.restorePhoto(record.id, entry: entry.id)
        XCTAssertFalse(session.busy)
        XCTAssertEqual(session.record(record.id)?.states[0].restoredCopy?.identifier, saved.localIdentifier)
        XCTAssertNotNil(PhotoLibrary.fetch(original.localIdentifier))
        try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest(for: original).isFavorite = false }
        XCTAssertNotNil(ArchiveLibrary.removalReason(entry, state: record.states[0]))
    }
    @MainActor private func context() throws -> (URL, ArchiveStore, ArchiveSession) {
        let root = URL.documentsDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ArchiveStore(root: URL.temporaryDirectory.appending(path: UUID().uuidString))
        return (root, store, ArchiveSession(store: store))
    }
    private func clean(_ root: URL, _ store: ArchiveStore) { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: store.root) }
    @MainActor private func archive(_ source: URL, in parent: URL, session: ArchiveSession) async throws -> ArchiveRecord {
        session.addFiles([source]); try await wait(session)
        session.create(Set(session.selections.map(\.id)), parent: parent, allowNetwork: false); try await wait(session)
        return try XCTUnwrap(session.records.first, session.message ?? "")
    }
    @MainActor private func wait(_ session: ArchiveSession) async throws {
        let deadline = Date().addingTimeInterval(45)
        while session.busy, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(session.busy, "Archive operation timed out")
    }
}
