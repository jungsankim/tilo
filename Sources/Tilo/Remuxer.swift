import Foundation
import CryptoKit
import AVFoundation

/// MKV/WebM처럼 macOS가 컨테이너를 지원하지 않는 파일을, 설치된 ffmpeg로
/// 재인코딩 없이 MP4로 다시 포장한다. 결과는 캐시되어 같은 파일은 즉시 반환.
enum Remuxer {
    static let ffmpegURL: URL? = {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ]
        return candidates
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }()

    static let ffprobeURL: URL? = {
        guard let ffmpeg = ffmpegURL else { return nil }
        let ffprobe = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        return FileManager.default.isExecutableFile(atPath: ffprobe.path) ? ffprobe : nil
    }()

    struct RemuxFailure: Error {
        let videoCodec: String?
        let logURL: URL?
    }

    /// 프로세스 stderr를 모으는 스레드 안전 버퍼
    private final class LineBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = ""
        func append(_ text: String) {
            lock.lock()
            storage += text
            lock.unlock()
        }
        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    /// MP4 컨테이너가 그대로 담을 수 있고 Apple 엔진이 재생하는 오디오 코덱
    private static let mp4CopyableAudio: Set<String> = ["aac", "mp3", "ac3", "eac3", "alac"]

    static func remux(_ source: URL, onProgress: ((Double) -> Void)? = nil) async -> Result<URL, RemuxFailure> {
        guard let ffmpeg = ffmpegURL else {
            return .failure(RemuxFailure(videoCodec: nil, logURL: nil))
        }
        let output = cacheURL(for: source)
        if FileManager.default.fileExists(atPath: output.path) {
            // 캐시본도 재생 가능해야 신뢰한다 (이전 버전의 잘못된 변환 대비)
            if await isPlayable(output) { return .success(output) }
            try? FileManager.default.removeItem(at: output)
        }
        try? FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // 코덱을 미리 확인해서 첫 시도에 맞는 설정을 쓴다.
        // HEVC는 Apple 엔진이 hvc1 태그만 재생할 수 있고(ffmpeg 기본은 hev1),
        // MP4가 못 담는 오디오(Vorbis/Opus/DTS 등)는 AAC로만 변환한다.
        let info = await probe(source)

        // VP8/VP9는 컨테이너를 바꿔도 macOS가 재생하지 못한다 (재인코딩 필요)
        if let codec = info.videoCodec, ["vp8", "vp9"].contains(codec) {
            return .failure(RemuxFailure(videoCodec: codec, logURL: nil))
        }

        var primary = ["-c:v", "copy"]
        if info.videoCodec == "hevc" { primary += ["-tag:v", "hvc1"] }
        primary += mp4CopyableAudio.contains(info.audioCodec ?? "aac")
            ? ["-c:a", "copy"]
            : ["-c:a", "aac"]

        var attempts = [primary]
        let fallbacks: [[String]] = [
            ["-c:v", "copy", "-c:a", "copy"],
            ["-c:v", "copy", "-tag:v", "hvc1", "-c:a", "copy"],
            ["-c:v", "copy", "-c:a", "aac"],
            ["-c:v", "copy", "-tag:v", "hvc1", "-c:a", "aac"],
        ]
        for fallback in fallbacks where !attempts.contains(fallback) {
            attempts.append(fallback)
        }

        let stderrLog = LineBuffer()
        let temp = output.deletingPathExtension().appendingPathExtension("partial.mp4")
        for codecArgs in attempts {
            try? FileManager.default.removeItem(at: temp)
            // 프로브한 스트림(첫 영상·첫 오디오)과 실제 매핑을 일치시킨다
            let arguments = ["-nostdin", "-y", "-i", source.path, "-map", "0:v:0", "-map", "0:a:0?"]
                + codecArgs
                + ["-sn", "-progress", "pipe:1", "-nostats", temp.path]
            stderrLog.append("\n=== ffmpeg \(codecArgs.joined(separator: " ")) ===\n")
            let succeeded = await run(ffmpeg, arguments, stderrBuffer: stderrLog) { line in
                guard let duration = info.duration, duration > 0 else { return }
                // out_time_us / out_time_ms 모두 마이크로초 단위 (ffmpeg 특성)
                for prefix in ["out_time_us=", "out_time_ms="] where line.hasPrefix(prefix) {
                    if let us = Double(line.dropFirst(prefix.count)) {
                        onProgress?(min(us / 1_000_000 / duration, 1))
                    }
                    return
                }
            }
            // 변환이 끝나도 Apple 엔진에서 실제로 재생되는지까지 확인한다
            if succeeded, FileManager.default.fileExists(atPath: temp.path) {
                if await isPlayable(temp) {
                    do {
                        try FileManager.default.moveItem(at: temp, to: output)
                        return .success(output)
                    } catch {
                        break
                    }
                }
                stderrLog.append("[Tilo] 변환은 성공했지만 Apple 엔진이 재생 불가 판정\n")
            }
        }
        try? FileManager.default.removeItem(at: temp)
        return .failure(RemuxFailure(videoCodec: info.videoCodec, logURL: writeLog(stderrLog.text, source: source)))
    }

    private static func writeLog(_ text: String, source: URL) -> URL? {
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Tilo")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let logURL = logsDir.appendingPathComponent("remux.log")
        let content = "원본: \(source.path)\n\(text)"
        return (try? content.write(to: logURL, atomically: true, encoding: .utf8)) != nil ? logURL : nil
    }

    private static func isPlayable(_ url: URL) async -> Bool {
        (try? await AVURLAsset(url: url).load(.isPlayable)) ?? false
    }

    // MARK: - ffprobe

    private struct ProbeInfo {
        var videoCodec: String?
        var audioCodec: String?
        var duration: Double?
    }

    private static func probe(_ source: URL) async -> ProbeInfo {
        guard let ffprobe = ffprobeURL else { return ProbeInfo() }
        func entry(_ args: [String]) async -> String? {
            let output = await runCapture(ffprobe, ["-v", "error"] + args + ["-of", "default=nw=1:nk=1", source.path])
            let trimmed = output?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }
        let video = await entry(["-select_streams", "v:0", "-show_entries", "stream=codec_name"])
        let audio = await entry(["-select_streams", "a:0", "-show_entries", "stream=codec_name"])
        let duration = await entry(["-show_entries", "format=duration"])
        return ProbeInfo(
            videoCodec: video,
            audioCodec: audio,
            duration: duration.flatMap(Double.init)
        )
    }

    // MARK: - 프로세스 실행

    private static func run(
        _ tool: URL,
        _ arguments: [String],
        stderrBuffer: LineBuffer? = nil,
        onLine: ((String) -> Void)? = nil
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = tool
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice

            let errorPipe = Pipe()
            if let stderrBuffer {
                process.standardError = errorPipe
                errorPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                    stderrBuffer.append(text)
                }
            } else {
                process.standardError = FileHandle.nullDevice
            }

            let pipe = Pipe()
            if let onLine {
                process.standardOutput = pipe
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                    for line in text.split(separator: "\n") {
                        onLine(String(line))
                    }
                }
            } else {
                process.standardOutput = FileHandle.nullDevice
            }

            process.terminationHandler = { finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: finished.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: false)
            }
        }
    }

    private static func runCapture(_ tool: URL, _ arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = tool
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.terminationHandler = { finished in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(
                    returning: finished.terminationStatus == 0
                        ? String(data: data, encoding: .utf8)
                        : nil
                )
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tilo/remux")
    }

    /// 변환 캐시 총 크기 (바이트)
    static func cacheSize() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return files.reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    static func clearCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    /// 경로 + 크기 + 수정 시각 기반 캐시 키 — 원본이 바뀌면 다시 변환된다
    private static func cacheURL(for source: URL) -> URL {
        let attributes = try? FileManager.default.attributesOfItem(atPath: source.path)
        let size = (attributes?[.size] as? Int) ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "v2|\(source.path)|\(size)|\(Int(modified))"
        let digest = Insecure.MD5.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return cacheDirectory.appendingPathComponent("\(digest).mp4")
    }
}
