import AppKit
import SwiftUI

private let browseRowHeight: CGFloat = 84
private let browseGridArtworkSize: CGFloat = 172
private let browseGridCardHeight: CGFloat = 286

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            BrowserView()
        }
        .navigationSplitViewStyle(.balanced)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayerBar()
        }
        .overlay(alignment: .top) {
            if let error = model.errorState {
                ErrorBanner(error: error) {
                    model.errorState = nil
                }
                .padding(.top, 14)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    model.goBack()
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .disabled((model.browsePage?.list.level ?? 0) == 0)

                Button {
                    model.openHierarchy(model.selectedHierarchy)
                } label: {
                    Image(systemName: "house")
                }

                Button {
                    model.refreshBrowse()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }

            ToolbarItem(placement: .principal) {
                ConnectionStatusPill()
            }

            ToolbarItem(placement: .automatic) {
                SearchToolbarField()
            }
        }
        .onAppear {
            model.start()
        }
    }
}

private struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section("Library") {
                ForEach(BrowseHierarchy.sidebarCases) { hierarchy in
                    SidebarRow(
                        title: hierarchy.title,
                        icon: iconName(for: hierarchy),
                        isSelected: hierarchy == model.selectedHierarchy
                    ) {
                        model.openHierarchy(hierarchy)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .controlBackgroundColor))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.connectionStatus.summary)
                    .font(.callout.weight(.semibold))
                Text(model.helperStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial)
            .overlay(alignment: .top) {
                Divider()
            }
        }
    }

    private func iconName(for hierarchy: BrowseHierarchy) -> String {
        switch hierarchy {
        case .browse: "square.grid.2x2"
        case .playlists: "music.note.list"
        case .albums: "rectangle.stack"
        case .artists: "music.mic"
        case .genres: "guitars"
        case .composers: "music.quarternote.3"
        case .internetRadio: "dot.radiowaves.left.and.right"
        case .search: "magnifyingglass"
        }
    }
}

private struct BrowserView: View {
    @Environment(AppModel.self) private var model
    @State private var promptText = ""

    var body: some View {
        VStack(spacing: 0) {
            BrowserHeader()

            if model.selectedHierarchy != .search,
               let promptItem = model.browsePromptItem {
                SearchPromptRow(
                    item: promptItem,
                    text: $promptText
                ) {
                    model.submitPrompt(for: promptItem, value: promptText)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 18)
            }

            if let page = model.browsePage {
                ScrollView {
                    if usesDenseGrid(for: page) {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 170, maximum: 210), spacing: 18)],
                            spacing: 18
                        ) {
                            ForEach(0..<page.list.count, id: \.self) { index in
                                BrowseGridSlot(index: index)
                                    .onAppear {
                                        model.ensureBrowseItemsLoaded(for: index)
                                    }
                            }
                        }
                        .padding(.horizontal, 22)
                        .padding(.bottom, 28)
                    } else {
                        LazyVStack(spacing: 1) {
                            ForEach(0..<page.list.count, id: \.self) { index in
                                BrowseRowSlot(index: index)
                                .onAppear {
                                    model.ensureBrowseItemsLoaded(for: index)
                                }
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.bottom, 28)
                    }
                }
                .background(Color(nsColor: .windowBackgroundColor))
            } else {
                ContentUnavailableView(
                    "No Library Content",
                    systemImage: "music.note.house",
                    description: Text("Connect to a Roon Core to browse the library.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func usesDenseGrid(for page: BrowsePage) -> Bool {
        let title = page.list.title.lowercased()
        return title == "albums" || title == "artists"
    }
}

private struct BrowseRowSlot: View {
    @Environment(AppModel.self) private var model
    let index: Int

    var body: some View {
        if let item = model.browseItem(at: index) {
            BrowserRow(item: item) {
                if item.inputPrompt == nil {
                    model.openItem(item)
                }
            }
        } else {
            BrowserRowPlaceholder()
        }
    }
}

private struct BrowseGridSlot: View {
    @Environment(AppModel.self) private var model
    let index: Int

    var body: some View {
        if let item = model.browseItem(at: index) {
            BrowserGridCard(item: item)
        } else {
            BrowserGridCardPlaceholder()
        }
    }
}

private struct SearchToolbarField: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search Library", text: $model.searchText)
                .textFieldStyle(.plain)
                .frame(width: 220)
                .onSubmit {
                    model.runSearch()
                }

            if model.searchText.isEmpty == false {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .frame(minWidth: 220)
    }
}

private struct BrowserHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.browsePage?.list.title ?? model.selectedHierarchy.title)
                    .font(.system(size: 30, weight: .semibold, design: .default))
                HStack(spacing: 8) {
                    if let subtitle = model.browsePage?.list.subtitle, subtitle.isEmpty == false {
                        Text(subtitle)
                    } else if let count = model.browsePage?.list.count {
                        Text("\(count) items")
                    }

                    if let core = model.currentCore {
                        Text("on \(core.displayName)")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .padding(.bottom, 18)
    }
}

private struct MiniPlayerBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 20) {
                if let nowPlaying = model.selectedZone?.nowPlaying {
                    HStack(spacing: 14) {
                        ArtworkView(
                            imageKey: nowPlaying.imageKey,
                            title: nowPlaying.title,
                            size: CGSize(width: 52, height: 52)
                        )

                        VStack(alignment: .leading, spacing: 3) {
                            Text(nowPlaying.title)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                            Text(nowPlaying.subtitle ?? nowPlaying.detail ?? " ")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(model.selectedZone?.state.capitalized ?? " ")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(width: 220, alignment: .leading)
                    }
                } else {
                    Label("Nothing Playing", systemImage: "music.note")
                        .foregroundStyle(.secondary)
                        .frame(width: 286, alignment: .leading)
                }

                Spacer(minLength: 24)

                MiniPlayerTransportSection()

                Spacer(minLength: 24)

                HStack(spacing: 12) {
                    VStack(alignment: .trailing, spacing: 10) {
                        Picker("Zone", selection: Binding(
                            get: { model.selectedZoneID ?? "" },
                            set: { zoneID in
                                model.selectedZoneID = zoneID.isEmpty ? nil : zoneID
                                model.refreshBrowse()
                            }
                        )) {
                            ForEach(model.zones) { zone in
                                Text(zone.displayName).tag(zone.zoneID)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 200)

                        MiniPlayerVolumeControl()
                            .frame(width: 200, alignment: .trailing)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.regularMaterial)
        }
    }
}

private struct MiniPlayerTransportSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            MiniPlayerProgressSection()

            HStack(spacing: 14) {
                MiniPlayerButton(systemName: "backward.fill", enabled: model.selectedZone?.capabilities.canPrevious == true) {
                    model.transport(.previous)
                }
                MiniPlayerButton(
                    systemName: "playpause.fill",
                    enabled: (model.selectedZone?.capabilities.canPlayPause == true) ||
                        ((model.selectedZone?.capabilities.canPlay == true) && (model.selectedZone?.capabilities.canPause == true))
                ) {
                    model.transport(.playPause)
                }
                MiniPlayerButton(systemName: "forward.fill", enabled: model.selectedZone?.capabilities.canNext == true) {
                    model.transport(.next)
                }
            }
        }
        .frame(width: 460)
    }
}

private struct MiniPlayerProgressSection: View {
    @Environment(AppModel.self) private var model
    @State private var isScrubbing = false
    @State private var scrubValue = 0.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: {
                            if isScrubbing {
                                return scrubValue
                            }
                            return resolvedSeekPosition(at: context.date)
                        },
                        set: { newValue in
                            scrubValue = newValue
                        }
                    ),
                    in: 0...max(trackLength, 1),
                    onEditingChanged: { editing in
                        isScrubbing = editing
                        if editing == false {
                            model.seek(to: scrubValue)
                        }
                    }
                )
                .disabled(model.selectedZone?.capabilities.canSeek != true || trackLength <= 0)

                HStack {
                    Text(formatTime(isScrubbing ? scrubValue : resolvedSeekPosition(at: context.date)))
                    Spacer()
                    Text(formatTime(trackLength))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .onAppear {
                syncScrubValue()
            }
            .onChange(of: model.selectedZone?.zoneID) { _, _ in
                syncScrubValue()
            }
            .onChange(of: model.selectedZone?.nowPlaying?.seekPosition) { _, _ in
                if isScrubbing == false {
                    syncScrubValue()
                }
            }
            .onChange(of: model.selectedZone?.nowPlaying?.length) { _, _ in
                if isScrubbing == false {
                    syncScrubValue()
                }
            }
        }
    }

    private var trackLength: Double {
        model.selectedZone?.nowPlaying?.length ?? 0
    }

    private func resolvedSeekPosition(at date: Date) -> Double {
        min(max(0, model.displayedSeekPosition(at: date) ?? 0), max(trackLength, 1))
    }

    private func syncScrubValue() {
        scrubValue = min(max(0, model.displayedSeekPosition() ?? 0), max(trackLength, 1))
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else {
            return "--:--"
        }
        let total = max(0, Int(seconds.rounded(.down)))
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}

private struct MiniPlayerVolumeControl: View {
    @Environment(AppModel.self) private var model
    @State private var isEditing = false
    @State private var volumeValue = 0.0

    var body: some View {
        if let output = model.selectedVolumeOutput, let volume = output.volume {
            if volume.supportsSlider {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Slider(
                        value: Binding(
                            get: { isEditing ? volumeValue : (output.volume?.value ?? volumeValue) },
                            set: { newValue in
                                volumeValue = newValue
                                model.setVolume(newValue)
                            }
                        ),
                        in: (volume.min ?? 0)...(volume.max ?? 100),
                        onEditingChanged: { editing in
                            isEditing = editing
                            if editing == false {
                                model.setVolume(volumeValue, immediate: true)
                            }
                        }
                    )
                    .frame(width: 150)
                }
                .onAppear {
                    volumeValue = volume.value ?? volume.min ?? 0
                }
                .onChange(of: output.outputID) { _, _ in
                    if isEditing == false {
                        volumeValue = output.volume?.value ?? output.volume?.min ?? 0
                    }
                }
                .onChange(of: output.volume?.value) { _, newValue in
                    if isEditing == false {
                        volumeValue = newValue ?? output.volume?.min ?? 0
                    }
                }
            } else if volume.supportsStepAdjustments {
                HStack(spacing: 6) {
                    Button {
                        model.stepVolume(by: -1)
                    } label: {
                        Image(systemName: "speaker.minus.fill")
                    }
                    .buttonStyle(.borderless)

                    Button {
                        model.stepVolume(by: 1)
                    } label: {
                        Image(systemName: "speaker.plus.fill")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Form {
            TextField("Host", text: $model.manualConnect.host)
            TextField("Port", value: $model.manualConnect.port, format: .number)
            Toggle("Use mock bridge", isOn: $model.isUsingMockBridge)
                .disabled(true)
            Text("The app launches the bundled helper when present, or falls back to an in-process mock bridge for UI development.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

private struct SidebarRow: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : .clear)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct ZoneRow: View {
    let zone: ZoneSummary
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(zone.displayName)
                        .font(.system(size: 13, weight: .medium))
                    Text(zone.nowPlaying?.title ?? zone.state.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : .clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var statusColor: Color {
        switch zone.state {
        case "playing":
            .green
        case "paused":
            .orange
        default:
            .secondary
        }
    }
}

private struct BrowserRow: View {
    @Environment(AppModel.self) private var model
    let item: BrowseItem
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: action) {
                HStack(spacing: 14) {
                    ArtworkView(
                        imageKey: item.imageKey,
                        title: item.title,
                        size: CGSize(width: 48, height: 48)
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.primary)
                        if let subtitle = item.subtitle, subtitle.isEmpty == false {
                            Text(subtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)

            PlaybackAffordances(item: item)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .frame(height: browseRowHeight)
        .contextMenu {
            if item.itemKey != nil {
                Button("Open", action: action)
            }
            Button("Play Now") {
                model.performPreferredAction(for: item, preferredActionTitles: ["Play Now"])
            }
            Button("Add Next") {
                model.performPreferredAction(for: item, preferredActionTitles: ["Add Next"])
            }
            Button("Queue") {
                model.performPreferredAction(for: item, preferredActionTitles: ["Queue"])
            }
        }
    }
}

private struct BrowserGridCard: View {
    @Environment(AppModel.self) private var model
    let item: BrowseItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                if item.inputPrompt == nil {
                    model.openItem(item)
                }
            } label: {
                ArtworkView(
                    imageKey: item.imageKey,
                    title: item.title,
                    size: CGSize(width: browseGridArtworkSize, height: browseGridArtworkSize)
                )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .top, spacing: 10) {
                Button {
                    if item.inputPrompt == nil {
                        model.openItem(item)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if let subtitle = item.subtitle, subtitle.isEmpty == false {
                            Text(subtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                PlaybackAffordances(item: item)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .frame(height: browseGridCardHeight)
    }
}

private struct BrowserRowPlaceholder: View {
    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .tertiarySystemFill))
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(nsColor: .tertiarySystemFill))
                    .frame(width: 180, height: 14)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(nsColor: .quaternarySystemFill))
                    .frame(width: 120, height: 12)
            }

            Spacer(minLength: 0)

            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .tertiarySystemFill))
                .frame(width: 24, height: 52)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .frame(height: browseRowHeight)
        .redacted(reason: .placeholder)
    }
}

private struct BrowserGridCardPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .tertiarySystemFill))
                .frame(width: browseGridArtworkSize, height: browseGridArtworkSize)

            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(nsColor: .tertiarySystemFill))
                        .frame(height: 14)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(nsColor: .quaternarySystemFill))
                        .frame(width: 110, height: 12)
                }
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .tertiarySystemFill))
                    .frame(width: 24, height: 52)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .frame(height: browseGridCardHeight)
        .redacted(reason: .placeholder)
    }
}

private struct SearchPromptRow: View {
    let item: BrowseItem
    @Binding var text: String
    let submit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(item.inputPrompt?.prompt ?? "Search", text: $text)
                .textFieldStyle(.plain)
            Button(item.inputPrompt?.action ?? "Go", action: submit)
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

private struct ConnectionStatusPill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(model.connectionStatus.summary)
                .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var statusColor: Color {
        switch model.connectionStatus {
        case .connected:
            .green
        case .connecting, .authorizing:
            .orange
        case .error:
            .red
        case .disconnected:
            .secondary
        }
    }
}

private struct ArtworkView: View {
    @Environment(AppModel.self) private var model
    let imageKey: String?
    let title: String
    let size: CGSize

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(nsColor: .quaternaryLabelColor),
                                Color(nsColor: .tertiarySystemFill)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: max(16, size.width * 0.3), weight: .medium))
                            .foregroundStyle(.white.opacity(0.88))
                    }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: imageKey) {
            image = await model.loadArtwork(
                imageKey: imageKey,
                width: Int(size.width * 2),
                height: Int(size.height * 2)
            )
        }
        .accessibilityLabel(title)
    }
}

private struct MiniPlayerButton: View {
    let systemName: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary : Color.secondary)
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
    }
}

private struct PlaybackAffordances: View {
    @Environment(AppModel.self) private var model
    let item: BrowseItem

    var body: some View {
        VStack(spacing: 4) {
            Button {
                model.performPreferredAction(for: item, preferredActionTitles: ["Play Now"])
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(item.itemKey == nil ? Color.secondary : Color.primary)
            .disabled(item.itemKey == nil)

            Menu {
                Button("Play Now") {
                    model.performPreferredAction(for: item, preferredActionTitles: ["Play Now"])
                }
                Button("Add Next") {
                    model.performPreferredAction(for: item, preferredActionTitles: ["Add Next"])
                }
                Button("Queue") {
                    model.performPreferredAction(for: item, preferredActionTitles: ["Queue"])
                }
                Button("Start Radio") {
                    model.performPreferredAction(for: item, preferredActionTitles: ["Start Radio"])
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .disabled(item.itemKey == nil)
        }
    }
}

private struct ErrorBanner: View {
    @Environment(AppModel.self) private var model
    let error: ErrorState
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 4) {
                Text(error.title)
                    .font(.headline)
                Text(error.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.autoConnectionIssue != nil {
                Button("Settings") {
                    model.openSettings()
                }
            }
            Button("Dismiss", action: dismiss)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(radius: 8, y: 2)
        .frame(maxWidth: 560)
    }
}
