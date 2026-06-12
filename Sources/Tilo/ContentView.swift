import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var manager: PlayerManager
    @AppStorage("fillMode") private var fillMode = true

    var body: some View {
        VStack(spacing: 0) {
            if manager.items.isEmpty {
                emptyState
            } else {
                videoGrid
            }
            controlBar
        }
        .background(Color.black)
        .background(hiddenShortcuts)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("동영상 파일을 드래그하거나 열기 버튼을 누르세요")
                .foregroundStyle(.secondary)
            Button("동영상 열기…") { manager.openVideos() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isZoomed: Bool { manager.zoomedItemID != nil }

    /// 컨트롤 바에 버튼이 없는 동작들의 단축키 (보이지 않는 버튼으로 등록)
    private var hiddenShortcuts: some View {
        Group {
            Button("") { manager.seekRelative(-5) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { manager.seekRelative(5) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { manager.seekRelative(-30) }
                .keyboardShortcut(.leftArrow, modifiers: .shift)
            Button("") { manager.seekRelative(30) }
                .keyboardShortcut(.rightArrow, modifiers: .shift)
            Button("") { manager.toggleMuteAll() }
                .keyboardShortcut("m", modifiers: [])
            Button("") {
                if let zoomed = manager.items.first(where: { $0.id == manager.zoomedItemID }) {
                    manager.toggleZoom(zoomed)
                }
            }
            .keyboardShortcut(.escape, modifiers: [])
            ForEach(0..<10, id: \.self) { digit in
                Button("") { manager.seekAll(to: Double(digit) / 10) }
                    .keyboardShortcut(KeyEquivalent(Character("\(digit)")), modifiers: [])
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    /// 확대 모드면 그 영상 하나가 전체를, 아니면 모자이크/저스티파이드 배치
    private func layoutItems(in size: CGSize) -> [(item: VideoItem, rect: CGRect)] {
        if let zoomed = manager.items.first(where: { $0.id == manager.zoomedItemID }) {
            return [(zoomed, CGRect(origin: .zero, size: size))]
        }
        let entries = manager.items.map { GridLayout.Entry(id: $0.id, aspect: $0.aspect) }
        let cells = fillMode
            ? MosaicLayout.cells(for: entries, in: size)
            : GridLayout.cells(for: entries, in: size)
        let rects = Dictionary(uniqueKeysWithValues: cells.map { ($0.id, $0.rect) })
        return manager.items.compactMap { item in rects[item.id].map { (item, $0) } }
    }

    /// 타일 크기(레티나 ×2)에 맞춰 각 영상의 디코딩 해상도를 제한한다
    private func applyResolutionCaps(_ layout: [(item: VideoItem, rect: CGRect)]) {
        let scale: CGFloat = 2
        for (item, rect) in layout {
            item.applyResolutionCap(CGSize(width: rect.width * scale, height: rect.height * scale))
        }
    }

    private var videoGrid: some View {
        GeometryReader { geo in
            let layout = layoutItems(in: geo.size)
            let _ = applyResolutionCaps(layout)
            ZStack(alignment: .topLeading) {
                ForEach(layout, id: \.item.id) { item, rect in
                    VideoCell(
                        item: item,
                        fill: isZoomed ? false : fillMode,
                        isSoloed: manager.soloItemID == item.id,
                        onRemove: { manager.remove(item) },
                        onSolo: isZoomed ? nil : { manager.toggleSolo(item) },
                        onZoom: { manager.toggleZoom(item) }
                    )
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .animation(.easeInOut(duration: 0.2), value: manager.items.count)
            .animation(.easeInOut(duration: 0.2), value: fillMode)
        }
    }

    private var controlBar: some View {
        HStack(spacing: 14) {
            Button { manager.openVideos() } label: {
                Image(systemName: "plus")
            }
            .help("동영상 추가")

            Button { manager.togglePlayAll() } label: {
                Image(systemName: manager.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(manager.items.isEmpty)
            .help(manager.isPlaying ? "모두 일시정지" : "모두 재생")

            Button { manager.loopEnabled.toggle() } label: {
                Image(systemName: "repeat")
                    .foregroundStyle(manager.loopEnabled ? Color.accentColor : Color.secondary)
            }
            .keyboardShortcut("l", modifiers: [])
            .help(manager.loopEnabled ? "반복재생 끄기 (L)" : "반복재생 켜기 (L)")

            Button { manager.seekAll(to: manager.progress) } label: {
                Image(systemName: "clock.arrow.2.circlepath")
            }
            .keyboardShortcut("s", modifiers: [])
            .disabled(manager.items.isEmpty)
            .help("모든 영상을 전체 타임라인 위치로 동기화 (S)")

            GlobalSeekSlider(manager: manager, progress: manager.progressModel)
                .disabled(manager.items.isEmpty)

            Button {
                fillMode.toggle()
            } label: {
                Image(systemName: fillMode ? "aspectratio.fill" : "aspectratio")
            }
            .keyboardShortcut("a", modifiers: [])
            .help(fillMode ? "원본 비율로 보기 (A)" : "화면 꽉 채우기 (A)")

            Button {
                NSApp.keyWindow?.toggleFullScreen(nil)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .keyboardShortcut("f", modifiers: [])
            .help("전체화면 (F)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private struct GlobalSeekSlider: View {
        let manager: PlayerManager
        @ObservedObject var progress: PlaybackProgress

        var body: some View {
            Slider(
                value: Binding(
                    get: { progress.fraction },
                    set: { manager.seekAll(to: $0) }
                ),
                in: 0...1
            ) { editing in
                manager.isScrubbing = editing
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handled = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil)
                else { return }
                DispatchQueue.main.async {
                    manager.add(urls: [url])
                }
            }
        }
        return handled
    }
}
