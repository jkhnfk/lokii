import AppKit
import UniformTypeIdentifiers
import Quartz
import SwiftUI

/// Container view that intercepts clicks outside interactiveCardView while routing clicks inside to the card.
private final class OverlayContainerView: NSView {
    weak var interactiveCardView: NSView?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let card = interactiveCardView {
            let pointInCard = card.convert(point, from: self)
            if card.bounds.contains(pointInCard), let hitView = card.hitTest(pointInCard) {
                return hitView
            }
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func keyDown(with event: NSEvent) {}
    override func keyUp(with event: NSEvent) {}
}

final class SearchWindow: NSWindowController {
    private let engine: SearchEngine
    private var defaultWindowFrame: NSRect {
        Self.calculateDefaultWindowFrame()
    }

    /// 基于当前主屏幕可用工作区几何尺寸，按黄金视觉比例自适应计算默认尺寸与居中位置
    static func calculateDefaultWindowFrame() -> NSRect {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return NSRect(x: 0, y: 0, width: 960, height: 640)
        }
        let visible = screen.visibleFrame
        // 宽度取可见屏幕宽度的 60%，钳制在 [960, 1280] pt
        let width = min(max(visible.width * 0.60, 960), 1280)
        // 高度取可见屏幕高度的 62%，钳制在 [600, 860] pt
        let height = min(max(visible.height * 0.62, 600), 860)

        // 水平居中，垂直方向位于视窗黄金中心（屏幕中心微偏上 5% 屏幕高度）
        let x = visible.origin.x + (visible.width - width) / 2
        let y = visible.origin.y + (visible.height - height) / 2 + (visible.height * 0.05)
        return NSRect(x: round(x), y: round(y), width: round(width), height: round(height))
    }

    private let savedWindowFrameKey = "LokiiMainWindowFrame"
    let splitViewController = SearchMainSplitViewController()
    var searchResultsViewController: SearchResultsViewController { splitViewController.searchResultsViewController }
    var sidebarTreeViewController: SidebarTreeViewController { splitViewController.sidebarTreeViewController }

    private var searchField: NSSearchField!
    private let searchContainer = NSView()
    private var searchWorkItem: DispatchWorkItem?
    private var currentMode: FfiSearchMode = .auto
    private var statusText: LocalizedText = .key("search.indexing") {
        didSet { updateStatusLabel() }
    }
    private var searchMatchText: LocalizedText? = nil {
        didSet { updateStatusLabel() }
    }

    // Loading overlay
    private var loadingOverlay: NSView?
    private var overlayState: IndexingOverlayState?
    private var overlayShownAt: Date?
    private var isColdStart: Bool = true  // Default true until startup mode known
    private var isInlineProgressActive: Bool = false
    private var originalSearchPlaceholder: String { L("search.placeholder") }

    var isOverlayVisible: Bool {
        loadingOverlay != nil
    }

    /// Tracks why the loading overlay is showing, so `onIndexReady` from
    /// a concurrent initialize/verify doesn't accidentally dismiss a rebuild overlay.
    private enum IndexingState { case idle, initializing, rebuilding, failed }
    private var indexingState: IndexingState = .initializing

    // MARK: - 文件夹浏览（Space 展开 / ⌘↓ 下钻 / ⌘↑ 返回上一级）

    /// 当前正在浏览的目录；`nil` 表示列表内容来自搜索结果。
    private var browsingFolder: String?
    /// 当前目录的完整条目（已按 Finder 式名称升序排好），过滤前的全集。
    private var browseEntries: [BrowseEntry] = []
    /// 条目数触顶被截断（超大目录只列前 `FolderBrowse.defaultMaxEntries` 条）。
    private var browseTruncated = false
    /// 进入浏览模式前搜索框里的查询，一路 ⌘↑ 退到最顶层时原样恢复。
    private var savedQuery: String?
    /// 状态栏临时提示的复位任务：连续提示时只保留最后一次。
    private var statusResetWorkItem: DispatchWorkItem?

    init(engine: SearchEngine) {
        self.engine = engine

        let window = LokiiWindow(
            contentRect: Self.calculateDefaultWindowFrame(),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Lokii"
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 780, height: 420)
        window.isReleasedWhenClosed = false

        super.init(window: window)

        splitViewController.delegate = self
        window.contentViewController = splitViewController

        window.onEscape = { [weak self] in
            self?.hideWindowWithAnimation()
        }
        // Escape 在 sendEvent 阶段拦截：浏览模式下退出文件夹，赶在搜索框 field editor
        // 吃掉 Escape 之前消费掉；不在浏览模式时放行，Esc 继续走清空搜索框/隐藏窗口。
        window.onEscapeIntercept = { [weak self] in
            self?.exitBrowseIfNeeded() ?? false
        }
        window.onReturn = { [weak self] in
            self?.openSelected()
        }
        window.onCommandF = { [weak self] in
            guard let self else { return false }
            self.focusSearchField()
            return true
        }
        // ⌘↩ / ⇧↩ / ⌘1…⌘9 / ⌘↓ / ⌘↑ / Space / 普通字符：见 SearchWindow+Interaction
        installInteractionShortcuts(on: window)

        setupUI()
        reloadWindowBehavior()
        applyInitialWindowFrame()
        window.delegate = self
        window.contentView?.wantsLayer = true
        setupSearchModeMenu()
        setupNotifications()
        onLanguageChanged()

        searchResultsViewController.onOpenFDAGuide = {
            FDAGuideWindowController.show()
        }
        searchResultsViewController.updateFDAStatus(hasFDA: engine.hasFullDiskAccess)
        if engine.stats.isReady {
            loadDefaultResults()
        }
    }

    /// 一键恢复自适应默认窗口尺寸并清除持久化位置
    @objc func resetToDefaultWindowFrame() {
        guard let window else { return }
        clearSavedWindowFrame()
        window.animator().setFrame(defaultWindowFrame, display: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        guard let window = window else { return }
        
        let isFirstAppear = !window.isVisible
        if isFirstAppear {
            window.alphaValue = 0.0
            if let layer = window.contentView?.layer {
                let center = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
                var transform = CATransform3DIdentity
                transform = CATransform3DTranslate(transform, center.x, center.y, 0)
                transform = CATransform3DScale(transform, 0.9, 0.9, 1.0) // Start smaller for more pop
                transform = CATransform3DTranslate(transform, -center.x, -center.y, 0)
                layer.transform = transform
            }
        }
        
        super.showWindow(sender)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(searchField)
        
        if isFirstAppear {
            // Quick fade in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                window.animator().alphaValue = 1.0
            })
            
            // 窗口弹出采用弹性阻尼微动效，增强视觉响应与交互质感
            if let layer = window.contentView?.layer {
                let spring = CASpringAnimation(keyPath: "transform")
                spring.fromValue = layer.transform
                spring.toValue = CATransform3DIdentity
                spring.damping = 20
                spring.stiffness = 300
                spring.mass = 1.0
                spring.duration = spring.settlingDuration
                layer.transform = CATransform3DIdentity
                layer.add(spring, forKey: "springScale")
            }
        }
    }

    @objc private func hideWindowWithAnimation() {
        if QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        }
        guard let window = window, window.isVisible else { return }
        
        // Remove scale pop on close for cleaner exit
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            self?.window?.orderOut(nil)
            self?.window?.alphaValue = 1.0
            self?.window?.contentView?.layer?.transform = CATransform3DIdentity
        })
    }

    // MARK: - UI Setup

    private func setupUI() {
        // ── Toolbar with standard sidebar toggle, tracking separator, and search field ──
        searchContainer.translatesAutoresizingMaskIntoConstraints = false

        searchField = NSSearchField()
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = L("search.placeholder")
        searchField.font = .systemFont(ofSize: 14)
        searchField.focusRingType = .exterior
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = false

        searchContainer.addSubview(searchField)

        NSLayoutConstraint.activate([
            searchContainer.heightAnchor.constraint(equalToConstant: 28),
            searchContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),

            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            searchField.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor),
            searchField.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor),
            searchField.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),
            searchField.heightAnchor.constraint(equalToConstant: 28),
        ])

        let toolbar = LokiiToolbar(identifier: "LokiiMainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        if #available(macOS 15.0, *) {
            toolbar.allowsDisplayModeCustomization = false
        }
        window?.toolbar = toolbar
    }

    // MARK: - Search Mode Menu (on the magnifying glass)

    private func setupSearchModeMenu() {
        let menu = NSMenu(title: L("search.mode.title"))
        let keys = [
            "search.mode.auto",
            "search.mode.substring",
            "search.mode.wildcard",
            "search.mode.regex",
            "search.mode.fuzzy",
        ]
        for (i, key) in keys.enumerated() {
            let item = NSMenuItem(localizedKey: key, action: #selector(searchModeSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            if i == 0 { item.state = .on }
            menu.addItem(item)
        }
        (searchField.cell as? NSSearchFieldCell)?.searchMenuTemplate = menu

        // D-04: Optimize magnifying glass icon for visual symmetry
        if let searchButtonCell = (searchField.cell as? NSSearchFieldCell)?.searchButtonCell {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            searchButtonCell.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")?.withSymbolConfiguration(config)
        }
    }

    @objc private func searchModeSelected(_ sender: NSMenuItem) {
        let modes: [FfiSearchMode] = [.auto, .substring, .wildcard, .regex, .fuzzy]
        let tag = sender.tag
        guard tag >= 0, tag < modes.count else { return }
        currentMode = modes[tag]
        if let menu = sender.menu {
            for item in menu.items { item.state = .off }
        }
        sender.state = .on
        if let query = searchField?.stringValue, !query.isEmpty {
            performSearch(query: query)
        }
    }

    // MARK: - Notifications

    private func setupNotifications() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(onLanguageChanged),
                       name: L10n.languageChangedNotification, object: nil)
        nc.addObserver(self, selector: #selector(onIndexProgress(_:)),
                       name: SearchEngine.indexProgressNotification, object: nil)
        nc.addObserver(self, selector: #selector(onIndexReady(_:)),
                       name: SearchEngine.indexReadyNotification, object: nil)
        nc.addObserver(self, selector: #selector(onIndexUpdated(_:)),
                       name: SearchEngine.indexUpdatedNotification, object: nil)
        nc.addObserver(self, selector: #selector(onStartupMode(_:)),
                       name: SearchEngine.startupModeNotification, object: nil)
        nc.addObserver(self, selector: #selector(onInitializationFailed(_:)),
                       name: SearchEngine.initializationFailedNotification, object: nil)
        nc.addObserver(self, selector: #selector(onConfigReloaded(_:)),
                       name: SearchEngine.configReloadedNotification, object: nil)
        nc.addObserver(self, selector: #selector(onAppDidBecomeActive),
                       name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func onAppDidBecomeActive() {
        let hasFDA = engine.hasFullDiskAccess
        searchResultsViewController.updateFDAStatus(hasFDA: hasFDA)
        guard let state = overlayState else { return }
        state.syncDismissedState()
        if hasFDA {
            state.markFDAGranted()
        }
    }

    @objc private func onLanguageChanged() {
        searchField.placeholderString = L(isInlineProgressActive ? "search.indexingIncomplete" : "search.placeholder")
        if let toolbar = window?.toolbar {
            for item in toolbar.items {
                if item.itemIdentifier == .toggleSidebar {
                    item.label = L("search.toggleSidebar")
                    item.paletteLabel = L("search.toggleSidebar")
                    item.toolTip = L("search.toggleSidebar")
                } else if item.itemIdentifier == .searchField {
                    item.label = L("search.placeholder")
                    item.paletteLabel = L("search.placeholder")
                } else if item.itemIdentifier == .resetWindowSize {
                    item.label = L("window.viewOptions")
                    item.paletteLabel = L("window.viewOptions")
                    item.toolTip = L("window.viewOptions")
                    if let button = item.view as? NSButton {
                        button.toolTip = L("window.viewOptions")
                        button.menu = buildViewOptionsMenu()
                    }
                }
            }
        }
        splitViewController.onLanguageChanged()
        if let menu = (searchField.cell as? NSSearchFieldCell)?.searchMenuTemplate {
            menu.title = L("search.mode.title")
            menu.refreshLocalizedTitles()
        }
        updateStatusLabel()
        overlayState?.headingText = L("search.buildingIndex")
        overlayState?.statusText = L("search.scanningFiles")
    }

    private func updateStatusLabel() {
        let formatted: String
        if let match = searchMatchText, !match.string.isEmpty {
            let template = L("search.statusWithMatches")
            formatted = template == "search.statusWithMatches"
                ? "\(match.string) | \(statusText.string)"
                : String(format: template, match.string, statusText.string)
        } else {
            formatted = statusText.string
        }
        searchResultsViewController.updateStatusText(formatted)
    }

    @objc private func onIndexProgress(_ note: Notification) {
        guard indexingState != .failed else { return }
        // 浏览模式下的状态栏属于当前目录，索引进度别来插一脚
        guard !isBrowsing else { return }
        let phase = note.userInfo?["phase"] as? String ?? ""
        guard phase != "verifying", indexingState != .idle else { return }
        if indexingState == .initializing && !isColdStart { return }
        let source = note.userInfo?["source"] as? String ?? ""
        if indexingState == .rebuilding && source != "rebuild" { return }
        if indexingState == .initializing && source == "rebuild" { return }

        let count = note.userInfo?["scannedFiles"] as? UInt64 ?? 0
        let formatted = formatFileCount(count)

        statusText = .formatted("search.indexingCount", formatted)
        // 冷启动期间额外把扫描计数同步到全屏建库遮罩卡片
        if isColdStart && indexingState == .initializing {
            overlayState?.scannedCount = count
        }
    }

    @objc private func onIndexReady(_ note: Notification) {
        let total = note.userInfo?["total"] as? UInt64 ?? 0
        let source = note.userInfo?["source"] as? String ?? ""

        guard indexingState != .failed else { return }
        // 浏览模式下的状态栏由当前目录接管，索引完成事件只刷新自身的内部状态
        if !isBrowsing {
            statusText = .formatted("search.indexedCount", formatFileCount(total))
        }

        // 完成事件必须与当前所处阶段同源：并发触发的 initialize/rebuild 事件
        // 到达时仅刷新计数，不得据此结束当前阶段
        switch indexingState {
        case .idle:
            return
        case .initializing where source == "rebuild":
            return
        case .rebuilding where source != "rebuild":
            return
        default:
            break
        }

        // 冷启动以全窗遮罩呈现进度，热启动与重建以内联指示器呈现，故收起方式不同
        if indexingState == .initializing && isColdStart {
            hideLoadingOverlay()
        } else {
            hideInlineProgress()
        }
        searchResultsViewController.setRebuildSpinning(false)
        searchResultsViewController.setRebuildEnabled(true)
        searchResultsViewController.updateFDAStatus(hasFDA: engine.hasFullDiskAccess)
        indexingState = .idle
        if !isBrowsing && searchField.stringValue.isEmpty {
            loadDefaultResults()
        }
    }

    @objc private func onIndexUpdated(_ note: Notification) {
        guard indexingState != .failed else { return }
        // 浏览模式下的状态栏属于当前目录，索引进度别来插一脚
        guard !isBrowsing else { return }
        let total = note.userInfo?["total"] as? UInt64 ?? 0
        statusText = .formatted("search.indexedCount", formatFileCount(total))
        overlayState?.scannedCount = total
    }

    @objc private func onStartupMode(_ note: Notification) {
        guard indexingState != .failed else { return }
        let coldStart = note.userInfo?["isColdStart"] as? Bool ?? true
        isColdStart = coldStart
        if coldStart {
            // Cold start — show overlay
            showLoadingOverlay(heading: L("search.buildingIndex"))
        } else {
            statusText = .key("search.loadingIndex")
        }
    }

    @objc private func onInitializationFailed(_ note: Notification) {
        indexingState = .failed
        searchWorkItem?.cancel()
        loadingOverlay?.removeFromSuperview()
        loadingOverlay = nil
        overlayState = nil
        hideInlineProgress()
        searchField.isEnabled = false
        searchResultsViewController.setRebuildEnabled(false)
        searchResultsViewController.setRebuildSpinning(false)
        statusText = .key("search.initializationFailed")

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L("search.initializationFailed")
        alert.informativeText = L("search.initializationFailedHelp") + "\n\n"
            + (note.userInfo?["message"] as? String ?? "")
        alert.addButton(withTitle: L("ok"))
        if let window {
            alert.beginSheetModal(for: window)
        }
    }

    @objc private func onConfigReloaded(_ note: Notification) {
        reloadWindowBehavior()
        applyWindowBehaviorFromConfig()
    }

    // MARK: - Window Behavior

    private func applyInitialWindowFrame() {
        guard let window else { return }
        if shouldRememberWindowPosition, restoreSavedWindowFrame() {
            ensureWindowMeetsMinimumSize(window)
            return
        }
        window.setFrame(defaultWindowFrame, display: false)
        window.center()
    }

    private func applyWindowBehaviorFromConfig() {
        guard let window else { return }
        if shouldRememberWindowPosition {
            if restoreSavedWindowFrame() {
                ensureWindowMeetsMinimumSize(window)
            } else {
                saveWindowFrameIfNeeded()
            }
        } else {
            clearSavedWindowFrame()
        }
    }

    /// 窗口位置记忆开关的本地缓存，随配置重载刷新。
    /// 拖动与缩放回调按显示刷新率触发，若每次实时跨 FFI 解码整份配置将产生大量冗余开销。
    private var shouldRememberWindowPosition = false

    private func reloadWindowBehavior() {
        shouldRememberWindowPosition = engine.getConfig()?.window.rememberPosition ?? false
    }

    private func saveWindowFrameIfNeeded() {
        guard shouldRememberWindowPosition, let window else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: savedWindowFrameKey)
    }

    @discardableResult
    private func restoreSavedWindowFrame() -> Bool {
        guard let frameString = UserDefaults.standard.string(forKey: savedWindowFrameKey),
              !frameString.isEmpty else { return false }
        let frame = NSRectFromString(frameString)
        guard frame.width > 0, frame.height > 0 else { return false }
        window?.setFrame(frame, display: false)
        return true
    }

    private func clearSavedWindowFrame() {
        UserDefaults.standard.removeObject(forKey: savedWindowFrameKey)
    }

    private func ensureWindowMeetsMinimumSize(_ window: NSWindow) {
        guard window.frame.width < window.minSize.width || window.frame.height < window.minSize.height else { return }
        window.setFrame(defaultWindowFrame, display: false)
        window.center()
    }

    // MARK: - Loading Overlay

    private func showLoadingOverlay(heading: String) {
        searchField.isEnabled = false
        guard loadingOverlay == nil else {
            overlayState?.headingText = heading
            return
        }
        overlayShownAt = Date()
        guard let contentView = window?.contentView else { return }

        let state = IndexingOverlayState(
            hasFDA: engine.hasFullDiskAccess,
            promptDismissed: FDAGuideWindowController.isPromptDismissed,
            heading: heading
        )
        self.overlayState = state

        // Full-window overlay container with selective hit-testing
        let overlay = OverlayContainerView(frame: contentView.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        overlay.alphaValue = 0
        contentView.addSubview(overlay)
        loadingOverlay = overlay

        // Fullscreen indexing overlay with center animation & bottom-trailing pill
        let cardView = IndexingFullScreenOverlayView(state: state)
        let hostingView = NSHostingView(rootView: cardView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        overlay.addSubview(hostingView)
        overlay.interactiveCardView = hostingView

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: overlay.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
        ])

        // Fade in
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            overlay.animator().alphaValue = 1.0
        }

        NSAccessibility.post(element: overlay, notification: .layoutChanged)
    }

    private func hideLoadingOverlay() {
        guard let overlay = loadingOverlay else { return }

        // Enforce minimum display time so overlay doesn't flash and disappear
        let minDisplayTime: TimeInterval = 1.0
        let elapsed = Date().timeIntervalSince(overlayShownAt ?? .distantPast)
        if elapsed < minDisplayTime {
            DispatchQueue.main.asyncAfter(deadline: .now() + (minDisplayTime - elapsed)) { [weak self] in
                self?.hideLoadingOverlay()
            }
            return
        }

        searchField.isEnabled = true

        // Accessibility: announce index ready
        if let mainWindow = NSApp.mainWindow {
            NSAccessibility.post(element: mainWindow as Any, notification: .announcementRequested,
                                 userInfo: [NSAccessibility.NotificationUserInfoKey.announcement: L("search.indexReady")])
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            overlay.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            overlay.removeFromSuperview()
            self?.loadingOverlay = nil
            self?.overlayState = nil
            // 遮罩已彻底收起，此时再弹出权限引导，避免引导浮窗被建库遮罩覆盖
            (NSApp.delegate as? AppDelegate)?.checkAndPromptFDA()
        })
    }

    // MARK: - Inline Progress (Hot Start / Rebuild)

    private func showInlineProgress() {
        isInlineProgressActive = true
        searchResultsViewController.setInlineProgressVisible(true)
        searchField.placeholderString = L("search.indexingIncomplete")
    }

    private func hideInlineProgress() {
        isInlineProgressActive = false
        searchResultsViewController.setInlineProgressVisible(false)
        searchField.placeholderString = originalSearchPlaceholder
    }

    // MARK: - Rebuild Action

    @objc private func rebuildIndexClicked() {
        guard indexingState == .idle else { return }

        if engine.isScanning {
            searchResultsViewController.notifyBackgroundIndexingActive()
            return
        }

        indexingState = .rebuilding
        searchResultsViewController.setRebuildEnabled(false)
        searchResultsViewController.setRebuildSpinning(true)
        showInlineProgress()
        statusText = .key("search.indexing")
        engine.rebuildIndex()
    }

    // MARK: - Search

    private var lastQuery: String = ""

    @objc private func searchChanged() {
        guard indexingState != .failed else { return }
        let query = searchField.stringValue
        guard query != lastQuery else { return }
        lastQuery = query
        searchWorkItem?.cancel()

        // 浏览模式下搜索框改当「当前目录内过滤器」用：不发起索引查询，只筛当前条目。
        if isBrowsing {
            applyBrowseFilter()
            return
        }

        if query.isEmpty {
            searchResultsViewController.updateBottomPath(with: nil)
            loadDefaultResults()
            return
        }

        let item = DispatchWorkItem { [weak self] in
            self?.performSearch(query: query)
        }
        searchWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016, execute: item)
    }

    private var isSearching = false

    /// 搜索框为空时自动呈现全量索引文件与目录树（按文件名自然字母顺序排列，且清除匹配高亮）
    private func loadDefaultResults() {
        guard indexingState != .failed, !isSearching else { return }
        isSearching = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let response = self.engine.search(query: "*", mode: .wildcard)
            // 按文件名自然字母顺序（A-Z）排列，并清除匹配范围（默认未检索状态下不施加高亮）
            let items: [FfiSearchResult] = response.results
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { item in
                    FfiSearchResult(
                        name: item.name,
                        path: item.path,
                        isDir: item.isDir,
                        size: item.size,
                        modified: item.modified,
                        created: item.created,
                        extension: item.extension,
                        score: item.score,
                        matchPositions: [],
                        parentMatchPositions: [],
                        searchMode: item.searchMode
                    )
                }
            let tree: ResultDirectoryTree? = items.isEmpty ? nil : ResultDirectoryTree.build(from: items)

            DispatchQueue.main.async {
                self.isSearching = false
                guard self.indexingState != .failed else { return }
                guard self.searchField.stringValue.isEmpty else { return }
                // 搜索期间用户可能已经 Space 展开了一个文件夹：这批结果已经过期，别覆盖目录内容
                guard !self.isBrowsing else { return }
                self.splitViewController.updateSearchResults(rawResults: items, tree: tree)
                self.searchMatchText = nil
                self.updateStatusLabel()
            }
        }
    }

    private func performSearch(query: String) {
        guard indexingState != .failed, !isSearching else { return }
        isSearching = true
        searchMatchText = .key("search.searching")

        let mode = currentMode
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let response = self.engine.search(query: query, mode: mode)
            let tree: ResultDirectoryTree? = response.results.isEmpty ? nil : ResultDirectoryTree.build(from: response.results)
            DispatchQueue.main.async {
                self.isSearching = false
                guard self.indexingState != .failed else { return }
                // 搜索期间用户可能已经 Space 展开了一个文件夹：这批结果已经过期，别覆盖目录内容
                guard !self.isBrowsing else { return }
                self.splitViewController.updateSearchResults(rawResults: response.results, tree: tree)

                if let error = response.error {
                    self.searchMatchText = .verbatim(error)
                } else {
                    let count = response.results.count
                    if count == 1 {
                        self.searchMatchText = .key("search.matchedCount.one")
                    } else {
                        self.searchMatchText = .formatted("search.matchedCount", formatFileCount(UInt64(count)))
                    }
                }

                // If user typed more while searching, trigger new search
                let current = self.searchField.stringValue
                if current != query && !current.isEmpty {
                    self.lastQuery = current
                    self.performSearch(query: current)
                }
            }
        }
    }

    // MARK: - Actions

    private var selectedResults: [FfiSearchResult] {
        searchResultsViewController.selectedResults
    }

    @objc private func openSelected() {
        let selected = selectedResults
        guard !selected.isEmpty else { return }
        for item in selected {
            engine.openFile(path: item.path)
        }
    }

    // MARK: - Focus Management

    /// 聚焦搜索输入框，并将输入光标定位至文本末尾
    func focusSearchField() {
        guard let window = window, let searchField = searchField else { return }
        window.makeFirstResponder(searchField)
        if let editor = searchField.currentEditor() {
            let length = (searchField.stringValue as NSString).length
            editor.selectedRange = NSRange(location: length, length: 0)
        }
    }
}

// MARK: - SearchMainSplitViewControllerDelegate

extension SearchWindow: SearchMainSplitViewControllerDelegate {
    func searchMainSplitViewDidSelect(result: FfiSearchResult?) {
        searchResultsViewController.updateBottomPath(with: result?.path)
    }

    func searchMainSplitViewDidDoubleClick(result: FfiSearchResult) {
        engine.openFile(path: result.path)
    }

    func searchMainSplitViewDidRequestRebuild() {
        rebuildIndexClicked()
    }

    func searchMainSplitViewDidRequestFocusSearchField() {
        focusSearchField()
    }

    func searchMainSplitViewDidTrashItems(paths: Set<String>, remainingCount: Int) {
        if remainingCount == 1 {
            searchMatchText = .key("search.matchedCount.one")
        } else {
            searchMatchText = .formatted("search.matchedCount", formatFileCount(UInt64(remainingCount)))
        }
    }
}

// MARK: - NSWindowDelegate

extension SearchWindow: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        saveWindowFrameIfNeeded()
    }

    func windowDidResize(_ notification: Notification) {
        saveWindowFrameIfNeeded()
    }
    
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideWindowWithAnimation()
        return false
    }
}

// MARK: - NSSearchFieldDelegate

extension SearchWindow: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        searchChanged()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // 方向下键语义命令：当光标处于文本末尾或输入为空时，将焦点交接至结果列表
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            let length = (textView.string as NSString).length
            if textView.selectedRange.length == 0 && textView.selectedRange.location == length {
                if searchResultsViewController.results.count > 0 {
                    return searchResultsViewController.focusResults()
                }
            }
        }
        return false
    }
}

// MARK: - Toolbar Item Identifiers

extension NSToolbarItem.Identifier {
    static let searchField = NSToolbarItem.Identifier("lokii.toolbar.searchField")
    static let resetWindowSize = NSToolbarItem.Identifier("lokii.toolbar.resetWindowSize")
}

/// 锁定为纯图标模式的主工具栏，屏蔽系统右键“图标和文本”切换，保证通栏检索布局紧凑稳定
final class LokiiToolbar: NSToolbar {
    override var displayMode: NSToolbar.DisplayMode {
        get { .iconOnly }
        set { /* 强制锁定纯图标显示模式 */ }
    }
}

// MARK: - NSToolbarDelegate

extension SearchWindow: NSToolbarDelegate {
    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .toggleSidebar:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = L("search.toggleSidebar")
            item.paletteLabel = L("search.toggleSidebar")
            item.toolTip = L("search.toggleSidebar")
            return item

        case .sidebarTrackingSeparator:
            return NSTrackingSeparatorToolbarItem(
                identifier: itemIdentifier,
                splitView: splitViewController.splitView,
                dividerIndex: 0
            )

        case .searchField:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = searchContainer
            item.label = L("search.placeholder")
            item.paletteLabel = L("search.placeholder")
            item.isNavigational = true
            return item

        case .resetWindowSize:
            let button = NSButton()
            button.image = NSImage(systemSymbolName: "textformat.size", accessibilityDescription: L("window.viewOptions"))
            button.bezelStyle = .toolbar
            button.isBordered = false
            button.toolTip = L("window.viewOptions")
            button.contentTintColor = .secondaryLabelColor
            button.target = self
            button.action = #selector(showViewOptionsMenu(_:))

            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = button
            item.label = L("window.viewOptions")
            item.paletteLabel = L("window.viewOptions")
            item.toolTip = L("window.viewOptions")
            return item

        default:
            return nil
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .searchField, .resetWindowSize]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .searchField, .resetWindowSize]
    }
}

// MARK: - View Options & Density Control

extension SearchWindow: NSMenuItemValidation {
    private var currentTableFontSize: CGFloat {
        get { TableDensity.savedFontSize }
        set {
            TableDensity.savedFontSize = newValue
            NotificationCenter.default.post(
                name: .tableDensityDidChange,
                object: nil,
                userInfo: ["fontSize": newValue]
            )
        }
    }

    @objc private func showViewOptionsMenu(_ sender: NSButton) {
        let menu = buildViewOptionsMenu()
        let location = NSPoint(x: 0, y: sender.bounds.height + 4)
        menu.popUp(positioning: nil, at: location, in: sender)
    }

    func buildViewOptionsMenu() -> NSMenu {
        let menu = NSMenu(title: L("window.viewOptions"))
        menu.autoenablesItems = true

        let zoomInItem = NSMenuItem(
            title: L("menu.zoomIn"),
            action: #selector(zoomInAction(_:)),
            keyEquivalent: "+"
        )
        zoomInItem.target = self
        menu.addItem(zoomInItem)

        let zoomOutItem = NSMenuItem(
            title: L("menu.zoomOut"),
            action: #selector(zoomOutAction(_:)),
            keyEquivalent: "-"
        )
        zoomOutItem.target = self
        menu.addItem(zoomOutItem)

        let actualSizeItem = NSMenuItem(
            title: L("menu.actualSize"),
            action: #selector(zoomActualSizeAction(_:)),
            keyEquivalent: "0"
        )
        actualSizeItem.target = self
        menu.addItem(actualSizeItem)

        menu.addItem(NSMenuItem.separator())

        for density in TableDensity.allCases {
            let item = NSMenuItem(
                title: L(density.titleKey),
                action: #selector(selectDensityAction(_:)),
                keyEquivalent: ""
            )
            item.tag = density.rawValue
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        let resetWindowItem = NSMenuItem(
            title: L("window.resetSize"),
            action: #selector(resetToDefaultWindowFrame),
            keyEquivalent: "0"
        )
        resetWindowItem.keyEquivalentModifierMask = [.command, .option]
        resetWindowItem.target = self
        menu.addItem(resetWindowItem)

        menu.addItem(NSMenuItem.separator())

        let preferencesItem = NSMenuItem(
            title: L("menu.preferences"),
            action: #selector(openPreferencesAction(_:)),
            keyEquivalent: ","
        )
        preferencesItem.target = self
        menu.addItem(preferencesItem)

        return menu
    }

    /// 按步长缩放列表字号，并钳制在可读区间内
    private func adjustFontSize(by delta: CGFloat) {
        let current = currentTableFontSize
        let next = min(
            max(current + delta, CGFloat(TableDensity.minFontSize)),
            CGFloat(TableDensity.maxFontSize)
        )
        if next != current {
            currentTableFontSize = next
        }
    }

    @objc private func zoomInAction(_ sender: Any?) {
        adjustFontSize(by: 2)
    }

    @objc private func zoomOutAction(_ sender: Any?) {
        adjustFontSize(by: -2)
    }

    @objc private func zoomActualSizeAction(_ sender: Any?) {
        currentTableFontSize = CGFloat(TableDensity.defaultFontSize)
    }

    @objc private func selectDensityAction(_ sender: NSMenuItem) {
        if let density = TableDensity(rawValue: sender.tag) {
            currentTableFontSize = density.fontSize
        }
    }

    @objc private func openPreferencesAction(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.openPreferences()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(zoomInAction(_:)) {
            return currentTableFontSize < CGFloat(TableDensity.maxFontSize)
        }
        if menuItem.action == #selector(zoomOutAction(_:)) {
            return currentTableFontSize > CGFloat(TableDensity.minFontSize)
        }
        if menuItem.action == #selector(zoomActualSizeAction(_:)) {
            return currentTableFontSize != CGFloat(TableDensity.defaultFontSize)
        }
        if menuItem.action == #selector(selectDensityAction(_:)) {
            menuItem.state = (Int(currentTableFontSize) == menuItem.tag) ? .on : .off
            return true
        }
        return true
    }
}


// MARK: - 快捷键接力与文件夹浏览

/// LokiiWindow 的快捷键闭包落到本窗口的实现，以及「Space 就地展开文件夹」的整套浏览逻辑。
///
/// 这里的方法都由 `installInteractionShortcuts(on:)` 接进 `LokiiWindow`：每个闭包先核对
/// 当前焦点与选中状态，条件不满足就返回 `false` 把事件交回 AppKit，因此搜索框里的
/// 空格仍然是空格、⌘↓ 仍然是表格自己的快捷键。
extension SearchWindow {
    // MARK: - 快捷键安装

    /// 把 LokiiWindow 的其余快捷键闭包接到本窗口的实现上。
    func installInteractionShortcuts(on window: LokiiWindow) {
        // ⌘↩ 交给 LaunchBar，⇧↩ 交给 Keyboard Maestro
        window.onCommandReturn = { [weak self] in
            self?.handoffToLaunchBar() ?? false
        }
        window.onShiftReturn = { [weak self] in
            self?.handoffToKeyboardMaestro() ?? false
        }
        // ⌘1…⌘9 快速选中第 N 个结果；无修饰键的普通字符把焦点送回搜索框继续筛选
        window.onSelectResult = { [weak self] index in
            self?.selectResult(at: index) ?? false
        }
        window.onTypeCharacter = { [weak self] characters in
            self?.typeAheadFilter(characters) ?? false
        }
        // Space 预览文件 / 展开文件夹，⌘↓ 进入文件夹，⌘↑ 返回上一级
        window.onPreview = { [weak self] in
            self?.handleSpace() ?? false
        }
        window.onCommandDown = { [weak self] in
            self?.enterSelectedFolder() ?? false
        }
        window.onCommandUp = { [weak self] in
            self?.leaveFolder() ?? false
        }
    }

    // MARK: - 焦点与选中状态

    /// 是否正在浏览某个目录。
    private var isBrowsing: Bool { browsingFolder != nil }

    /// 结果列表的表格视图。
    private var resultsTableView: SearchTableView { searchResultsViewController.tableView }

    /// 表格当前的行数（浏览模式下就是过滤后的目录条目数）。
    private var rowCount: Int { searchResultsViewController.results.count }

    /// 键盘焦点是否落在结果列表里（表格本身或它的子视图）。
    private func isResultsFocused(_ window: NSWindow) -> Bool {
        guard let responder = window.firstResponder as? NSView else { return false }
        let table = resultsTableView
        return responder === table || responder.isDescendant(of: table)
    }

    /// 表格第 `row` 行对应的条目；浏览模式下同样由这张表承载目录条目。
    private func resultAt(row: Int) -> FfiSearchResult? {
        let results = searchResultsViewController.results
        guard row >= 0, row < results.count else { return nil }
        return results[row]
    }

    /// 表格中选中条目对应的文件 URL（按行序）。
    private func selectedURLs() -> [URL] {
        searchResultsViewController.selectedResults.map { URL(fileURLWithPath: $0.path) }
    }

    /// Quick Look 面板是否正开着（`sharedPreviewPanelExists` 保证不会顺手把面板建出来）。
    private var isPreviewing: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && (QLPreviewPanel.shared()?.isVisible ?? false)
    }

    // MARK: - ⌘1…⌘9

    /// ⌘1…⌘9：选中第 N 个结果，并把键盘焦点交给列表，紧接着 ↩ 就能打开它。
    /// 序号超出当前结果数时给一声提示音，而不是把按键静默吞掉。
    private func selectResult(at index: Int) -> Bool {
        let row = index - 1
        guard row < rowCount else {
            NSSound.beep()
            return true
        }
        return searchResultsViewController.focusResults(row: row)
    }

    // MARK: - 打字即筛选

    /// 列表聚焦时按普通字符：当作「开始筛选」，聚焦搜索框后把按键交回 AppKit，
    /// 让 field editor 走正常输入流程——Rime 等输入法能接管组合输入（拼音候选），
    /// 而不是被直接打成英文输出。焦点不在结果列表时同样返回 false 交回默认行为。
    private func typeAheadFilter(_ characters: String) -> Bool {
        guard let window, isResultsFocused(window) else { return false }
        // 只聚焦、不直接 insertText：insertText 会绕过输入法上下文，把字符当英文提交。
        // 返回 false 让事件继续分发到刚聚焦的 field editor，由输入法正常接管。
        focusSearchField()
        return false
    }



    // MARK: - ⌘C 复制路径

    /// ⌘C 在主窗口按下时的实际处理（由 AppDelegate 的「编辑 → 拷贝」菜单项转发过来）。
    ///
    /// 之所以绕这一圈：搜索框有焦点时，field editor 自己实现了 `copy:`，
    /// 主菜单原来的「拷贝」项会先被它接管——没有选中文本时静默无动作，
    /// 这正是「必须先右键再按 ⌘C 才能复制路径」的原因。改用本方法作为菜单项
    /// 的 action 后不再和 NSTextView 抢 `copy:`。
    ///
    /// 返回 `false` 表示这次不该处理（搜索框里有选中文字，或没有选中条目）。
    func copySelectedPathsToPasteboard() -> Bool {
        if let editor = window?.firstResponder as? NSTextView, editor.selectedRange().length > 0 {
            return false
        }
        let paths = searchResultsViewController.selectedResults.map(\.path)
        guard !paths.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        flashStatus(String(format: L("search.copiedPaths"), paths.count))
        return true
    }

    // MARK: - 交给外部 App

    /// 右键菜单入口：把选中项交给 LaunchBar（对应 ⌘↩）。
    @objc func sendSelectionToLaunchBar(_ sender: Any?) {
        _ = handoffToLaunchBar()
    }

    /// 把选中的结果交给 LaunchBar，让用户在那边挑后续动作。
    /// 返回 `false` 表示没有交出去，调用方可退回 AppKit 的默认行为。
    @discardableResult
    func handoffToLaunchBar() -> Bool {
        guard LaunchBar.isInstalled else {
            statusText = .key("search.launchBar.notInstalled")
            NSSound.beep()
            return false
        }

        let urls = selectedURLs()
        guard !urls.isEmpty else {
            NSSound.beep()
            return false
        }

        guard LaunchBar.send(urls: urls) else {
            statusText = .key("search.launchBar.failed")
            NSSound.beep()
            return false
        }
        return true
    }

    /// 右键菜单入口：把选中项交给 Keyboard Maestro（对应 ⇧↩）。
    @objc func sendSelectionToKeyboardMaestro(_ sender: Any?) {
        _ = handoffToKeyboardMaestro()
    }

    /// ⇧↩（或右键菜单）：把选中项交给 Keyboard Maestro 的宏继续处理。
    ///
    /// 路径既作为 `do script` 的参数传入（宏里用 `%TriggerValue%` 取），
    /// 也写进 KM 变量 `LokiiPath` / `LokiiPaths`，具体见 `KeyboardMaestro`。
    @discardableResult
    func handoffToKeyboardMaestro() -> Bool {
        guard KeyboardMaestro.isInstalled else {
            statusText = .key("search.keyboardMaestro.notInstalled")
            NSSound.beep()
            return false
        }

        let urls = selectedURLs()
        guard !urls.isEmpty else {
            NSSound.beep()
            return false
        }

        // KM 的 `do script` 会等宏执行完才返回，宏里可能带等待/交互动作，
        // 放在主线程会把界面卡住，所以丢到后台队列去发。
        statusText = .key("search.keyboardMaestro.sending")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = Result { try KeyboardMaestro.handoff(paths: urls) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch outcome {
                case .success(let returned):
                    // 宏里如果有 Return 动作，其返回值直接显示出来，方便调试宏
                    self.flashStatus(returned ?? L("search.keyboardMaestro.done"))
                case .failure(let error):
                    self.statusText = .verbatim(error.localizedDescription)
                    NSSound.beep()
                }
            }
        }
        return true
    }

    /// 右键菜单入口：把焦点送回搜索框，光标停在文本末尾，方便接着改查询。
    @objc func focusSearchFieldFromMenu(_ sender: Any?) {
        focusSearchField()
    }

    // MARK: - 文件夹浏览

    /// Escape 的拦截入口：浏览模式下退回搜索结果，其余情况把 Escape 原样放行。
    private func exitBrowseIfNeeded() -> Bool {
        guard isBrowsing else { return false }
        exitBrowse()
        return true
    }

    /// Space：焦点在搜索框就原样当空格用；焦点在结果列表时，选中的是文件夹就就地展开，
    /// 是文件就交回结果列表弹 Quick Look。
    private func handleSpace() -> Bool {
        guard let window else { return false }
        let row = resultsTableView.selectedRow
        let selected = resultAt(row: row)
        let focus = SpaceRules.focusTarget(
            firstResponder: window.firstResponder,
            searchFieldEditor: searchField.currentEditor(),
            isResultsResponder: isResultsFocused(window)
        )
        let selection = SpaceRules.selectionKind(
            selectedRow: row,
            isSelectedContainer: selected.map { FolderBrowse.isContainer(at: $0.path) }
        )
        switch SpaceRules.intent(focus: focus, selection: selection, isPreviewing: isPreviewing) {
        case .enterFolder:
            if let path = selected?.path { browse(folder: path) }
            return true
        case .passThrough, .preview, .closePreview:
            // 预览与收面板归结果列表自己的 Space 处理（Quick Look 面板在 SearchResultsViewController 里）
            return false
        }
    }

    /// ⌘↓：焦点在结果列表时进入选中的文件夹。
    private func enterSelectedFolder() -> Bool {
        guard let window, isResultsFocused(window),
              let result = resultAt(row: resultsTableView.selectedRow),
              FolderBrowse.isContainer(at: result.path) else { return false }
        browse(folder: result.path)
        return true
    }

    /// ⌘↑：浏览模式下回到上一级（并把刚离开的目录选上）；
    /// 不在浏览模式时，把选中项所在的目录当作起点开始浏览。
    private func leaveFolder() -> Bool {
        guard let window, isResultsFocused(window) else { return false }
        if let folder = browsingFolder {
            if let parent = FolderBrowse.parent(of: folder) {
                browse(folder: parent, select: folder)
            } else {
                exitBrowse()
            }
            return true
        }
        guard let result = resultAt(row: resultsTableView.selectedRow),
              let parent = FolderBrowse.parent(of: result.path) else { return false }
        browse(folder: parent, select: result.path)
        return true
    }

    /// 进入 `folder` 的浏览模式；`select` 用来在进入后选中指定条目（⌘↑ 回上级时用）。
    private func browse(folder: String, select: String? = nil) {
        let includeHidden = engine.getConfig()?.index.includeHidden ?? false
        guard let listing = FolderBrowse.listing(in: folder, includeHidden: includeHidden) else {
            flashStatus(L("search.browseUnreadable"))
            NSSound.beep()
            return
        }

        if !isBrowsing {
            // 第一次进入浏览模式：把当前查询留底，一路 ⌘↑ 退到最顶层时原样放回
            savedQuery = lastQuery
        }
        // 每进入一个文件夹都清空搜索框，完整列出该目录内容（否则会带着上一步的词继续过滤）。
        // 先改 lastQuery 再写回搜索框，让 searchChanged 的去重直接拦下、不再清一遍列表。
        lastQuery = ""
        searchField.stringValue = ""

        browsingFolder = folder
        browseEntries = listing.entries
        browseTruncated = listing.truncated
        searchField.placeholderString = L("search.browsePlaceholder")
        applyBrowseFilter(select: select)
    }

    /// 按搜索框里的关键字过滤当前目录，并把结果写进列表。
    private func applyBrowseFilter(select: String? = nil) {
        guard isBrowsing else { return }
        let shown = FolderBrowse.filter(browseEntries, query: lastQuery)
        let items = shown.map { Self.browseResult(for: $0, query: lastQuery) }
        searchResultsViewController.displayResults(items, preserveSelection: false)

        if let select,
           let row = searchResultsViewController.results.firstIndex(where: { $0.path == select }) {
            searchResultsViewController.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            searchResultsViewController.tableView.scrollRowToVisible(row)
            searchResultsViewController.updateBottomPath(with: select)
        }
        updateBrowseStatus(shown: shown.count)
    }

    /// 退出浏览模式：恢复进入前的查询与列表，并把搜索框的占位提示换回去。
    private func exitBrowse() {
        guard isBrowsing else { return }
        if isPreviewing { QLPreviewPanel.shared()?.orderOut(nil) }

        let query = savedQuery ?? ""
        browsingFolder = nil
        browseEntries = []
        browseTruncated = false
        savedQuery = nil
        searchMatchText = nil
        searchField.placeholderString = originalSearchPlaceholder

        // 先改 lastQuery 再写回搜索框：即便控件回调了 searchChanged，也会被去重挡下来
        lastQuery = query
        searchField.stringValue = query
        if query.isEmpty {
            loadDefaultResults()
        } else {
            performSearch(query: query)
        }
    }

    /// 浏览模式的状态栏：左边是当前目录，右边是「显示 N / 共 M 项」。
    private func updateBrowseStatus(shown: Int) {
        let total = browseEntries.count
        let shownText = formatFileCount(UInt64(shown))
        let totalText = formatFileCount(UInt64(total))
        searchMatchText = shown == total
            ? .formatted("search.browseCount", shownText)
            : .verbatim(String(format: L("search.browseCountFiltered"), shownText, totalText))

        if let folder = browsingFolder {
            let label = Self.abbreviated(path: folder)
            if browseTruncated {
                let note = String(format: L("search.browseTruncated"),
                                  formatFileCount(UInt64(FolderBrowse.defaultMaxEntries)))
                statusText = .verbatim(String(format: L("search.browseStatus"), label) + " · " + note)
            } else {
                statusText = .formatted("search.browseStatus", label)
            }
        }
        if searchResultsViewController.selectedResults.isEmpty, let folder = browsingFolder {
            searchResultsViewController.updateBottomPath(with: folder)
        }
    }


    // MARK: - 浏览条目 → 结果行

    /// 把目录条目包装成结果行，列表因此能沿用同一套单元格、图标与列宽。
    private static func browseResult(for entry: BrowseEntry, query: String) -> FfiSearchResult {
        FfiSearchResult(
            name: entry.name,
            path: entry.path,
            isDir: entry.isContainer,
            size: entry.size,
            modified: entry.modified,
            created: entry.created,
            extension: (entry.name as NSString).pathExtension,
            score: 0,
            matchPositions: matchPositions(in: entry.name, query: query),
            parentMatchPositions: [],
            searchMode: .substring
        )
    }

    /// 目录内过滤时的命中区间：用于把匹配到的字母标出来。
    /// 过滤本身（`FolderBrowse.filter`）只要大小写/变音符不敏感的子串，这里与之保持一致。
    private static func matchPositions(in name: String, query: String) -> [FfiMatchRange] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        var ranges: [FfiMatchRange] = []
        var searchStart = name.startIndex
        while searchStart < name.endIndex,
              let found = name.range(of: trimmed,
                                     options: [.caseInsensitive, .diacriticInsensitive],
                                     range: searchStart..<name.endIndex) {
            ranges.append(FfiMatchRange(
                start: UInt32(name.distance(from: name.startIndex, to: found.lowerBound)),
                end: UInt32(name.distance(from: name.startIndex, to: found.upperBound))
            ))
            searchStart = found.upperBound
            if found.isEmpty { break }
        }
        return ranges
    }

    // MARK: - 状态栏

    /// 临时提示：显示 `message`，过一会儿自动换回正常状态文字。
    private func flashStatus(_ message: String) {
        statusResetWorkItem?.cancel()
        statusText = .verbatim(message)
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.isBrowsing {
                self.updateBrowseStatus(shown: self.rowCount)
            } else {
                self.refreshIdleStatus()
            }
        }
        statusResetWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: item)
    }

    /// 把状态栏换回「已索引 N 个文件」。
    private func refreshIdleStatus() {
        statusText = .formatted("search.indexedCount", formatFileCount(engine.stats.totalCount))
    }

    /// 状态栏里的目录：`$HOME` 用 `~` 缩写，太长的路径保留末尾两级。
    private static func abbreviated(path: String) -> String {
        let tilde = (path as NSString).abbreviatingWithTildeInPath
        let components = tilde.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > 3 else { return tilde }
        return (tilde.hasPrefix("~") ? "~/" : "/") + components.suffix(2).joined(separator: "/")
    }
}

