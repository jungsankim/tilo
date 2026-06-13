import SwiftUI

/// 재생창 오른쪽에 붙는 재생목록 패널 (팟플레이어 스타일)
struct PlaylistView: View {
    @EnvironmentObject var manager: PlayerManager

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if manager.playlist.isEmpty {
                emptyHint
            } else {
                list
            }
        }
        .frame(width: 280)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("재생목록")
                .font(.system(size: 13, weight: .semibold))
            Text("\(manager.playlist.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
            Spacer()
            ControlIconButton(icon: "plus", diameter: 24, fontSize: 11, helpText: "동영상 추가 (⌘O)") {
                manager.openVideos()
            }
            ControlIconButton(icon: "trash", diameter: 24, fontSize: 11, helpText: "목록 비우기") {
                manager.clearPlaylist()
            }
            .disabled(manager.playlist.isEmpty)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "list.and.film")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("영상을 열면 같은 폴더의\n영상들이 자동으로 등록됩니다")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(Array(manager.playlist.enumerated()), id: \.element.id) { index, entry in
                    PlaylistRow(
                        index: index,
                        entry: entry,
                        isOnStage: manager.isOnStage(entry),
                        onToggle: { manager.toggleOnStage(entry) },
                        onDelete: { manager.removeFromPlaylist(entry) }
                    )
                }
            }
            .padding(.vertical, 6)
        }
    }
}

private struct PlaylistRow: View {
    let index: Int
    let entry: PlaylistEntry
    let isOnStage: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)

            Text(entry.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isOnStage ? Color.accentColor : Color.primary)

            Spacer(minLength: 4)

            if hovering {
                Button(action: onToggle) {
                    Image(systemName: isOnStage ? "rectangle.badge.minus" : "rectangle.badge.plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(isOnStage ? LocalizedStringKey("화면에서 제거") : LocalizedStringKey("화면에 추가"))
            } else if isOnStage {
                Image(systemName: "play.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            hovering ? Color.primary.opacity(0.08) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
        .contentShape(Rectangle())
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: onToggle)
        .contextMenu {
            if isOnStage {
                Button("화면에서 제거", action: onToggle)
            } else {
                Button("화면에 추가", action: onToggle)
            }
            Button("목록에서 제거", role: .destructive, action: onDelete)
        }
    }
}
