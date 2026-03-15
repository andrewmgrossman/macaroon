import AppKit
import SwiftUI

private let browseRowHeight: CGFloat = 84
private let browseGridArtworkSize: CGFloat = 172
private let browseGridCardHeight: CGFloat = 286
private let miniPlayerReservedHeight: CGFloat = 118
private let miniPlayerArtworkSize: CGFloat = 56
private let detailHeaderArtworkSize: CGFloat = 220
private let detailSectionSpacing: CGFloat = 26

private struct ResettableScrollContainer<Content: View>: View {
    @Environment(AppModel.self) private var model
    let identity: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            content()
                .background(
                    ScrollOffsetAccessory(
                        identity: identity,
                        restoredOffset: model.scrollOffset(for: identity)
                    ) { offset in
                        model.rememberScrollOffset(offset, for: identity)
                    }
                )
        }
    }
}

private struct ScrollOffsetAccessory: NSViewRepresentable {
    let identity: String
    let restoredOffset: CGFloat
    let onOffsetChanged: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollOffsetTrackingView {
        let view = ScrollOffsetTrackingView()
        view.onOffsetChanged = onOffsetChanged
        return view
    }

    func updateNSView(_ nsView: ScrollOffsetTrackingView, context: Context) {
        nsView.identity = identity
        nsView.restoredOffset = restoredOffset
        nsView.onOffsetChanged = onOffsetChanged
        nsView.attachIfNeeded()
        nsView.restoreIfNeeded()
    }

    static func dismantleNSView(_ nsView: ScrollOffsetTrackingView, coordinator: ()) {
        nsView.detach()
    }
}

private final class ScrollOffsetTrackingView: NSView {
    var identity = ""
    var restoredOffset: CGFloat = 0
    var onOffsetChanged: ((CGFloat) -> Void)?

    private weak var observedScrollView: NSScrollView?
    private weak var observedClipView: NSClipView?
    private var appliedIdentity: String?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.attachIfNeeded()
            self?.restoreIfNeeded()
        }
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil {
            detach()
        }
        super.viewWillMove(toSuperview: newSuperview)
    }

    func attachIfNeeded() {
        guard observedScrollView == nil, let scrollView = enclosingScrollView else {
            return
        }

        observedScrollView = scrollView
        observedClipView = scrollView.contentView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    func restoreIfNeeded() {
        guard let scrollView = observedScrollView else {
            return
        }
        guard appliedIdentity != identity else {
            return
        }

        appliedIdentity = identity

        DispatchQueue.main.async { [weak self, weak scrollView] in
            guard let self, let scrollView else {
                return
            }

            let documentHeight = scrollView.documentView?.bounds.height ?? 0
            let visibleHeight = scrollView.contentView.bounds.height
            let maximumOffset = max(documentHeight - visibleHeight, 0)
            let clampedOffset = min(max(0, self.restoredOffset), maximumOffset)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: clampedOffset))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            self.onOffsetChanged?(clampedOffset)
        }
    }

    func detach() {
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: observedClipView)
        observedClipView = nil
        observedScrollView = nil
    }

    @objc
    private func scrollBoundsDidChange(_ notification: Notification) {
        guard let clipView = notification.object as? NSClipView else {
            return
        }
        onOffsetChanged?(clipView.bounds.origin.y)
    }
}

private func formatDuration(_ seconds: Double) -> String {
    guard seconds.isFinite else {
        return "--:--"
    }
    let total = max(0, Int(seconds.rounded(.down)))
    let minutes = total / 60
    let secs = total % 60
    return String(format: "%d:%02d", minutes, secs)
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 150, ideal: 210, max: 280)
            } detail: {
                MainContentView()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationSplitViewStyle(.balanced)

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
        .simultaneousGesture(
            TapGesture().onEnded {
                clearToolbarSearchFocus()
            }
        )
        .onChange(of: model.dismissTransientUIRequestID) { _, _ in
            clearToolbarSearchFocus()
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
                    model.goForward()
                } label: {
                    Image(systemName: "chevron.forward")
                }
                .disabled(model.canGoForward == false)
            }

            if DebugLoggingConfiguration.isCompiled {
                ToolbarItem(placement: .automatic) {
                    ConnectionStatusPill()
                }
            }

            ToolbarItem(placement: .principal) {
                HStack {
                    Spacer()
                    SearchToolbarField()
                }
                .frame(maxWidth: .infinity)
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.toggleQueueSidebar()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(.bordered)
                .help(model.isQueueSidebarVisible ? "Hide Queue" : "Show Queue")
            }
        }
        .onAppear {
            model.start()
        }
    }
}

@MainActor
private func clearToolbarSearchFocus() {
    NSApp.keyWindow?.makeFirstResponder(nil)
}

private struct AutofillDisabledTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: (() -> Void)? = nil
    var focusRequestID: Int = 0

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NonAutofillTextField {
        let textField = NonAutofillTextField()
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: NSFont.systemFontSize)
        textField.lineBreakMode = .byTruncatingTail
        textField.placeholderString = placeholder
        textField.stringValue = text
        textField.delegate = context.coordinator
        textField.target = context.coordinator
        textField.action = #selector(Coordinator.submit)
        textField.configureForPlainInput()
        return textField
    }

    func updateNSView(_ nsView: NonAutofillTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if nsView.placeholderString != placeholder {
            nsView.placeholderString = placeholder
        }
        nsView.configureForPlainInput()
        if nsView.lastAppliedFocusRequestID != focusRequestID {
            nsView.lastAppliedFocusRequestID = focusRequestID
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
        context.coordinator.parent = self
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AutofillDisabledTextField

        init(parent: AutofillDisabledTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else {
                return
            }
            if parent.text != textField.stringValue {
                parent.text = textField.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit?()
                return true
            }
            return false
        }

        @objc
        func submit() {
            parent.onSubmit?()
        }
    }
}

private final class NonAutofillTextField: NSTextField {
    var lastAppliedFocusRequestID = 0

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        configureForPlainInput()
        return becameFirstResponder
    }

    override func textDidBeginEditing(_ notification: Notification) {
        super.textDidBeginEditing(notification)
        configureForPlainInput()
    }

    func configureForPlainInput() {
        isAutomaticTextCompletionEnabled = false
        allowsCharacterPickerTouchBarItem = false
        if #available(macOS 11.0, *) {
            contentType = nil
        }
        if #available(macOS 15.2, *) {
            allowsWritingTools = false
        }
        if #available(macOS 15.4, *) {
            allowsWritingToolsAffordance = false
        }
        if let editor = currentEditor() as? NSTextView {
            editor.isAutomaticTextCompletionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticDataDetectionEnabled = false
            editor.isAutomaticLinkDetectionEnabled = false
        }
    }
}

private struct MainContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack(alignment: .trailing) {
            BrowserView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if model.isQueueSidebarVisible {
                ZStack(alignment: .trailing) {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.hideQueueSidebar()
                        }

                    HStack(spacing: 0) {
                        Divider()
                        QueueSidebar()
                            .frame(width: 320)
                    }
                    .frame(maxHeight: .infinity)
                    .background(.regularMaterial)
                    .shadow(color: .black.opacity(0.08), radius: 12, y: 2)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
    }
}

private struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section("Library") {
                ForEach(BrowseHierarchy.libraryCases) { hierarchy in
                    SidebarRow(
                        title: hierarchy.title,
                        icon: iconName(for: hierarchy),
                        isSelected: hierarchy == model.selectedHierarchy
                    ) {
                        model.openHierarchy(hierarchy)
                    }
                }
            }

            Section("Browse") {
                if model.browseServices.isEmpty {
                    Text("No Services")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.browseServices) { service in
                        SidebarRow(
                            title: service.title,
                            icon: "globe",
                            isSelected: model.selectedHierarchy == .browse && model.selectedBrowseServiceTitle == service.title
                        ) {
                            model.openBrowseService(service)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func iconName(for hierarchy: BrowseHierarchy) -> String {
        switch hierarchy {
        case .playlists: "music.note.list"
        case .albums: "rectangle.stack"
        case .artists: "music.mic"
        case .genres: "guitars"
        case .composers: "music.quarternote.3"
        case .internetRadio: "dot.radiowaves.left.and.right"
        case .browse: "square.grid.2x2"
        case .search: "magnifyingglass"
        }
    }
}

private struct BrowserView: View {
    @Environment(AppModel.self) private var model
    @State private var promptText = ""

    var body: some View {
        VStack(spacing: 0) {
            if let page = model.browsePage {
                if let searchResultsPage = searchResultsPage(for: page) {
                    SearchResultsView(resultsPage: searchResultsPage)
                } else if let albumContext = albumDetailContext(for: page) {
                    AlbumDetailView(context: albumContext)
                } else if let playlistContext = playlistDetailContext(for: page) {
                    PlaylistDetailView(context: playlistContext)
                } else if let artistContext = artistDetailContext(for: page) {
                    ArtistDetailView(context: artistContext)
                } else {
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

                    ResettableScrollContainer(identity: browseScrollIdentity(for: page)) {
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
                }
            } else if shouldShowRecoveryView {
                RecoveryView()
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

    private var shouldShowRecoveryView: Bool {
        switch model.connectionStatus {
        case .disconnected, .connecting, .authorizing, .error:
            return true
        case .connected:
            return false
        }
    }

    private func usesDenseGrid(for page: BrowsePage) -> Bool {
        let title = page.list.title.lowercased()
        return title == "albums" || title == "artists" || title == "composers" || title == "genres" || title == "playlists"
    }

    private func browseScrollIdentity(for page: BrowsePage) -> String {
        [
            page.hierarchy.rawValue,
            page.list.title,
            String(page.list.level),
            model.selectedBrowseServiceTitle ?? ""
        ].joined(separator: "|")
    }

    private func albumDetailContext(for page: BrowsePage) -> AlbumDetailContext? {
        guard let playItem = page.items.first,
              playItem.title == "Play Album",
              playItem.itemKey != nil
        else {
            return nil
        }

        return AlbumDetailContext(
            page: page,
            playItem: playItem
        )
    }

    private func artistDetailContext(for page: BrowsePage) -> ArtistDetailContext? {
        guard let playItem = page.items.first,
              playItem.title == "Play Artist",
              playItem.itemKey != nil
        else {
            return nil
        }

        return ArtistDetailContext(
            page: page,
            playItem: playItem
        )
    }

    private func playlistDetailContext(for page: BrowsePage) -> PlaylistDetailContext? {
        guard let playItem = page.items.first,
              playItem.title == "Play Playlist",
              playItem.itemKey != nil
        else {
            return nil
        }

        return PlaylistDetailContext(
            page: page,
            playItem: playItem
        )
    }

    private func searchResultsPage(for page: BrowsePage) -> SearchResultsPage? {
        guard page.hierarchy == .search,
              page.list.title.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Search") == .orderedSame
        else {
            return nil
        }
        return model.searchResultsPage
    }
}

private struct RecoveryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top, spacing: 20) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(accentTint.opacity(0.14))
                                .frame(width: 84, height: 84)

                            Image(systemName: iconName)
                                .font(.system(size: 32, weight: .medium))
                                .foregroundStyle(accentTint)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text(title)
                                .font(.system(size: 32, weight: .bold))

                            Text(message)
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }

                    if showsProgress {
                        ProgressView()
                            .controlSize(.regular)
                    }

                    HStack(spacing: 12) {
                        Button(primaryActionTitle, action: primaryAction)
                            .buttonStyle(.borderedProminent)

                        if showsSecondaryAction {
                            Button(secondaryActionTitle, action: secondaryAction)
                                .buttonStyle(.bordered)
                        }
                    }

                    if showsManualConnect {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Connect Manually")
                                .font(.system(size: 18, weight: .semibold))

                            HStack(spacing: 12) {
                                AutofillDisabledTextField(
                                    text: Binding(
                                        get: { model.manualConnect.host },
                                        set: { model.manualConnect.host = $0 }
                                    ),
                                    placeholder: "Host"
                                )
                                .frame(height: 24)

                                TextField(
                                    "Port",
                                    value: Binding(
                                        get: { model.manualConnect.port },
                                        set: { model.manualConnect.port = $0 }
                                    ),
                                    format: .number
                                )
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)

                                Button("Connect") {
                                    model.connectManually()
                                }
                                .buttonStyle(.bordered)
                            }

                            Text("Use this if your Core is on another machine or automatic discovery is not working.")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(18)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                    }
                }
                .padding(32)
                .frame(maxWidth: 760, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06))
                }
                .shadow(color: .black.opacity(0.06), radius: 20, y: 8)
                .padding(.horizontal, 32)
                .padding(.top, 48)
                .padding(.bottom, 32)
            }
            .frame(maxWidth: .infinity)
        }
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color.accentColor.opacity(0.035)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var title: String {
        switch model.connectionStatus {
        case .connecting:
            return "Connecting to your Core"
        case let .authorizing(core):
            return core == nil ? "Approve Macaroon in Roon" : "Approve Macaroon on \(core!.displayName)"
        case let .error(message):
            return message.isEmpty ? "Connection Failed" : "Connection Failed"
        case .disconnected:
            return model.autoConnectionIssue == nil ? "Connect to a Roon Core" : "Couldn’t Reach Your Core"
        case .connected:
            return "Connect to a Roon Core"
        }
    }

    private var message: String {
        switch model.connectionStatus {
        case let .connecting(mode):
            return "Macaroon is trying to connect via \(mode). This usually takes only a moment."
        case let .authorizing(core):
            let target = core?.displayName ?? "your Roon Core"
            return "Open Roon, go to Settings > Extensions, and enable Macaroon on \(target). Once it’s approved, retry the connection here."
        case let .error(message):
            return message
        case .disconnected:
            return model.autoConnectionIssue ?? "Macaroon isn’t connected yet. Try automatic discovery first, or enter your Core’s host and port below."
        case .connected:
            return "Macaroon isn’t connected yet."
        }
    }

    private var iconName: String {
        switch model.connectionStatus {
        case .connecting:
            return "dot.radiowaves.left.and.right"
        case .authorizing:
            return "checkmark.shield"
        case .error, .disconnected:
            return "music.note.house"
        case .connected:
            return "music.note.house"
        }
    }

    private var accentTint: Color {
        switch model.connectionStatus {
        case .authorizing:
            return .orange
        case .error:
            return .red
        default:
            return .accentColor
        }
    }

    private var showsProgress: Bool {
        if case .connecting = model.connectionStatus {
            return true
        }
        return false
    }

    private var showsManualConnect: Bool {
        switch model.connectionStatus {
        case .disconnected, .error:
            return true
        case .connecting, .authorizing, .connected:
            return false
        }
    }

    private var primaryActionTitle: String {
        switch model.connectionStatus {
        case .connecting:
            return "Retry"
        case .authorizing:
            return "I’ve Authorized It"
        case .disconnected, .error, .connected:
            return "Try Automatic Connect"
        }
    }

    private var secondaryActionTitle: String {
        "Settings"
    }

    private var showsSecondaryAction: Bool {
        true
    }

    private func primaryAction() {
        switch model.connectionStatus {
        case .connecting, .authorizing, .disconnected, .error, .connected:
            model.connectAutomatically()
        }
    }

    private func secondaryAction() {
        model.openSettings()
    }
}

private struct AlbumDetailContext {
    var page: BrowsePage
    var playItem: BrowseItem
}

private struct ArtistDetailContext {
    var page: BrowsePage
    var playItem: BrowseItem
}

private struct PlaylistDetailContext {
    var page: BrowsePage
    var playItem: BrowseItem
}

private struct BrowseRowSlot: View {
    @Environment(AppModel.self) private var model
    let index: Int

    var body: some View {
        if let item = model.browseItem(at: index) {
            if model.selectedHierarchy == .internetRadio {
                InternetRadioRow(item: item)
            } else {
                BrowserRow(item: item) {
                    if item.inputPrompt == nil {
                        model.openItem(item)
                    }
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
            BrowserGridCard(
                item: item,
                showsPlaybackAffordances: model.selectedHierarchy != .artists && model.selectedHierarchy != .composers
            )
        } else {
            BrowserGridCardPlaceholder()
        }
    }
}

private struct AlbumDetailView: View {
    @Environment(AppModel.self) private var model
    let context: AlbumDetailContext

    var body: some View {
        ResettableScrollContainer(identity: scrollIdentity) {
            VStack(alignment: .leading, spacing: detailSectionSpacing) {
                HStack(alignment: .top, spacing: 30) {
                    ArtworkView(
                        imageKey: context.page.list.imageKey,
                        title: context.page.list.title,
                        size: CGSize(width: detailHeaderArtworkSize, height: detailHeaderArtworkSize)
                    )

                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(context.page.list.title)
                                .font(.system(size: 38, weight: .bold))
                                .lineSpacing(1)
                                .fixedSize(horizontal: false, vertical: true)

                            if let artistName = context.page.list.subtitle,
                               artistName.isEmpty == false {
                                Button {
                                    model.openArtist(named: artistName)
                                } label: {
                                    Text(artistName)
                                        .font(.system(size: 24, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if trackCount > 0 {
                            Text(trackCount == 1 ? "1 track" : "\(trackCount) tracks")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 14)
                        }

                        DetailHeaderPlaybackControls(item: context.playItem)
                            .padding(.top, 18)

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: 560, alignment: .topLeading)

                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 14) {
                    VStack(spacing: 0) {
                        ForEach(1..<context.page.list.count, id: \.self) { index in
                            if let track = model.browseItem(at: index) {
                                AlbumTrackRow(item: track) {
                                    model.performPreferredAction(for: track, preferredActionTitles: ["Play Now"])
                                }
                                .onAppear {
                                    model.ensureBrowseItemsLoaded(for: index)
                                }
                            } else {
                                AlbumTrackRowPlaceholder()
                                    .onAppear {
                                        model.ensureBrowseItemsLoaded(for: index)
                                    }
                            }

                            if index < context.page.list.count - 1 {
                                Divider()
                                    .padding(.leading, 58)
                            }
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            }
            .padding(.horizontal, 28)
            .padding(.top, 26)
            .padding(.bottom, 28)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var scrollIdentity: String {
        [
            context.page.hierarchy.rawValue,
            context.page.list.title,
            context.page.list.subtitle ?? "",
            String(context.page.list.level)
        ].joined(separator: "|")
    }

    private var trackCount: Int {
        max(context.page.list.count - 1, 0)
    }
}

private struct ArtistDetailView: View {
    @Environment(AppModel.self) private var model
    let context: ArtistDetailContext

    var body: some View {
        ResettableScrollContainer(identity: scrollIdentity) {
            VStack(alignment: .leading, spacing: detailSectionSpacing) {
                HStack(alignment: .top, spacing: 30) {
                    ArtworkView(
                        imageKey: context.page.list.imageKey,
                        title: context.page.list.title,
                        size: CGSize(width: detailHeaderArtworkSize, height: detailHeaderArtworkSize)
                    )

                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(context.page.list.title)
                                .font(.system(size: 38, weight: .bold))
                                .lineSpacing(1)
                                .fixedSize(horizontal: false, vertical: true)

                            if let subtitle = displaySubtitle,
                               subtitle.isEmpty == false {
                                Text(subtitle)
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        if albumCount > 0 {
                            Text(albumCount == 1 ? "1 album" : "\(albumCount) albums")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 14)
                        }

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: 560, alignment: .topLeading)

                    Spacer(minLength: 0)
                }

                if albumCount > 0 {
                    VStack(alignment: .leading, spacing: 14) {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 170, maximum: 210), spacing: 18)],
                            spacing: 18
                        ) {
                            ForEach(1..<context.page.list.count, id: \.self) { index in
                                if let item = model.browseItem(at: index) {
                                    BrowserGridCard(item: item)
                                        .onAppear {
                                            model.ensureBrowseItemsLoaded(for: index)
                                        }
                                } else {
                                    BrowserGridCardPlaceholder()
                                        .onAppear {
                                            model.ensureBrowseItemsLoaded(for: index)
                                        }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 26)
            .padding(.bottom, 28)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var scrollIdentity: String {
        [
            context.page.hierarchy.rawValue,
            context.page.list.title,
            context.page.list.subtitle ?? "",
            String(context.page.list.level)
        ].joined(separator: "|")
    }

    private var albumCount: Int {
        max(context.page.list.count - 1, 0)
    }

    private var displaySubtitle: String? {
        guard let subtitle = context.page.list.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              subtitle.isEmpty == false
        else {
            return nil
        }

        let normalizedSubtitle = subtitle.lowercased()
        let singular = "\(albumCount) album"
        let plural = "\(albumCount) albums"

        if normalizedSubtitle == singular || normalizedSubtitle == plural {
            return nil
        }

        return subtitle
    }
}

private struct PlaylistDetailView: View {
    @Environment(AppModel.self) private var model
    let context: PlaylistDetailContext

    var body: some View {
        ResettableScrollContainer(identity: scrollIdentity) {
            VStack(alignment: .leading, spacing: detailSectionSpacing) {
                HStack(alignment: .top, spacing: 30) {
                    ArtworkView(
                        imageKey: context.page.list.imageKey,
                        title: context.page.list.title,
                        size: CGSize(width: detailHeaderArtworkSize, height: detailHeaderArtworkSize)
                    )

                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(context.page.list.title)
                                .font(.system(size: 38, weight: .bold))
                                .lineSpacing(1)
                                .fixedSize(horizontal: false, vertical: true)

                            if let subtitle = context.page.list.subtitle,
                               subtitle.isEmpty == false {
                                Text(subtitle)
                                    .font(.system(size: 24, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        if trackCount > 0 {
                            Text(trackCount == 1 ? "1 track" : "\(trackCount) tracks")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 14)
                        }

                        DetailHeaderPlaybackControls(item: context.playItem)
                            .padding(.top, 18)

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: 560, alignment: .topLeading)

                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 14) {
                    VStack(spacing: 0) {
                        ForEach(1..<context.page.list.count, id: \.self) { index in
                            if let track = model.browseItem(at: index) {
                                AlbumTrackRow(item: track) {
                                    model.performPreferredAction(for: track, preferredActionTitles: ["Play Now"])
                                }
                                .onAppear {
                                    model.ensureBrowseItemsLoaded(for: index)
                                }
                            } else {
                                AlbumTrackRowPlaceholder()
                                    .onAppear {
                                        model.ensureBrowseItemsLoaded(for: index)
                                    }
                            }

                            if index < context.page.list.count - 1 {
                                Divider()
                                    .padding(.leading, 58)
                            }
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            }
            .padding(.horizontal, 28)
            .padding(.top, 26)
            .padding(.bottom, 28)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var scrollIdentity: String {
        [
            context.page.hierarchy.rawValue,
            context.page.list.title,
            context.page.list.subtitle ?? "",
            String(context.page.list.level)
        ].joined(separator: "|")
    }

    private var trackCount: Int {
        max(context.page.list.count - 1, 0)
    }
}

private struct SearchResultsView: View {
    @Environment(AppModel.self) private var model
    let resultsPage: SearchResultsPage

    var body: some View {
        ResettableScrollContainer(identity: resultsPage.query) {
            VStack(alignment: .leading, spacing: 24) {
                Text("Search: \(resultsPage.query)")
                    .font(.system(size: 30, weight: .semibold))

                if let topHit = resultsPage.topHit {
                    SearchTopHitRow(
                        query: resultsPage.query,
                        item: topHit,
                        category: topHitCategory(for: topHit)
                    )
                }

                if resultsPage.sections.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, 8)
                } else {
                    ForEach(resultsPage.sections) { section in
                        SearchResultsSectionView(
                            query: resultsPage.query,
                            section: section
                        )
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 26)
            .padding(.bottom, 28)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func topHitCategory(for item: BrowseItem) -> SearchResultsSectionKind? {
        resultsPage.sections.first { section in
            section.items.contains(where: { candidate in
                candidate.id == item.id ||
                    (candidate.title == item.title && candidate.subtitle == item.subtitle)
            })
        }?.kind
    }
}

private struct SearchTopHitRow: View {
    @Environment(AppModel.self) private var model
    let query: String
    let item: BrowseItem
    let category: SearchResultsSectionKind?

    var body: some View {
        HStack(spacing: 14) {
            if showsPlaybackControls {
                SplitPlayActionPill(
                    enabled: item.itemKey != nil,
                    playAction: primaryPlayAction
                ) {
                    Button("Play Now", action: primaryPlayAction)
                    Button("Add Next") {
                        performSearchAction(["Add Next"])
                    }
                    Button("Queue") {
                        performSearchAction(["Queue"])
                    }
                    Button("Start Radio") {
                        performSearchAction(["Start Radio"])
                    }
                }
                .frame(width: 76, alignment: .leading)
            }

            Button(action: openAction) {
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var showsPlaybackControls: Bool {
        category == .albums || category == .tracks
    }

    private func openAction() {
        guard let category else {
            if item.inputPrompt == nil {
                model.openItem(item)
            }
            return
        }

        switch category {
        case .tracks:
            model.playSearchResult(query: query, category: .tracks, matchTitle: item.title)
        case .artists, .albums, .composers, .works:
            model.openSearchResult(query: query, category: category, matchTitle: item.title)
        }
    }

    private func primaryPlayAction() {
        performSearchAction(["Play Now"])
    }

    private func performSearchAction(_ preferredActionTitles: [String]) {
        guard let category else {
            return
        }
        model.playSearchResult(
            query: query,
            category: category,
            matchTitle: item.title,
            preferredActionTitles: preferredActionTitles
        )
    }
}

private struct SearchResultsSectionView: View {
    let query: String
    let section: SearchResultsSection

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(section.kind.title)
                .font(.system(size: 18, weight: .semibold))

            if section.kind == .tracks {
                VStack(spacing: 0) {
                    ForEach(section.items) { item in
                        SearchTrackRow(
                            query: query,
                            item: item
                        )
                        if item.id != section.items.last?.id {
                            Divider()
                                .padding(.leading, 44)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 170, maximum: 210), spacing: 18)],
                    spacing: 18
                ) {
                    ForEach(section.items) { item in
                        SearchGridCard(
                            query: query,
                            category: section.kind,
                            item: item
                        )
                    }
                }
            }
        }
    }
}

private struct SearchGridCard: View {
    @Environment(AppModel.self) private var model
    let query: String
    let category: SearchResultsSectionKind
    let item: BrowseItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                model.openSearchResult(query: query, category: category, matchTitle: item.title)
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
                    model.openSearchResult(query: query, category: category, matchTitle: item.title)
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

                if category != .artists {
                    SearchGridPlaybackAffordances(
                        query: query,
                        category: category,
                        item: item
                    )
                }
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

private struct SearchGridPlaybackAffordances: View {
    @Environment(AppModel.self) private var model
    let query: String
    let category: SearchResultsSectionKind
    let item: BrowseItem

    var body: some View {
        VStack(spacing: 4) {
            Button {
                model.playSearchResult(query: query, category: category, matchTitle: item.title)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)

            Menu {
                Button("Play Now") {
                    model.playSearchResult(query: query, category: category, matchTitle: item.title, preferredActionTitles: ["Play Now"])
                }
                Button("Add Next") {
                    model.playSearchResult(query: query, category: category, matchTitle: item.title, preferredActionTitles: ["Add Next"])
                }
                Button("Queue") {
                    model.playSearchResult(query: query, category: category, matchTitle: item.title, preferredActionTitles: ["Queue"])
                }
                Button("Start Radio") {
                    model.playSearchResult(query: query, category: category, matchTitle: item.title, preferredActionTitles: ["Start Radio"])
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
        }
    }
}

private struct SearchTrackRow: View {
    @Environment(AppModel.self) private var model
    let query: String
    let item: BrowseItem

    var body: some View {
        HStack(spacing: 14) {
            Button {
                model.playSearchResult(query: query, category: .tracks, matchTitle: item.title)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(item.title.isEmpty)

            Button {
                model.playSearchResult(query: query, category: .tracks, matchTitle: item.title)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let subtitle = item.subtitle, subtitle.isEmpty == false {
                            Text(subtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    Spacer(minLength: 8)

                    if let length = item.length {
                        Text(formatDuration(length))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct DetailHeaderPlaybackControls: View {
    @Environment(AppModel.self) private var model
    let item: BrowseItem

    var body: some View {
        SplitPlayActionPill(
            enabled: item.itemKey != nil,
            style: .large,
            playAction: {
                model.performPreferredAction(for: item, preferredActionTitles: ["Play Now"])
            }
        ) {
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
        }
    }
}

private struct SplitPlayActionPill<MenuContent: View>: View {
    enum Style {
        case compact
        case large
    }

    let enabled: Bool
    var style: Style = .compact
    let playAction: () -> Void
    @ViewBuilder let menuContent: () -> MenuContent

    var body: some View {
        HStack(spacing: 0) {
            Button(action: playAction) {
                Image(systemName: "play.fill")
                    .font(.system(size: playIconSize, weight: .bold))
                    .frame(width: leadingSegmentWidth, height: pillHeight)
            }
            .buttonStyle(.plain)
            .disabled(!enabled)

            Rectangle()
                .fill(Color.white.opacity(0.28))
                .frame(width: 1, height: dividerHeight)

            Menu {
                menuContent()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: caretSize, weight: .bold))
                    .frame(width: trailingSegmentWidth, height: pillHeight)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(!enabled)
        }
        .foregroundStyle(enabled ? Color.white : Color.white.opacity(0.85))
        .background(
            Capsule(style: .continuous)
                .fill(enabled ? pillFillColor : pillFillColor.opacity(0.45))
        )
        .compositingGroup()
    }

    private var pillHeight: CGFloat {
        switch style {
        case .compact:
            34
        case .large:
            58
        }
    }

    private var leadingSegmentWidth: CGFloat {
        switch style {
        case .compact:
            34
        case .large:
            54
        }
    }

    private var trailingSegmentWidth: CGFloat {
        switch style {
        case .compact:
            42
        case .large:
            62
        }
    }

    private var dividerHeight: CGFloat {
        switch style {
        case .compact:
            18
        case .large:
            30
        }
    }

    private var playIconSize: CGFloat {
        switch style {
        case .compact:
            11
        case .large:
            18
        }
    }

    private var caretSize: CGFloat {
        switch style {
        case .compact:
            11
        case .large:
            14
        }
    }

    private var pillFillColor: Color {
        Color(nsColor: .systemGray)
    }
}

private struct AlbumTrackRow: View {
    @Environment(AppModel.self) private var model
    let item: BrowseItem
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            SplitPlayActionPill(
                enabled: item.itemKey != nil,
                playAction: action
            ) {
                Button("Play Now") {
                    action()
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
            }
            .frame(width: 102, alignment: .leading)

            Button(action: action) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let subtitle = item.subtitle, subtitle.isEmpty == false {
                            Text(subtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    Spacer(minLength: 8)

                    if let length = item.length {
                        Text(formatDuration(length))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contextMenu {
            Button("Play Now", action: action)
            Button("Add Next") {
                model.performPreferredAction(for: item, preferredActionTitles: ["Add Next"])
            }
            Button("Queue") {
                model.performPreferredAction(for: item, preferredActionTitles: ["Queue"])
            }
            Button("Start Radio") {
                model.performPreferredAction(for: item, preferredActionTitles: ["Start Radio"])
            }
        }
    }
}

private struct AlbumTrackRowPlaceholder: View {
    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .tertiarySystemFill))
                .frame(width: 102, height: 34)

            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(nsColor: .tertiarySystemFill))
                    .frame(height: 14)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(nsColor: .quaternarySystemFill))
                    .frame(width: 180, height: 12)
            }

            Spacer(minLength: 8)

            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color(nsColor: .quaternarySystemFill))
                .frame(width: 36, height: 12)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .redacted(reason: .placeholder)
    }
}

private struct SearchToolbarField: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            AutofillDisabledTextField(
                text: $model.searchText,
                placeholder: "Search Library",
                onSubmit: {
                    model.runSearch()
                },
                focusRequestID: model.searchFocusRequestID
            )
                .frame(width: 220)

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
                Text(headerTitle)
                    .font(.system(size: 30, weight: .semibold, design: .default))
                if let subtitle = model.browsePage?.list.subtitle, subtitle.isEmpty == false {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if let count = model.browsePage?.list.count {
                    Text("\(count) items")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .padding(.bottom, 18)
    }

    private var headerTitle: String {
        if model.selectedHierarchy == .internetRadio {
            return BrowseHierarchy.internetRadio.title
        }
        return model.browsePage?.list.title ?? model.selectedHierarchy.title
    }
}

private struct MiniPlayerBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 24) {
                if let nowPlaying = model.selectedZone?.nowPlaying {
                    HStack(spacing: 16) {
                        Button {
                            model.openNowPlayingAlbum()
                        } label: {
                            ArtworkView(
                                imageKey: nowPlaying.imageKey,
                                title: nowPlaying.title,
                                size: CGSize(width: miniPlayerArtworkSize, height: miniPlayerArtworkSize)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled((nowPlaying.detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(nowPlaying.title)
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(1)
                            if let subtitle = nowPlaying.subtitle, subtitle.isEmpty == false {
                                Button {
                                    model.openNowPlayingArtist()
                                } label: {
                                    Text(subtitle)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .buttonStyle(.plain)
                            } else {
                                Text(nowPlaying.detail ?? " ")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Text(model.selectedZone?.state.capitalized ?? " ")
                                .font(.system(size: 11, weight: .medium))
                                .textCase(.uppercase)
                                .tracking(0.4)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(width: 240, alignment: .leading)
                    }
                } else {
                    Label("Nothing Playing", systemImage: "music.note")
                        .foregroundStyle(.secondary)
                        .frame(width: 312, alignment: .leading)
                }

                Spacer(minLength: 12)

                MiniPlayerTransportSection()

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 10) {
                    Picker("Zone", selection: Binding(
                        get: { model.selectedZoneID ?? "" },
                        set: { zoneID in
                            model.selectZone(zoneID.isEmpty ? nil : zoneID)
                        }
                    )) {
                            ForEach(model.zones) { zone in
                                Text(zone.displayName).tag(zone.zoneID)
                            }
                        }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 214)

                    MiniPlayerVolumeControl()
                        .frame(width: 214, alignment: .trailing)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.75))
                )
            }
            .frame(height: miniPlayerReservedHeight)
            .padding(.horizontal, 18)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 1)
            }
        }
    }
}

private struct QueueSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Queue")
                        .font(.system(size: 22, weight: .semibold))
                    if let queueState = model.queueState {
                        Text(queueSubtitle(for: queueState))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let zone = model.selectedZone {
                        Text(zone.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 14)

            if let queueState = model.queueState, queueState.items.isEmpty == false {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(queueState.items) { item in
                            QueueRow(item: item) {
                                model.playQueueItem(item)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 18)
                }
            } else {
                ContentUnavailableView(
                    "No Queue",
                    systemImage: "text.line.first.and.arrowtriangle.forward",
                    description: Text("Playback queue items for the selected zone will appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 18)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func queueSubtitle(for queueState: QueueState) -> String {
        if queueState.totalCount == 1 {
            return "1 item"
        }
        return "\(queueState.totalCount) items"
    }
}

private struct QueueRow: View {
    let item: QueueItemSummary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ArtworkView(
                    imageKey: item.imageKey,
                    title: item.title,
                    size: CGSize(width: 44, height: 44)
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 13, weight: item.isCurrent ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if let subtitle = item.subtitle, subtitle.isEmpty == false {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if let detail = item.detail, detail.isEmpty == false {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 6) {
                    if item.isCurrent {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    if let length = item.length {
                        Text(formatTime(length))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(item.isCurrent ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Play From Here", action: action)
        }
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

private struct MiniPlayerTransportSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 7) {
            MiniPlayerProgressSection()

            HStack(spacing: 16) {
                MiniPlayerButton(systemName: "backward.fill", enabled: model.selectedZone?.capabilities.canPrevious == true) {
                    model.transport(.previous)
                }
                MiniPlayerButton(
                    systemName: "playpause.fill",
                    enabled: (model.selectedZone?.capabilities.canPlayPause == true) ||
                        ((model.selectedZone?.capabilities.canPlay == true) && (model.selectedZone?.capabilities.canPause == true)),
                    prominence: .primary
                ) {
                    model.transport(.playPause)
                }
                MiniPlayerButton(systemName: "forward.fill", enabled: model.selectedZone?.capabilities.canNext == true) {
                    model.transport(.next)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.82))
            )
        }
        .frame(width: 500)
    }
}

private struct MiniPlayerProgressSection: View {
    @Environment(AppModel.self) private var model
    @State private var isScrubbing = false
    @State private var scrubValue = 0.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 3) {
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
                .controlSize(.small)

                HStack {
                    Text(formatTime(isScrubbing ? scrubValue : resolvedSeekPosition(at: context.date)))
                    Spacer()
                    Text(formatTime(trackLength))
                }
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
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
                    muteButton(isMuted: volume.isMuted == true)

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
                    .controlSize(.small)
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
                    muteButton(isMuted: volume.isMuted == true)

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

    private func muteButton(isMuted: Bool) -> some View {
        Button {
            model.toggleMute()
        } label: {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isMuted ? Color.primary : Color.secondary)
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(isMuted ? Color.primary.opacity(0.12) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isMuted ? "Unmute" : "Mute")
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var cacheLimitMegabytes = 0.0

    var body: some View {
        Form {
            Section("Artwork Cache") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Maximum Cache Size")
                        Spacer()
                        Text(model.artworkCacheLimitDisplay)
                            .foregroundStyle(.secondary)
                    }

                    Slider(
                        value: $cacheLimitMegabytes,
                        in: 128...4096,
                        step: 64
                    ) { editing in
                        if editing == false {
                            Task {
                                await model.setArtworkCacheLimit(megabytes: cacheLimitMegabytes)
                            }
                        }
                    }

                    HStack {
                        Text("Current Usage")
                        Spacer()
                        Text(model.artworkCacheUsageDisplay)
                            .foregroundStyle(.secondary)
                    }

                    Button("Clear Cache") {
                        Task {
                            await model.clearArtworkCache()
                        }
                    }
                }
                .onAppear {
                    cacheLimitMegabytes = model.artworkCacheLimitMegabytes
                }
                .onChange(of: model.artworkCacheLimitBytes) { _, newValue in
                    cacheLimitMegabytes = Double(newValue) / (1024 * 1024)
                }
            }
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : .clear)
            )
            .contentShape(Rectangle())
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
    var showsPlaybackAffordances: Bool = true

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

                if showsPlaybackAffordances {
                    PlaybackAffordances(item: item)
                }
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

private struct InternetRadioRow: View {
    @Environment(AppModel.self) private var model
    let item: BrowseItem

    var body: some View {
        HStack(spacing: 14) {
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

            Button {
                if item.inputPrompt == nil {
                    model.openItem(item)
                }
            } label: {
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
                Button("Open") {
                    model.openItem(item)
                }
            }
            Button("Play Now") {
                model.performPreferredAction(for: item, preferredActionTitles: ["Play Now"])
            }
        }
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
            AutofillDisabledTextField(
                text: $text,
                placeholder: item.inputPrompt?.prompt ?? "Search",
                onSubmit: submit
            )
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
    enum Prominence {
        case standard
        case primary
    }

    let systemName: String
    let enabled: Bool
    var prominence: Prominence = .standard
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: prominence == .primary ? 15 : 13, weight: .semibold))
                .frame(
                    width: prominence == .primary ? 40 : 30,
                    height: prominence == .primary ? 40 : 30
                )
                .background(backgroundShape)
        }
        .buttonStyle(.plain)
        .foregroundStyle(foregroundColor)
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
    }

    private var foregroundColor: Color {
        switch prominence {
        case .primary:
            return enabled ? Color.white : Color.white.opacity(0.85)
        case .standard:
            return enabled ? Color.primary : Color.secondary
        }
    }

    @ViewBuilder
    private var backgroundShape: some View {
        switch prominence {
        case .primary:
            Circle()
                .fill(enabled ? Color.accentColor : Color.accentColor.opacity(0.45))
        case .standard:
            Circle()
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.9))
        }
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
