import SwiftUI

/// 호버 하이라이트가 있는 아이콘 버튼. 컨트롤 바·셀 오버레이·재생목록에서 공용.
/// icon(SF Symbol) 또는 text(짧은 글자 라벨) 중 하나를 쓴다.
struct ControlIconButton: View {
    var icon: String?
    var text: String?
    var active = false
    /// active 상태 대신 직접 색을 지정할 때 (예: 구간반복의 중간 상태)
    var tint: Color?
    var diameter: CGFloat = 30
    var fontSize: CGFloat = 13
    var helpText: LocalizedStringKey = ""
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    private var iconColor: Color {
        if let tint { return tint }
        if active { return .accentColor }
        return .primary.opacity(hovering ? 1 : 0.72)
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: fontSize, weight: .medium))
                } else if let text {
                    Text(text)
                        .font(.system(size: fontSize - 1, weight: .bold, design: .rounded))
                }
            }
            .foregroundStyle(iconColor)
                .frame(width: diameter, height: diameter)
                .background(
                    Color.primary.opacity(hovering && isEnabled ? 0.13 : 0),
                    in: RoundedRectangle(cornerRadius: diameter * 0.27)
                )
                .contentShape(RoundedRectangle(cornerRadius: diameter * 0.27))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .help(helpText)
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}
