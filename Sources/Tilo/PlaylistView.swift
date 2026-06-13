import SwiftUI
import AppKit

/// 재생창 오른쪽에 붙는 재생목록 패널 (팟플레이어 스타일)
struct PlaylistView: View {
    @EnvironmentObject var manager: PlayerManager

    private var hasSelection: Bool { !manager.selectedPlaylist.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if manager.playlist.isEmpty {
                emptyHint
            } else {
                list
            }
            // Delete 키로 선택 항목 삭제 (보이지 않는 단축키 버튼)
            Button("") { manager.deleteSelectedFromPlaylist() }
                .keyboardShortcut(.delete, modifiers: [])
                .opacity(0).frame(width: 0, height: 0)
                .disabled(!hasSelection)
        }
        .frame(width: 280)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("재생목록")
                .font(.system(size: 13, weight: .semibold))
            Text(hasSelection ? "\(manager.selectedPlaylist.count) 선택" : "\(manager.playlist.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(hasSelection ? Color.accentColor : .secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
            Spacer()
            ControlIconButton(icon: "plus", diameter: 24, fontSize: 11, helpText: "동영상 추가 (⌘O)") {
                manager.openVideos()
            }
            if hasSelection {
                ControlIconButton(icon: "trash", diameter: 24, fontSize: 11, helpText: "선택 삭제 (Delete)") {
                    manager.deleteSelectedFromPlaylist()
                }
            } else {
                ControlIconButton(icon: "trash", diameter: 24, fontSize: 11, helpText: "목록 비우기") {
                    manager.clearPlaylist()
                }
                .disabled(manager.playlist.isEmpty)
            }
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
        .contentShape(Rectangle())
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(Array(manager.playlist.enumerated()), id: \.element.id) { index, entry in
                    PlaylistRow(
                        index: index,
                        entry: entry,
                        isOnStage: manager.isOnStage(entry),
                        isSelected: manager.selectedPlaylist.contains(entry.url),
                        onSelect: { command, shift in
                            manager.clickPlaylist(entry, index: index, command: command, shift: shift)
                        },
                        onToggle: { manager.toggleOnStage(entry) },
                        onDelete: { manager.removeFromPlaylist(entry) }
                    )
                }
            }
            .padding(.vertical, 6)
        }
        // 빈 영역 클릭 시 선택 해제
        .contentShape(Rectangle())
        .onTapGesture { manager.clearPlaylistSelection() }
    }
}

private struct PlaylistRow: View {
    let index: Int
    let entry: PlaylistEntry
    let isOnStage: Bool
    let isSelected: Bool
    let onSelect: (_ command: Bool, _ shift: Bool) -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.25) }
        if hovering { return Color.primary.opacity(0.08) }
        return .clear
    }

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
                // 화면에 올리기/내리기
                Button(action: onToggle) {
                    Image(systemName: isOnStage ? "rectangle.badge.minus" : "rectangle.badge.plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(isOnStage ? LocalizedStringKey("화면에서 제거") : LocalizedStringKey("화면에 추가"))
                // 이 항목만 목록에서 삭제
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("목록에서 제거")
            } else if isOnStage {
                Image(systemName: "play.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(background, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
        // 단일 클릭 = 선택(⌘/⇧ 조합 지원), 더블 클릭 = 화면에 올리기/내리기
        .onTapGesture(count: 2, perform: onToggle)
        .onTapGesture {
            let flags = NSEvent.modifierFlags
            onSelect(flags.contains(.command), flags.contains(.shift))
        }
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
