import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var manager: PlayerManager
    @AppStorage("fillMode") private var fillMode = true
    @AppStorage("playlistVisible") private var playlistVisible = true
    @AppStorage("gridColumns") private var gridColumns = 0 // 0 = 자동 모자이크
    @State private var controlsVisible = true
    @State private var overControls = false
    @State private var dropTargeted = false
    @State private var showShortcuts = false
    @State private var hideTimer = AutoHideTimer()

    /// 일시정지 중이거나 영상이 없거나 컨트롤 바 위에 마우스가 있으면 숨기지 않는다
    private var showControls: Bool {
        controlsVisible || !manager.isPlaying || manager.items.isEmpty || overControls
    }

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                if manager.items.isEmpty {
                    emptyState
                } else {
                    videoGrid
                }
                controlBar
                    .opacity(showControls ? 1 : 0)
                    .allowsHitTesting(showControls)
                    .animation(.easeInOut(duration: 0.25), value: showControls)
                    .onHover { overControls = $0 }
            }
            .onContinuousHover { _ in bumpActivity() }
            .overlay(alignment: .top) {
                VStack(spacing: 6) {
                    if !manager.remuxing.isEmpty {
                        let status = manager.remuxing
                            .sorted { $0.key < $1.key }
                            .map { "\($0.key) \($0.value)%" }
                            .joined(separator: ", ")
                        toast(String(localized: "MP4로 변환 중: \(status)"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    if let notice = manager.notice {
                        toast(notice, systemImage: "exclamationmark.triangle")
                    }
                }
                .padding(.top, 14)
                .animation(.easeInOut(duration: 0.2), value: manager.remuxing)
                .animation(.easeInOut(duration: 0.2), value: manager.notice)
            }

            if playlistVisible {
                Divider()
                PlaylistView()
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: playlistVisible)
        .background(Color.black)
        .background(hiddenShortcuts)
        .overlay {
            if dropTargeted {
                dropHighlight
            }
        }
        .animation(.easeInOut(duration: 0.15), value: dropTargeted)
        .overlay {
            if showShortcuts { shortcutsOverlay }
        }
        .animation(.easeInOut(duration: 0.15), value: showShortcuts)
        .preferredColorScheme(.dark)
        .onChange(of: manager.isPlaying) { playing in
            if playing { scheduleHide() }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            // 실행 시 파일 인자가 없으면 마지막 세션을 복원
            manager.restoreSession()
        }
    }

    private var shortcutsOverlay: some View {
        let rows: [(String, String)] = [
            ("Space", String(localized: "재생 / 일시정지")),
            ("← / →", String(localized: "5초 뒤로 / 앞으로")),
            ("⇧← / ⇧→", String(localized: "30초 뒤로 / 앞으로")),
            (", / .", String(localized: "이전 / 다음 프레임")),
            ("0–9", String(localized: "타임라인 0–90%로 점프")),
            ("L", String(localized: "반복재생")),
            ("R", String(localized: "구간반복 (A→B→해제)")),
            ("M", String(localized: "전체 음소거")),
            ("S", String(localized: "모든 영상 동기화")),
            ("A", String(localized: "꽉 채우기 / 원본 비율")),
            ("C", String(localized: "자막")),
            ("P", String(localized: "재생목록")),
            ("F", String(localized: "전체화면")),
            ("⇧⌘S", String(localized: "스냅샷 저장")),
            ("Esc", String(localized: "확대 해제")),
            ("?", String(localized: "이 도움말")),
        ]
        return ZStack {
            Color.black.opacity(0.55).onTapGesture { showShortcuts = false }
            VStack(alignment: .leading, spacing: 10) {
                Text("키보드 단축키").font(.title3.bold())
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                    ForEach(rows, id: \.0) { key, desc in
                        GridRow {
                            Text(key).font(.callout.monospaced().bold())
                                .frame(minWidth: 70, alignment: .leading)
                            Text(desc).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .allowsHitTesting(true)
    }

    private var dropHighlight: some View {
        ZStack {
            Color.black.opacity(0.4)
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 40))
                Text("여기에 놓아 추가")
                    .font(.headline)
            }
            .foregroundStyle(Color.accentColor)
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [10, 6]))
                .padding(10)
        }
        .allowsHitTesting(false)
    }

    private func toast(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .lineLimit(2)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .transition(.opacity)
    }

    /// 마우스가 움직이면 컨트롤 바를 보여주고 숨김 타이머를 다시 건다
    private func bumpActivity() {
        if !controlsVisible { controlsVisible = true }
        // 마우스 이벤트마다 Task를 만들지 않도록 0.4초 간격으로만 갱신
        guard Date().timeIntervalSince(hideTimer.lastSchedule) > 0.4 else { return }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTimer.lastSchedule = Date()
        hideTimer.task?.cancel()
        hideTimer.task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            if manager.isPlaying, !overControls, !manager.isScrubbing {
                controlsVisible = false
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 22) {
            Image(systemName: "play.square.stack")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.tertiary)

            VStack(spacing: 6) {
                Text("Tilo")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("여러 영상을 한 화면에서 동시에 재생합니다")
                    .foregroundStyle(.secondary)
            }

            Button {
                manager.openVideos()
            } label: {
                Label("동영상 열기", systemImage: "folder")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("또는 동영상 파일이나 폴더를 창에 끌어다 놓으세요")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isZoomed: Bool { manager.zoomedItemID != nil }

    /// 메뉴에 넣기 애매한 단축키만 보이지 않는 버튼으로 등록
    /// (나머지는 메뉴바 파일/재생/보기 메뉴가 소유한다)
    private var hiddenShortcuts: some View {
        Group {
            Button("") {
                if showShortcuts {
                    showShortcuts = false
                } else if let zoomed = manager.items.first(where: { $0.id == manager.zoomedItemID }) {
                    manager.toggleZoom(zoomed)
                }
            }
            .keyboardShortcut(.escape, modifiers: [])
            Button("") { showShortcuts.toggle() }
                .keyboardShortcut("/", modifiers: .shift) // "?"
            ForEach(0..<10, id: \.self) { digit in
                Button("") { manager.seekAll(to: Double(digit) / 10) }
                    .keyboardShortcut(KeyEquivalent(Character("\(digit)")), modifiers: [])
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    /// 확대 모드면 그 영상 하나가 전체를, 아니면 수동 그리드/모자이크/저스티파이드 배치
    private func layoutItems(in size: CGSize) -> [(item: VideoItem, rect: CGRect)] {
        if let zoomed = manager.items.first(where: { $0.id == manager.zoomedItemID }) {
            return [(zoomed, CGRect(origin: .zero, size: size))]
        }
        let rects: [UUID: CGRect]
        if gridColumns > 0 {
            // 수동 균일 그리드 (영상 추가 순서대로)
            let grid = uniformGrid(count: manager.items.count, columns: gridColumns, in: size)
            rects = Dictionary(uniqueKeysWithValues: zip(manager.items.map { $0.id }, grid))
        } else {
            let entries = manager.items.map { GridLayout.Entry(id: $0.id, aspect: $0.displayAspect) }
            let cells = fillMode
                ? MosaicLayout.cells(for: entries, in: size)
                : GridLayout.cells(for: entries, in: size)
            rects = Dictionary(uniqueKeysWithValues: cells.map { ($0.id, $0.rect) })
        }
        // 드래그로 맞바꾼 자리를 적용한다
        return manager.items.compactMap { item in
            let slotID = manager.rectSwaps[item.id] ?? item.id
            return rects[slotID].map { (item, $0) }
        }
    }

    /// 영상 개수와 열 수로 균일 격자 사각형들을 만든다 (마지막 줄은 남는 칸 비움)
    private func uniformGrid(count: Int, columns: Int, in size: CGSize) -> [CGRect] {
        guard count > 0 else { return [] }
        let cols = max(1, min(columns, count))
        let rows = Int((Double(count) / Double(cols)).rounded(.up))
        let cw = size.width / CGFloat(cols)
        let ch = size.height / CGFloat(rows)
        return (0..<count).map { i in
            CGRect(x: CGFloat(i % cols) * cw, y: CGFloat(i / cols) * ch, width: cw, height: ch)
        }
    }

    /// 타일 크기(레티나 ×2)에 맞춰 각 영상의 디코딩 해상도를 제한한다.
    /// 적용은 매니저 쪽에서 디바운스된다.
    private func applyResolutionCaps(_ layout: [(item: VideoItem, rect: CGRect)]) {
        let scale: CGFloat = 2
        let sizes = Dictionary(uniqueKeysWithValues: layout.map {
            ($0.item.id, CGSize(width: $0.rect.width * scale, height: $0.rect.height * scale))
        })
        manager.scheduleResolutionCaps(sizes)
    }

    /// 배치에 영향을 주는 요소들의 해시. 창 크기는 제외해서
    /// 리사이즈 중에는 애니메이션이 끼어들지 않게 한다.
    private var layoutKey: Int {
        var hasher = Hasher()
        hasher.combine(fillMode)
        hasher.combine(gridColumns)
        hasher.combine(manager.zoomedItemID)
        for item in manager.items {
            hasher.combine(item.id)
            hasher.combine(Int(item.displayAspect * 64))
            hasher.combine(item.rotationQuarters)
            hasher.combine(manager.rectSwaps[item.id])
        }
        return hasher.finalize()
    }

    private var videoGrid: some View {
        GeometryReader { geo in
            let layout = layoutItems(in: geo.size)
            let _ = applyResolutionCaps(layout)
            let _ = manager.recordLayout(
                rects: Dictionary(uniqueKeysWithValues: layout.map { ($0.item.id, $0.rect) }),
                canvas: geo.size,
                fill: isZoomed ? false : fillMode
            )
            ZStack(alignment: .topLeading) {
                ForEach(layout, id: \.item.id) { item, rect in
                    VideoCell(
                        item: item,
                        fill: isZoomed ? false : fillMode,
                        isSoloed: manager.soloItemID == item.id,
                        showSubtitles: manager.subtitlesEnabled,
                        onRemove: { manager.remove(item) },
                        onSolo: isZoomed ? nil : { manager.toggleSolo(item) },
                        onZoom: { manager.toggleZoom(item) },
                        onRotate: { manager.rotate(item) },
                        onOffset: { manager.adjustOffset(item, by: $0) },
                        onResetOffset: { manager.resetOffset(item) }
                    )
                    .onDrag {
                        manager.draggingItemID = item.id
                        return NSItemProvider(object: item.id.uuidString as NSString)
                    } preview: {
                        // 셀 전체 스냅샷 대신 작은 카드가 커서를 따라다닌다
                        HStack(spacing: 6) {
                            Image(systemName: "film")
                            Text(item.sourceURL.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: 200)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .onDrop(of: [.plainText], delegate: SwapDropDelegate(targetID: item.id, manager: manager))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .animation(.easeInOut(duration: 0.25), value: layoutKey)
        }
    }

    private var barDivider: some View {
        Divider().frame(height: 18).padding(.horizontal, 3)
    }

    private var controlBar: some View {
        HStack(spacing: 2) {
            ControlIconButton(icon: "plus", helpText: "동영상 추가 (⌘O)") {
                manager.openVideos()
            }

            barDivider

            ControlIconButton(
                icon: manager.isPlaying ? "pause.fill" : "play.fill",
                diameter: 38,
                fontSize: 17,
                helpText: manager.isPlaying ? "모두 일시정지 (Space)" : "모두 재생 (Space)"
            ) {
                manager.togglePlayAll()
            }
            .disabled(manager.items.isEmpty)

            barDivider

            GlobalSeekSlider(
                manager: manager,
                progress: manager.progressModel,
                markA: manager.abA,
                markB: manager.abB
            )
            .disabled(manager.items.isEmpty)
            .padding(.horizontal, 6)

            barDivider

            VolumeButton(manager: manager)

            barDivider

            ControlIconButton(
                icon: "repeat",
                active: manager.loopEnabled,
                helpText: manager.loopEnabled ? "반복재생 끄기 (L)" : "반복재생 켜기 (L)"
            ) {
                manager.loopEnabled.toggle()
            }

            ControlIconButton(
                text: "AB",
                tint: manager.abB != nil ? .accentColor : manager.abA != nil ? .orange : nil,
                helpText: manager.abA == nil ? "구간반복: 시작점 설정 (R)"
                    : manager.abB == nil ? "구간반복: 끝점 설정 (R)"
                    : "구간반복 해제 (R)"
            ) {
                manager.cycleABLoop()
            }
            .disabled(manager.items.isEmpty)

            barDivider

            ControlIconButton(
                icon: manager.subtitlesEnabled ? "captions.bubble.fill" : "captions.bubble",
                active: manager.subtitlesEnabled,
                helpText: manager.subtitlesEnabled ? "자막 끄기 (C)" : "자막 켜기 (C)"
            ) {
                manager.subtitlesEnabled.toggle()
            }

            ControlIconButton(
                icon: fillMode ? "aspectratio.fill" : "aspectratio",
                active: fillMode,
                helpText: fillMode ? "원본 비율로 보기 (A)" : "화면 꽉 채우기 (A)"
            ) {
                fillMode.toggle()
            }

            barDivider

            ControlIconButton(
                icon: "sidebar.trailing",
                active: playlistVisible,
                helpText: "재생목록 (P)"
            ) {
                playlistVisible.toggle()
            }

            ControlIconButton(icon: "arrow.up.left.and.arrow.down.right", helpText: "전체화면 (F)") {
                NSApp.keyWindow?.toggleFullScreen(nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 760)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private struct VolumeButton: View {
        @ObservedObject var manager: PlayerManager
        @State private var showPopover = false

        private var icon: String {
            if manager.masterVolume <= 0.001 { return "speaker.slash.fill" }
            if manager.masterVolume < 0.5 { return "speaker.wave.1.fill" }
            return "speaker.wave.2.fill"
        }

        var body: some View {
            ControlIconButton(icon: icon, helpText: "볼륨") {
                showPopover.toggle()
            }
            .popover(isPresented: $showPopover, arrowEdge: .top) {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $manager.masterVolume, in: 0...1)
                        .frame(width: 140)
                    Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    private struct GlobalSeekSlider: View {
        let manager: PlayerManager
        @ObservedObject var progress: PlaybackProgress
        var markA: Double?
        var markB: Double?

        var body: some View {
            HStack(spacing: 10) {
                Slider(
                    value: Binding(
                        get: { progress.fraction },
                        set: { manager.seekAll(to: $0) }
                    ),
                    in: 0...1
                ) { editing in
                    manager.isScrubbing = editing
                    // 스크럽 중에는 키프레임 단위로 따라갔으므로 정밀 보정
                    if !editing { manager.seekAll(to: progress.fraction) }
                }
                .overlay {
                    // A-B 구간반복 지점 표시
                    GeometryReader { geo in
                        ForEach([markA, markB].compactMap { $0 }, id: \.self) { mark in
                            Rectangle()
                                .fill(Color.orange)
                                .frame(width: 2, height: 10)
                                .position(x: mark * geo.size.width, y: geo.size.height / 2)
                        }
                    }
                    .allowsHitTesting(false)
                }
                Text("\(timeString(progress.fraction * manager.maxDuration)) / \(timeString(manager.maxDuration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
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

/// 컨트롤 자동 숨김 타이머. 참조 타입이라 내용이 바뀌어도
/// 뷰를 다시 그리지 않는다.
final class AutoHideTimer {
    var task: Task<Void, Never>?
    var lastSchedule = Date.distantPast
}

/// 영상 타일을 다른 타일 위로 드래그하면 두 자리를 맞바꾼다.
/// 드래그 중 다른 타일에 들어서는 순간 실시간으로 교환된다.
private struct SwapDropDelegate: DropDelegate {
    let targetID: UUID
    let manager: PlayerManager

    func validateDrop(info: DropInfo) -> Bool {
        manager.draggingItemID != nil
    }

    func dropEntered(info: DropInfo) {
        guard let source = manager.draggingItemID, source != targetID else { return }
        manager.swapPositions(source, targetID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        manager.draggingItemID = nil
        return true
    }
}
