import Foundation

@main
struct GeneratePhotoFixtures {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let exact = try SyntheticPhoto.make(in: directory, name: "ExactA", width: 1600, height: 1200)
        try FileManager.default.copyItem(at: exact, to: directory.appending(path: "ExactA-copy.jpg"))
        _ = try SyntheticPhoto.make(in: directory, name: "SimilarB", width: 960, height: 720, seed: 81)
        _ = try SyntheticPhoto.make(in: directory, name: "SimilarB-recompressed", width: 960, height: 720, seed: 81, quality: 0.9)
        _ = try SyntheticPhoto.make(in: directory, name: "CompressHEIC", width: 2000, height: 1500, seed: 17, heic: true, orientation: 6)
        print(directory.path)
    }
}
