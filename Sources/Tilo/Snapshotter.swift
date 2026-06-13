import AVFoundation
import AppKit

/// 현재 모자이크 화면을 이미지 파일로 저장한다. 화면 녹화 권한이 필요한
/// 윈도우 캡처 대신, 각 영상의 현재 프레임을 직접 생성해 레이아웃대로
/// 합성하므로 권한 없이 UI 없는 깨끗한 결과를 얻는다.
enum Snapshotter {
    struct Tile {
        let item: VideoItem
        let rect: CGRect
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
            guard let cg = await frame(for: tile.item) else { continue }
            // CGContext 원점은 좌하단이라 y를 뒤집는다
            let r = CGRect(
                x: tile.rect.minX * scale,
                y: (canvas.height - tile.rect.maxY) * scale,
                width: tile.rect.width * scale,
                height: tile.rect.height * scale
            )
            draw(cg, in: r, fill: fill, context: ctx, rotationQuarters: tile.item.rotationQuarters)
        }

        guard let image = ctx.makeImage() else { return nil }
        return write(image)
    }

    private static func frame(for item: VideoItem) async -> CGImage? {
        guard let asset = item.player.currentItem?.asset else { return nil }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let time = item.player.currentTime()
        return try? await gen.image(at: time).image
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
