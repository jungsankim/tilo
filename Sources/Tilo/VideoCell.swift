import SwiftUI
import AVFoundation

struct VideoCell: View {
    @ObservedObject var item: VideoItem
    let fill: Bool
    var isSoloed = false
    var showSubtitles = true
    let onRemove: () -> Void
    var onSolo: (() -> Void)?
    var onZoom: (() -> Void)?

    @State private var hovering = false
    @State private var active = true
    @State private var hideTimer = AutoHideTimer()

    /// 셀 위에 있으면서 최근에 마우스를 움직였을 때만 컨트롤을 보여준다
    private var showOverlay: Bool { hovering && active }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            PlayerLayerView(player: item.player, fill: fill)
                .background(Color.black)
                .gesture(
                    TapGesture(count: 2)
                        .onEnded { onZoom?() }
                        .exclusively(before: TapGesture().onEnded { onSolo?() })
                )

            if item.loadFailed {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(.yellow)
                    Group {
                        if PlayerManager.needsRemux(item.sourceURL) {
                            Text("변환 없이는 재생할 수 없는 형식입니다 (\(item.sourceURL.pathExtension.uppercased()))")
                        } else {
                            Text("재생할 수 없는 파일")
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
                    .frame(maxWidth: 260, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if showSubtitles, !item.loadFailed, let subtitle = item.currentSubtitle {
                Text(subtitle)
                    .font(.system(size: 14, weight: .medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
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
                            set: { item.seek(to: $0) }
                        ),
                        in: 0...1
                    ) { editing in
                        item.isScrubbing = editing
                        // 스크럽 중에는 키프레임 단위로 따라갔으므로 정밀 보정
                        if !editing { item.seek(to: item.progress) }
                    }
                    .controlSize(.mini)

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
            if isSoloed {
                Rectangle().strokeBorder(Color.accentColor, lineWidth: 2)
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
            guard !Task.isCancelled, !item.isScrubbing else { return }
            active = false
            item.progressActive = false
        }
    }
}

struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    let fill: Bool

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerNSView, context: Context) {
        nsView.playerLayer.player = player
        nsView.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }
}

final class PlayerNSView: NSView {
    let playerLayer = AVPlayerLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        playerLayer.videoGravity = .resizeAspect
        // 채우기(crop) 모드에서 영상이 셀 밖으로 넘치지 않도록
        playerLayer.masksToBounds = true
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}
