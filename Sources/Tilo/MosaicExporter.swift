import AVFoundation
import CoreGraphics
import Foundation

/// 현재 Tilo 배치를 하나의 H.264/AAC MP4로 렌더링한다.
enum MosaicExporter {
    struct Tile {
        let url: URL
        let rect: CGRect
        let duration: Double
        let timeOffset: Double
        let rotationQuarters: Int
        let zoomScale: CGFloat
        let panOffset: CGSize
        let includeAudio: Bool
        let audioVolume: Double
        var audioStreamIndex: Int = 0
    }

    struct Request {
        let tiles: [Tile]
        let canvasSize: CGSize
        let outputSize: CGSize
        let duration: Double
        let framesPerSecond: Int
        let fill: Bool
        let relativeTimeline: Bool
        let loopEnabled: Bool
        let outputURL: URL
    }

    enum ExportFailure: LocalizedError {
        case ffmpegMissing
        case invalidRequest
        case cancelled
        case encodingFailed(logURL: URL?)
        case fileWriteFailed

        var errorDescription: String? {
            switch self {
            case .ffmpegMissing:
                return String(localized: "영상 내보내기에는 ffmpeg가 필요합니다")
            case .invalidRequest:
                return String(localized: "내보낼 영상이나 레이아웃 정보가 없습니다")
            case .cancelled:
                return String(localized: "영상 내보내기가 취소되었습니다")
            case .encodingFailed:
                return String(localized: "모자이크 영상을 만들 수 없습니다")
            case .fileWriteFailed:
                return String(localized: "내보낸 파일을 저장할 수 없습니다")
            }
        }
    }

    /// 실행 중인 ffmpeg를 UI에서 안전하게 취소하기 위한 세션.
    final class Session: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        fileprivate func attach(_ process: Process) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else { return false }
            self.process = process
            return true
        }

        fileprivate func detach(_ process: Process) {
            lock.lock()
            if self.process === process { self.process = nil }
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let running = process
            lock.unlock()
            if running?.isRunning == true { running?.terminate() }
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    private final class TextBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = ""

        func append(_ value: String) {
            lock.lock()
            storage += value
            lock.unlock()
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private final class ProgressLines: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = ""

        func ingest(_ data: Data) -> [String] {
            guard let chunk = String(data: data, encoding: .utf8) else { return [] }
            lock.lock()
            pending += chunk
            let parts = pending.components(separatedBy: "\n")
            pending = parts.last ?? ""
            lock.unlock()
            return Array(parts.dropLast())
        }
    }

    static func export(
        _ request: Request,
        session: Session,
        onProgress: ((Double) -> Void)? = nil
    ) async -> Result<URL, ExportFailure> {
        guard let ffmpeg = Remuxer.ffmpegURL else { return .failure(.ffmpegMissing) }
        guard !request.tiles.isEmpty,
              request.canvasSize.width > 0, request.canvasSize.height > 0,
              request.outputSize.width >= 2, request.outputSize.height >= 2,
              request.duration.isFinite, request.duration > 0
        else { return .failure(.invalidRequest) }

        let filter = makeFilterGraph(request)
        let temp = request.outputURL.deletingLastPathComponent().appendingPathComponent(
            ".\(request.outputURL.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).partial.mp4"
        )
        let stderr = TextBuffer()
        let bitrate = outputBitrate(for: request.outputSize)
        let encoders: [[String]] = [
            [
                "-c:v", "h264_videotoolbox", "-allow_sw", "1",
                "-profile:v", "high", "-b:v", bitrate, "-pix_fmt", "yuv420p",
            ],
            [
                "-c:v", "libx264", "-preset", "medium", "-crf", "19",
                "-pix_fmt", "yuv420p",
            ],
        ]

        for encoder in encoders {
            if session.isCancelled { return .failure(.cancelled) }
            try? FileManager.default.removeItem(at: temp)
            onProgress?(0)
            let arguments = commandArguments(
                request: request,
                filter: filter.graph,
                hasAudio: filter.hasAudio,
                encoder: encoder,
                output: temp
            )
            let succeeded = await run(
                ffmpeg,
                arguments: arguments,
                session: session,
                stderr: stderr,
                duration: request.duration,
                onProgress: onProgress
            )
            if session.isCancelled {
                try? FileManager.default.removeItem(at: temp)
                return .failure(.cancelled)
            }
            guard succeeded, FileManager.default.fileExists(atPath: temp.path),
                  await Remuxer.isNativelyPlayable(temp)
            else { continue }

            do {
                if FileManager.default.fileExists(atPath: request.outputURL.path) {
                    try FileManager.default.removeItem(at: request.outputURL)
                }
                try FileManager.default.moveItem(at: temp, to: request.outputURL)
                onProgress?(1)
                return .success(request.outputURL)
            } catch {
                try? FileManager.default.removeItem(at: temp)
                return .failure(.fileWriteFailed)
            }
        }

        try? FileManager.default.removeItem(at: temp)
        return .failure(.encodingFailed(logURL: writeLog(stderr.text)))
    }

    /// 테스트에서 필터 구성을 검증할 수 있도록 모듈 내부에 공개한다.
    static func makeFilterGraph(_ request: Request) -> (graph: String, hasAudio: Bool) {
        let outputWidth = max(2, Int(request.outputSize.width.rounded()))
        let outputHeight = max(2, Int(request.outputSize.height.rounded()))
        let duration = number(request.duration)
        var filters = [
            "color=c=black:s=\(outputWidth)x\(outputHeight):r=\(request.framesPerSecond):d=\(duration)[base0]"
        ]

        for (index, tile) in request.tiles.enumerated() {
            let pixelRect = outputRect(
                tile.rect,
                canvas: request.canvasSize,
                output: request.outputSize
            )
            let factor = request.relativeTimeline && tile.duration > 0
                ? request.duration / tile.duration
                : 1
            let trimStart = max(0, tile.timeOffset)
            let delay = tile.timeOffset < 0 ? -tile.timeOffset * factor : 0
            var chain: [String] = []
            if trimStart > 0 { chain.append("trim=start=\(number(trimStart))") }
            chain.append(
                "setpts=(PTS-STARTPTS)*\(number(factor))+\(number(delay))/TB"
            )
            chain.append("fps=\(request.framesPerSecond)")

            let quarters = ((tile.rotationQuarters % 4) + 4) % 4
            for _ in 0..<quarters { chain.append("transpose=clock") }

            if request.fill {
                chain.append(
                    "scale=\(pixelRect.width):\(pixelRect.height):force_original_aspect_ratio=increase:flags=lanczos"
                )
                chain.append("crop=\(pixelRect.width):\(pixelRect.height)")
            } else {
                chain.append(
                    "scale=\(pixelRect.width):\(pixelRect.height):force_original_aspect_ratio=decrease:flags=lanczos"
                )
                chain.append(
                    "pad=\(pixelRect.width):\(pixelRect.height):(ow-iw)/2:(oh-ih)/2:color=black"
                )
            }

            if tile.zoomScale > 1.001 || tile.panOffset != .zero {
                let zoomWidth = max(pixelRect.width, Int((CGFloat(pixelRect.width) * tile.zoomScale).rounded(.up)))
                let zoomHeight = max(pixelRect.height, Int((CGFloat(pixelRect.height) * tile.zoomScale).rounded(.up)))
                let maxX = max(0, zoomWidth - pixelRect.width)
                let maxY = max(0, zoomHeight - pixelRect.height)
                let cropX = min(max(
                    Int(CGFloat(maxX) / 2 - tile.panOffset.width * CGFloat(pixelRect.width)), 0
                ), maxX)
                let cropY = min(max(
                    Int(CGFloat(maxY) / 2 - tile.panOffset.height * CGFloat(pixelRect.height)), 0
                ), maxY)
                chain.append("scale=\(zoomWidth):\(zoomHeight):flags=lanczos")
                chain.append(
                    "crop=\(pixelRect.width):\(pixelRect.height):\(cropX):\(cropY)"
                )
            }
            chain.append("setsar=1")
            chain.append("format=rgba[v\(index)]")
            filters.append("[\(index):v:0]" + chain.joined(separator: ","))

            let base = index == 0 ? "base0" : "base\(index)"
            let next = "base\(index + 1)"
            filters.append(
                "[\(base)][v\(index)]overlay=x=\(pixelRect.x):y=\(pixelRect.y):eof_action=pass:shortest=0[\(next)]"
            )
        }
        filters.append("[base\(request.tiles.count)]format=yuv420p[vout]")

        let audioTiles = request.tiles.enumerated().filter { $0.element.includeAudio }
        var audioLabels: [String] = []
        for (audioIndex, pair) in audioTiles.enumerated() {
            let inputIndex = pair.offset
            let tile = pair.element
            let factor = request.relativeTimeline && tile.duration > 0
                ? request.duration / tile.duration
                : 1
            let trimStart = max(0, tile.timeOffset)
            let delay = tile.timeOffset < 0 ? -tile.timeOffset * factor : 0
            var chain: [String] = []
            if trimStart > 0 { chain.append("atrim=start=\(number(trimStart))") }
            chain.append("asetpts=PTS-STARTPTS")
            if request.relativeTimeline, tile.duration > 0 {
                chain.append(contentsOf: tempoFilters(tile.duration / request.duration))
            }
            if delay > 0 {
                chain.append("adelay=\(Int((delay * 1000).rounded())):all=1")
            }
            chain.append("volume=\(number(tile.audioVolume))")
            chain.append("atrim=duration=\(duration)")
            chain.append("aresample=48000")
            chain.append("aformat=sample_fmts=fltp:channel_layouts=stereo[a\(audioIndex)]")
            filters.append(
                "[\(inputIndex):a:\(max(0, tile.audioStreamIndex))]" + chain.joined(separator: ",")
            )
            audioLabels.append("[a\(audioIndex)]")
        }
        if audioLabels.count == 1 {
            filters.append("\(audioLabels[0])anull[aout]")
        } else if audioLabels.count > 1 {
            filters.append(
                "\(audioLabels.joined())amix=inputs=\(audioLabels.count):duration=longest:dropout_transition=0:normalize=0,alimiter=limit=0.95[aout]"
            )
        }
        return (filters.joined(separator: ";"), !audioLabels.isEmpty)
    }

    private static func commandArguments(
        request: Request,
        filter: String,
        hasAudio: Bool,
        encoder: [String],
        output: URL
    ) -> [String] {
        var arguments = ["-hide_banner", "-loglevel", "warning", "-nostdin", "-y"]
        for tile in request.tiles {
            if request.loopEnabled, !request.relativeTimeline {
                arguments += ["-stream_loop", "-1"]
            }
            arguments += ["-i", tile.url.path]
        }
        arguments += ["-filter_complex", filter, "-map", "[vout]"]
        if hasAudio {
            arguments += ["-map", "[aout]"]
        } else {
            arguments += ["-an"]
        }
        arguments += encoder
        if hasAudio { arguments += ["-c:a", "aac", "-b:a", "192k"] }
        arguments += [
            "-t", number(request.duration),
            "-movflags", "+faststart",
            "-progress", "pipe:1", "-nostats",
            output.path,
        ]
        return arguments
    }

    private static func outputRect(
        _ rect: CGRect,
        canvas: CGSize,
        output: CGSize
    ) -> (x: Int, y: Int, width: Int, height: Int) {
        let sx = output.width / canvas.width
        let sy = output.height / canvas.height
        let x = max(0, min(Int((rect.minX * sx).rounded()), Int(output.width) - 1))
        let y = max(0, min(Int((rect.minY * sy).rounded()), Int(output.height) - 1))
        let maxX = max(x + 1, min(Int((rect.maxX * sx).rounded()), Int(output.width)))
        let maxY = max(y + 1, min(Int((rect.maxY * sy).rounded()), Int(output.height)))
        return (x, y, max(1, maxX - x), max(1, maxY - y))
    }

    private static func tempoFilters(_ requested: Double) -> [String] {
        guard requested.isFinite, requested > 0 else { return [] }
        var remaining = requested
        var values: [Double] = []
        while remaining < 0.5 {
            values.append(0.5)
            remaining /= 0.5
        }
        while remaining > 2 {
            values.append(2)
            remaining /= 2
        }
        if abs(remaining - 1) > 0.0001 { values.append(remaining) }
        return values.map { "atempo=\(number($0))" }
    }

    private static func outputBitrate(for size: CGSize) -> String {
        let pixels = size.width * size.height
        if pixels < 1_000_000 { return "4M" }
        if pixels < 3_000_000 { return "8M" }
        if pixels < 9_000_000 { return "18M" }
        return "30M"
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func run(
        _ tool: URL,
        arguments: [String],
        session: Session,
        stderr: TextBuffer,
        duration: Double,
        onProgress: ((Double) -> Void)?
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = tool
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice

            let errorPipe = Pipe()
            process.standardError = errorPipe
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                stderr.append(text)
            }

            let progressPipe = Pipe()
            let lines = ProgressLines()
            process.standardOutput = progressPipe
            progressPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                for line in lines.ingest(data) {
                    for prefix in ["out_time_us=", "out_time_ms="] where line.hasPrefix(prefix) {
                        if let microseconds = Double(line.dropFirst(prefix.count)) {
                            onProgress?(min(max(microseconds / 1_000_000 / duration, 0), 1))
                        }
                    }
                }
            }

            guard session.attach(process) else {
                continuation.resume(returning: false)
                return
            }
            process.terminationHandler = { finished in
                progressPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                session.detach(finished)
                continuation.resume(returning: finished.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                progressPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                session.detach(process)
                continuation.resume(returning: false)
            }
        }
    }

    private static func writeLog(_ text: String) -> URL? {
        let folder = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Tilo")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("export.log")
        return (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
    }
}
