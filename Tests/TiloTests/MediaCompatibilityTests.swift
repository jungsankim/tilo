import AVFoundation
import XCTest
@testable import Tilo

final class MediaCompatibilityTests: XCTestCase {
    func testVP9WebMIsConvertedToPlayableMP4() async throws {
        guard let ffmpeg = Remuxer.ffmpegURL else {
            throw XCTSkip("ffmpeg is not installed")
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TiloCompatibilityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let source = folder.appendingPathComponent("vp9-sample.webm")
        let generated = run(
            ffmpeg,
            arguments: [
                "-hide_banner", "-loglevel", "error", "-y",
                "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24",
                "-t", "0.5", "-an", "-c:v", "libvpx-vp9",
                "-deadline", "realtime", source.path,
            ]
        )
        guard generated else {
            throw XCTSkip("This ffmpeg build cannot generate a VP9 fixture")
        }

        let result = await Remuxer.makePlayableCopy(source, forceTranscode: true)
        switch result {
        case .success(let output):
            defer { try? FileManager.default.removeItem(at: output) }
            XCTAssertEqual(output.pathExtension.lowercased(), "mp4")
            let playable = await Remuxer.isNativelyPlayable(output)
            XCTAssertTrue(playable)
        case .failure(let failure):
            XCTFail("VP9 compatibility conversion failed: \(failure.videoCodec ?? "unknown codec")")
        }
    }

    func testAdditionalVideoExtensionsAreRecognized() {
        for ext in ["wmv", "flv", "m2ts", "vob", "ogv", "mxf"] {
            XCTAssertTrue(PlayerManager.isVideoFile(URL(fileURLWithPath: "/tmp/sample.\(ext)")))
        }
    }

    func testNativePlaybackAlwaysWinsEvenForLegacyContainers() {
        XCTAssertEqual(
            PlayerManager.importStrategy(
                nativePlayable: true,
                compatibilityToolAvailable: true
            ),
            .direct
        )
        XCTAssertEqual(
            PlayerManager.importStrategy(
                nativePlayable: false,
                compatibilityToolAvailable: true
            ),
            .compatibilityProcessing
        )
        XCTAssertEqual(
            PlayerManager.importStrategy(
                nativePlayable: false,
                compatibilityToolAvailable: false
            ),
            .unsupported
        )
    }

    func testExperimentalDirectPlaybackPrefersLibMPVBeforeConversion() {
        XCTAssertEqual(
            PlayerManager.importStrategy(
                nativePlayable: false,
                directPlaybackEnabled: true,
                libmpvAvailable: true,
                compatibilityToolAvailable: true
            ),
            .libmpv
        )
        XCTAssertEqual(
            PlayerManager.importStrategy(
                nativePlayable: false,
                directPlaybackEnabled: true,
                libmpvAvailable: false,
                compatibilityToolAvailable: true
            ),
            .compatibilityProcessing
        )
        XCTAssertEqual(
            PlayerManager.importStrategy(
                nativePlayable: true,
                directPlaybackEnabled: true,
                libmpvAvailable: true,
                compatibilityToolAvailable: true
            ),
            .direct
        )
    }

    func testLibMPVProbeOpensVP9WebMWithoutConversion() async throws {
        guard let ffmpeg = Remuxer.ffmpegURL, MPVPlaybackEngine.isAvailable else {
            throw XCTSkip("ffmpeg or libmpv is not installed")
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TiloMPVProbeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let source = folder.appendingPathComponent("direct-vp9.webm")
        guard run(
            ffmpeg,
            arguments: [
                "-hide_banner", "-loglevel", "error", "-y",
                "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24",
                "-t", "0.5", "-an", "-c:v", "libvpx-vp9",
                "-deadline", "realtime", source.path,
            ]
        ) else {
            throw XCTSkip("This ffmpeg build cannot generate a VP9 fixture")
        }

        let mpvCanOpen = await MPVPlaybackEngine.canOpen(source)
        let avFoundationCanOpen = await Remuxer.isNativelyPlayable(source)
        XCTAssertTrue(mpvCanOpen)
        XCTAssertFalse(avFoundationCanOpen)
    }

    func testTextSubtitleCodecAllowlistExcludesBitmapFormats() {
        for codec in ["ass", "subrip", "webvtt", "mov_text"] {
            XCTAssertTrue(Remuxer.canPreserveSubtitleCodec(codec))
        }
        for codec in ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "xsub"] {
            XCTAssertFalse(Remuxer.canPreserveSubtitleCodec(codec))
        }
    }

    func testRemuxPreservesMultipleAudioAndTextSubtitleTracks() async throws {
        guard let ffmpeg = Remuxer.ffmpegURL else {
            throw XCTSkip("ffmpeg is not installed")
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TiloMultiTrackTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let subtitle = folder.appendingPathComponent("captions.srt")
        try Data("1\n00:00:00,000 --> 00:00:00,600\nHello\n".utf8).write(to: subtitle)
        let source = folder.appendingPathComponent("multi-track.mkv")
        let sidecar = folder.appendingPathComponent("multi-track.srt")
        try Data("1\n00:00:00,000 --> 00:00:00,600\nSidecar\n".utf8).write(to: sidecar)
        let generated = run(ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
            "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000",
            "-f", "srt", "-i", subtitle.path,
            "-t", "0.7",
            "-map", "0:v:0", "-map", "1:a:0", "-map", "2:a:0", "-map", "3:s:0",
            "-c:v", "mpeg4", "-q:v", "4",
            "-c:a:0", "aac", "-c:a:1", "pcm_s16le", "-c:s", "srt",
            "-metadata:s:a:0", "language=eng", "-metadata:s:a:1", "language=kor",
            "-metadata:s:s:0", "language=eng",
            source.path,
        ])
        guard generated else {
            throw XCTSkip("This ffmpeg build cannot generate a multi-track fixture")
        }

        let automatic = await Remuxer.makePlayableCopy(source)
        let forced = await Remuxer.makePlayableCopy(source, forceTranscode: true)
        guard case .success(let output) = automatic,
              case .success(let forcedOutput) = forced
        else { return XCTFail("Multi-track compatibility conversion failed") }
        defer {
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: forcedOutput)
        }

        XCTAssertNotEqual(output, forcedOutput, "Forced recovery must not reuse the remux cache")
        let playable = await Remuxer.isNativelyPlayable(output)
        XCTAssertTrue(playable)
        let asset = AVURLAsset(url: output)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audible = try await asset.loadMediaSelectionGroup(for: .audible)
        let legible = try await asset.loadMediaSelectionGroup(for: .legible)
        XCTAssertEqual(audioTracks.count, 2)
        XCTAssertEqual(audible?.options.count, 2)
        XCTAssertGreaterThanOrEqual(legible?.options.count ?? 0, 1)

        let firstItem = await MainActor.run { VideoItem(url: output, sourceURL: source) }
        let firstLoaded = await waitForMediaOptions(firstItem)
        XCTAssertTrue(firstLoaded)
        let readyCallback = expectation(description: "late ready callback")
        let durationCallback = expectation(description: "late duration callback")
        await MainActor.run {
            firstItem.readyChanged = {
                readyCallback.fulfill()
            }
            firstItem.durationChanged = {
                durationCallback.fulfill()
            }
        }
        await fulfillment(of: [readyCallback, durationCallback], timeout: 1)
        let reference = await MainActor.run { () -> ProjectTrackReference? in
            XCTAssertEqual(firstItem.audioTrackOptions.count, 2)
            XCTAssertGreaterThanOrEqual(firstItem.subtitleTrackOptions.count, 1)
            firstItem.selectedAudioTrackIndex = 1
            return firstItem.selectedAudioTrackReference
        }
        XCTAssertNotNil(reference?.propertyListData)
        let automaticSubtitle = await waitForSubtitle(firstItem)
        XCTAssertEqual(automaticSubtitle, "Sidecar")
        await MainActor.run { firstItem.subtitleTrackSelection = .embedded(0) }
        let embeddedSubtitle = await waitForSubtitle(firstItem, expected: "Hello")
        XCTAssertEqual(embeddedSubtitle, "Hello")

        let restoredItem = await MainActor.run {
            VideoItem(
                url: output,
                sourceURL: source,
                audioTrackIndex: 0,
                audioTrackReference: reference
            )
        }
        let restoredLoaded = await waitForMediaOptions(restoredItem)
        XCTAssertTrue(restoredLoaded)
        let restoredIndex = await MainActor.run { restoredItem.selectedAudioTrackIndex }
        XCTAssertEqual(restoredIndex, 1)
    }

    private func waitForMediaOptions(_ item: VideoItem) async -> Bool {
        for _ in 0..<100 {
            if await MainActor.run(body: {
                item.mediaOptionsLoaded && item.mediaReady && item.durationSeconds > 0
            }) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    private func waitForSubtitle(
        _ item: VideoItem,
        expected: String? = nil
    ) async -> String? {
        for _ in 0..<100 {
            let text = await MainActor.run { item.currentSubtitle }
            if let expected {
                if text == expected { return text }
            } else if text != nil {
                return text
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await MainActor.run { item.currentSubtitle }
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
