import Foundation
import XCTest
@testable import Tilo

final class PlaylistReplacementTests: XCTestCase {
    func testUnsavedWorkspaceUsesAppNameInsteadOfUntitled() {
        let manager = PlayerManager()
        XCTAssertEqual(manager.projectWindowTitle, "Tilo")

        manager.playlist = [PlaylistEntry(url: URL(fileURLWithPath: "/tmp/example.mp4"))]
        manager.markProjectEdited()
        XCTAssertEqual(manager.projectWindowTitle, "Tilo •")
        XCTAssertFalse(manager.projectWindowTitle.contains("제목 없음"))
    }

    func testReplacementPreservesTileIdentityAndSettings() async throws {
        guard let ffmpeg = Remuxer.ffmpegURL else {
            throw XCTSkip("ffmpeg is not installed")
        }
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let originalURL = folder.appendingPathComponent("original.mp4")
        let replacementURL = folder.appendingPathComponent("replacement.mp4")
        guard makeVideo(ffmpeg, at: originalURL, color: "red"),
              makeVideo(ffmpeg, at: replacementURL, color: "blue"),
              await Remuxer.isNativelyPlayable(replacementURL)
        else {
            throw XCTSkip("Could not create a natively playable replacement fixture")
        }

        let manager = PlayerManager()
        let original = VideoItem(url: originalURL)
        original.isMuted = true
        original.volume = 0.35
        original.timeOffset = 0.4
        original.rotationQuarters = 1
        original.zoomScale = 1.6
        original.panOffset = CGSize(width: 0.08, height: -0.04)
        manager.items = [original]
        manager.selectedItemID = original.id
        manager.soloItemID = original.id
        manager.zoomedItemID = original.id

        let entry = PlaylistEntry(url: replacementURL)
        manager.playlist = [entry]
        manager.replaceSelectedItem(with: entry)
        XCTAssertFalse(manager.canReplaceSelectedItem(with: entry))

        let replaced = await waitUntil {
            manager.items.first?.sourceURL.standardizedFileURL
                == replacementURL.standardizedFileURL
        }
        XCTAssertTrue(replaced)
        let item = try XCTUnwrap(manager.items.first)
        XCTAssertEqual(manager.items.count, 1)
        XCTAssertEqual(item.id, original.id)
        XCTAssertEqual(manager.selectedItemID, original.id)
        XCTAssertEqual(manager.soloItemID, original.id)
        XCTAssertEqual(manager.zoomedItemID, original.id)
        XCTAssertTrue(item.isMuted)
        XCTAssertEqual(item.volume, 0.35, accuracy: 0.001)
        XCTAssertEqual(item.timeOffset, 0.4, accuracy: 0.001)
        XCTAssertEqual(item.rotationQuarters, 1)
        XCTAssertEqual(item.zoomScale, 1.6, accuracy: 0.001)
        XCTAssertEqual(item.panOffset.width, 0.08, accuracy: 0.001)
        XCTAssertEqual(item.panOffset.height, -0.04, accuracy: 0.001)
        XCTAssertTrue(manager.isProjectEdited)
    }

    func testFailedReplacementKeepsCurrentTile() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let originalURL = folder.appendingPathComponent("original.mp4")
        let invalidURL = folder.appendingPathComponent("broken.mp4")
        try Data("not a video".utf8).write(to: invalidURL)

        let manager = PlayerManager()
        let original = VideoItem(url: originalURL)
        manager.items = [original]
        manager.selectedItemID = original.id
        let entry = PlaylistEntry(url: invalidURL)
        manager.playlist = [entry]

        manager.replaceSelectedItem(with: entry)
        XCTAssertFalse(manager.canReplaceSelectedItem(with: entry))
        let finished = await waitUntil(timeout: 8) {
            manager.canReplaceSelectedItem(with: entry)
        }

        XCTAssertTrue(finished)
        XCTAssertEqual(manager.items.count, 1)
        XCTAssertTrue(manager.items.first === original)
        XCTAssertEqual(manager.selectedItemID, original.id)
    }

    private func makeTemporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TiloReplacementTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func makeVideo(_ ffmpeg: URL, at output: URL, color: String) -> Bool {
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "color=c=\(color):s=160x90:r=24",
            "-t", "0.4", "-an", "-c:v", "libx264", "-pix_fmt", "yuv420p",
            output.path,
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return condition()
    }
}
