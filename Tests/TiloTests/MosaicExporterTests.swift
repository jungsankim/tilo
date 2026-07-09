import AVFoundation
import XCTest
@testable import Tilo

final class MosaicExporterTests: XCTestCase {
    func testFilterGraphContainsLayoutTimingAndAudioMix() {
        let request = MosaicExporter.Request(
            tiles: [
                MosaicExporter.Tile(
                    url: URL(fileURLWithPath: "/tmp/one.mp4"),
                    rect: CGRect(x: 0, y: 0, width: 320, height: 360),
                    duration: 2,
                    timeOffset: 0.2,
                    rotationQuarters: 1,
                    zoomScale: 1.5,
                    panOffset: CGSize(width: 0.1, height: 0),
                    includeAudio: true,
                    audioVolume: 0.7,
                    audioStreamIndex: 1
                ),
                MosaicExporter.Tile(
                    url: URL(fileURLWithPath: "/tmp/two.mp4"),
                    rect: CGRect(x: 320, y: 0, width: 320, height: 360),
                    duration: 1,
                    timeOffset: -0.1,
                    rotationQuarters: 0,
                    zoomScale: 1,
                    panOffset: .zero,
                    includeAudio: true,
                    audioVolume: 0.5
                ),
            ],
            canvasSize: CGSize(width: 640, height: 360),
            outputSize: CGSize(width: 640, height: 360),
            duration: 2,
            framesPerSecond: 30,
            fill: true,
            relativeTimeline: true,
            loopEnabled: false,
            outputURL: URL(fileURLWithPath: "/tmp/out.mp4")
        )

        let filter = MosaicExporter.makeFilterGraph(request)

        XCTAssertTrue(filter.graph.contains("overlay=x=320:y=0"))
        XCTAssertTrue(filter.graph.contains("transpose=clock"))
        XCTAssertTrue(filter.graph.contains("atempo=0.500000"))
        XCTAssertTrue(filter.graph.contains("amix=inputs=2"))
        XCTAssertTrue(filter.graph.contains("[0:a:1]"))
        XCTAssertTrue(filter.hasAudio)
    }

    func testExportsTwoVideoMosaicWithMixedAudio() async throws {
        guard let ffmpeg = Remuxer.ffmpegURL else {
            throw XCTSkip("ffmpeg is not installed")
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TiloMosaicExporterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let first = folder.appendingPathComponent("first.mp4")
        let second = folder.appendingPathComponent("second.mp4")
        guard makeFixture(ffmpeg, output: first, color: "red", frequency: 440),
              makeFixture(ffmpeg, output: second, color: "blue", frequency: 660)
        else { throw XCTSkip("This ffmpeg build cannot generate the fixtures") }

        let output = folder.appendingPathComponent("mosaic.mp4")
        let request = MosaicExporter.Request(
            tiles: [
                MosaicExporter.Tile(
                    url: first,
                    rect: CGRect(x: 0, y: 0, width: 320, height: 360),
                    duration: 1,
                    timeOffset: 0,
                    rotationQuarters: 0,
                    zoomScale: 1,
                    panOffset: .zero,
                    includeAudio: true,
                    audioVolume: 0.5
                ),
                MosaicExporter.Tile(
                    url: second,
                    rect: CGRect(x: 320, y: 0, width: 320, height: 360),
                    duration: 1,
                    timeOffset: 0,
                    rotationQuarters: 0,
                    zoomScale: 1,
                    panOffset: .zero,
                    includeAudio: true,
                    audioVolume: 0.5
                ),
            ],
            canvasSize: CGSize(width: 640, height: 360),
            outputSize: CGSize(width: 640, height: 360),
            duration: 1,
            framesPerSecond: 24,
            fill: true,
            relativeTimeline: false,
            loopEnabled: false,
            outputURL: output
        )

        let result = await MosaicExporter.export(request, session: MosaicExporter.Session())
        guard case .success(let url) = result else {
            return XCTFail("Mosaic export failed")
        }
        let playable = await Remuxer.isNativelyPlayable(url)
        XCTAssertTrue(playable)

        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first
        let size = try await track?.load(.naturalSize)
        XCTAssertEqual(Int(size?.width ?? 0), 640)
        XCTAssertEqual(Int(size?.height ?? 0), 360)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertFalse(audioTracks.isEmpty)
    }

    private func makeFixture(
        _ ffmpeg: URL,
        output: URL,
        color: String,
        frequency: Int
    ) -> Bool {
        run(ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "color=c=\(color):s=320x360:r=24",
            "-f", "lavfi", "-i", "sine=frequency=\(frequency):sample_rate=48000",
            "-t", "1", "-c:v", "mpeg4", "-q:v", "4", "-c:a", "aac", output.path,
        ])
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
