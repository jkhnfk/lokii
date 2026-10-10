import AppKit
import QuickLookUI
import UniformTypeIdentifiers

/// Blocks all mouse and keyboard events so the UI beneath is not interactive.
private final class EventBlockingView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { self }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func keyDown(with event: NSEvent) {}
    override func keyUp(with event: NSEvent) {}
}

/// Container view that perfectly stabilizes rotation for a subview
/// to prevent AppKit's frame syncing from breaking the anchor point.
private final class CenterSpinContainerView: NSView {
    override func layout() {
        super.layout()
        guard let subview = subviews.first else { return }
        subview.frame = bounds
        if let layer = subview.layer {
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }
}

final class SearchWindow: NSWindowController {
    private let engine: SearchEngine
    private let defaultWindowFrame = NSRect(x: 0, y: 0, width: 900, height: 580)
    private let savedWindowFrameKey = "LokiiMainWindowFrame"
    private var results: [FfiSearchResult] = []
    private var searchField: NSSearchField!
    private var tableView: NSTableView!
    private var countLabel: NSTextField!
    private var pathBar: NSPathControl!
    private var statusLabel: NSTextField!
    private var searchWorkItem: DispatchWorkItem?
    private var currentMode: FfiSearchMode = .auto

    // 文件夹浏览（Space 展开 / ⌘↓ 下钻 / ⌘↑ 返回上一级）
    /// 当前正在浏览的目录；`nil` 表示列表内容来自搜索结果。
    private var browsingFolder: String?
    /// 当前目录的完整条目（已按表格排序描述符排好），过滤前的全集。
    private var browseAllEntries: [BrowseEntry] = []
    /// 过滤后真正显示在表格里的条目。
    private var browseEntries: [BrowseEntry] = []
    /// 条目数触顶被截断（超大目录只列前 `FolderBrowse.defaultMaxEntries` 条）。
    private var browseTruncated = false
    /// 进入浏览模式前的搜索结果，一路 ⌘↑ 退到最顶层时原样恢复。
    private var savedSearch: SavedSearch?
    /// 弹 Quick Look 面板时选中的那批 URL：表格选中行被清掉后仍要能翻页预览。
    private var previewItemsFallback: [URL] = []

    /// 进入浏览模式时暂存的搜索结果快照。
    private struct SavedSearch {
        let results: [FfiSearchResult]
        let query: String
        let count: String
        let status: String
    }

    // Info panel
    private var infoPanelView: NSView!
    private var infoIconView: NSImageView!
    private var infoNameLabel: NSTextField!
    private var infoKindLabel: NSTextField!
    private var infoDetailLabels: [(key: NSTextField, value: NSTextField)] = []
    private var infoPanelWidth: NSLayoutConstraint!
    private var infoPanelVisible = false
    private var toggleInfoButton: NSButton!

    // Rebuild button and loading overlay
    private var rebuildButton: NSButton!
    private var loadingOverlay: NSView?
    private var overlayHeadingLabel: NSTextField?
    private var overlaySubtextLabel: NSTextField?
    private var overlayShownAt: Date?
    private var isColdStart: Bool = true  // Default true until startup mode known
    private var overlayProgressIndicator: NSProgressIndicator?
    private var inlineProgressIndicator: NSView?
    private var originalSearchPlaceholder: String = L("search.placeholder")

    /// Tracks why the loading overlay is showing, so `onIndexReady` from
    /// a concurrent initialize/verify doesn't accidentally dismiss a rebuild overlay.
    private enum IndexingState { case idle, initializing, rebuilding }
    private var indexingState: IndexingState = .initializing

    // Main split: table scroll + info panel
    private var tableScrollView: NSScrollView!

    // Icon cache
    private var iconCache: [String: NSImage] = [:]

    // Shared formatters
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/M/d, HH:mm"
        return f
    }()
    private static let fullDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .medium
        return f
    }()
    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()
    private static let countFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    init(engine: SearchEngine) {
        self.engine = engine

        let window = LokiiWindow(
            contentRect: defaultWindowFrame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.title = "Lokii"
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 700, height: 400)
        window.contentMinSize = NSSize(width: 700, height: 370)
        window.isReleasedWhenClosed = false

        super.init(window: window)

        window.delegate = self
        applyInitialWindowFrame()

        window.onEscape = { [weak self] in
            self?.hideWindowWithAnimation()
        }
        // Escape 在 sendEvent 阶段拦截：浏览模式下退出文件夹，赶在搜索框 field editor
        // 吃掉 Escape 之前消费掉；不在浏览模式时放行，Esc 继续走清空搜索框/隐藏窗口。
        window.onEscapeIntercept = { [weak self] in
            guard let self, self.isBrowsing else { return false }
            self.exitBrowse()
            return true
        }
        window.onReturn = { [weak self] in
            self?.openSelected()
        }
        // ⌘↩ 交给 LaunchBar，⇧↩ 交给 Keyboard Maestro，⌘F 回到搜索框。
        // Tab 已交还 AppKit 默认的焦点切换行为。
        window.onCommandReturn = { [weak self] in
            self?.sendSelectionToLaunchBar() ?? false
        }
        window.onShiftReturn = { [weak self] in
            self?.sendSelectionToKeyboardMaestro() ?? false
        }
        window.onCommandF = { [weak self] in
            guard let self else { return false }
            self.focusSearchField()
            return true
        }
        // ⌘1…⌘9 快速选中第 N 个结果；↓ 从搜索框跳到列表，↑ 由首行回到搜索框末尾。
        // 这三个闭包内部都会先核对当前焦点状态，条件不满足时返回 false 交回 AppKit。
        window.onSelectResult = { [weak self] index in
            self?.selectResult(at: index) ?? false
        }
        window.onMoveDownFromSearchField = { [weak self] in
            self?.moveFocusToResultsFromSearchField() ?? false
        }
        window.onMoveUpFromResults = { [weak self] in
            self?.moveFocusToSearchFieldFromResults() ?? false
        }
        // Space 预览文件 / 展开文件夹，⌘↓ 进入文件夹，⌘↑ 返回上一级。
        // 这三个闭包同样先核对焦点与选中状态，条件不满足时返回 false 交回 AppKit
        // （搜索框里的空格仍然是空格字符，⌘↓ 仍然是表格自己的快捷键）。
        window.onPreview = { [weak self] in
            self?.handleSpace() ?? false
        }
        window.onCommandDown = { [weak self] in
            self?.enterSelectedFolder() ?? false
        }
        window.onCommandUp = { [weak self] in
            self?.leaveFolder() ?? false
        }
        // 无修饰键的普通字符：列表聚焦时打字即筛选，聚焦搜索框并输入该字符。
        window.onTypeCharacter = { [weak self] characters in
            self?.typeAheadFilter(characters) ?? false
        }

        setupUI()
        window.contentView?.wantsLayer = true
        setupSearchModeMenu()
        setupNotifications()
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
        guard let window = window, window.isVisible else { return }

        // 关窗顺手收起 Quick Look 面板，免得它孤零零留在屏幕上
        dismissPreview()

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

    // MARK: - Toolbar item identifiers

    private static let searchBarItem = NSToolbarItem.Identifier("searchBar")

    // MARK: - UI Setup

    private func setupUI() {
        guard let contentView = window?.contentView,
              let layoutGuide = window?.contentLayoutGuide as? NSLayoutGuide else { return }

        // ── Toolbar with search field ──

        searchField = NSSearchField()
        searchField.placeholderString = L("search.placeholder")
        searchField.font = .systemFont(ofSize: 14)
        searchField.focusRingType = .exterior
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = false

        countLabel = NSTextField(labelWithString: "")
        countLabel.font = .systemFont(ofSize: 12)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        // Toggle info panel button (sidebar icon)
        toggleInfoButton = NSButton(image: NSImage(systemSymbolName: "sidebar.right",
                                                   accessibilityDescription: "Toggle Info")!,
                                    target: self, action: #selector(toggleInfoPanel))
        toggleInfoButton.bezelStyle = .toolbar
        toggleInfoButton.isBordered = false
        toggleInfoButton.toolTip = L("search.toggleInfo")

        let toolbar = NSToolbar(identifier: "LokiiMainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window?.toolbar = toolbar

        // Rebuild index button — placed in bottom bar, not toolbar
        rebuildButton = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise",
                                                 accessibilityDescription: "Rebuild Index")!,
                                  target: self, action: #selector(rebuildIndexClicked))
        rebuildButton.bezelStyle = .toolbar
        rebuildButton.isBordered = false
        rebuildButton.toolTip = L("search.rebuildIndex")
        rebuildButton.contentTintColor = .secondaryLabelColor

        // ── Middle area: table + info panel side by side ──
        let middleView = NSView()
        middleView.translatesAutoresizingMaskIntoConstraints = false
        middleView.wantsLayer = true
        middleView.layer?.masksToBounds = true
        contentView.addSubview(middleView)

        // Table
        tableView = NSTableView()
        tableView.style = .fullWidth
        tableView.rowHeight = 20
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnSelection = false
        tableView.gridStyleMask = []
        tableView.selectionHighlightStyle = .regular
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(tableDoubleClicked)
        tableView.target = self

        addTableColumns()

        tableScrollView = NSScrollView()
        tableScrollView.translatesAutoresizingMaskIntoConstraints = false
        tableScrollView.documentView = tableView
        tableScrollView.hasVerticalScroller = true
        tableScrollView.hasHorizontalScroller = false
        tableScrollView.autohidesScrollers = true
        tableScrollView.borderType = .noBorder
        tableScrollView.drawsBackground = true
        middleView.addSubview(tableScrollView)

        // Info panel (right side, initially hidden)
        setupInfoPanel(in: middleView)

        // ── Bottom bar: path bar + status ──
        let bottomBar = NSView()
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.wantsLayer = true
        contentView.addSubview(bottomBar)

        // Separator line above bottom bar
        let separator = NSBox()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator
        contentView.addSubview(separator)

        pathBar = NSPathControl()
        pathBar.translatesAutoresizingMaskIntoConstraints = false
        pathBar.pathStyle = .standard
        pathBar.isEditable = false
        pathBar.font = .systemFont(ofSize: 11)
        pathBar.backgroundColor = .clear
        pathBar.focusRingType = .none
        pathBar.refusesFirstResponder = true
        pathBar.target = self
        pathBar.action = #selector(pathBarClicked)
        pathBar.url = nil
        pathBar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathBar.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bottomBar.addSubview(pathBar)

        statusLabel = NSTextField(labelWithString: L("search.indexing"))
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.alignment = .right
        statusLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        bottomBar.addSubview(statusLabel)

        // Container to stabilize anchor point for rotation
        let rebuildContainer = CenterSpinContainerView()
        rebuildContainer.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(rebuildContainer)

        rebuildButton.translatesAutoresizingMaskIntoConstraints = true
        rebuildButton.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        rebuildButton.wantsLayer = true
        rebuildContainer.addSubview(rebuildButton)

        // ── Layout ──
        NSLayoutConstraint.activate([
            middleView.topAnchor.constraint(equalTo: layoutGuide.topAnchor),
            middleView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            middleView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            middleView.bottomAnchor.constraint(equalTo: separator.topAnchor),
            middleView.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),

            tableScrollView.topAnchor.constraint(equalTo: middleView.topAnchor),
            tableScrollView.leadingAnchor.constraint(equalTo: middleView.leadingAnchor),
            tableScrollView.bottomAnchor.constraint(equalTo: middleView.bottomAnchor),

            separator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            bottomBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 24),

            pathBar.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 8),
            pathBar.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            pathBar.trailingAnchor.constraint(lessThanOrEqualTo: statusLabel.leadingAnchor, constant: -8),

            statusLabel.trailingAnchor.constraint(equalTo: rebuildContainer.leadingAnchor, constant: -4),
            statusLabel.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),

            rebuildContainer.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -8),
            rebuildContainer.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            rebuildContainer.widthAnchor.constraint(equalToConstant: 20),
            rebuildContainer.heightAnchor.constraint(equalToConstant: 20),
        ])

        // Table takes full width when info panel hidden
        tableScrollView.trailingAnchor.constraint(equalTo: infoPanelView.leadingAnchor).isActive = true

        rebuildButton.isEnabled = false

        // Context menu
        // 注意：`NSMenuItem` 默认的 `keyEquivalentModifierMask` 是 ⌘，只有显式写出的
        // 修饰键才与这里标称的快捷键一致；Open 不挂快捷键（↩ 由窗口的 keyDown 处理），
        // 把 ⌘↩ 让给「用 LaunchBar 处理」。
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: L("search.ctx.open"), action: #selector(openSelected), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L("search.ctx.revealInFinder"), action: #selector(revealSelected), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: L("search.ctx.copyPath"), action: #selector(copyPath), keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: L("search.ctx.copyName"), action: #selector(copyName), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: L("search.ctx.focusSearch"), action: #selector(focusSearchFieldFromMenu), keyEquivalent: "f"))
        menu.addItem(NSMenuItem.separator())

        // 交给外部 App 继续处理：⌘↩ → LaunchBar，⇧↩ → Keyboard Maestro
        let launchBarItem = NSMenuItem(title: L("search.ctx.launchBar"),
                                       action: #selector(sendToLaunchBar), keyEquivalent: "\r")
        launchBarItem.keyEquivalentModifierMask = .command
        menu.addItem(launchBarItem)

        let keyboardMaestroItem = NSMenuItem(title: L("search.ctx.keyboardMaestro"),
                                             action: #selector(sendToKeyboardMaestro), keyEquivalent: "\r")
        keyboardMaestroItem.keyEquivalentModifierMask = .shift
        menu.addItem(keyboardMaestroItem)

        tableView.menu = menu
    }

    private func addTableColumns() {
        let nameCol = NSTableColumn(identifier: .columnName)
        nameCol.title = L("search.col.name")
        nameCol.width = 280
        nameCol.minWidth = 140
        nameCol.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true,
                                                           selector: #selector(NSString.localizedStandardCompare(_:)))
        tableView.addTableColumn(nameCol)

        let pathCol = NSTableColumn(identifier: .columnPath)
        pathCol.title = L("search.col.path")
        pathCol.width = 240
        pathCol.minWidth = 100
        pathCol.sortDescriptorPrototype = NSSortDescriptor(key: "path", ascending: true,
            selector: #selector(NSString.localizedStandardCompare(_:)))
        tableView.addTableColumn(pathCol)

        let modifiedCol = NSTableColumn(identifier: .columnModified)
        modifiedCol.title = L("search.col.dateModified")
        modifiedCol.width = 160
        modifiedCol.minWidth = 100
        modifiedCol.sortDescriptorPrototype = NSSortDescriptor(key: "modified", ascending: false)
        tableView.addTableColumn(modifiedCol)

        let sizeCol = NSTableColumn(identifier: .columnSize)
        sizeCol.title = L("search.col.size")
        sizeCol.width = 80
        sizeCol.minWidth = 50
        sizeCol.headerCell.alignment = .right
        sizeCol.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: false)
        tableView.addTableColumn(sizeCol)
    }

    // MARK: - Info Panel

    private func setupInfoPanel(in parent: NSView) {
        infoPanelView = ThemedBackgroundView()
        infoPanelView.translatesAutoresizingMaskIntoConstraints = false
        infoPanelView.wantsLayer = true
        infoPanelView.layer?.masksToBounds = true
        parent.addSubview(infoPanelView)

        // Vertical separator
        let sep = NSBox()
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.boxType = .separator
        infoPanelView.addSubview(sep)

        // Large icon
        infoIconView = NSImageView()
        infoIconView.translatesAutoresizingMaskIntoConstraints = false
        infoIconView.imageScaling = .scaleProportionallyUpOrDown
        infoPanelView.addSubview(infoIconView)

        // Name
        infoNameLabel = NSTextField(wrappingLabelWithString: "")
        infoNameLabel.translatesAutoresizingMaskIntoConstraints = false
        infoNameLabel.font = .boldSystemFont(ofSize: 13)
        infoNameLabel.alignment = .center
        infoNameLabel.maximumNumberOfLines = 2
        infoNameLabel.lineBreakMode = .byTruncatingMiddle
        infoPanelView.addSubview(infoNameLabel)

        // Kind subtitle
        infoKindLabel = NSTextField(labelWithString: "")
        infoKindLabel.translatesAutoresizingMaskIntoConstraints = false
        infoKindLabel.font = .systemFont(ofSize: 11)
        infoKindLabel.textColor = .secondaryLabelColor
        infoKindLabel.alignment = .center
        infoPanelView.addSubview(infoKindLabel)

        // Detail rows container
        let detailStack = NSStackView()
        detailStack.translatesAutoresizingMaskIntoConstraints = false
        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 4
        infoPanelView.addSubview(detailStack)

        let fields = [
            L("search.info.kind"),
            L("search.info.size"),
            L("search.info.created"),
            L("search.info.modified"),
            L("search.info.where"),
        ]
        for (i, label) in fields.enumerated() {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 6
            row.alignment = .top

            let key = NSTextField(labelWithString: label)
            key.font = .systemFont(ofSize: 11)
            key.textColor = .secondaryLabelColor
            key.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            key.widthAnchor.constraint(equalToConstant: 60).isActive = true
            key.alignment = .right

            let value = NSTextField(wrappingLabelWithString: "—")
            value.font = .systemFont(ofSize: 11)
            value.textColor = .labelColor
            value.maximumNumberOfLines = 2
            value.lineBreakMode = .byTruncatingMiddle

            if i == 4 {  // Where (last field)
                value.maximumNumberOfLines = 0
                value.lineBreakMode = .byCharWrapping
            }

            row.addArrangedSubview(key)
            row.addArrangedSubview(value)
            detailStack.addArrangedSubview(row)
            infoDetailLabels.append((key: key, value: value))
        }

        infoPanelWidth = infoPanelView.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            infoPanelView.topAnchor.constraint(equalTo: parent.topAnchor),
            infoPanelView.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            infoPanelView.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            infoPanelWidth,

            sep.topAnchor.constraint(equalTo: infoPanelView.topAnchor),
            sep.bottomAnchor.constraint(equalTo: infoPanelView.bottomAnchor),
            sep.leadingAnchor.constraint(equalTo: infoPanelView.leadingAnchor),
            sep.widthAnchor.constraint(equalToConstant: 1),

            infoIconView.topAnchor.constraint(equalTo: infoPanelView.topAnchor, constant: 20),
            infoIconView.centerXAnchor.constraint(equalTo: infoPanelView.centerXAnchor),
            infoIconView.widthAnchor.constraint(equalToConstant: 64),
            infoIconView.heightAnchor.constraint(equalToConstant: 64),

            infoNameLabel.topAnchor.constraint(equalTo: infoIconView.bottomAnchor, constant: 8),
            infoNameLabel.leadingAnchor.constraint(equalTo: sep.trailingAnchor, constant: 12),
            infoNameLabel.trailingAnchor.constraint(equalTo: infoPanelView.trailingAnchor, constant: -12),

            infoKindLabel.topAnchor.constraint(equalTo: infoNameLabel.bottomAnchor, constant: 2),
            infoKindLabel.leadingAnchor.constraint(equalTo: infoNameLabel.leadingAnchor),
            infoKindLabel.trailingAnchor.constraint(equalTo: infoNameLabel.trailingAnchor),

            detailStack.topAnchor.constraint(equalTo: infoKindLabel.bottomAnchor, constant: 16),
            detailStack.leadingAnchor.constraint(equalTo: sep.trailingAnchor, constant: 8),
            detailStack.trailingAnchor.constraint(equalTo: infoPanelView.trailingAnchor, constant: -8),
        ])
    }

    @objc private func toggleInfoPanel() {
        infoPanelVisible.toggle()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            // Swift, native snappy curve
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.4, 1.0)
            ctx.allowsImplicitAnimation = true
            infoPanelWidth.constant = infoPanelVisible ? 240 : 0
            window?.contentView?.layoutSubtreeIfNeeded()
        }) { [weak self] in
            self?.tableView.sizeLastColumnToFit()
        }
        if infoPanelVisible {
            updateInfoPanel()
        }
    }

    private func updateInfoPanel() {
        guard let result = resultAt(row: tableView.selectedRow) else {
            infoIconView.image = nil
            infoNameLabel.stringValue = ""
            infoKindLabel.stringValue = ""
            for (_, v) in infoDetailLabels { v.stringValue = "—" }
            return
        }

        let icon = NSWorkspace.shared.icon(forFile: result.path)
        icon.size = NSSize(width: 64, height: 64)
        infoIconView.image = icon

        infoNameLabel.stringValue = result.name
        infoKindLabel.stringValue = kindDescription(for: result)

        // Kind
        infoDetailLabels[0].value.stringValue = kindDescription(for: result)

        // Size
        infoDetailLabels[1].value.stringValue = result.isDir ? "--"
            : Self.sizeFormatter.string(fromByteCount: Int64(result.size))

        // Created
        if result.created > 0 {
            let createdDate = Date(timeIntervalSince1970: TimeInterval(result.created))
            infoDetailLabels[2].value.stringValue = Self.fullDateFormatter.string(from: createdDate)
        } else {
            infoDetailLabels[2].value.stringValue = "---"
        }

        // Modified
        let date = Date(timeIntervalSince1970: TimeInterval(result.modified))
        infoDetailLabels[3].value.stringValue = Self.fullDateFormatter.string(from: date)

        // Where (parent dir)
        let parent = (result.path as NSString).deletingLastPathComponent
        infoDetailLabels[4].value.stringValue = abbreviatePath(parent)
    }

    // MARK: - Search Mode Menu (on the magnifying glass)

    private func setupSearchModeMenu() {
        let menu = NSMenu(title: L("search.mode.title"))
        let titles = [
            L("search.mode.auto"),
            L("search.mode.substring"),
            L("search.mode.wildcard"),
            L("search.mode.regex"),
            L("search.mode.fuzzy"),
        ]
        for (i, title) in titles.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(searchModeSelected(_:)), keyEquivalent: "")
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
        nc.addObserver(self, selector: #selector(onIndexProgress(_:)),
                       name: SearchEngine.indexProgressNotification, object: nil)
        nc.addObserver(self, selector: #selector(onIndexReady(_:)),
                       name: SearchEngine.indexReadyNotification, object: nil)
        nc.addObserver(self, selector: #selector(onIndexUpdated(_:)),
                       name: SearchEngine.indexUpdatedNotification, object: nil)
        nc.addObserver(self, selector: #selector(onStartupMode(_:)),
                       name: SearchEngine.startupModeNotification, object: nil)
        nc.addObserver(self, selector: #selector(onConfigReloaded(_:)),
                       name: SearchEngine.configReloadedNotification, object: nil)
    }

    @objc private func onIndexProgress(_ note: Notification) {
        let source = note.userInfo?["source"] as? String ?? ""
        if indexingState == .rebuilding && source != "rebuild" { return }
        if indexingState == .initializing && source == "rebuild" { return }
        // 浏览模式下的状态栏属于当前目录，索引进度别来插一脚
        guard !isBrowsing else { return }

        let count = note.userInfo?["scannedFiles"] as? UInt64 ?? 0
        let formatted = formatCount(count)

        if isColdStart && indexingState == .initializing {
            // Cold start: update overlay
            overlaySubtextLabel?.stringValue = "Scanned \(formatted) files"
            statusLabel.stringValue = "Indexing \(formatted)..."
        } else {
            // Hot start or rebuild: update inline status bar
            statusLabel.stringValue = "Indexing... \(formatted) files"
        }
    }

    @objc private func onIndexReady(_ note: Notification) {
        let total = note.userInfo?["total"] as? UInt64 ?? 0
        let source = note.userInfo?["source"] as? String ?? ""

        switch indexingState {
        case .initializing:
            guard source != "rebuild" else {
                setIdleStatus(total)
                return
            }
            setIdleStatus(total)
            if isColdStart {
                hideLoadingOverlay()
            } else {
                hideInlineProgress()
            }
            rebuildButton.isEnabled = true
            indexingState = .idle
        case .rebuilding:
            guard source == "rebuild" else {
                setIdleStatus(total)
                return
            }
            setIdleStatus(total)
            hideInlineProgress()
            stopRebuildButtonAnimation()
            indexingState = .idle
        case .idle:
            setIdleStatus(total)
        }
    }

    @objc private func onIndexUpdated(_ note: Notification) {
        let total = note.userInfo?["total"] as? UInt64 ?? 0
        setIdleStatus(total)
    }

    @objc private func onStartupMode(_ note: Notification) {
        let coldStart = note.userInfo?["isColdStart"] as? Bool ?? true
        isColdStart = coldStart
        if coldStart {
            // Cold start — show overlay
            showLoadingOverlay(heading: L("search.buildingIndex"))
        } else {
            // Hot start — show inline progress only
            showInlineProgress()
        }
    }

    @objc private func onConfigReloaded(_ note: Notification) {
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

    private var shouldRememberWindowPosition: Bool {
        engine.getConfig()?.window.rememberPosition ?? false
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
        guard loadingOverlay == nil else {
            overlayHeadingLabel?.stringValue = heading
            return
        }
        overlayShownAt = Date()
        guard let contentView = window?.contentView else { return }

        // Full-window event-blocking overlay
        let overlay = EventBlockingView(frame: contentView.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        overlay.alphaValue = 0
        contentView.addSubview(overlay)
        loadingOverlay = overlay

        // Frosted glass background (per D-02: full-window blur)
        let blurView = NSVisualEffectView(frame: overlay.bounds)
        blurView.autoresizingMask = [.width, .height]
        blurView.material = .underWindowBackground
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        overlay.addSubview(blurView)

        // Center card (per D-03)
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(card)

        // Magnifying glass icon — STATIC, no pulse animation (per D-03)
        let iconConfig = NSImage.SymbolConfiguration(pointSize: 40, weight: .light)
        let iconImage = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Indexing")!
            .withSymbolConfiguration(iconConfig)!
        let iconView = NSImageView(image: iconImage)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentTintColor = .secondaryLabelColor
        card.addSubview(iconView)

        // Indeterminate progress bar (per D-04)
        let progressBar = NSProgressIndicator()
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.style = .bar
        progressBar.isIndeterminate = true
        progressBar.startAnimation(nil)
        card.addSubview(progressBar)
        overlayProgressIndicator = progressBar

        // Heading label: "Building Index..."
        let headingLabel = NSTextField(labelWithString: heading)
        headingLabel.translatesAutoresizingMaskIntoConstraints = false
        headingLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        headingLabel.textColor = .labelColor
        headingLabel.alignment = .center
        card.addSubview(headingLabel)
        overlayHeadingLabel = headingLabel

        // Subtext: live file count
        let subtextLabel = NSTextField(labelWithString: L("search.scanningFiles"))
        subtextLabel.translatesAutoresizingMaskIntoConstraints = false
        subtextLabel.font = .systemFont(ofSize: 13, weight: .regular)
        subtextLabel.textColor = .secondaryLabelColor
        subtextLabel.alignment = .center
        card.addSubview(subtextLabel)
        overlaySubtextLabel = subtextLabel

        // Layout
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 260),

            iconView.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            iconView.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 48),
            iconView.heightAnchor.constraint(equalToConstant: 48),

            progressBar.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 20),
            progressBar.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            progressBar.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),

            headingLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 16),
            headingLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            headingLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),

            subtextLabel.topAnchor.constraint(equalTo: headingLabel.bottomAnchor, constant: 4),
            subtextLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            subtextLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            subtextLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),
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

        // Accessibility: announce index ready
        if let mainWindow = NSApp.mainWindow {
            NSAccessibility.post(element: mainWindow as Any, notification: .announcementRequested,
                                 userInfo: [NSAccessibility.NotificationUserInfoKey.announcement: "Index ready"])
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            overlay.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            overlay.removeFromSuperview()
            self?.loadingOverlay = nil
            self?.overlayHeadingLabel = nil
            self?.overlaySubtextLabel = nil
            self?.overlayProgressIndicator = nil
        })
    }

    // MARK: - Inline Progress (Hot Start / Rebuild)

    private func showInlineProgress() {
        guard inlineProgressIndicator == nil else { return }

        // Small indeterminate spinner in status bar area (per D-06)
        let spinnerContainer: NSView
        if #available(macOS 14.0, *) {
            let imageView = NSImageView()
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            imageView.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)?.withSymbolConfiguration(config)
            imageView.contentTintColor = .secondaryLabelColor
            imageView.addSymbolEffect(.variableColor.iterative.reversing)
            spinnerContainer = imageView
        } else {
            let pi = NSProgressIndicator()
            pi.style = .spinning
            pi.controlSize = .small
            pi.isIndeterminate = true
            pi.wantsLayer = true
            pi.startAnimation(nil)
            spinnerContainer = pi
        }
        spinnerContainer.translatesAutoresizingMaskIntoConstraints = false

        // Insert spinner into bottom bar, before statusLabel
        guard let bottomBar = statusLabel.superview else { return }
        bottomBar.addSubview(spinnerContainer)
        inlineProgressIndicator = spinnerContainer

        // Layout: place spinner just before statusLabel (per D-07)
        NSLayoutConstraint.activate([
            spinnerContainer.trailingAnchor.constraint(equalTo: statusLabel.leadingAnchor, constant: -4),
            spinnerContainer.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            spinnerContainer.widthAnchor.constraint(equalToConstant: 16),
            spinnerContainer.heightAnchor.constraint(equalToConstant: 16),
        ])

        // Change search field placeholder (per D-08)
        refreshSearchPlaceholder()
    }

    private func hideInlineProgress() {
        if let pi = inlineProgressIndicator as? NSProgressIndicator {
            pi.stopAnimation(nil)
        } else if #available(macOS 14.0, *) {
            if let imageView = inlineProgressIndicator as? NSImageView {
                imageView.removeAllSymbolEffects()
            }
        }
        inlineProgressIndicator?.removeFromSuperview()
        inlineProgressIndicator = nil

        // Restore search field placeholder (per D-09)
        refreshSearchPlaceholder()
    }

    // MARK: - Toast

    private func showToast(_ message: String) {
        guard let contentView = window?.contentView else { return }

        // Card — same material as loading overlay for visual consistency
        let card = NSVisualEffectView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.material = .hudWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.alphaValue = 0
        contentView.addSubview(card)

        // Spinning refresh icon — wrapped in a stable container
        let iconContainer = CenterSpinContainerView()
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(iconContainer)

        let iconConfig = NSImage.SymbolConfiguration(pointSize: 32, weight: .light)
        let iconView = NSImageView(image: NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                                                   accessibilityDescription: "Refreshing")!
            .withSymbolConfiguration(iconConfig)!)
        iconView.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        iconView.contentTintColor = .secondaryLabelColor
        iconView.wantsLayer = true
        iconContainer.addSubview(iconView)

        // Heading — same font as loading overlay
        let label = NSTextField(labelWithString: message)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        card.addSubview(label)

        // Layout — matches loading overlay card proportions
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 200),

            iconContainer.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            iconContainer.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            iconContainer.widthAnchor.constraint(equalToConstant: 40),
            iconContainer.heightAnchor.constraint(equalToConstant: 40),

            label.topAnchor.constraint(equalTo: iconContainer.bottomAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            label.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),
        ])

        // Spin animation (must be linear to avoid stuttering)
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -CGFloat.pi * 2 // AppKit clockwise
        spin.duration = 1.0
        spin.repeatCount = .infinity
        spin.timingFunction = CAMediaTimingFunction(name: .linear)
        spin.isRemovedOnCompletion = false
        iconView.layer?.add(spin, forKey: "spin")

        // Fade in + Spring Scale for Apple native pop effect
        card.layer?.transform = CATransform3DMakeScale(0.8, 0.8, 1.0)
        
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            card.animator().alphaValue = 1.0
            
            let spring = CASpringAnimation(keyPath: "transform")
            spring.fromValue = CATransform3DMakeScale(0.8, 0.8, 1.0)
            spring.toValue = CATransform3DIdentity
            spring.damping = 15
            spring.stiffness = 300
            spring.duration = spring.settlingDuration
            card.layer?.transform = CATransform3DIdentity
            card.layer?.add(spring, forKey: "pop")
        }

        // Auto dismiss after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                ctx.allowsImplicitAnimation = true
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                card.animator().alphaValue = 0.0
                card.layer?.transform = CATransform3DMakeScale(0.9, 0.9, 1.0)
            }, completionHandler: {
                card.removeFromSuperview()
            })
        }
    }

    // MARK: - Rebuild Action

    @objc private func rebuildIndexClicked() {
        guard indexingState == .idle else { return }

        if engine.isScanning {
            showToast(L("search.backgroundRefresh"))
            return
        }

        indexingState = .rebuilding
        rebuildButton.isEnabled = false
        startRebuildButtonAnimation()
        showInlineProgress()
        statusLabel.stringValue = L("search.indexing")
        engine.rebuildIndex()
    }

    private func startRebuildButtonAnimation() {
        guard let layer = rebuildButton.layer else { return }

        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = -CGFloat.pi * 2 // AppKit: negative is clockwise
        rotation.duration = 1.0
        rotation.repeatCount = .infinity
        // Linear is strictly required for continuous rotation so it doesn't stutter
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        rotation.isRemovedOnCompletion = false
        layer.add(rotation, forKey: "spin")
    }

    private func stopRebuildButtonAnimation() {
        guard let layer = rebuildButton.layer else { return }
        
        if let currentRotation = layer.presentation()?.value(forKeyPath: "transform.rotation.z") as? CGFloat {
            layer.removeAnimation(forKey: "spin")
            
            let fullRotation = -CGFloat.pi * 2
            var targetMultiplier = ceil(currentRotation / fullRotation)
            // If it's too close to snapping, give it an extra spin to decelerate gracefully
            if abs((targetMultiplier * fullRotation) - currentRotation) < 0.5 {
                targetMultiplier += 1
            }
            let targetRotation = targetMultiplier * fullRotation
            
            CATransaction.begin()
            CATransaction.setCompletionBlock {
                layer.transform = CATransform3DIdentity
                layer.removeAnimation(forKey: "stopSpin")
            }
            
            let stop = CABasicAnimation(keyPath: "transform.rotation.z")
            stop.fromValue = currentRotation
            stop.toValue = targetRotation
            stop.duration = 0.4
            stop.timingFunction = CAMediaTimingFunction(controlPoints: 0.1, 0.7, 0.3, 1.0)
            stop.fillMode = .forwards
            stop.isRemovedOnCompletion = false
            
            layer.add(stop, forKey: "stopSpin")
            CATransaction.commit()
        } else {
            layer.removeAnimation(forKey: "spin")
        }
        
        rebuildButton.isEnabled = true
        rebuildButton.contentTintColor = .secondaryLabelColor
    }

    // MARK: - Search

    private var lastQuery: String = ""

    /// 状态栏临时提示的复位任务：连续提示时只保留最后一次。
    private var statusResetWorkItem: DispatchWorkItem?

    @objc private func searchChanged() {
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
            results = []
            iconCache.removeAll()
            tableView.sortDescriptors = []
            tableView.reloadData()
            countLabel.stringValue = ""
            pathBar.url = nil
            refreshIdleStatus()
            return
        }

        let item = DispatchWorkItem { [weak self] in
            self?.performSearch(query: query)
        }
        searchWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016, execute: item)
    }

    private var isSearching = false

    private func performSearch(query: String) {
        guard !isSearching else { return }
        isSearching = true
        countLabel.stringValue = L("search.searching")

        let mode = currentMode
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let response = self.engine.search(query: query, mode: mode)
            DispatchQueue.main.async {
                self.isSearching = false
                // 搜索期间用户可能已经 Space 展开了一个文件夹：这批结果已经过期，别覆盖目录内容。
                guard !self.isBrowsing else { return }
                self.results = response.results
                self.iconCache.removeAll()
                self.tableView.sortDescriptors = []  // Reset sort to relevance order (D-06)
                self.reloadResultsWithFade()

                if let error = response.error {
                    self.countLabel.stringValue = error
                } else {
                    self.countLabel.stringValue = "\(self.formatCount(UInt64(self.results.count))) files found"
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

    @objc private func pathBarClicked() {
        guard let item = pathBar.clickedPathItem,
              let url = item.url else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }

    @objc private func tableDoubleClicked() {
        guard let result = resultAt(row: tableView.clickedRow) else { return }
        engine.openFile(path: result.path)
    }

    @objc private func openSelected() {
        guard let result = resultAt(row: tableView.selectedRow) else { return }
        engine.openFile(path: result.path)
    }

    @objc private func revealSelected() {
        guard let result = resultAt(row: tableView.selectedRow) else { return }
        engine.revealInFinder(path: result.path)
    }

    @objc private func copyPath() {
        guard let result = resultAt(row: tableView.selectedRow) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.path, forType: .string)
    }

    /// ⌘C 在主窗口按下时的实际处理（由 AppDelegate 的「编辑 → 拷贝」菜单项转发过来）。
    ///
    /// 之所以绕这一圈：搜索框有焦点时，field editor 自己实现了 `copy:`，
    /// 主菜单原来的「拷贝」项会先被它接管——没有选中文本时静默无动作，
    /// 这正是「必须先右键再按 ⌘C 才能复制路径」的原因。改用本方法作为菜单项
    /// 的 action 后不再和 NSTextView 抢 `copy:`，最后再由调用方把文本拷贝
    /// 转发回响应链。
    ///
    /// 返回 `false` 表示这次不该处理（搜索框里有选中文字，或没有选中条目）。
    func copySelectedPathsToPasteboard() -> Bool {
        if let editor = window?.firstResponder as? NSTextView, editor.selectedRange().length > 0 {
            return false
        }
        let paths = selectedURLs().map(\.path)
        guard !paths.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        flashStatus(String(format: L("search.copiedPaths"), paths.count))
        return true
    }

    @objc private func copyName() {
        guard let result = resultAt(row: tableView.selectedRow) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.name, forType: .string)
    }

    /// Context-menu entry point: hand the selection over to LaunchBar (⌘↩).
    @objc private func sendToLaunchBar() {
        _ = sendSelectionToLaunchBar()
    }

    /// Hand the selected result(s) to LaunchBar so the user can pick a follow-up
    /// action there (⌘↩, or the context menu). Returns `false` when nothing was
    /// handed over, so the caller can fall back to AppKit's default behaviour.
    @discardableResult
    private func sendSelectionToLaunchBar() -> Bool {
        guard LaunchBar.isInstalled else {
            statusLabel.stringValue = L("search.launchBar.notInstalled")
            NSSound.beep()
            return false
        }

        let urls = selectedURLs()
        guard !urls.isEmpty else {
            NSSound.beep()
            return false
        }

        guard LaunchBar.send(urls: urls) else {
            statusLabel.stringValue = L("search.launchBar.failed")
            NSSound.beep()
            return false
        }
        return true
    }

    /// Context-menu entry point: hand the selection over to Keyboard Maestro (⇧↩).
    @objc private func sendToKeyboardMaestro() {
        _ = sendSelectionToKeyboardMaestro()
    }

    /// ⇧↩（或右键菜单）：把选中项交给 Keyboard Maestro 的宏继续处理。
    ///
    /// 路径既作为 `do script` 的参数传入（宏里用 `%TriggerValue%` 取），
    /// 也写进 KM 变量 `LokiiPath` / `LokiiPaths`，具体见 `KeyboardMaestro`。
    @discardableResult
    private func sendSelectionToKeyboardMaestro() -> Bool {
        guard KeyboardMaestro.isInstalled else {
            statusLabel.stringValue = L("search.keyboardMaestro.notInstalled")
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
        statusLabel.stringValue = L("search.keyboardMaestro.sending")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = Result { try KeyboardMaestro.handoff(paths: urls) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch outcome {
                case .success(let returned):
                    // 宏里如果有 Return 动作，其返回值直接显示出来，方便调试宏
                    self.flashStatus(returned ?? L("search.keyboardMaestro.done"))
                case .failure(let error):
                    self.statusLabel.stringValue = error.localizedDescription
                    NSSound.beep()
                }
            }
        }
        return true
    }

    /// ⌘F（或右键菜单）：把焦点送回搜索框，光标停在文本末尾，方便接着改查询。
    @objc private func focusSearchFieldFromMenu() {
        focusSearchField()
    }

    func focusSearchField() {
        guard let window, let searchField else { return }
        window.makeFirstResponder(searchField)
        if let editor = searchField.currentEditor() {
            let end = (searchField.stringValue as NSString).length
            editor.selectedRange = NSRange(location: end, length: 0)
        }
    }

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

    /// ⌘1…⌘9：选中第 N 个结果，并把键盘焦点交给列表，紧接着 ↩ 就能打开它。
    /// 序号超出当前结果数时给一声提示音，而不是把按键静默吞掉。
    private func selectResult(at index: Int) -> Bool {
        let row = index - 1
        guard row < rowCount else {
            NSSound.beep()
            return true
        }
        return focusResults(row: row)
    }

    /// ↓：焦点在搜索框、且插入点已经停在文本末尾时，把焦点交给结果列表。
    /// 插入点还在文本中间则不拦截，交回 AppKit 处理，保留正常的编辑手感。
    private func moveFocusToResultsFromSearchField() -> Bool {
        guard let window, let searchField,
              window.firstResponder === searchField.currentEditor(),
              let editor = searchField.currentEditor(),
              editor.selectedRange.length == 0,
              editor.selectedRange.location == (searchField.stringValue as NSString).length,
              rowCount > 0 else { return false }
        // 已经有选中行就沿用它，避免把用户先前用 ⌘1…⌘9 挑好的那一条丢掉；
        // 结果集变短后留下的越界旧选中行则退回首行。
        let selected = tableView.selectedRow
        let row = (selected >= 0 && selected < rowCount) ? selected : 0
        return focusResults(row: row)
    }

    /// ↑：焦点在结果列表、且当前停在第一个结果上时，回到搜索框并把光标放到末尾。
    private func moveFocusToSearchFieldFromResults() -> Bool {
        guard let window, isResultsFocused(window), tableView.selectedRow <= 0 else { return false }
        focusSearchField()
        return true
    }

    /// 选中第 `row` 行、滚进可视区域，并把键盘焦点交给列表；返回是否真的做了事。
    @discardableResult
    private func focusResults(row: Int) -> Bool {
        guard let window, row >= 0, row < rowCount else { return false }
        window.makeFirstResponder(tableView)
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        return true
    }

    /// 键盘焦点是否落在结果列表里（表格本身或它的子视图）。
    private func isResultsFocused(_ window: NSWindow) -> Bool {
        guard let responder = window.firstResponder as? NSView else { return false }
        return responder === tableView || responder.isDescendant(of: tableView)
    }

    /// 表格中选中条目对应的文件 URL（按行序）。
    private func selectedURLs() -> [URL] {
        tableView.selectedRowIndexes.compactMap { row in
            guard let result = resultAt(row: row) else { return nil }
            return URL(fileURLWithPath: result.path)
        }
    }

    // MARK: - Helpers

    private func formatCount(_ n: UInt64) -> String {
        Self.countFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// 底部状态栏的临时提示：2 秒后恢复成空闲状态。
    private func flashStatus(_ message: String) {
        statusLabel.stringValue = message
        statusResetWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.refreshIdleStatus()
        }
        statusResetWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: item)
    }

    /// 状态栏的「已索引 N 项」文案；浏览模式下让位给目录说明。
    private func setIdleStatus(_ total: UInt64) {
        guard !isBrowsing else { return }
        statusLabel.stringValue = "\(formatCount(total)) indexed"
    }

    /// 空闲（搜索框为空）时底部显示的索引进度/总数。
    private func refreshIdleStatus() {
        // 浏览模式下的「空闲状态」就是当前目录说明，别让进度的文案盖上去
        if isBrowsing {
            updateBrowseChrome()
            return
        }
        let stats = engine.stats
        statusLabel.stringValue = stats.isReady
            ? "\(formatCount(stats.totalCount)) indexed"
            : L("search.indexing")
    }

    private func iconForFile(at path: String, isDir: Bool) -> NSImage {
        if let cached = iconCache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 16, height: 16)
        iconCache[path] = icon
        return icon
    }

    fileprivate func kindDescription(for result: FfiSearchResult) -> String {
        if result.isDir { return L("kind.folder") }

        let ext = result.extension.lowercased()

        // Tier 1: Custom mapping table — developer file types (D-07: custom map takes priority over UTType)
        if !ext.isEmpty, let custom = FileKindMap.extensionToKind[ext] {
            return custom
        }

        // Tier 2: UTType system description — PDF, PNG, MP3, etc. (D-08)
        // CRITICAL: Must check isDeclared to avoid dyn.xxx identifiers for unknown extensions
        if !ext.isEmpty, let uttype = UTType(filenameExtension: ext),
           uttype.isDeclared,
           let desc = uttype.localizedDescription {
            return desc
        }

        // Tier 3: Fallback (D-09, D-10)
        if ext.isEmpty {
            return L("kind.document")  // D-10: no extension, non-directory
        }
        return "\(ext.uppercased()) \(L("kind.file"))"  // D-09: unknown extension -> "XYZ File"
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    // MARK: - 文件夹浏览（Finder 式就地展开）

    /// 是否正在浏览某个目录。
    private var isBrowsing: Bool { browsingFolder != nil }

    /// 表格当前的行数：搜索结果条数，或浏览模式下过滤后的条目数。
    private var rowCount: Int { isBrowsing ? browseEntries.count : results.count }

    /// 选中区里排在前面的一行（多选时以最靠前的一行为准）；没有选中时是 -1。
    private var firstSelectedRow: Int {
        tableView.selectedRowIndexes.first ?? tableView.selectedRow
    }

    /// 表格第 `row` 行对应的条目。
    ///
    /// 浏览模式把目录条目现场包装成 `FfiSearchResult`，于是打开、拷贝路径、详情面板、
    /// 单元格渲染这些下游逻辑不必为两种数据源各写一份。
    private func resultAt(row: Int) -> FfiSearchResult? {
        guard row >= 0, row < rowCount else { return nil }
        return isBrowsing ? Self.result(for: browseEntries[row], query: lastQuery) : results[row]
    }

    /// 把目录条目包装成搜索结果结构；`matchPositions` 同样按 UTF-8 字节偏移给出，
    /// 好让名字列复用搜索结果那套高亮渲染。
    private static func result(for entry: BrowseEntry, query: String) -> FfiSearchResult {
        FfiSearchResult(
            name: entry.name,
            path: entry.path,
            isDir: entry.isDirectory,
            size: entry.size,
            modified: entry.modified,
            created: entry.created,
            extension: (entry.name as NSString).pathExtension,
            score: 0,
            matchPositions: matchPositions(in: entry.name, query: query),
            searchMode: .substring
        )
    }

    /// 关键字在名字里出现的区间（UTF-8 字节偏移，与 Rust 侧口径一致）。
    private static func matchPositions(in name: String, query: String) -> [FfiMatchRange] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }

        var positions: [FfiMatchRange] = []
        var cursor = name.startIndex
        while let found = name.range(of: needle,
                                     options: [.caseInsensitive, .diacriticInsensitive],
                                     range: cursor..<name.endIndex),
              let lower = found.lowerBound.samePosition(in: name.utf8),
              let upper = found.upperBound.samePosition(in: name.utf8) {
            positions.append(FfiMatchRange(
                start: UInt32(name.utf8.distance(from: name.utf8.startIndex, to: lower)),
                end: UInt32(name.utf8.distance(from: name.utf8.startIndex, to: upper))
            ))
            cursor = found.upperBound
        }
        return positions
    }

    /// 空格键：选中文件夹就展开浏览，选中文件就弹 Quick Look，已经在预览就关掉。
    /// 返回 `false` 表示这个空格不该由 Lokii 处理（搜索框里打字、焦点在别处、没有选中项）。
    private func handleSpace() -> Bool {
        guard let window else { return false }
        let focus = SpaceRules.focusTarget(
            firstResponder: window.firstResponder,
            searchFieldEditor: searchField.currentEditor(),
            isResultsResponder: isResultsFocused(window)
        )
        let row = firstSelectedRow
        let selected = resultAt(row: row)
        let selection = SpaceRules.selectionKind(
            selectedRow: row,
            isSelectedContainer: selected.map { FolderBrowse.isContainer(at: $0.path) }
        )

        switch SpaceRules.intent(focus: focus, selection: selection, isPreviewing: isPreviewing) {
        case .passThrough:
            return false
        case .closePreview:
            dismissPreview()
            return true
        case .preview:
            presentPreview(urls: selectedURLs())
            return true
        case .enterFolder:
            if let path = selected?.path { browse(folder: path) }
            return true
        }
    }

    /// ⌘↓：进入选中的文件夹。选中项不是文件夹时不拦截，⌘↓ 交回表格自己的行为。
    private func enterSelectedFolder() -> Bool {
        guard let window, isResultsFocused(window),
              let result = resultAt(row: firstSelectedRow),
              FolderBrowse.isContainer(at: result.path) else { return false }
        browse(folder: result.path)
        return true
    }

    /// ⌘↑：回到上一级目录；已经在浏览的最顶层时退出浏览模式、恢复原来的搜索结果。
    /// 搜索模式里按下则跳进选中项所在的目录，之后一路 ⌘↑ 同样能退回搜索结果。
    private func leaveFolder() -> Bool {
        guard let window, isResultsFocused(window) else { return false }

        if let folder = browsingFolder {
            if let parent = FolderBrowse.parent(of: folder) {
                // 进上级目录后把刚离开的那个目录选上，方便按 ⌘↓ 再走回去
                browse(folder: parent, select: folder)
            } else {
                exitBrowse()
            }
            return true
        }

        guard let result = resultAt(row: firstSelectedRow),
              let parent = FolderBrowse.parent(of: result.path) else { return false }
        browse(folder: parent, select: result.path)
        return true
    }

    /// 切换到 `folder` 目录浏览；`select` 指定进入后要选中的条目路径。
    /// 目录读不出来（权限、已被删除…）时保持原状，只在状态栏提示一声。
    private func browse(folder: String, select: String? = nil) {
        let includeHidden = engine.getConfig()?.index.includeHidden ?? false
        guard let listing = FolderBrowse.listing(in: folder,
                                                 includeHidden: includeHidden,
                                                 maxEntries: FolderBrowse.defaultMaxEntries) else {
            NSSound.beep()
            flashStatus(L("search.browseUnreadable"))
            return
        }

        dismissPreview()
        if !isBrowsing {
            // 第一次进入浏览模式：把搜索结果整份留底，一路 ⌘↑ 退到最顶层后原样放回
            savedSearch = SavedSearch(results: results,
                                      query: lastQuery,
                                      count: countLabel.stringValue,
                                      status: statusLabel.stringValue)
            results = []
            iconCache.removeAll()
        }

        // 每进入一个文件夹都清空搜索框，完整列出该目录内容（否则会带着上一步的词继续过滤）。
        // 先改 lastQuery 再写回搜索框，让 searchChanged 的去重直接拦下、不再清一遍列表。
        lastQuery = ""
        searchField.stringValue = ""

        browsingFolder = folder
        browseAllEntries = Self.sorted(listing.entries, matching: tableView.sortDescriptors)
        browseTruncated = listing.truncated
        // 目录内容先按名称升序列出，清掉表头的排序指示免得和内容对不上
        tableView.sortDescriptors = []
        applyBrowseFilter(select: select)
    }

    /// 退出浏览模式，恢复进入前的搜索结果。
    private func exitBrowse() {
        guard isBrowsing else { return }
        dismissPreview()

        browsingFolder = nil
        browseAllEntries = []
        browseEntries = []
        browseTruncated = false
        results = savedSearch?.results ?? []

        // 先改 lastQuery 再写回搜索框：万一控件回调了 searchChanged，也会被去重挡下来
        lastQuery = savedSearch?.query ?? ""
        searchField.stringValue = lastQuery
        countLabel.stringValue = savedSearch?.count ?? ""
        statusLabel.stringValue = savedSearch?.status ?? ""
        savedSearch = nil

        iconCache.removeAll()
        tableView.sortDescriptors = []
        refreshSearchPlaceholder()
        reloadResultsWithFade()
        refreshPathBar()
    }

    /// 重新套用搜索框里的过滤词并刷新表格；`select` 是过滤后要选中的条目路径。
    private func applyBrowseFilter(select: String? = nil) {
        browseEntries = FolderBrowse.filter(browseAllEntries, query: lastQuery)

        let row: Int?
        if let select {
            row = browseEntries.firstIndex { $0.path == select }
        } else {
            let selected = tableView.selectedRow
            row = (selected >= 0 && selected < browseEntries.count) ? selected : nil
        }

        reloadResultsWithFade()
        if let row {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        } else {
            // 过滤后行数变少时把越界的选中行收回；没有内容就清空选中
            tableView.deselectAll(nil)
            refreshPathBar()
        }
        updateBrowseChrome()
    }

    /// 浏览模式下的计数与状态栏文案。
    private func updateBrowseChrome() {
        let shown = formatCount(UInt64(browseEntries.count))
        let total = formatCount(UInt64(browseAllEntries.count))
        countLabel.stringValue = browseEntries.count == browseAllEntries.count
            ? String(format: L("search.browseCount"), shown)
            : String(format: L("search.browseCountFiltered"), shown, total)
        if browseTruncated {
            countLabel.stringValue += " · " + String(format: L("search.browseTruncated"),
                                                      formatCount(UInt64(FolderBrowse.defaultMaxEntries)))
        }

        if let folder = browsingFolder {
            statusLabel.stringValue = String(format: L("search.browseStatus"), abbreviatePath(folder))
        }
        refreshSearchPlaceholder()
    }

    /// 搜索框当前的占位文案：浏览模式提示「在当前文件夹内过滤」，索引中提示可能不完整。
    private var activePlaceholder: String {
        if isBrowsing { return L("search.browsePlaceholder") }
        return inlineProgressIndicator == nil ? originalSearchPlaceholder : L("search.indexingIncomplete")
    }

    private func refreshSearchPlaceholder() {
        searchField.placeholderString = activePlaceholder
    }

    /// 带淡入淡出的列表刷新（与搜索结果刷新保持同一观感）。
    private func reloadResultsWithFade() {
        let transition = CATransition()
        transition.type = .fade
        transition.duration = 0.15
        transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
        tableView.layer?.add(transition, forKey: "fade")
        tableView.reloadData()
    }

    /// 底部路径条跟随选中行；浏览模式下没有选中行时指回当前目录。
    private func refreshPathBar() {
        if let result = resultAt(row: tableView.selectedRow) {
            pathBar.url = URL(fileURLWithPath: result.path)
        } else if let folder = browsingFolder {
            pathBar.url = URL(fileURLWithPath: folder)
        } else {
            pathBar.url = nil
        }
    }

    /// 按表格当前的排序描述符排列目录条目；没有描述符时用 Finder 式的名称升序。
    private static func sorted(_ entries: [BrowseEntry],
                               matching descriptors: [NSSortDescriptor]) -> [BrowseEntry] {
        guard let descriptor = descriptors.first,
              let key = descriptor.key,
              let sortKey = BrowseSortKey(rawValue: key) else {
            return FolderBrowse.sorted(entries, by: .name, ascending: true)
        }
        return FolderBrowse.sorted(entries, by: sortKey, ascending: descriptor.ascending)
    }

    // MARK: - Quick Look（空格预览）

    /// Quick Look 面板是否正开着。`sharedPreviewPanelExists` 保证这里不会顺手把面板建出来。
    private var isPreviewing: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && (QLPreviewPanel.shared()?.isVisible ?? false)
    }

    /// 预览面板当前该显示的内容：跟着表格选择走，选择被清空后沿用弹出时记录的那批。
    private var previewItemURLs: [URL] {
        let selected = selectedURLs()
        return selected.isEmpty ? previewItemsFallback : selected
    }

    /// 弹出 Quick Look 面板（手动驱动模式：自己当 dataSource/delegate，不接响应链）。
    private func presentPreview(urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else {
            NSSound.beep()
            return
        }
        previewItemsFallback = urls
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
    }

    /// 收起 Quick Look 面板（正在预览时把键盘焦点交还给主窗口）。
    private func dismissPreview() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared() else { return }
        previewItemsFallback.removeAll()
        if panel.isVisible { panel.orderOut(nil) }
    }
}

// MARK: - Quick Look 面板

extension SearchWindow: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewItemURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let urls = previewItemURLs
        guard index >= 0, index < urls.count else { return nil }
        return urls[index] as NSURL
    }

    /// 面板拿到键盘焦点后，Lokii 自己的那几个快捷键仍要生效。
    ///
    /// 面板只把它没处理的按键交过来，这里就接 Space / ⌘↓ / ⌘↑ 三个，剩下的一律返回
    /// `false`，把滚动、翻页、Esc 关面板这些默认行为留给面板自己。
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, let window,
              let shortcut = LokiiWindow.shortcut(for: event) else { return false }
        switch shortcut {
        case .preview, .commandDown, .commandUp:
            window.sendEvent(event)
            return true
        default:
            return false
        }
    }
}

// MARK: - NSTableViewDataSource

extension SearchWindow: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rowCount
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key else { return }

        // 浏览模式：按同一套排序键重排目录条目（文件夹依旧排在文件前面），再套回过滤词
        if isBrowsing {
            guard let sortKey = BrowseSortKey(rawValue: key) else { return }
            browseAllEntries = FolderBrowse.sorted(browseAllEntries, by: sortKey,
                                                   ascending: descriptor.ascending)
            tableView.deselectAll(nil)
            refreshPathBar()
            applyBrowseFilter()
            return
        }

        results.sort { a, b in
            let cmp: ComparisonResult
            switch key {
            case "name":
                cmp = a.name.localizedStandardCompare(b.name)
            case "path":
                let pathA = (a.path as NSString).deletingLastPathComponent
                let pathB = (b.path as NSString).deletingLastPathComponent
                cmp = pathA.localizedStandardCompare(pathB)
            case "modified":
                if a.modified < b.modified { cmp = .orderedAscending }
                else if a.modified > b.modified { cmp = .orderedDescending }
                else { cmp = .orderedSame }
            case "size":
                if a.size < b.size { cmp = .orderedAscending }
                else if a.size > b.size { cmp = .orderedDescending }
                else { cmp = .orderedSame }
            default:
                cmp = .orderedSame
            }
            return descriptor.ascending ? cmp == .orderedAscending : cmp == .orderedDescending
        }

        // Clear selection (simpler than preserving; matches Finder behavior)
        tableView.deselectAll(nil)
        refreshPathBar()
        reloadResultsWithFade()
    }
}

// MARK: - NSTableViewDelegate

extension SearchWindow: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn,
              let result = resultAt(row: row) else { return nil }
        let colID = column.identifier

        switch colID {
        case .columnName:
            return nameCell(for: result, in: tableView)
        case .columnPath:
            let parent = (result.path as NSString).deletingLastPathComponent
            return textCell(string: abbreviatePath(parent), font: .systemFont(ofSize: 13),
                            color: .secondaryLabelColor, alignment: .left, identifier: colID, in: tableView)
        case .columnModified:
            let date = Date(timeIntervalSince1970: TimeInterval(result.modified))
            let str = Self.dateFormatter.string(from: date)
            return textCell(string: str, font: .systemFont(ofSize: 13),
                            color: .labelColor, alignment: .left, identifier: colID, in: tableView)
        case .columnSize:
            let str = result.isDir ? "--" : Self.sizeFormatter.string(fromByteCount: Int64(result.size))
            return textCell(string: str, font: .monospacedDigitSystemFont(ofSize: 13, weight: .regular),
                            color: .secondaryLabelColor, alignment: .right, identifier: colID, in: tableView)
        default:
            return nil
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshPathBar()
        if infoPanelVisible {
            updateInfoPanel()
        }
        // 预览面板开着时让预览跟着选择走（Finder 里点另一个文件，预览就换过去）
        if isPreviewing, let panel = QLPreviewPanel.shared(), !tableView.selectedRowIndexes.isEmpty {
            panel.currentPreviewItemIndex = 0
            panel.reloadData()
        }
    }

    private func nameCell(for result: FfiSearchResult, in tableView: NSTableView) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier("NameCell")
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? SearchNameTableCellView {
            reused.imageView?.image = iconForFile(at: result.path, isDir: result.isDir)
            if let tf = reused.textField {
                tf.maximumNumberOfLines = 1
                tf.cell?.wraps = false
            }
            reused.configure(name: result.name, matchPositions: result.matchPositions)
            return reused
        }

        let cell = SearchNameTableCellView()
        cell.identifier = id

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = iconForFile(at: result.path, isDir: result.isDir)
        cell.addSubview(imageView)
        cell.imageView = imageView

        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.font = .systemFont(ofSize: 13)
        textField.lineBreakMode = .byTruncatingTail
        textField.maximumNumberOfLines = 1
        textField.cell?.wraps = false
        textField.cell?.isScrollable = false
        textField.isEditable = false
        textField.isBezeled = false
        textField.drawsBackground = false
        cell.addSubview(textField)
        cell.textField = textField

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        cell.configure(name: result.name, matchPositions: result.matchPositions)

        return cell
    }

    private func textCell(string: String, font: NSFont, color: NSColor, alignment: NSTextAlignment,
                          identifier: NSUserInterfaceItemIdentifier, in tableView: NSTableView) -> NSView {
        let cellID = NSUserInterfaceItemIdentifier(identifier.rawValue + "Cell")
        if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView {
            reused.textField?.stringValue = string
            return reused
        }

        let cell = NSTableCellView()
        cell.identifier = cellID

        let textField = NSTextField(labelWithString: string)
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.font = font
        textField.textColor = color
        textField.alignment = alignment
        textField.lineBreakMode = .byTruncatingTail
        textField.isEditable = false
        textField.isBezeled = false
        textField.drawsBackground = false
        cell.addSubview(textField)
        cell.textField = textField

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        return cell
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

// MARK: - Column Identifiers

extension NSUserInterfaceItemIdentifier {
    static let columnName = NSUserInterfaceItemIdentifier("Name")
    static let columnPath = NSUserInterfaceItemIdentifier("Path")
    static let columnSize = NSUserInterfaceItemIdentifier("Size")
    static let columnModified = NSUserInterfaceItemIdentifier("DateModified")
}

// MARK: - NSSearchFieldDelegate

extension SearchWindow: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        searchChanged()
    }
}

// MARK: - NSToolbarDelegate

extension SearchWindow: NSToolbarDelegate {
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == Self.searchBarItem else { return nil }

        // Container holds searchField + countLabel + toggleInfoButton in a single toolbar item
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        searchField.translatesAutoresizingMaskIntoConstraints = true
        countLabel.translatesAutoresizingMaskIntoConstraints = true
        toggleInfoButton.translatesAutoresizingMaskIntoConstraints = true

        searchField.translatesAutoresizingMaskIntoConstraints = false
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        toggleInfoButton.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(searchField)
        container.addSubview(countLabel)
        container.addSubview(toggleInfoButton)

        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        toggleInfoButton.setContentHuggingPriority(.required, for: .horizontal)
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            searchField.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            countLabel.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 10),
            countLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            toggleInfoButton.leadingAnchor.constraint(equalTo: countLabel.trailingAnchor, constant: 8),
            toggleInfoButton.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toggleInfoButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            toggleInfoButton.widthAnchor.constraint(equalToConstant: 28),

            container.heightAnchor.constraint(equalToConstant: 28),
        ])

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.view = container
        item.label = ""
        item.isNavigational = true  // Expand to fill available toolbar space
        return item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.searchBarItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.searchBarItem]
    }
}

// MARK: - Themed Background View
final class ThemedBackgroundView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayer()
    }
}

// MARK: - Search Name Table Cell View
final class SearchNameTableCellView: NSTableCellView {
    private var matchPositions: [FfiMatchRange] = []
    private var rawName: String = ""

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            updateText()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateText()
    }

    func configure(name: String, matchPositions: [FfiMatchRange]) {
        self.rawName = name
        self.matchPositions = matchPositions
        updateText()
    }

    private func updateText() {
        guard !rawName.isEmpty else {
            textField?.stringValue = ""
            return
        }

        let isSelected = backgroundStyle == .emphasized
        let regularFont = NSFont.systemFont(ofSize: 13)
        let boldFont = NSFont.systemFont(ofSize: 13, weight: .bold)

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let defaultColor: NSColor = isSelected ? .white : .labelColor
        let highlightColor: NSColor = isSelected ? .white : (isDark ? .controlAccentColor : .labelColor)

        let attributed = NSMutableAttributedString(string: rawName, attributes: [
            .font: regularFont,
            .foregroundColor: defaultColor
        ])

        let utf8 = rawName.utf8
        for range in matchPositions {
            let startByte = Int(range.start)
            let endByte = Int(range.end)
            guard let startIdx = utf8.index(utf8.startIndex, offsetBy: startByte, limitedBy: utf8.endIndex),
                  let endIdx = utf8.index(utf8.startIndex, offsetBy: endByte, limitedBy: utf8.endIndex) else {
                continue
            }
            let nsRange = NSRange(startIdx..<endIdx, in: rawName)
            var attrs: [NSAttributedString.Key: Any] = [
                .font: boldFont,
                .foregroundColor: highlightColor
            ]
            if isSelected {
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            attributed.addAttributes(attrs, range: nsRange)
        }
        textField?.attributedStringValue = attributed
    }
}
