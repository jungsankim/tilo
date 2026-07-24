import SwiftUI
import AVFoundation

struct VideoCell: View {
    @ObservedObject var item: VideoItem
    let fill: Bool
    var isSoloed = false
    var isSelected = false
    var showSubtitles = true
    var subtitleScale: Double = 1
    let onRemove: () -> Void
    var onSelect: (() -> Void)?
    var onSolo: (() -> Void)?
    var onZoom: (() -> Void)?
    var onRotate: (() -> Void)?
    var onOffset: ((Double) -> Void)?
    var onResetOffset: (() -> Void)?
    var onScrollZoom: ((CGFloat, CGPoint) -> Void)?
    var onPan: ((CGSize) -> Void)?
    var onResetReframe: (() -> Void)?
    /// 개별 시크. 동기화 보정이 되돌리지 않도록 매니저가 시간 정렬과 함께 처리한다.
    var onSeek: ((Double) -> Void)?
    /// 개별 A-B 구간반복 토글 (한 번 = A, 두 번 = B + 반복, 세 번 = 해제)
    var onCycleAB: (() -> Void)?

    /// 개별 시간 오프셋 한 번 누를 때 이동량(초)
    private let offsetStep = 0.1

    @State private var hovering = false
    @State private var active = true
    @State private var hideTimer = AutoHideTimer()
    @State private var cellSize: CGSize = .zero
    @State private var panBase: CGSize?
    @State private var showMenu = false

    /// 셀 위에 있으면서 최근에 마우스를 움직였을 때(또는 더보기 메뉴가 열렸을 때) 컨트롤 표시
    private var showOverlay: Bool { (hovering && active) || showMenu }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let engine = item.mpvEngine {
                    MPVSurfaceView(
                        engine: engine,
                        fill: fill,
                        rotationQuarters: item.rotationQuarters,
                        zoomScale: item.zoomScale,
                        panOffset: item.panOffset,
                        onZoom: { onScrollZoom?($0, $1) }
                    )
                } else {
                    PlayerLayerView(
                        player: item.player,
                        fill: fill,
                        rotationQuarters: item.rotationQuarters,
                        zoomScale: item.zoomScale,
                        panOffset: item.panOffset,
                        onZoom: { onScrollZoom?($0, $1) }
                    )
                }
            }
                .background(Color.black)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { cellSize = geo.size }
                            .onChange(of: geo.size) { cellSize = $0 }
                    }
                )
                .gesture(
                    TapGesture(count: 2)
                        .onEnded { onZoom?() }
                        .exclusively(before: TapGesture().onEnded { onSelect?() })
                )
                // Option+드래그로 확대된 영상의 보이는 영역을 이동 (자리 교환과 분리)
                .highPriorityGesture(
                    DragGesture(minimumDistance: 2).modifiers(.option)
                        .onChanged { value in
                            guard cellSize.width > 0, cellSize.height > 0 else { return }
                            let base = panBase ?? item.panOffset
                            if panBase == nil { panBase = base }
                            onPan?(CGSize(
                                width: base.width + value.translation.width / cellSize.width,
                                height: base.height + value.translation.height / cellSize.height
                            ))
                        }
                        .onEnded { _ in panBase = nil }
                )

            if item.loadFailed {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(.yellow)
                    Group {
                        if PlayerManager.needsRemux(item.sourceURL) {
                            Text("이 파일은 기본 재생 방식으로 열 수 없습니다")
                        } else if Remuxer.ffmpegURL == nil {
                            Text("호환 변환 도구가 없어 재생할 수 없습니다")
                        } else {
                            Text("파일이 손상됐거나 지원되지 않는 스트림입니다")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Text(item.sourceURL.lastPathComponent)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.85))
            }

            if showOverlay {
                HStack(spacing: 2) {
                    ControlIconButton(
                        icon: item.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                        active: !item.isMuted,
                        diameter: 26,
                        fontSize: 12,
                        helpText: item.isMuted ? "음소거 해제" : "음소거"
                    ) {
                        item.isMuted.toggle()
                    }
                    ControlIconButton(
                        icon: "headphones",
                        active: isSoloed,
                        diameter: 26,
                        fontSize: 12,
                        helpText: isSoloed ? "오디오 솔로 해제" : "이 영상만 듣기"
                    ) {
                        onSolo?()
                    }
                    ControlIconButton(
                        text: "AB",
                        tint: item.abB != nil ? .accentColor : item.abA != nil ? .orange : nil,
                        diameter: 26,
                        fontSize: 12,
                        helpText: item.abA == nil ? "이 영상만 구간반복: 시작점 설정"
                            : item.abB == nil ? "이 영상만 구간반복: 끝점 설정"
                            : "이 영상 구간반복 해제"
                    ) {
                        onCycleAB?()
                    }
                    ControlIconButton(
                        icon: "ellipsis",
                        active: showMenu,
                        diameter: 26,
                        fontSize: 12,
                        helpText: "더보기"
                    ) {
                        showMenu.toggle()
                    }
                    .popover(isPresented: $showMenu, arrowEdge: .bottom) {
                        cellMenu.frame(width: 200).padding(14)
                    }
                    ControlIconButton(
                        icon: "xmark",
                        diameter: 26,
                        fontSize: 12,
                        helpText: "영상 제거"
                    ) {
                        onRemove()
                    }
                }
                .padding(3)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9))
                .padding(10)
                .transition(.opacity)
            }
        }
        .overlay(alignment: .topLeading) {
            if showOverlay {
                Text(item.sourceURL.lastPathComponent)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                    .padding(10)
                    .frame(maxWidth: 220, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if showSubtitles, !item.loadFailed, let subtitle = item.currentSubtitle {
                Text(subtitle)
                    .font(.system(size: 14 * subtitleScale, weight: .medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.9), radius: 1.5)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
                    .padding(.horizontal, 6)
                    .padding(.bottom, showOverlay ? 32 : 10)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if showOverlay {
                HStack(spacing: 8) {
                    Slider(
                        value: Binding(
                            get: { item.progress },
                            set: { seek(to: $0) }
                        ),
                        in: 0...1
                    ) { editing in
                        item.isScrubbing = editing
                        // 스크럽 중에는 키프레임 단위로 따라갔으므로 정밀 보정
                        if !editing { seek(to: item.progress) }
                    }
                    .controlSize(.small)
                    .overlay {
                        // 개별 A-B 구간반복 지점 표시
                        GeometryReader { geo in
                            ForEach([item.abA, item.abB].compactMap { $0 }, id: \.self) { mark in
                                Rectangle()
                                    .fill(Color.orange)
                                    .frame(width: 2, height: 8)
                                    .position(x: mark * geo.size.width, y: geo.size.height / 2)
                            }
                        }
                        .allowsHitTesting(false)
                    }

                    Text(timeString(item.progress * item.durationSeconds))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                        .fixedSize()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.55)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .transition(.opacity)
            }
        }
        .overlay {
            if isSelected || isSoloed {
                Rectangle().strokeBorder(
                    isSelected ? Color.accentColor : Color.orange,
                    lineWidth: 2
                )
            }
        }
        .animation(.easeInOut(duration: 0.15), value: showOverlay)
        .onHover { inside in
            hovering = inside
            // 시크바가 보이는 동안만 진행률 발행을 켠다
            item.progressActive = inside
            if inside {
                bump()
            } else {
                hideTimer.task?.cancel()
                active = true
            }
        }
        .onContinuousHover { _ in
            if hovering { bump() }
        }
    }

    private func seek(to fraction: Double) {
        if let onSeek { onSeek(fraction) } else { item.seek(to: fraction) }
    }

    private var offsetLabel: String {
        let v = item.timeOffset
        if abs(v) < 0.001 { return "±0s" }
        return String(format: "%+.1fs", v)
    }

    /// 개별 영상 "더보기" 팝오버 내용 (시간 정렬·회전·확대 초기화·제거)
    private var cellMenu: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("시간 정렬")
                Spacer()
                ControlIconButton(icon: "minus", diameter: 22, fontSize: 10, helpText: "뒤로") {
                    onOffset?(-offsetStep)
                }
                Text(offsetLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 46)
                ControlIconButton(icon: "plus", diameter: 22, fontSize: 10, helpText: "앞으로") {
                    onOffset?(offsetStep)
                }
            }
            if abs(item.timeOffset) > 0.001 {
                Button("정렬 초기화") { onResetOffset?() }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }

            Divider()

            Button("90° 회전") { onRotate?() }.buttonStyle(.plain)
            if item.isReframed {
                Button("확대·이동 초기화") { onResetReframe?() }.buttonStyle(.plain)
            }
        }
        .font(.callout)
    }

    /// 마우스가 움직이면 컨트롤을 보여주고 숨김 타이머를 다시 건다
    private func bump() {
        if !active {
            active = true
            item.progressActive = true
        }
        guard Date().timeIntervalSince(hideTimer.lastSchedule) > 0.4 else { return }
        hideTimer.lastSchedule = Date()
        hideTimer.task?.cancel()
        hideTimer.task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, !item.isScrubbing, !showMenu else { return }
            active = false
            item.progressActive = false
        }
    }
}

struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    let fill: Bool
    var rotationQuarters: Int = 0
    var zoomScale: CGFloat = 1
    var panOffset: CGSize = .zero
    var onZoom: ((CGFloat, CGPoint) -> Void)?

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerNSView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
        let gravity: AVLayerVideoGravity = fill ? .resizeAspectFill : .resizeAspect
        if nsView.playerLayer.videoGravity != gravity {
            nsView.playerLayer.videoGravity = gravity
        }
        let layoutChanged = nsView.rotationQuarters != rotationQuarters
            || nsView.zoomScale != zoomScale
            || nsView.panOffset != panOffset
        if layoutChanged {
            nsView.rotationQuarters = rotationQuarters
            nsView.zoomScale = zoomScale
            nsView.panOffset = panOffset
            nsView.needsLayout = true
        }
        nsView.onZoom = onZoom
    }
}

final class PlayerNSView: NSView {
    let playerLayer = AVPlayerLayer()
    var rotationQuarters = 0
    var zoomScale: CGFloat = 1
    var panOffset: CGSize = .zero
    var onZoom: ((CGFloat, CGPoint) -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        playerLayer.videoGravity = .resizeAspect
        // 채우기(crop)·확대 모드에서 영상이 셀 밖으로 넘치지 않도록
        playerLayer.masksToBounds = true
        layer?.masksToBounds = true
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 스크롤로 확대 (트랙패드·마우스 휠 모두 scrollingDeltaY).
    /// 커서 위치를 타일 중심 기준 비율(x 오른쪽, y 아래, -0.5…0.5)로 넘겨
    /// 그 지점을 기준으로 확대되게 한다.
    override func scrollWheel(with event: NSEvent) {
        guard event.scrollingDeltaY != 0, bounds.width > 0, bounds.height > 0 else {
            return super.scrollWheel(with: event)
        }
        // 픽셀 단위(트랙패드)는 작게, 라인 단위(휠)는 크게 들어오므로 정규화
        let unit: CGFloat = event.hasPreciseScrollingDeltas ? 0.005 : 0.08
        let lp = convert(event.locationInWindow, from: nil) // 원점 좌하단(y 위로)
        let focus = CGPoint(
            x: (lp.x - bounds.midX) / bounds.width,
            y: (bounds.midY - lp.y) / bounds.height // 화면 아래 방향을 +로
        )
        onZoom?(event.scrollingDeltaY * unit, focus)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let q = ((rotationQuarters % 4) + 4) % 4
        // 90°/270° 회전 시 레이어 bounds의 가로·세로를 바꿔 셀을 채운다.
        let swapped = q % 2 != 0
        playerLayer.bounds = CGRect(
            origin: .zero,
            size: swapped ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        )
        // 리프레임 이동: 타일 크기 대비 비율을 점 단위로 환산
        let dx = panOffset.width * bounds.width
        let dy = -panOffset.height * bounds.height // 레이어 좌표는 y가 위로 증가
        playerLayer.position = CGPoint(x: bounds.midX + dx, y: bounds.midY + dy)
        // 회전 후 확대를 적용
        let t = CGAffineTransform(rotationAngle: CGFloat(q) * .pi / 2).scaledBy(x: zoomScale, y: zoomScale)
        playerLayer.setAffineTransform(t)
        CATransaction.commit()
    }
}
