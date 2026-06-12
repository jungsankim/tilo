import SwiftUI
import AVFoundation

struct VideoCell: View {
    @ObservedObject var item: VideoItem
    let fill: Bool
    var isSoloed = false
    let onRemove: () -> Void
    var onSolo: (() -> Void)?
    var onZoom: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            PlayerLayerView(player: item.player, fill: fill)
                .background(Color.black)
                .gesture(
                    TapGesture(count: 2)
                        .onEnded { onZoom?() }
                        .exclusively(before: TapGesture().onEnded { onSolo?() })
                )

            if hovering {
                HStack(spacing: 10) {
                    Button {
                        item.isMuted.toggle()
                    } label: {
                        Image(systemName: item.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .help(item.isMuted ? "음소거 해제" : "음소거")

                    Button(role: .destructive, action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .help("영상 제거")
                }
                .buttonStyle(.plain)
                .font(.system(size: 14))
                .padding(8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(10)
            }
        }
        .overlay(alignment: .bottom) {
            if hovering {
                Slider(
                    value: Binding(
                        get: { item.progress },
                        set: { item.seek(to: $0) }
                    ),
                    in: 0...1
                ) { editing in
                    item.isScrubbing = editing
                }
                .controlSize(.mini)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.55)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
        }
        .overlay {
            if isSoloed {
                Rectangle().strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .onHover {
            hovering = $0
            // 시크바가 보이는 동안만 진행률 발행을 켠다
            item.progressActive = $0
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
