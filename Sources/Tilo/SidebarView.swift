import SwiftUI
import AppKit

private enum SidebarTab: String {
    case playlist
    case inspector
}

/// 재생목록과 선택 영상 설정을 한 패널에 모은 작업 사이드바.
struct SidebarView: View {
    @EnvironmentObject var manager: PlayerManager
    @AppStorage("sidebarTab") private var tab = SidebarTab.playlist.rawValue

    var body: some View {
        VStack(spacing: 0) {
            Picker("사이드바", selection: $tab) {
                Label("재생목록", systemImage: "list.bullet").tag(SidebarTab.playlist.rawValue)
                Label("선택 영상", systemImage: "slider.horizontal.3").tag(SidebarTab.inspector.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if tab == SidebarTab.inspector.rawValue {
                InspectorView()
            } else {
                PlaylistView()
            }
        }
        .frame(width: 300)
        .background(.regularMaterial)
        .onChange(of: manager.selectedItemID) { selected in
            if selected != nil { tab = SidebarTab.inspector.rawValue }
        }
    }
}

private struct InspectorView: View {
    @EnvironmentObject var manager: PlayerManager

    var body: some View {
        if let item = manager.selectedItem {
            SelectedVideoInspector(item: item)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "cursorarrow.click")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text("설정할 영상을 선택하세요")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct SelectedVideoInspector: View {
    @EnvironmentObject var manager: PlayerManager
    @ObservedObject var item: VideoItem

    private var offsetLabel: String {
        abs(item.timeOffset) < 0.001 ? "±0.0s" : String(format: "%+.1fs", item.timeOffset)
    }

    private var resolutionLabel: String {
        guard item.pixelSize.width > 0, item.pixelSize.height > 0 else { return "—" }
        return "\(Int(item.pixelSize.width.rounded())) × \(Int(item.pixelSize.height.rounded()))"
    }

    private var frameRateLabel: String {
        item.nominalFrameRate > 0 ? String(format: "%.2f fps", item.nominalFrameRate) : "—"
    }

    private var fileSizeLabel: String {
        let size = (try? item.sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size > 0
            ? ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            : "—"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.sourceURL.lastPathComponent)
                        .font(.headline)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(item.sourceURL.deletingLastPathComponent().path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.sourceURL.path)
                    Button("Finder에서 보기") {
                        NSWorkspace.shared.activateFileViewerSelecting([item.sourceURL])
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }

                inspectorSection("미디어 정보") {
                    LabeledContent("형식", value: item.sourceURL.pathExtension.uppercased())
                    LabeledContent("재생 엔진", value: item.backendKind.displayName)
                    LabeledContent("해상도", value: resolutionLabel)
                    LabeledContent("프레임률", value: frameRateLabel)
                    LabeledContent("길이", value: item.mediaReady ? timeString(item.durationSeconds) : "—")
                    LabeledContent("파일 크기", value: fileSizeLabel)
                }

                inspectorSection("오디오") {
                    if !item.mediaOptionsLoaded {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("소리 정보를 불러오는 중…")
                                .foregroundStyle(.secondary)
                        }
                    } else if !item.audioTrackOptions.isEmpty {
                        Picker(
                            "재생할 소리",
                            selection: Binding(
                                get: { item.selectedAudioTrackIndex },
                                set: { item.selectedAudioTrackIndex = $0 }
                            )
                        ) {
                            Text("자동 선택").tag(nil as Int?)
                            ForEach(item.audioTrackOptions) { option in
                                Text(verbatim: option.displayName).tag(Optional(option.index))
                            }
                        }
                        .pickerStyle(.menu)
                    } else if !item.hasAudio {
                        Text("이 영상에는 소리가 없습니다")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Group {
                        Toggle("이 영상만 듣기", isOn: Binding(
                            get: { manager.soloItemID == item.id },
                            set: { enabled in
                                if enabled != (manager.soloItemID == item.id) {
                                    manager.toggleSolo(item)
                                }
                            }
                        ))
                        Toggle("음소거", isOn: $item.isMuted)
                        HStack {
                            Text("볼륨")
                            Slider(value: $item.volume, in: 0...1)
                            Text("\(Int(item.volume * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 36, alignment: .trailing)
                        }
                    }
                    .disabled(!item.hasAudio)
                }

                inspectorSection("자막") {
                    if !manager.subtitlesEnabled {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("전체 자막이 꺼져 있습니다")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("전체 자막 켜기") { manager.subtitlesEnabled = true }
                                .buttonStyle(.link)
                        }
                    }

                    if !item.mediaOptionsLoaded {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("자막 정보를 불러오는 중…")
                                .foregroundStyle(.secondary)
                        }
                    } else if item.externalSubtitleName == nil && item.subtitleTrackOptions.isEmpty {
                        Text("이 영상에는 사용할 수 있는 자막이 없습니다")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker(
                            "표시할 자막",
                            selection: Binding(
                                get: { item.subtitleTrackSelection },
                                set: { selection in
                                    item.subtitleTrackSelection = selection
                                    if selection != .off { manager.subtitlesEnabled = true }
                                }
                            )
                        ) {
                            Text("자동 선택").tag(SubtitleTrackSelection.automatic)
                            Text("끄기").tag(SubtitleTrackSelection.off)
                            if let name = item.externalSubtitleName {
                                Text(String(localized: "별도 파일 자막 · \(name)"))
                                    .tag(SubtitleTrackSelection.external)
                            }
                            ForEach(item.subtitleTrackOptions) { option in
                                Text(String(localized: "영상에 포함된 자막 · \(option.displayName)"))
                                    .tag(SubtitleTrackSelection.embedded(option.index))
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    HStack {
                        Text("자막 크기")
                        Slider(value: $manager.subtitleScale, in: 0.5...2, step: 0.1)
                        Text("\(Int((manager.subtitleScale * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                    if abs(manager.subtitleScale - 1) > 0.001 {
                        Button("기본 크기") { manager.subtitleScale = 1 }
                            .buttonStyle(.link)
                    }

                    Text("자막은 현재 영상 내보내기에 포함되지 않습니다")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                inspectorSection("시간 정렬") {
                    HStack {
                        Button { manager.adjustOffset(item, by: -0.1) } label: {
                            Image(systemName: "minus")
                        }
                        Text(offsetLabel)
                            .font(.callout.monospacedDigit())
                            .frame(maxWidth: .infinity)
                        Button { manager.adjustOffset(item, by: 0.1) } label: {
                            Image(systemName: "plus")
                        }
                    }
                    if abs(item.timeOffset) > 0.001 {
                        Button("정렬 초기화") { manager.resetOffset(item) }
                            .buttonStyle(.link)
                    }
                }

                inspectorSection("화면") {
                    HStack {
                        Text("확대")
                        Slider(
                            value: Binding(
                                get: { Double(item.zoomScale) },
                                set: { manager.setZoom(item, to: CGFloat($0)) }
                            ),
                            in: 1...6
                        )
                        Text(String(format: "%.1f×", item.zoomScale))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                    Button("90° 회전") { manager.rotate(item) }
                    if item.isReframed {
                        Button("확대·이동 초기화") {
                            item.resetReframe()
                            manager.markProjectEdited()
                        }
                    }
                }

                Divider()

                Button("영상 제거", role: .destructive) {
                    manager.remove(item)
                }
            }
            .font(.callout)
            .padding(14)
        }
    }

    @ViewBuilder
    private func inspectorSection<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }
}
