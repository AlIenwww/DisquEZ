import Foundation

enum FileExports {
    static let root = URL.cachesDirectory.appending(path: "FileExports", directoryHint: .isDirectory)
    static func prepare(_ jobs: [FileJob], store: FileTaskStore) async throws -> [URL] {
        let directory = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: directory) } }
        var files: [URL] = []
        for job in jobs {
            try Task.checkCancellation()
            guard let result = job.result else { continue }
            let source = try result.url(in: store)
            guard try FileAccess.digest(source) == result.digest else { throw CompressionError.invalidOutput }
            let stem = (job.name as NSString).deletingPathExtension
            var target = directory.appending(path: "\(stem)-压缩.\(source.pathExtension)")
            var suffix = 2
            while FileManager.default.fileExists(atPath: target.path) {
                target = directory.appending(path: "\(stem)-压缩-\(suffix).\(source.pathExtension)"); suffix += 1
            }
            guard target.deletingLastPathComponent() == directory,
                  try FileAccess.copy(source, to: target) == result.digest else { throw CompressionError.invalidOutput }
            files.append(target)
        }
        if files.isEmpty { return [] }
        success = true
        return files
    }
    static func clean(_ urls: [URL]) {
        let directories = Set(urls.map { $0.deletingLastPathComponent() })
        for directory in directories where directory.deletingLastPathComponent() == root
            && UUID(uuidString: directory.lastPathComponent) != nil {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
