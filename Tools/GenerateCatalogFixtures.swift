import AVFoundation

// Compile alongside DisquEZTests/SyntheticVideo.swift and pass a fresh output directory.
@main
struct GenerateCatalogFixtures {
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let inputs: [(String, CGSize, Int, CMTime)] = [
            ("Catalog4K", CGSize(width: 3_840, height: 2_160), 16, CMTime(value: 1, timescale: 30)),
            ("CatalogLong", CGSize(width: 320, height: 240), 10, CMTime(value: 35, timescale: 1)),
            ("Catalog60fps", CGSize(width: 960, height: 540), 48, CMTime(value: 1, timescale: 60))
        ]
        for (name, size, count, frameDuration) in inputs {
            let movie = try await SyntheticVideo.make(size: size, frames: count, frameDuration: frameDuration)
            defer { try? FileManager.default.removeItem(at: movie) }
            if name == "Catalog4K" {
                // A valid QuickTime free atom crosses the file-size threshold without encoding minutes of 4K.
                let file = try FileHandle(forWritingTo: movie)
                defer { try? file.close() }
                let offset = try file.seekToEnd()
                var atomSize = UInt32(115_000_000).bigEndian
                try withUnsafeBytes(of: &atomSize) { try file.write(contentsOf: Data($0)) }
                try file.write(contentsOf: Data([0x66, 0x72, 0x65, 0x65]))
                try file.truncate(atOffset: offset + 115_000_000)
            }
            let asset = AVURLAsset(url: movie)
            let track = try await asset.loadTracks(withMediaType: .video).first!
            let (duration, fps) = try await (asset.load(.duration), track.load(.nominalFrameRate))
            let bytes = try movie.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            try FileManager.default.moveItem(at: movie, to: directory.appending(path: "\(name).mov"))
            print("\(name): \(bytes) bytes, \(duration.seconds) seconds, \(fps) fps")
        }
    }
}
