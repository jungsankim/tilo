import AppKit
import CMpv
import MpvBridge
import SwiftUI

private func mpvRenderUpdateCallback(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let view = Unmanaged<MPVOpenGLView>.fromOpaque(context).takeUnretainedValue()
    view.enqueueFrameRequest()
}

/// libmpv의 OpenGL render context를 수명 내내 보관하는 표면. SwiftUI가
/// 모자이크/확대 전환으로 뷰를 다시 붙여도 같은 context와 디코더를 유지한다.
final class MPVOpenGLView: NSOpenGLView {
    private weak var engine: MPVPlaybackEngine?
    private var renderContext: OpaquePointer?
    private var preparing = false
    private let frameRequestLock = NSLock()
    private var frameRequestQueued = false
    var onZoom: ((CGFloat, CGPoint) -> Void)?

    init(engine: MPVPlaybackEngine) {
        self.engine = engine
        let attributes: [NSOpenGLPixelFormatAttribute] = [
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAOpenGLProfile),
            NSOpenGLPixelFormatAttribute(NSOpenGLProfileVersion3_2Core),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAAccelerated),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFADoubleBuffer),
            0,
        ]
        let format = attributes.withUnsafeBufferPointer {
            NSOpenGLPixelFormat(attributes: $0.baseAddress!)
        }
        super.init(
            frame: NSRect(x: 0, y: 0, width: 2, height: 2),
            pixelFormat: format
        )!
        wantsBestResolutionOpenGLSurface = true
        canDrawConcurrently = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { true }

    func prepareRenderer() {
        precondition(Thread.isMainThread)
        guard !preparing, renderContext == nil,
              let engine, let handle = engine.handle else { return }
        guard let openGLContext else {
            engine.rendererDidFail(MPV_ERROR_UNINITIALIZED.rawValue)
            return
        }
        preparing = true
        openGLContext.makeCurrentContext()
        var context: OpaquePointer?
        let status = tilo_mpv_render_context_create(&context, handle)
        guard status >= 0, let context else {
            preparing = false
            engine.rendererDidFail(status)
            return
        }
        renderContext = context
        mpv_render_context_set_update_callback(
            context,
            mpvRenderUpdateCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        engine.rendererDidPrepare()
        requestFrame()
    }

    func shutdownRenderer() {
        precondition(Thread.isMainThread)
        guard let context = renderContext else { return }
        mpv_render_context_set_update_callback(context, nil, nil)
        openGLContext?.makeCurrentContext()
        mpv_render_context_free(context)
        renderContext = nil
        preparing = false
    }

    func requestFrame() {
        guard renderContext != nil else { return }
        needsDisplay = true
    }

    /// libmpv callback은 디코더 스레드에서 올 수 있다. 메인 큐에 아직 처리하지
    /// 않은 요청이 있으면 합쳐서 다중 영상 재생 시 큐가 불어나는 것을 막는다.
    fileprivate func enqueueFrameRequest() {
        frameRequestLock.lock()
        guard !frameRequestQueued else {
            frameRequestLock.unlock()
            return
        }
        frameRequestQueued = true
        frameRequestLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.frameRequestLock.lock()
            self.frameRequestQueued = false
            self.frameRequestLock.unlock()
            self.requestFrame()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = renderContext, let openGLContext else {
            self.openGLContext?.makeCurrentContext()
            tilo_mpv_clear_frame()
            return
        }
        openGLContext.makeCurrentContext()
        _ = mpv_render_context_update(context)
        let backing = convertToBacking(bounds)
        let width = max(1, Int32(backing.width.rounded()))
        let height = max(1, Int32(backing.height.rounded()))
        _ = tilo_mpv_render_frame(context, 0, width, height, 1)
        openGLContext.flushBuffer()
        mpv_render_context_report_swap(context)
    }

    override func reshape() {
        super.reshape()
        requestFrame()
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.scrollingDeltaY != 0, bounds.width > 0, bounds.height > 0 else {
            return super.scrollWheel(with: event)
        }
        let unit: CGFloat = event.hasPreciseScrollingDeltas ? 0.005 : 0.08
        let location = convert(event.locationInWindow, from: nil)
        let focus = CGPoint(
            x: (location.x - bounds.midX) / bounds.width,
            y: (bounds.midY - location.y) / bounds.height
        )
        onZoom?(event.scrollingDeltaY * unit, focus)
    }
}

struct MPVSurfaceView: NSViewRepresentable {
    let engine: MPVPlaybackEngine
    let fill: Bool
    var rotationQuarters: Int = 0
    var zoomScale: CGFloat = 1
    var panOffset: CGSize = .zero
    var onZoom: ((CGFloat, CGPoint) -> Void)?

    func makeNSView(context: Context) -> MPVOpenGLView {
        engine.surfaceView
    }

    func updateNSView(_ nsView: MPVOpenGLView, context: Context) {
        engine.setPresentation(
            fill: fill,
            rotationQuarters: rotationQuarters,
            zoomScale: zoomScale,
            panOffset: panOffset
        )
        nsView.onZoom = onZoom
        nsView.requestFrame()
    }
}
