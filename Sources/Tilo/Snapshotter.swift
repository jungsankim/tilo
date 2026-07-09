import AVFoundation
import AppKit
import ImageIO

/// 현재 모자이크 화면을 이미지 파일로 저장한다. 화면 녹화 권한이 필요한
/// 윈도우 캡처 대신, 각 영상의 현재 프레임을 직접 생성해 레이아웃대로
/// 합성하므로 권한 없이 UI 없는 깨끗한 결과를 얻는다.
enum Snapshotter {
    struct Tile {
        /// 메인 스레드의 AVPlayer를 넘기지 않고, 캡처 시작 순간의 값만 보관한다.
        let url: URL
        let timeSeconds: Double
        let rect: CGRect
        let rotationQuarters: Int
        /// libmpv로 재생 중인 원본은 AVFoundation에 다시 맡기지 않는다.
        let prefersFFmpeg: Bool
    }

    /// 저장 폴더: ~/Pictures/Tilo
    static var outputFolder: URL {
        let pics = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        return pics.appendingPathComponent("Tilo")
    }

    @discardableResult
    static func capture(tiles: [Tile], canvas: CGSize, fill: Bool) async -> URL? {
        guard canvas.width > 0, canvas.height > 0 else { return nil }
        let scale: CGFloat = 2 // 레티나 해상도로 저장
        let pxW = Int(canvas.width * scale)
        let pxH = Int(canvas.height * scale)
        guard let ctx = CGContext(
            data: nil, width: pxW, height: pxH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))

        for tile in tiles {
            guard let cg = await frame(for: tile) else { continue }
            // CGContext 원점은 좌하단이라 y를 뒤집는다
            let r = CGRect(
                x: tile.rect.minX * scale,
                y: (canvas.height - tile.rect.maxY) * scale,
                width: tile.rect.width * scale,
                height: tile.rect.height * scale
            )
            draw(cg, in: r, fill: fill, context: ctx, rotationQuarters: tile.rotationQuarters)
        }

        guard let image = ctx.makeImage() else { return nil }
        return write(image)
    }

    private static func frame(for tile: Tile) async -> CGImage? {
        await frame(
            url: tile.url,
            timeSeconds: tile.timeSeconds,
            prefersFFmpeg: tile.prefersFFmpeg
        )
    }

    /// AVFoundation이 읽을 수 있는 파일은 기존의 빠른 경로를 사용하고,
    /// 직접 재생 백엔드에서만 열리는 파일은 ffmpeg로 한 프레임만 추출한다.
    /// 테스트에서도 실제 원본 파일 호환성을 검증할 수 있도록 internal로 둔다.
    static func frame(
        url: URL,
        timeSeconds: Double,
        prefersFFmpeg: Bool = false
    ) async -> CGImage? {
        let seconds = timeSeconds.isFinite ? max(0, timeSeconds) : 0
        if prefersFFmpeg {
            if let image = await ffmpegFrame(url: url, timeSeconds: seconds) {
                return image
            }
            return await avFoundationFrame(url: url, timeSeconds: seconds)
        }
        if let image = await avFoundationFrame(url: url, timeSeconds: seconds) {
            return image
        }
        return await ffmpegFrame(url: url, timeSeconds: seconds)
    }

    private static func avFoundationFrame(url: URL, timeSeconds: Double) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let time = CMTime(seconds: timeSeconds, preferredTimescale: 600)
        return try? await gen.image(at: time).image
    }

    private static func ffmpegFrame(url: URL, timeSeconds: Double) async -> CGImage? {
        guard let ffmpeg = Remuxer.ffmpegURL else { return nil }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TiloSnapshotFrames", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            return nil
        }

        let output = temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: output) }

        let timestamp = String(
            format: "%.6f",
            locale: Locale(identifier: "en_US_POSIX"),
            timeSeconds
        )
        let succeeded = await run(
            ffmpeg,
            arguments: [
                "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                "-ss", timestamp,
                "-i", url.path,
                "-map", "0:v:0", "-frames:v", "1",
                "-an", "-sn", "-c:v", "png", "-update", "1",
                output.path,
            ]
        )
        guard succeeded,
              let source = CGImageSourceCreateWithURL(output as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let residentImage = residentCopy(of: image)
        else { return nil }
        return residentImage
    }

    /// ImageIO가 임시 PNG를 지운 뒤에도 파일을 지연 참조하지 않도록 픽셀을
    /// 메모리 비트맵으로 복사한다.
    private static func residentCopy(of image: CGImage) -> CGImage? {
        guard image.width > 0, image.height > 0,
              let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        return context.makeImage()
    }

    private static func run(_ executable: URL, arguments: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
            }
        }
    }

    private static func draw(_ image: CGImage, in rect: CGRect, fill: Bool, context ctx: CGContext, rotationQuarters: Int) {
        ctx.saveGState()
        ctx.clip(to: rect)

        // 회전을 반영한 화면 표시 화면비
        var srcW = CGFloat(image.width)
        var srcH = CGFloat(image.height)
        if rotationQuarters % 2 != 0 { swap(&srcW, &srcH) }
        let srcAspect = srcW / srcH
        let dstAspect = rect.width / rect.height

        // 채우기면 셀을 덮도록(넘침 잘림), 맞춤이면 셀 안에 들어오도록
        let widthBound = fill ? (srcAspect < dstAspect) : (srcAspect > dstAspect)
        let w = widthBound ? rect.width : rect.height * srcAspect
        let h = widthBound ? rect.width / srcAspect : rect.height

        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.rotate(by: CGFloat(rotationQuarters) * .pi / 2)
        // 90°/270° 회전 시 그리는 박스의 가로·세로가 바뀐다
        let drawW = rotationQuarters % 2 == 0 ? w : h
        let drawH = rotationQuarters % 2 == 0 ? h : w
        ctx.draw(image, in: CGRect(x: -drawW / 2, y: -drawH / 2, width: drawW, height: drawH))
        ctx.restoreGState()
    }

    private static func write(_ image: CGImage) -> URL? {
        try? FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH.mm.ss"
        let url = outputFolder.appendingPathComponent("Tilo_\(formatter.string(from: Date())).png")
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        return (try? data.write(to: url)) != nil ? url : nil
    }
}
