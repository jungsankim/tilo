import XCTest
@testable import Tilo

final class SubtitleLoaderTests: XCTestCase {
    func testSubtitleDiscoveryDoesNotMatchAnotherVideoWithSamePrefix() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TiloSubtitleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let wrong = folder.appendingPathComponent("movie2.srt")
        try Data("1\n00:00:00,000 --> 00:00:01,000\nWrong\n".utf8).write(to: wrong)
        let localized = folder.appendingPathComponent("movie.ko.srt")
        try Data("1\n00:00:00,000 --> 00:00:01,000\nCorrect\n".utf8).write(to: localized)

        let loaded = SubtitleLoader.loadWithSource(
            for: folder.appendingPathComponent("movie.mp4")
        )
        XCTAssertEqual(loaded?.url.lastPathComponent, localized.lastPathComponent)
        XCTAssertEqual(loaded?.cues.first?.text, "Correct")
    }
}
