import Foundation
import CryptoKit
import AVFoundation

/// 여러 고용량 파일이 동시에 변환되어 CPU·디스크를 포화시키지 않도록 제한한다.
private actor ConversionLimiter {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { permits = max(1, limit) }

    func acquire() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            permits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// MKV/WebM처럼 macOS가 컨테이너를 지원하지 않는 파일을, 설치된 ffmpeg로
/// 재인코딩 없이 MP4로 다시 포장한다. 결과는 캐시되어 같은 파일은 즉시 반환.
enum Remuxer {
    private static let limiter = ConversionLimiter(limit: 2)
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

    /// 직접 재생할 수 없는 파일을 먼저 무손실 리먹스하고, 그것으로 해결되지
    /// 않으면 H.264/AAC로 변환해 AVFoundation이 읽을 수 있는 MP4를 만든다.
    static func makePlayableCopy(
        _ source: URL,
        forceTranscode: Bool = false,
        onProgress: ((Double) -> Void)? = nil
    ) async -> Result<URL, RemuxFailure> {
        guard let ffmpeg = ffmpegURL else {
            return .failure(RemuxFailure(videoCodec: nil, logURL: nil))
        }
        await limiter.acquire()
        let result = await performConversion(
            source,
            ffmpeg: ffmpeg,
            forceTranscode: forceTranscode,
            onProgress: onProgress
        )
        await limiter.release()
        return result
    }

    /// 기존 호출부·캐시 사용자와의 소스 호환을 위한 별칭.
    static func remux(
        _ source: URL,
        onProgress: ((Double) -> Void)? = nil
    ) async -> Result<URL, RemuxFailure> {
        await makePlayableCopy(source, onProgress: onProgress)
    }

    private static func performConversion(
        _ source: URL,
        ffmpeg: URL,
        forceTranscode: Bool,
        onProgress: ((Double) -> Void)?
    ) async -> Result<URL, RemuxFailure> {
        let output = cacheURL(for: source, forceTranscode: forceTranscode)
        if FileManager.default.fileExists(atPath: output.path) {
            // 캐시본도 재생 가능해야 신뢰한다 (이전 버전의 잘못된 변환 대비)
            if await isNativelyPlayable(output) { return .success(output) }
            try? FileManager.default.removeItem(at: output)
        }
        try? FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // 코덱을 미리 확인해서 첫 시도에 맞는 설정을 쓴다.
        // HEVC는 Apple 엔진이 hvc1 태그만 재생할 수 있고(ffmpeg 기본은 hev1),
        // MP4가 못 담는 오디오(Vorbis/Opus/DTS 등)는 해당 트랙만 AAC로 변환한다.
        let info = await probe(source)

        var attempts: [(name: String, arguments: [String])] = []
        let copyableVideo: Set<String> = ["h264", "hevc", "mpeg4", "prores", "mjpeg", "dvvideo"]
        if !forceTranscode, info.videoCodec.map(copyableVideo.contains) ?? true {
            var primary = ["-c:v", "copy"]
            if info.videoCodec == "hevc" { primary += ["-tag:v", "hvc1"] }
            primary += audioArguments(for: info.audioStreams, copyCompatible: true)
            attempts.append(("stream copy", primary))

            let copyFallback = ["-c:v", "copy"]
                + audioArguments(for: info.audioStreams, copyCompatible: false)
            if copyFallback != primary { attempts.append(("stream copy + AAC", copyFallback)) }
        }

        // 컨테이너 변경만으로 해결되지 않는 VP8/VP9/AV1/WMV/MPEG 계열도
        // Apple 하드웨어 인코더를 이용해 호환 H.264 프록시로 변환한다.
        let targetBitrate = videoBitrate(width: info.width, height: info.height)
        attempts.append((
            "H.264 VideoToolbox",
            [
                "-c:v", "h264_videotoolbox", "-allow_sw", "1",
                "-profile:v", "high", "-b:v", targetBitrate,
                "-pix_fmt", "yuv420p",
            ]
                + audioArguments(for: info.audioStreams, copyCompatible: false)
        ))
        attempts.append((
            "H.264 software",
            [
                "-c:v", "libx264", "-preset", "veryfast", "-crf", "19",
                "-pix_fmt", "yuv420p",
            ]
                + audioArguments(for: info.audioStreams, copyCompatible: false)
        ))

        let stderrLog = LineBuffer()
        let temp = output.deletingPathExtension().appendingPathExtension("partial.mp4")
        for attempt in attempts {
            try? FileManager.default.removeItem(at: temp)
            onProgress?(0)
            // 오디오 순서를 유지하고 MP4로 변환 가능한 텍스트 자막만 함께 담는다.
            var mappings = ["-map", "0:v:0"]
            if info.audioStreams.isEmpty {
                mappings += ["-map", "0:a?"]
            } else {
                for stream in info.audioStreams { mappings += ["-map", "0:\(stream.index)?"] }
            }
            for stream in info.subtitleStreams { mappings += ["-map", "0:\(stream.index)?"] }

            var subtitleArguments = ["-sn"]
            if !info.subtitleStreams.isEmpty {
                subtitleArguments = ["-c:s", "mov_text"]
            }
            let arguments = [
                "-hide_banner", "-loglevel", "warning", "-nostdin", "-y",
                "-i", source.path,
            ]
                + mappings
                + attempt.arguments
                + subtitleArguments
                + [
                    "-map_metadata", "0", "-map_chapters", "0",
                    "-movflags", "+faststart", "-progress", "pipe:1", "-nostats", temp.path,
                ]
            stderrLog.append("\n=== \(attempt.name): ffmpeg \(attempt.arguments.joined(separator: " ")) ===\n")
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
                if await isNativelyPlayable(temp) {
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

    private static func videoBitrate(width: Int?, height: Int?) -> String {
        let pixels = (width ?? 1920) * (height ?? 1080)
        switch pixels {
        case ..<1_000_000: return "3M"
        case ..<3_000_000: return "7M"
        case ..<9_000_000: return "16M"
        default: return "28M"
        }
    }

    private static func audioArguments(
        for streams: [ProbeInfo.Stream],
        copyCompatible: Bool
    ) -> [String] {
        // ffprobe가 없거나 실패한 경우에도 선택적 오디오 전체를 안전한 AAC로 만든다.
        guard !streams.isEmpty else {
            return copyCompatible
                ? ["-c:a", "copy"]
                : ["-c:a", "aac", "-b:a", "192k"]
        }
        var result: [String] = []
        for (outputIndex, stream) in streams.enumerated() {
            let specifier = "a:\(outputIndex)"
            if copyCompatible, stream.codec.map(mp4CopyableAudio.contains) == true {
                result += ["-c:\(specifier)", "copy"]
            } else {
                let bitrate: String
                switch stream.channels ?? 2 {
                case ...1: bitrate = "128k"
                case 2: bitrate = "192k"
                case 3...6: bitrate = "384k"
                default: bitrate = "512k"
                }
                result += ["-c:\(specifier)", "aac", "-b:\(specifier)", bitrate]
            }
        }
        return result
    }

    private static func writeLog(_ text: String, source: URL) -> URL? {
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Tilo")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let logURL = logsDir.appendingPathComponent("remux.log")
        let content = "원본: \(source.path)\n\(text)"
        return (try? content.write(to: logURL, atomically: true, encoding: .utf8)) != nil ? logURL : nil
    }

    static func isNativelyPlayable(_ url: URL) async -> Bool {
        (try? await AVURLAsset(url: url).load(.isPlayable)) ?? false
    }

    // MARK: - ffprobe

    private struct ProbeInfo {
        struct Stream {
            let index: Int
            let codec: String?
            let channels: Int?
        }

        var videoCodec: String?
        var audioStreams: [Stream] = []
        var subtitleStreams: [Stream] = []
        var duration: Double?
        var width: Int?
        var height: Int?
    }

    private struct ProbeDocument: Decodable {
        struct Stream: Decodable {
            let index: Int?
            let codec_type: String?
            let codec_name: String?
            let width: Int?
            let height: Int?
            let channels: Int?
        }
        struct Format: Decodable { let duration: String? }

        let streams: [Stream]
        let format: Format?
    }

    private static func probe(_ source: URL) async -> ProbeInfo {
        guard let ffprobe = ffprobeURL else { return ProbeInfo() }
        guard let output = await runCapture(ffprobe, [
            "-v", "error",
            "-show_entries", "stream=index,codec_type,codec_name,width,height,channels:format=duration",
            "-of", "json", source.path,
        ]),
        let data = output.data(using: .utf8),
        let document = try? JSONDecoder().decode(ProbeDocument.self, from: data)
        else { return ProbeInfo() }
        let video = document.streams.first { $0.codec_type == "video" }
        let audio = document.streams.filter { $0.codec_type == "audio" }.compactMap { stream in
            stream.index.map { ProbeInfo.Stream(index: $0, codec: stream.codec_name, channels: stream.channels) }
        }
        let subtitles = document.streams.filter {
            $0.codec_type == "subtitle" && canPreserveSubtitleCodec($0.codec_name)
        }.compactMap { stream in
            stream.index.map { ProbeInfo.Stream(index: $0, codec: stream.codec_name, channels: nil) }
        }
        return ProbeInfo(
            videoCodec: video?.codec_name,
            audioStreams: audio,
            subtitleStreams: subtitles,
            duration: document.format?.duration.flatMap(Double.init),
            width: video?.width,
            height: video?.height
        )
    }

    /// MP4의 mov_text로 안전하게 옮길 수 있는 텍스트 기반 자막만 허용한다.
    static func canPreserveSubtitleCodec(_ codec: String?) -> Bool {
        guard let codec = codec?.lowercased() else { return false }
        return [
            "ass", "ssa", "subrip", "srt", "webvtt", "mov_text", "text",
            "microdvd", "sami", "realtext", "jacosub", "mpl2", "vplayer",
            "subviewer", "subviewer1", "pjs", "stl", "eia_608", "ttml",
        ].contains(codec)
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
    private static func cacheURL(for source: URL, forceTranscode: Bool) -> URL {
        let attributes = try? FileManager.default.attributesOfItem(atPath: source.path)
        let size = (attributes?[.size] as? Int) ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let profile = forceTranscode ? "forced-h264" : "auto"
        let key = "v4|profile=\(profile)|\(source.path)|\(size)|\(modified.bitPattern)"
        let digest = Insecure.MD5.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return cacheDirectory.appendingPathComponent("\(digest).mp4")
    }
}
