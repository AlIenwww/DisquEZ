import Foundation

enum ArchiveIO {
    static let indexName = "DisquEZ-清单.json"
    static func originalInfoMatches(_ entry: ArchiveEntry, url: URL) -> Bool {
        guard url.lastPathComponent == entry.name,
              let values = try? FileManager.default.attributesOfItem(atPath: url.path),
              values[.type] as? FileAttributeType == .typeRegular,
              values[.creationDate] as? Date == entry.created,
              values[.modificationDate] as? Date == entry.modified,
              (values[.size] as? NSNumber)?.int64Value == entry.digest.bytes else { return false }
        return true
    }
    static func file(_ item: ArchiveEntry, in folder: URL) throws -> URL {
        let url = folder.appending(path: "Originals", directoryHint: .isDirectory).appending(path: item.fileName)
        guard FileAccess.isDescendant(url, of: folder),
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw ArchiveError.invalid }
        return url
    }
    static func manifest(at folder: URL) throws -> ArchiveManifest {
        let url = folder.appending(path: indexName)
        guard FileAccess.isDescendant(url, of: folder),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 16_000_000 else { throw ArchiveError.invalid }
        let manifest = try JSONDecoder().decode(ArchiveManifest.self, from: Data(contentsOf: url))
        try manifest.validate()
        return manifest
    }
    static func createFolder(parent: FileReference, manifest: ArchiveManifest) async throws -> FileReference {
        try await FileAccess.coordinated(parent, writing: true, writingOptions: []) { parent, _ in
            guard try parent.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw ArchiveError.destination }
            let directory = parent.appending(path: manifest.directoryName, directoryHint: .isDirectory)
            guard !FileManager.default.fileExists(atPath: directory.path) else { throw CocoaError(.fileWriteFileExists) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            // Retain the picker-granted parent scope when creating a new child directory.
            return try FileReference(root: parent, child: directory)
        }
    }
    static func write(_ manifest: ArchiveManifest, sources: [UUID: URL], to reference: FileReference) async throws {
        try manifest.validate()
        try await FileAccess.coordinated(reference, writing: true, writingOptions: []) { folder, cancel in
            let originals = folder.appending(path: "Originals", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: false)
            let volume = try folder.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsInternalKey, .volumeAvailableCapacityKey])
            let externalVolume = volume.volumeIsLocal == true && volume.volumeIsInternal == false
            if externalVolume, let available = volume.volumeAvailableCapacity,
               Int64(available) < StorageCapacity.downloadRequirement(bytes: manifest.bytes) { throw CompressionError.insufficientSpace(manifest.bytes) }
            for item in manifest.entries {
                try cancel.check()
                guard let source = sources[item.id], try FileAccess.digest(source, cancellation: cancel) == item.digest else { throw ArchiveError.changed }
                let target = try file(item, in: folder)
                guard try FileAccess.copy(source, to: target, cancellation: cancel, checkingLocalSpace: !externalVolume) == item.digest,
                      try FileAccess.digest(target, cancellation: cancel) == item.digest else { throw ArchiveError.invalid }
                var attributes: [FileAttributeKey: Any] = [:]
                if let created = item.created { attributes[.creationDate] = created }
                if let modified = item.modified { attributes[.modificationDate] = modified }
                // Some external filesystems cannot represent every timestamp; the manifest retains them.
                try? FileManager.default.setAttributes(attributes, ofItemAtPath: target.path)
            }
            try cancel.check()
            let index = folder.appending(path: indexName)
            guard !FileManager.default.fileExists(atPath: index.path) else { throw ArchiveError.changed }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: index, options: [.atomic])
        }
    }
    static func verify(_ expected: ArchiveManifest, at reference: FileReference) async throws -> ArchiveDestination {
        try await FileAccess.coordinated(reference) { folder, cancel in
            let actual = try manifest(at: folder)
            guard actual == expected else { throw ArchiveError.changed }
            for item in actual.entries {
                try cancel.check()
                guard try FileAccess.digest(file(item, in: folder), cancellation: cancel) == item.digest else { throw ArchiveError.invalid }
            }
        }
        // Resource status must be queried after coordinated reads have finished, not while blocking uploads.
        return try reference.withAccess { folder in
            let urls = [folder.appending(path: indexName)] + (try expected.entries.map { try file($0, in: folder) })
            let root = try folder.resourceValues(forKeys: [.isUbiquitousItemKey, .volumeIsLocalKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey])
            if FileAccess.isInsideDocuments(folder) { return .local }
            if root.isUbiquitousItem == true {
                let synced = try urls.allSatisfy { url in
                    let values = try url.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey, .ubiquitousItemUploadingErrorKey, .ubiquitousItemDownloadingErrorKey, .ubiquitousItemHasUnresolvedConflictsKey])
                    return values.ubiquitousItemIsUploaded == true && values.ubiquitousItemIsUploading != true
                        && values.ubiquitousItemUploadingError == nil && values.ubiquitousItemDownloadingError == nil
                        && values.ubiquitousItemHasUnresolvedConflicts != true
                }
                return synced ? .cloudSynced : .cloudPending
            }
            if root.volumeIsLocal == true && root.volumeIsInternal == false && (root.volumeIsRemovable == true || root.volumeIsEjectable == true) { return .external }
            return .unknown
        }
    }
    static func readManifest(_ reference: FileReference) async throws -> ArchiveManifest {
        try await FileAccess.coordinated(reference) { folder, _ in try manifest(at: folder) }
    }
    static func digest(_ url: URL) async throws -> ResourceDigest { try FileAccess.digest(url) }
    static func exports(_ items: [ArchiveEntry], sources: [UUID: URL]) async throws -> [URL] {
        let output = FileExports.root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var success = false; defer { if !success { try? FileManager.default.removeItem(at: output) } }
        var urls: [URL] = []
        for entry in items {
            try Task.checkCancellation()
            guard let source = sources[entry.id] else { throw ArchiveError.invalid }
            var target = output.appending(path: entry.name), suffix = 2
            while FileManager.default.fileExists(atPath: target.path) {
                target = output.appending(path: "\((entry.name as NSString).deletingPathExtension)-\(suffix).\((entry.name as NSString).pathExtension)"); suffix += 1
            }
            guard try FileAccess.copy(source, to: target) == entry.digest,
                  try FileAccess.digest(target) == entry.digest else { throw ArchiveError.invalid }
            var attributes: [FileAttributeKey: Any] = [:]
            if let created = entry.created { attributes[.creationDate] = created }
            if let modified = entry.modified { attributes[.modificationDate] = modified }
            try? FileManager.default.setAttributes(attributes, ofItemAtPath: target.path)
            urls.append(target)
        }
        success = !urls.isEmpty
        return urls
    }
    static func stage(_ items: [ArchiveEntry], from record: ArchiveRecord, directory: URL) async throws -> [UUID: URL] {
        try await FileAccess.coordinated(record.location) { folder, cancel in
            guard try manifest(at: folder) == record.manifest else { throw ArchiveError.changed }
            var result: [UUID: URL] = [:]
            for item in items {
                let target = directory.appending(path: item.fileName)
                guard try FileAccess.copy(file(item, in: folder), to: target, cancellation: cancel) == item.digest,
                      try FileAccess.digest(target, cancellation: cancel) == item.digest else { throw ArchiveError.invalid }
                result[item.id] = target
            }
            return result
        }
    }
}
