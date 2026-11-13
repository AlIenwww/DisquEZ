import AVFoundation
import CoreLocation
import Photos
import XCTest
@testable import DisquEZ

final class VideoCompressionTests: XCTestCase {
    func testPortraitCompressionPreservesOrientationTimestampsAndAudio() async throws {
        let url = try await SyntheticVideo.make(rotated: true, audio: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try await VideoSource.inspect(AVURLAsset(url: url))
        let output = try await VideoCompression.compress(source, preset: .space) { _ in }
        defer { try? FileManager.default.removeItem(at: output.url) }
        let compressed = try await VideoSource.inspect(AVURLAsset(url: output.url))
        XCTAssertLessThan(output.bytes, source.bytes)
        XCTAssertEqual(compressed.displaySize, CGSize(width: 720, height: 1_280))
        XCTAssertEqual(compressed.duration.seconds, source.duration.seconds, accuracy: 1 / 30)
        XCTAssertEqual(compressed.frameRate, source.frameRate, accuracy: 0.01)
        XCTAssertEqual(try timestamps(source.videoTrack, asset: source.asset),
                       try timestamps(compressed.videoTrack, asset: compressed.asset))
        XCTAssertEqual(try samples(source.audioTrack!, asset: source.asset),
                       try samples(compressed.audioTrack!, asset: compressed.asset))
    }

    func testAllPresetsShrinkOrdinaryLandscapeVideo() async throws {
        let url = try await SyntheticVideo.make()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try await VideoSource.inspect(AVURLAsset(url: url))
        for preset in CompressionPreset.allCases {
            let output = try await VideoCompression.compress(source, preset: preset) { _ in }
            defer { try? FileManager.default.removeItem(at: output.url) }
            XCTAssertLessThan(output.bytes, source.bytes, preset.rawValue)
            let compressed = try await VideoSource.inspect(AVURLAsset(url: output.url))
            XCTAssertNil(compressed.audioTrack)
            XCTAssertEqual(compressed.size, preset.dimensions(for: source.size))
        }
    }

    func testFourKSourceCanBeReducedTo1080p() async throws {
        let url = try await SyntheticVideo.make(size: CGSize(width: 3_840, height: 2_160), frames: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try await VideoSource.inspect(AVURLAsset(url: url))
        let output = try await VideoCompression.compress(source, preset: .balanced) { _ in }
        defer { try? FileManager.default.removeItem(at: output.url) }
        XCTAssertEqual(output.displaySize, CGSize(width: 1_920, height: 1_080))
        XCTAssertLessThan(output.bytes, source.bytes)
    }

    func testHLGAndDolbyVisionRemainHDRWhenResized() async throws {
        let fixtures: [(SyntheticVideo.HDR, VideoRange, String, CGSize)] = [
            (.hlg, .hlg, "UIHDR-HLG.mov", CGSize(width: 3_840, height: 2_160)),
            (.dolbyVision, .dolbyVision, "UIHDR-DolbyVision.mov", CGSize(width: 1_920, height: 1_080))
        ]
        for (hdr, range, name, size) in fixtures {
            let url = try await SyntheticVideo.make(size: size, frames: 24, rotated: true, audio: true, hdr: hdr)
            defer { try? FileManager.default.removeItem(at: url) }
            let source = try await VideoSource.inspect(AVURLAsset(url: url))
            XCTAssertEqual(source.range, range)
            let output = try await VideoCompression.compress(source, preset: .space) { _ in }
            defer { try? FileManager.default.removeItem(at: output.url) }
            let resized = try await VideoSource.inspect(AVURLAsset(url: output.url))
            XCTAssertEqual(resized.range, range)
            XCTAssertEqual(resized.ambientViewingEnvironment, source.ambientViewingEnvironment)
            XCTAssertEqual(resized.displaySize, CGSize(width: 720, height: 1_280))
            XCTAssertTrue(output.requiresCopy)
            XCTAssertEqual(try timestamps(source.videoTrack, asset: source.asset),
                           try timestamps(resized.videoTrack, asset: resized.asset))
            let sourceAudio = try XCTUnwrap(source.audioTrack)
            let outputAudio = try XCTUnwrap(resized.audioTrack)
            XCTAssertEqual(try samples(sourceAudio, asset: source.asset), try samples(outputAudio, asset: resized.asset))

            #if targetEnvironment(simulator)
            if ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"]?.hasPrefix("DisquEZ") == true {
                let fixture = URL.documentsDirectory.appending(path: name)
                if FileManager.default.fileExists(atPath: fixture.path) {
                    try FileManager.default.removeItem(at: fixture)
                }
                try FileManager.default.copyItem(at: url, to: fixture)
            }
            #endif
        }
    }

    func testHDRCompatibilityExportIsSDRMP4WithAACAndKeepsSource() async throws {
        let url = try await SyntheticVideo.make(size: CGSize(width: 3_840, height: 2_160), frames: 24,
                                                audio: true, hdr: .dolbyVision)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try await VideoSource.inspect(AVURLAsset(url: url))
        let originalDigest = try VideoCompression.fingerprint(url)
        XCTAssertEqual(source.range, .dolbyVision)
        let output = try await VideoCompression.compress(source, preset: .space, encoding: .h264) { _ in }
        defer { try? FileManager.default.removeItem(at: output.url) }
        let readBack = try await VideoSource.inspect(AVURLAsset(url: output.url))
        XCTAssertEqual(output.url.pathExtension, "mp4")
        XCTAssertEqual(readBack.range, .sdr)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(readBack.videoFormat), kCMVideoCodecType_H264)
        XCTAssertEqual(readBack.audioFormat.map(CMFormatDescriptionGetMediaSubType), kAudioFormatMPEG4AAC)
        XCTAssertEqual(readBack.frameRate, source.frameRate, accuracy: 0.01)
        XCTAssertLessThan(output.bytes, source.bytes)
        XCTAssertEqual(try VideoCompression.fingerprint(url), originalDigest)

        let stored = try JSONEncoder().encode(OutputRecord(output))
        let restored = try JSONDecoder().decode(OutputRecord.self, from: stored).video()
        XCTAssertEqual(restored.url, output.url)
        XCTAssertTrue(restored.requiresCopy)
    }

    func testInsufficientSpaceIsReportedBeforeWriting() throws {
        XCTAssertThrowsError(try StorageCapacity.require(Int64.max)) { error in
            guard case CompressionError.insufficientSpace = error else {
                return XCTFail("Expected a space error")
            }
        }
    }

    func testCancellationRemovesPartialOutputAndLeavesSource() async throws {
        let url = try await SyntheticVideo.make()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try await VideoSource.inspect(AVURLAsset(url: url))
        let before = try VideoCompression.fingerprint(url)
        let existingOutputs = (try? FileManager.default.contentsOfDirectory(atPath: StorageCapacity.directory.path)) ?? []
        let task = Task {
            try await VideoCompression.compress(source, preset: .balanced) { progress in
                if progress > 0.01 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do {
            _ = try await task.value
            XCTFail("A cancelled compression must not produce a result")
        } catch is CancellationError {}
        XCTAssertEqual(try VideoCompression.fingerprint(url), before)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: StorageCapacity.directory.path)) ?? [], existingOutputs)
    }

    func testTinyVideoWithoutSavingsIsSkippedAndSourceIsKept() async throws {
        let url = try await SyntheticVideo.make(size: CGSize(width: 16, height: 16), frames: 1, solid: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try await VideoSource.inspect(AVURLAsset(url: url))
        let before = try VideoCompression.fingerprint(url)
        do {
            let output = try await VideoCompression.compress(source, preset: .balanced) { _ in }
            try? FileManager.default.removeItem(at: output.url)
            XCTFail("Fixture should grow due to HEVC container overhead")
        } catch CompressionError.noSavings(let original, let output) {
            XCTAssertGreaterThanOrEqual(output, original)
        }
        XCTAssertEqual(try VideoCompression.fingerprint(url), before)
    }

    func testMetadataAndAlbumSurviveSaveAndOriginalChangesBlockReplacement() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("This PhotoKit fixture test requires a dedicated simulator")
        #else
        guard ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"]?.hasPrefix("DisquEZ") == true,
              PhotoLibrary.access == .authorized else {
            throw XCTSkip("Use a simulator named DisquEZ… and run the photo permission UI test first")
        }
        let url = try await SyntheticVideo.make()
        defer { try? FileManager.default.removeItem(at: url) }
        var identifier: String?
        var albumID: String?
        let date = Date(timeIntervalSince1970: 946_684_800)
        let location = CLLocation(latitude: 31.23, longitude: 121.47)
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: url, options: nil)
            request.creationDate = date
            request.location = location
            request.isFavorite = true
            let album = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: "DisquEZ 合成视频验证")
            let placeholder = request.placeholderForCreatedAsset!
            album.addAssets([placeholder] as NSArray)
            identifier = placeholder.localIdentifier
            albumID = album.placeholderForCreatedAssetCollection.localIdentifier
        }
        let original = PHAsset.fetchAssets(withLocalIdentifiers: [try XCTUnwrap(identifier)], options: nil).firstObject!
        let selection = try await PhotoLibrary.select(original)
        let output = try await VideoCompression.compress(selection.source, preset: .balanced) { _ in }
        defer { try? FileManager.default.removeItem(at: output.url) }
        let copy = try await PhotoLibrary.save(output, from: selection)
        let verified = try await PhotoLibrary.verify(copy, video: output, original: original)
        XCTAssertTrue(verified.canReplace)
        let saved = PHAsset.fetchAssets(withLocalIdentifiers: [try XCTUnwrap(copy.identifier)], options: nil).firstObject!
        XCTAssertEqual(saved.creationDate!.timeIntervalSince(date), 0, accuracy: 1)
        XCTAssertTrue(saved.isFavorite)
        XCTAssertLessThan(saved.location!.distance(from: location), 1)
        let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID!], options: nil).firstObject!
        XCTAssertEqual(PHAsset.fetchAssets(in: album, options: nil).count, 2)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: original).isFavorite = false
        }
        do {
            try await PhotoLibrary.moveOriginalToRecentlyDeleted(original, copy: copy, verified: verified)
            XCTFail("A source changed after preview must stay in Photos")
        } catch CompressionError.replacementUnavailable {}
        XCTAssertEqual(PHAsset.fetchAssets(withLocalIdentifiers: [original.localIdentifier], options: nil).count, 1)
        let fixture = URL.documentsDirectory.appending(path: "UIFixture.mov")
        try? FileManager.default.removeItem(at: fixture)
        try FileManager.default.copyItem(at: url, to: fixture)
        #endif
    }

    private func timestamps(_ track: AVAssetTrack, asset: AVAsset) throws -> [Double] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var result: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0, CMSampleBufferGetTotalSampleSize(sample) > 0 {
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                XCTAssertTrue(time.isNumeric)
                result.append(time.seconds)
            }
        }
        return result.sorted()
    }

    private func samples(_ track: AVAssetTrack, asset: AVAsset) throws -> Data {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var result = Data()
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = Data(count: length)
            _ = chunk.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            result.append(chunk)
        }
        return result
    }
}
