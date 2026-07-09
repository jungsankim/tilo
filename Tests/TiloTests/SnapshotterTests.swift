import XCTest
@testable import Tilo

final class SnapshotterTests: XCTestCase {
    func testExtractsFrameFromVP9WebMWhenAVFoundationCannotReadIt() async throws {
        guard let ffmpeg = Remuxer.ffmpegURL else {
            throw XCTSkip("ffmpeg is not installed")
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tilo Snapshot Tests; (UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let source = folder.appendingPathComponent("VP9 sample; direct.webm")
        guard run(ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "color=c=red:s=96x54:r=24",
            "-t", "0.5", "-an", "-c:v", "libvpx-vp9",
            "-deadline", "realtime", source.path,
        ]) else {
            throw XCTSkip("This ffmpeg build cannot generate a VP9 fixture")
        }

        let nativePlayable = await Remuxer.isNativelyPlayable(source)
        XCTAssertFalse(nativePlayable)
        let image = await Snapshotter.frame(
            url: source,
            timeSeconds: 0.2,
            prefersFFmpeg: true
        )
        XCTAssertEqual(image?.width, 96)
        XCTAssertEqual(image?.height, 54)
        XCTAssertNotNil(image?.dataProvider?.data)
    }

    @discardableResult
    private func run(_ executable: URL, arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
