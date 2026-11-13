import Foundation

enum ArchiveError: LocalizedError {
    case invalid, changed, destination, notExternal, syncPending, restorePending
    var errorDescription: String? {
        switch self {
        case .invalid: "归档清单或文件核验失败，已停止本次操作。"
        case .changed: "原件或归档已变化，请重新选择并核验。"
        case .destination: "归档位置无法访问，请重新连接该归档目录。"
        case .notExternal: "此位置尚不能确认是外接盘或已同步云盘，原件保留。"
        case .syncPending: "尚未确认全部归档文件已同步到 iCloud，原件保留。"
        case .restorePending: "上次恢复或移除的结果待核对，不会自动重复操作。"
        }
    }
}

struct ArchiveAlbum: Codable, Equatable { let identifier: String; let title: String }

struct ArchiveEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case file, photo, video }
    let id: UUID
    let name: String
    let fileName: String
    let kind: Kind
    let digest: ResourceDigest
    let created: Date?
    let modified: Date?
    let photo: PhotoSnapshot?
    let albums: [ArchiveAlbum]
    var relativePath: String? = nil
}

struct ArchiveManifest: Codable, Equatable, Identifiable {
    let version: Int
    let id: UUID
    let created: Date
    let entries: [ArchiveEntry]
    var bytes: Int64 { entries.reduce(0) { $0 + $1.digest.bytes } }
    var directoryName: String { "DisquEZ-归档-\(id.uuidString)" }
    func validate() throws {
        guard version == 1, !entries.isEmpty, entries.count <= 5_000,
              Set(entries.map(\.id)).count == entries.count,
              Set(entries.map(\.fileName)).count == entries.count else { throw ArchiveError.invalid }
        var total: Int64 = 0
        for item in entries {
            guard item.digest.bytes > 0, item.digest.hash.count == 32,
                  item.digest.bytes <= Int64.max - total,
                  !item.name.isEmpty, item.name == (item.name as NSString).lastPathComponent,
                  item.name != ".", item.name != "..",
                  item.fileName == (item.fileName as NSString).lastPathComponent,
                  UUID(uuidString: (item.fileName as NSString).deletingPathExtension) != nil,
                  !(item.fileName as NSString).pathExtension.isEmpty,
                  item.fileName.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" }),
                  (item.kind == .file && item.photo == nil) || (item.kind != .file && item.photo != nil) else { throw ArchiveError.invalid }
            total += item.digest.bytes
            if let path = item.relativePath {
                guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
                      (path as NSString).lastPathComponent == item.name else { throw ArchiveError.invalid }
            }
        }
    }
}

enum ArchiveDestination: String, Codable {
    case local, external, cloudPending, cloudSynced, unknown
    var permitsRemoval: Bool { self == .external || self == .cloudSynced }
    var label: String {
        switch self {
        case .local: "本机归档 · 原件保留"
        case .external: "外接盘 · 已回读核验"
        case .cloudPending: "iCloud · 同步尚未确认"
        case .cloudSynced: "iCloud · 系统已确认同步"
        case .unknown: "位置或同步状态无法确认 · 原件保留"
        }
    }
}

struct ArchiveItemState: Codable {
    enum Removal: String, Codable { case present, removing, pending, removed }
    enum Restoration: String, Codable { case none, restoring, pending, restored }
    let id: UUID
    var fileOrigin: FileReference?
    var photoOrigin: PhotoSnapshot?
    var removal: Removal = .present
    var restoration: Restoration = .none
    var restoredCopy: SavedCopy?
    var note: String?
}

struct ArchiveRecord: Codable, Identifiable {
    enum Stage: String, Codable { case writing, needsVerification, verified }
    var id: UUID { manifest.id }
    let manifest: ArchiveManifest
    var location: FileReference
    var locationName: String
    var stage: Stage = .writing
    var destination: ArchiveDestination = .unknown
    var verifiedAt: Date?
    var states: [ArchiveItemState]
    var note: String?
}

struct ArchiveStore {
    let root: URL
    static let live = ArchiveStore(root: URL.applicationSupportDirectory.appending(path: "Archives"))
    var staging: URL { root.appending(path: "Staging") }
    private var journal: URL { root.appending(path: "archives.json") }
    func prepare() throws {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var url = root; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
    func save(_ records: [ArchiveRecord]) throws {
        try prepare()
        try JSONEncoder().encode(records).write(to: journal, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func load() throws -> [ArchiveRecord] {
        guard FileManager.default.fileExists(atPath: journal.path) else { return [] }
        let records = try JSONDecoder().decode([ArchiveRecord].self, from: Data(contentsOf: journal))
        guard Set(records.map(\.id)).count == records.count else { throw ArchiveError.invalid }
        return try records.map { value in
            var record = value
            try record.manifest.validate()
            guard Set(record.states.map(\.id)) == Set(record.manifest.entries.map(\.id)),
                  record.states.count == record.manifest.entries.count else { throw ArchiveError.invalid }
            // Every launch requires a new read from the target; never trust a past mount or upload state.
            record.stage = .needsVerification; record.verifiedAt = nil
            for i in record.states.indices {
                guard let entry = record.manifest.entries.first(where: { $0.id == record.states[i].id }) else { throw ArchiveError.invalid }
                if entry.kind == .file {
                    guard record.states[i].photoOrigin == nil else { throw ArchiveError.invalid }
                } else {
                    guard record.states[i].fileOrigin == nil,
                          record.states[i].photoOrigin == nil || record.states[i].photoOrigin == entry.photo else { throw ArchiveError.invalid }
                }
                if record.states[i].removal == .removing { record.states[i].removal = .pending }
                if record.states[i].restoration == .restoring { record.states[i].restoration = .pending }
                if let copy = try receipt(record.id, record.states[i].id) {
                    record.states[i].restoredCopy = copy
                    if record.states[i].restoration != .restored { record.states[i].restoration = .pending }
                }
            }
            return record
        }
    }
    private func receiptURL(_ record: UUID, _ entry: UUID) -> URL { root.appending(path: "\(record)-\(entry)-restore.json") }
    func saveReceipt(_ copy: SavedCopy, record: UUID, entry: UUID) throws {
        try prepare()
        try JSONEncoder().encode(copy).write(to: receiptURL(record, entry), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func receipt(_ record: UUID, _ entry: UUID) throws -> SavedCopy? {
        let url = receiptURL(record, entry)
        return FileManager.default.fileExists(atPath: url.path) ? try JSONDecoder().decode(SavedCopy.self, from: Data(contentsOf: url)) : nil
    }
    func cleanStaging() throws {
        try prepare()
        for url in try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            where UUID(uuidString: url.lastPathComponent) != nil { try FileManager.default.removeItem(at: url) }
    }
}
