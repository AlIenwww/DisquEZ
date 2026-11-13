import Foundation
import Photos
import XCTest
@testable import DisquEZ

final class VideoCatalogTests: XCTestCase {
    func testSizeAndFrameRateFiltersKeepUnresolvedVideosSeparate() {
        let pending = video("pending")
        XCTAssertEqual(pending.section(for: .large), .unknownSize)
        XCTAssertEqual(pending.section(for: .highFrameRate), .unknownFrameRate)

        let inCloud = video("cloud", resourceBytes: 100_000_000, measurement: .cloudOnly)
        XCTAssertEqual(inCloud.section(for: .large), .knownSize)
        XCTAssertNil(inCloud.savings(preset: .balanced))

        let measured = video("measured", resourceBytes: 105_000_000,
                             measurement: .local(bytes: 95_000_000, frameRate: 59.94, estimate: nil))
        XCTAssertEqual(measured.fileBytes, 95_000_000)
        XCTAssertNil(measured.section(for: .large))
        XCTAssertEqual(measured.section(for: .highFrameRate), .knownSize)

        let ordinary = video("30fps", measurement: .local(bytes: 100_000_000, frameRate: 30, estimate: nil))
        XCTAssertNil(ordinary.section(for: .highFrameRate))
        XCTAssertEqual(ordinary.section(for: .large), .knownSize)
    }

    func testMetadataFiltersHandlePortraitClipsAndPhotoKitSubtypes() {
        let recording = video("recording", width: 2_160, height: 3_840, duration: 300,
                              subtypes: .videoScreenRecording)
        XCTAssertEqual(recording.section(for: .fourK), .unknownSize)
        XCTAssertEqual(recording.section(for: .long), .unknownSize)
        XCTAssertEqual(recording.section(for: .screenRecording), .unknownSize)

        let slowMotion = video("slow-mo", duration: 299.9, subtypes: .videoHighFrameRate)
        XCTAssertEqual(slowMotion.section(for: .highFrameRate), .unknownSize)
        XCTAssertEqual(slowMotion.protectedCaptureEffect, "慢动作")
        XCTAssertNil(slowMotion.section(for: .long))
        XCTAssertNil(slowMotion.section(for: .screenRecording))
        XCTAssertNil(slowMotion.section(for: .fourK))
    }

    func testSavingsSortCanPreferTheSmallerFileAndLeavesUnknownLast() {
        let short = video("short", measurement: .local(bytes: 60_000_000, frameRate: 30, estimate: estimate(20)))
        let long = video("long", duration: 130,
                         measurement: .local(bytes: 100_000_000, frameRate: 30, estimate: estimate(130)))
        let unmeasured = video("unmeasured", resourceBytes: 200_000_000)
        let items = [unmeasured, long, short]
        let bySize = CatalogSection.ordered(items, sort: .size, preset: .balanced, video: { $0 })
        let bySavings = CatalogSection.ordered(items, sort: .savings, preset: .balanced, video: { $0 })
        XCTAssertEqual(bySize.map(\.id), ["unmeasured", "long", "short"])
        XCTAssertEqual(bySavings.map(\.id), ["short", "long", "unmeasured"])
        XCTAssertEqual(long.savings(preset: .quality), 0)
        XCTAssertGreaterThan(long.savings(preset: .space) ?? 0, long.savings(preset: .balanced) ?? 0)
    }

    private func estimate(_ duration: TimeInterval) -> VideoEstimate {
        VideoEstimate(size: CGSize(width: 3_840, height: 2_160), duration: duration,
                      frameRate: 30, videoBitrate: 8_000_000, audioBitrate: 256_000)
    }

    private func video(_ id: String, width: Int = 1_920, height: Int = 1_080, duration: TimeInterval = 20,
                       subtypes: PHAssetMediaSubtype = [], resourceBytes: Int64? = nil,
                       measurement: VideoMeasurement? = nil) -> CatalogVideo {
        CatalogVideo(id: id, created: nil,
                     revision: .init(modified: nil, width: width, height: height, duration: duration,
                                     subtypes: subtypes, adjusted: false),
                     resourceBytes: resourceBytes, measurement: measurement)
    }
}
