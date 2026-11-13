import Photos
import XCTest
import os
@testable import DisquEZ

final class SpacePlanTests: XCTestCase {
    func testGoalStrategyAndIgnoresDoNotCountOneSourceTwice() {
        let choices = [proposal("compressed", .compression, "a", 4_000_000), proposal("archived", .archive, "a", 12_000_000),
                       proposal("other", .compression, "b", 3_000_000), proposal("unknown", .archive, "c", nil)]
        var prefs = SpacePreferences(goalMB: 5)
        let first = SpacePlan.make(choices, preferences: prefs)
        XCTAssertEqual(first.proposals.map(\.id), ["compressed", "other", "unknown"])
        XCTAssertEqual(first.totalBytes, 7_000_000)
        XCTAssertEqual(first.suggestedIDs, ["compressed", "other"])
        prefs.strategy = .archive
        prefs.ignored = [.init(id: "b", title: "Excluded")]
        let second = SpacePlan.make(choices, preferences: prefs)
        XCTAssertEqual(second.proposals.map(\.id), ["archived", "unknown"])
        XCTAssertEqual(second.totalBytes, 12_000_000)
        XCTAssertEqual(second.suggestedIDs, ["archived"])
    }

    func testPreferencesPersistAndInvalidGoalKeepsPreviousRecord() throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SpacePreferenceStore(url: root.appending(path: "prefs.json"))
        let prefs = SpacePreferences(goalMB: 23, strategy: .archive, excludeFavorites: false, albumIDs: ["test-album"],
                                    ignored: [.init(id: "photo:ignore", title: "Ignored")], scanLimit: 1_000)
        try store.save(prefs)
        XCTAssertEqual(try store.load(), prefs)
        XCTAssertThrowsError(try store.save(SpacePreferences(goalMB: Int.max)))
        XCTAssertEqual(try store.load(), prefs)
    }

    @MainActor func testLiveAlbumAndFavoriteExclusionsReserveOneKeeper() async throws {
        guard ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"]?.hasPrefix("DisquEZ") == true,
              PhotoLibrary.access == .authorized else { throw XCTSkip("Needs synthetic Photos library") }
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try SyntheticPhoto.make(in: root)
        let receipt = OSAllocatedUnfairLock(initialState: (ids: [String](), album: ""))
        try await PHPhotoLibrary.shared().performChanges {
            let album = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: "DisquEZ Plan Protected")
            receipt.withLock { $0.album = album.placeholderForCreatedAssetCollection.localIdentifier }
            for index in 0..<4 {
                let create = PHAssetCreationRequest.forAsset()
                create.addResource(with: .photo, fileURL: file, options: nil)
                create.isFavorite = index == 2
                if let placeholder = create.placeholderForCreatedAsset {
                    receipt.withLock { $0.ids.append(placeholder.localIdentifier) }
                    if index == 3 { album.addAssets([placeholder] as NSArray) }
                }
            }
        }
        let value = receipt.withLock { $0 }
        XCTAssertEqual(value.ids.count, 4)
        guard value.ids.count == 4 else { return }
        let restrictions = SpaceRestrictions(excludeFavorites: true, albumIDs: [value.album], ignored: [])
        let assets = value.ids.compactMap(PhotoLibrary.fetch).filter(restrictions.allows)
        XCTAssertEqual(assets.map(\.localIdentifier), Array(value.ids.prefix(2)))
        let scan = try await MediaAnalysis.scan(assets) { _, _, _ in }
        let group = try XCTUnwrap(scan.groups.first { $0.kind == .exact })
        let bytes = try StorageCapacity.fileSize(file)
        XCTAssertEqual(SpacePlan.duplicateBytes(group.members), bytes)
        let keys = Set(group.members.map { SpaceRestrictions.photoKey($0.id) })
        let exact = SpaceProposal(id: "pair", action: .duplicates, title: "Duplicate pair", note: "", keys: keys,
                                  bytes: bytes, route: .group(group))
        XCTAssertEqual(SpacePlan.make(keys.map { proposal($0, .archive, $0, 9_000_000) } + [exact], preferences: .init()).totalBytes, bytes)
        let original = try XCTUnwrap(PhotoLibrary.fetch(value.ids[1]))
        let album = try XCTUnwrap(PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [value.album], options: nil).firstObject)
        try await PHPhotoLibrary.shared().performChanges { PHAssetCollectionChangeRequest(for: album)?.addAssets([original] as NSArray) }
        var selection = GroupSelection()
        selection.keep(value.ids[0]); selection.toggle(value.ids[1])
        do {
            try await MediaAnalysis.remove(selection, from: group) { restrictions.allows($0) }
            XCTFail("Newly excluded member must stay in Photos")
        } catch CompressionError.replacementUnavailable { }
        XCTAssertEqual(value.ids.compactMap(PhotoLibrary.fetch).count, 4)
    }

    private func proposal(_ id: String, _ action: SpaceAction, _ key: String, _ bytes: Int64?) -> SpaceProposal {
        .init(id: id, action: action, title: id, note: "", keys: [key], bytes: bytes, route: .file(UUID()))
    }
}
