import Foundation
import Photos

enum SpaceStrategy: String, Codable, CaseIterable, Identifiable {
    case compress = "优先压缩", archive = "优先归档"
    var id: Self { self }
}

struct SpaceIgnored: Codable, Equatable, Identifiable {
    let id: String
    let title: String
}

struct SpacePreferences: Codable, Equatable {
    var goalMB = 1_000
    var strategy = SpaceStrategy.compress
    var excludeFavorites = true
    var albumIDs: Set<String> = []
    var ignored: [SpaceIgnored] = []
    var scanLimit = 300

    static let goalRange = 1...1_000_000
    static let scanLimits = [100, 300, 1_000]
    var goalBytes: Int64 { Int64(goalMB) * 1_000_000 }
    var restrictions: SpaceRestrictions {
        .init(excludeFavorites: excludeFavorites, albumIDs: albumIDs, ignored: Set(ignored.map(\.id)))
    }
    var valid: Bool {
        Self.goalRange.contains(goalMB) && Self.scanLimits.contains(scanLimit) && Set(ignored.map(\.id)).count == ignored.count
    }
}

struct SpaceRestrictions: Sendable {
    let excludeFavorites: Bool
    let albumIDs: Set<String>
    let ignored: Set<String>

    static func photoKey(_ id: String) -> String { "photo:\(id)" }
    func allows(_ photo: PHAsset) -> Bool {
        guard !photo.isHidden, !ignored.contains(Self.photoKey(photo.localIdentifier)),
              !excludeFavorites || !photo.isFavorite else { return false }
        if albumIDs.isEmpty { return true }
        guard PhotoLibrary.access == .authorized else { return false }
        let albums = PHAssetCollection.fetchAssetCollectionsContaining(photo, with: .album, options: nil)
        for index in 0..<albums.count where albumIDs.contains(albums.object(at: index).localIdentifier) { return false }
        return true
    }
}

struct SpaceAlbum: Identifiable {
    let id: String
    let title: String
}

enum SpaceAction: String, CaseIterable, Identifiable {
    case duplicates = "重复整理", compression = "压缩", archive = "归档"
    var id: Self { self }
}

struct SpaceProposal: Identifiable {
    enum Route {
        case group(MediaGroup)
        case video(MediaMember)
        case photo(MediaMember)
        case newArchive(MediaMember)
        case archive(UUID, UUID, MediaMember)
        case file(UUID)
    }

    let id: String
    let action: SpaceAction
    let title: String
    let note: String
    let keys: Set<String>
    let bytes: Int64?
    let route: Route

    var members: [MediaMember] {
        switch route {
        case .group(let group): group.members
        case .video(let member), .photo(let member), .newArchive(let member), .archive(_, _, let member): [member]
        case .file: []
        }
    }
    var priority: Int {
        switch route {
        case .group: 0
        case .archive: 1
        default: 2
        }
    }
}

struct SpacePlan {
    let proposals: [SpaceProposal]
    let suggestedIDs: Set<String>
    let totalBytes: Int64
    let suggestedBytes: Int64

    static func make(_ options: [SpaceProposal], preferences: SpacePreferences) -> Self {
        let ignored = preferences.restrictions.ignored
        let sorted = options.filter { !$0.keys.isEmpty && $0.keys.isDisjoint(with: ignored) }.sorted { first, second in
            if (first.bytes != nil) != (second.bytes != nil) { return first.bytes != nil }
            if first.priority != second.priority { return first.priority < second.priority }
            let preferred: SpaceAction = preferences.strategy == .archive ? .archive : .compression
            if (first.action == preferred) != (second.action == preferred) { return first.action == preferred }
            return bySavings(first, second)
        }
        var claimed: Set<String> = []
        let distinct = sorted.filter { proposal in
            // Similarity is a manual review and never reserves or contributes estimated bytes.
            if case .group(let group) = proposal.route, group.kind == .similar { return true }
            guard claimed.isDisjoint(with: proposal.keys) else { return false }
            claimed.formUnion(proposal.keys)
            return true
        }.sorted(by: bySavings)

        var total: Int64 = 0, suggested: Int64 = 0
        var ids: Set<String> = []
        for proposal in distinct {
            if case .group(let group) = proposal.route, group.kind == .similar { continue }
            guard let bytes = proposal.bytes, bytes > 0 else { continue }
            total = add(total, bytes)
            if suggested < preferences.goalBytes {
                suggested = add(suggested, bytes)
                ids.insert(proposal.id)
            }
        }
        return .init(proposals: distinct, suggestedIDs: ids, totalBytes: total, suggestedBytes: suggested)
    }

    static func duplicateBytes(_ members: [MediaMember]) -> Int64? {
        guard members.count > 1, let keeper = members.first, keeper.digest.bytes > 0,
              members.allSatisfy({ $0.digest == keeper.digest }) else { return nil }
        return members.dropFirst().reduce(0) { add($0, $1.digest.bytes) }
    }

    private static func bySavings(_ first: SpaceProposal, _ second: SpaceProposal) -> Bool {
        if first.bytes != second.bytes { return (first.bytes ?? -1) > (second.bytes ?? -1) }
        return first.id < second.id
    }

    private static func add(_ first: Int64, _ second: Int64) -> Int64 {
        let (total, overflow) = first.addingReportingOverflow(second)
        return overflow ? Int64.max : total
    }
}

struct SpacePreferenceStore {
    let url: URL
    static let live = SpacePreferenceStore(url: URL.applicationSupportDirectory.appending(path: "SpacePlan/preferences-v1.json"))

    func load() throws -> SpacePreferences {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        let result = try JSONDecoder().decode(SpacePreferences.self, from: Data(contentsOf: url))
        guard result.valid else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }

    func save(_ preferences: SpacePreferences) throws {
        guard preferences.valid else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(preferences).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
