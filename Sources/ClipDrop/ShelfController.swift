import AppKit
import QuartzCore
import ServiceManagement

final class ShelfController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let store: ClipStore
    weak var writer: ClipboardWriting?
    var keepsOverlay: () -> Bool = { false }
    var suspendOverlay: (Bool) -> Void = { _ in }
    var overlayFront: () -> Void = {}
    var stackIsOpen: () -> Bool = { false }
    var onOpenStack: (NSRect) -> Void = { _ in }
    var onCloseStack: () -> Void = {}

    private(set) var armedID: UUID?
    private var shown: [ClipItem] = []
    private var query = ""
    private var cursor: Int?
    private var stuck = false
    private var dragHolding = false
    private var scratchOpen = false
    private var dropActive = false
    private var suppressNextClick = false
    private var menuOpen = false
    private var lastArm: (id: UUID, time: TimeInterval)?
    private var lastToggleAt: TimeInterval = -1
    private var ignoreMenuUntil: TimeInterval = 0

    private var statusItem: NSStatusItem?
    private var catcher: MailboxCatcher?
    private let panel: ShelfPanel
    private let background = ShelfBackground(frame: NSRect(x: 0, y: 0, width: 360, height: 240))
    private let titleLabel = NSTextField(labelWithString: "Clipboard")
    private let countLabel = NSTextField(labelWithString: "")
    private let optionsButton = IconButton(frame: .zero)
    private let search = ClickSearchField(frame: .zero)
    private let scroll = NSScrollView(frame: .zero)
    private let table = ShelfTable(frame: .zero)
    private let divider = NSView(frame: .zero)
    private let footer = NSTextField(labelWithString: "Click an item, then press ⌘V")
    private let empty = NSView(frame: .zero)
    private let emptyIcon = NSImageView(frame: .zero)
    private let emptyTitle = NSTextField(labelWithString: "Nothing saved yet")
    private let emptyBody = NSTextField(labelWithString: "Copy something, or drop it here.")
    private var scrollHeight: NSLayoutConstraint!
    private var timer: Timer?
    private var hideWork: DispatchWorkItem?
    private var localMonitor: Any?
    private var globalMonitor: Any?

    init(store: ClipStore) {
        self.store = store
        panel = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 240))
        super.init()
        buildPanel()
        wireDrop()
    }

    func start() {
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        }
        buildStatusItem()
        installMonitors()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.tickHover()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        reload()
    }

    func showPinned() {
        stuck = true
        show()
        onOpenStack(panel.frame)
    }

    func setScratchVisible(_ visible: Bool) {
        scratchOpen = visible
        refreshHighlight()
    }

    func apply(_ effect: IngestEffect) {
        switch effect {
        case .ignored:
            break
        case .inserted(let id), .promoted(let id):
            armedID = id
            reload()
        }
    }

    func clearArm() {
        guard armedID != nil else { return }
        armedID = nil
        reload()
    }

    func reload() {
        shown = store.filtered(query: query)
        table.reloadData()
        updateChrome()
        let height = preferredHeight()
        scrollHeight.constant = height - Metrics.chrome
        if panel.isVisible {
            position(height: height)
            syncColumnWidth()
        }
    }

    deinit {
        timer?.invalidate()
        hideWork?.cancel()
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    private func buildStatusItem() {
        guard let button = statusItem?.button else { return }
        button.image = MailboxIcon.menuBar
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = #selector(statusClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "Click to open the scratchpad and clipboard. Drag a file here to open the clipboard. Right-click for settings."
        button.setAccessibilityLabel("utilBox")
        button.setAccessibilityHelp("Opens the scratchpad and clipboard. Dragging a file here opens the clipboard.")
        let catcher = self.catcher ?? MailboxCatcher(frame: button.bounds)
        self.catcher = catcher
        catcher.onClick = { [weak self] in
            self?.toggleStack()
        }
        catcher.onMenu = { [weak self, weak button] in
            guard let self, let button else { return }
            self.showMenu(from: button)
        }
        catcher.onDragEntered = { [weak self] in
            self?.dragEnteredIcon()
        }
        catcher.onDragExited = { [weak self] in
            self?.dragHolding = false
        }
        catcher.onDragEnded = { [weak self] dropped in
            self?.dragFinishedOnIcon(dropped: dropped)
        }
        catcher.accepts = { [weak self] sender in
            self?.dragOperation(for: sender) ?? []
        }
        catcher.onPerform = { [weak self] sender in
            self?.dropOnIcon(sender) ?? false
        }
        if catcher.superview !== button {
            button.addSubview(catcher)
        }
        catcher.frame = button.bounds
        catcher.autoresizingMask = [.width, .height]
        catcher.toolTip = button.toolTip
    }

    private func buildPanel() {
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        countLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        optionsButton.isBordered = false
        optionsButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Settings")
        optionsButton.imageScaling = .scaleProportionallyDown
        optionsButton.contentTintColor = .secondaryLabelColor
        optionsButton.target = self
        optionsButton.action = #selector(optionsClicked(_:))
        optionsButton.toolTip = "Settings"

        search.placeholderString = "Search"
        search.focusRingType = .none
        search.controlSize = .small
        search.font = .systemFont(ofSize: 13)
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(100), for: .vertical)
        search.setContentHuggingPriority(NSLayoutConstraint.Priority(100), for: .vertical)

        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false

        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.rowHeight = Metrics.rowHeight
        table.intercellSpacing = .zero
        table.gridStyleMask = []
        table.focusRingType = .none
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.usesAutomaticRowHeights = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask([], forLocal: true)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clips"))
        column.resizingMask = .autoresizingMask
        column.minWidth = 200
        column.maxWidth = 10_000
        column.width = Metrics.width
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        scroll.documentView = table

        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.7).cgColor

        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .tertiaryLabelColor
        footer.alignment = .center
        footer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(100), for: .vertical)

        emptyIcon.imageScaling = .scaleProportionallyDown
        emptyIcon.contentTintColor = .tertiaryLabelColor
        emptyIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 26, weight: .regular)
        emptyTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        emptyTitle.textColor = .labelColor
        emptyTitle.alignment = .center
        emptyBody.font = .systemFont(ofSize: 12)
        emptyBody.textColor = .secondaryLabelColor
        emptyBody.alignment = .center
        emptyBody.maximumNumberOfLines = 2
        emptyBody.preferredMaxLayoutWidth = 280

        let subviews: [NSView] = [
            titleLabel, countLabel, optionsButton, search, scroll, divider, footer, empty
        ]
        for view in subviews {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        for view in [emptyIcon, emptyTitle, emptyBody] {
            view.translatesAutoresizingMaskIntoConstraints = false
            empty.addSubview(view)
        }

        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: Metrics.emptyListHeight)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            titleLabel.topAnchor.constraint(equalTo: background.topAnchor, constant: Metrics.topInset),
            titleLabel.heightAnchor.constraint(equalToConstant: Metrics.titleHeight),

            optionsButton.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            optionsButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            optionsButton.widthAnchor.constraint(equalToConstant: 22),
            optionsButton.heightAnchor.constraint(equalToConstant: 22),

            countLabel.trailingAnchor.constraint(equalTo: optionsButton.leadingAnchor, constant: -4),
            countLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -8),

            search.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            search.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: Metrics.titleGap),
            search.heightAnchor.constraint(equalToConstant: Metrics.searchHeight),

            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: Metrics.searchGap),
            scrollHeight,

            divider.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            divider.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            divider.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: Metrics.listGap),
            divider.heightAnchor.constraint(equalToConstant: Metrics.dividerHeight),

            footer.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            footer.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: Metrics.footerGap),
            footer.heightAnchor.constraint(equalToConstant: Metrics.footerHeight),
            footer.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -Metrics.bottomInset),

            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            empty.leadingAnchor.constraint(greaterThanOrEqualTo: scroll.leadingAnchor, constant: 20),
            empty.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor, constant: -20),

            emptyIcon.topAnchor.constraint(equalTo: empty.topAnchor),
            emptyIcon.centerXAnchor.constraint(equalTo: empty.centerXAnchor),
            emptyIcon.widthAnchor.constraint(equalToConstant: 28),
            emptyIcon.heightAnchor.constraint(equalToConstant: 28),
            emptyTitle.topAnchor.constraint(equalTo: emptyIcon.bottomAnchor, constant: 8),
            emptyTitle.leadingAnchor.constraint(equalTo: empty.leadingAnchor),
            emptyTitle.trailingAnchor.constraint(equalTo: empty.trailingAnchor),
            emptyBody.topAnchor.constraint(equalTo: emptyTitle.bottomAnchor, constant: 2),
            emptyBody.leadingAnchor.constraint(equalTo: empty.leadingAnchor),
            emptyBody.trailingAnchor.constraint(equalTo: empty.trailingAnchor),
            emptyBody.bottomAnchor.constraint(equalTo: empty.bottomAnchor)
        ])

        background.onLayout = { [weak self] in
            self?.syncColumnWidth()
        }
        background.onAppearance = { [weak self] in
            self?.divider.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.7).cgColor
        }
        panel.contentView = background
    }

    private func wireDrop() {
        let operation: (NSDraggingInfo) -> NSDragOperation = { [weak self] sender in
            self?.dragOperation(for: sender) ?? []
        }
        let exit: () -> Void = { [weak self] in
            self?.dragEnded()
        }
        let perform: (NSDraggingInfo) -> Bool = { [weak self] sender in
            self?.performDrop(sender) ?? false
        }
        background.dragOperation = operation
        background.dragExit = exit
        background.dragPerform = perform
        table.dragOperation = operation
        table.dragExit = exit
        table.dragPerform = perform
        table.registerForDraggedTypes(PasteboardService.acceptedDropTypes)
    }

    private func installMonitors() {
        let localMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .keyDown]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: localMask) { [weak self] event in
            guard let self else { return event }
            if self.menuOpen { return event }
            if event.type == .keyDown, event.keyCode == 53, self.panel.isVisible {
                if let key = NSApp.keyWindow, key !== self.panel {
                    return event
                }
                self.escape()
                return nil
            }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                self.handleMouseDown()
            }
            return event
        }
        let mouseMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseMask) { [weak self] _ in
            guard let self, !self.menuOpen else { return }
            self.handleMouseDown()
        }
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu(from: sender)
            return
        }
        toggleStack()
    }

    private func toggleStack() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastToggleAt < 0.05 { return }
        lastToggleAt = now
        if panel.isVisible && stuck && stackIsOpen() {
            stuck = false
            closePanel()
            onCloseStack()
            return
        }
        stuck = true
        show()
        onOpenStack(panel.frame)
    }

    @objc private func optionsClicked(_ sender: NSButton) {
        showMenu(from: sender)
    }

    private func showMenu(from view: NSView) {
        let now = ProcessInfo.processInfo.systemUptime
        if menuOpen || now < ignoreMenuUntil { return }
        menuOpen = true
        defer {
            menuOpen = false
            ignoreMenuUntil = ProcessInfo.processInfo.systemUptime + 0.25
        }
        let menu = buildMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: view)
        reload()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let title = NSMenuItem(title: "utilBox", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        let total = store.items.count
        let saved = NSMenuItem(
            title: total == 1 ? "1 item saved" : "\(total) items saved",
            action: nil,
            keyEquivalent: ""
        )
        saved.isEnabled = false
        menu.addItem(saved)

        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            let versionItem = NSMenuItem(title: "Version \(version)", action: nil, keyEquivalent: "")
            versionItem.isEnabled = false
            menu.addItem(versionItem)
        }

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        switch SMAppService.mainApp.status {
        case .enabled:
            login.state = .on
            login.title = "Open at Login"
        case .requiresApproval:
            login.state = .mixed
            login.title = "Open at Login (needs approval)"
        case .notRegistered, .notFound:
            login.state = .off
            login.title = "Open at Login"
        @unknown default:
            login.state = .off
            login.title = "Open at Login"
        }
        menu.addItem(login)

        let clear = NSMenuItem(title: "Clear Unpinned", action: #selector(clearUnpinnedAction(_:)), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = store.items.contains { !$0.pinned }
        menu.addItem(clear)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit utilBox", action: #selector(quit(_:)), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.present(
                    title: "Couldn't change Open at Login",
                    message: "Move utilBox into the Applications folder and try again."
                )
            }
        }
    }

    @objc private func clearUnpinnedAction(_ sender: NSMenuItem) {
        DispatchQueue.main.async { [weak self] in
            self?.confirmClear()
        }
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    private func confirmClear() {
        let unpinned = store.items.filter { !$0.pinned }.count
        guard unpinned > 0 else { return }
        closePanel()
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = unpinned == 1
            ? "1 item will be removed. Pinned items stay."
            : "\(unpinned) items will be removed. Pinned items stay."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        activateApp()
        let response = alert.runModal()
        yieldToPreviousApp()
        guard response == .alertFirstButtonReturn else { return }
        if let armedID, store.item(armedID)?.pinned != true {
            self.armedID = nil
        }
        store.clearUnpinned()
    }

    private func present(title: String, message: String) {
        closePanel()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        activateApp()
        alert.runModal()
        yieldToPreviousApp()
    }

    private func activateApp() {
        suspendOverlay(true)
        activateUtilBox()
    }

    private func yieldToPreviousApp() {
        guard NSApp.isActive else { return }
        let keep = keepsOverlay()
        if keep, !AppFocus.returnToPreviousApp() {
            NSApp.keyWindow?.resignKey()
        }
        suspendOverlay(false)
        guard keep else {
            NSApp.hide(nil)
            return
        }
        overlayFront()
    }

    private func tickHover() {
        if menuOpen || dragHolding {
            hideWork?.cancel()
            hideWork = nil
            return
        }
        if hotspotContains(NSEvent.mouseLocation) {
            hideWork?.cancel()
            hideWork = nil
            return
        }
        guard panel.isVisible, !stuck, hideWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hideWork = nil
            guard self.panel.isVisible, !self.stuck, !self.dragHolding else { return }
            guard !self.hotspotContains(NSEvent.mouseLocation) else { return }
            self.closePanel()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    private func hotspotContains(_ point: NSPoint) -> Bool {
        guard let button = statusButtonFrame() else { return false }
        if button.insetBy(dx: -1, dy: -2).contains(point) { return true }
        guard panel.isVisible else { return false }
        if panel.frame.insetBy(dx: -12, dy: -8).contains(point) { return true }
        let gap = NSRect(
            x: button.minX - 6,
            y: min(button.minY, panel.frame.maxY),
            width: button.width + 12,
            height: abs(button.minY - panel.frame.maxY)
        )
        return gap.height > 0 && gap.contains(point)
    }

    private func handleMouseDown() {
        let point = NSEvent.mouseLocation
        if let button = statusButtonFrame(), button.insetBy(dx: -4, dy: -4).contains(point) {
            return
        }
        if panel.isVisible, panel.frame.contains(point) {
            stuck = true
            return
        }
        if panel.isVisible {
            stuck = false
            closePanel()
        }
    }

    private func escape() {
        if !query.isEmpty || !search.stringValue.isEmpty {
            search.stringValue = ""
            applyQuery("")
            return
        }
        stuck = false
        closePanel()
    }

    private func show() {
        reload()
        let height = preferredHeight()
        scrollHeight.constant = height - Metrics.chrome
        let wasVisible = panel.isVisible
        position(height: height)
        if !wasVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.panel.animator().alphaValue = 1
            }
        }
        refreshHighlight()
        syncColumnWidth()
    }

    private func closePanel(yield: Bool = false) {
        dragEnded()
        if panel.isVisible {
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
        refreshHighlight()
        cursor = nil
        if !search.stringValue.isEmpty || !query.isEmpty {
            search.stringValue = ""
            query = ""
        }
        if yield {
            yieldToPreviousApp()
        }
    }

    private func arm(_ id: UUID) {
        let now = ProcessInfo.processInfo.systemUptime
        if let lastArm, lastArm.id == id, now - lastArm.time < 0.35 { return }
        guard let item = store.item(id) else { return }
        guard let writer, writer.writeToClipboard(item) else {
            NSSound.beep()
            return
        }
        lastArm = (id, now)
        armedID = id
        stuck = false
        closePanel(yield: true)
    }

    private func refreshHighlight() {
        statusItem?.button?.isHighlighted = panel.isVisible || scratchOpen
    }

    private func dragEnteredIcon() {
        dragHolding = true
        hideWork?.cancel()
        hideWork = nil
        guard !panel.isVisible else { return }
        stuck = false
        show()
    }

    private func dragFinishedOnIcon(dropped: Bool) {
        dragHolding = false
        if dropped || stuck { return }
        dragEnded()
        if panel.isVisible {
            closePanel()
        }
    }

    private func dropOnIcon(_ sender: NSDraggingInfo) -> Bool {
        dragHolding = false
        let accepted = performDrop(sender)
        if accepted {
            show()
        }
        return accepted
    }

    private func togglePin(_ id: UUID) {
        if !store.togglePin(id) {
            NSSound.beep()
        }
    }

    private func delete(_ id: UUID) {
        if armedID == id {
            armedID = nil
        }
        store.delete(id)
    }

    private func preferredHeight() -> CGFloat {
        Metrics.chrome + listHeight()
    }

    private func listHeight() -> CGFloat {
        if shown.isEmpty { return Metrics.emptyListHeight }
        return CGFloat(min(shown.count, Metrics.maxVisibleRows)) * Metrics.rowHeight
    }

    private func position(height: CGFloat) {
        let size = NSSize(width: Metrics.width, height: height)
        guard let anchor = statusButtonFrame() else {
            panel.setContentSize(size)
            return
        }
        var frame = NSRect(
            x: anchor.midX - size.width / 2,
            y: anchor.minY - size.height - 6,
            width: size.width,
            height: size.height
        )
        let screen = NSScreen.screens.first {
            $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY))
        } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            if frame.maxX > visible.maxX - 8 {
                frame.origin.x = visible.maxX - 8 - frame.width
            }
            if frame.minX < visible.minX + 8 {
                frame.origin.x = visible.minX + 8
            }
            if frame.minY < visible.minY + 8 {
                frame.origin.y = visible.minY + 8
            }
            if frame.maxY > visible.maxY - 4 {
                frame.origin.y = visible.maxY - 4 - frame.height
            }
        }
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    private func statusButtonFrame() -> NSRect? {
        statusItem?.button?.window?.frame
    }

    private func syncColumnWidth() {
        let width = scroll.contentSize.width
        guard width > 20, let column = table.tableColumns.first else { return }
        if abs(column.width - width) > 0.5 {
            column.width = width
        }
    }

    private func updateChrome() {
        let total = store.items.count
        countLabel.stringValue = total == 0 ? "" : "\(total)"
        if shown.isEmpty {
            empty.isHidden = false
            if store.items.isEmpty {
                emptyTitle.stringValue = "Nothing saved yet"
                emptyBody.stringValue = "Copy something, or drop it here."
                emptyIcon.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
            } else {
                emptyTitle.stringValue = "No matches"
                emptyBody.stringValue = "Try a different search."
                emptyIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
            }
        } else {
            empty.isHidden = true
        }
        if !dropActive {
            footer.stringValue = "Click an item, then press ⌘V"
        }
    }

    private func applyQuery(_ text: String) {
        guard text != query else { return }
        query = text
        cursor = nil
        reload()
        if !shown.isEmpty {
            table.scrollRowToVisible(0)
        }
    }

    private func moveCursor(_ delta: Int) {
        guard !shown.isEmpty else { return }
        let start = cursor ?? (delta > 0 ? -1 : shown.count)
        let next = min(max(start + delta, 0), shown.count - 1)
        cursor = next
        refreshPointer()
        table.scrollRowToVisible(next)
    }

    private func confirmCursor() {
        let index: Int
        if let cursor {
            index = cursor
        } else if let armedID, let found = shown.firstIndex(where: { $0.id == armedID }) {
            index = found
        } else {
            index = 0
        }
        guard shown.indices.contains(index) else { return }
        arm(shown[index].id)
    }

    private func refreshPointer() {
        for row in shown.indices {
            let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ClipCell
            cell?.setPointed(row == cursor)
        }
    }

    @objc private func rowClicked() {
        if suppressNextClick {
            suppressNextClick = false
            return
        }
        let row = table.clickedRow
        guard shown.indices.contains(row) else { return }
        arm(shown[row].id)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        shown.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard shown.indices.contains(row) else { return nil }
        let item = shown[row]
        let cell = tableView.makeView(withIdentifier: ClipCell.reuseID, owner: self) as? ClipCell ?? ClipCell(frame: .zero)
        cell.identifier = ClipCell.reuseID
        var thumbnail: NSImage?
        if case .image(let body) = item.kind, let data = store.blob(body.file) {
            thumbnail = ThumbnailCache.shared.image(file: body.file, data: data)
        }
        let showsSeparator = row > 0 && shown[row - 1].pinned && !item.pinned
        cell.configure(ClipRowModel(
            id: item.id,
            title: ClipDisplay.title(for: item),
            detail: ClipDisplay.detail(for: item, now: Date(), fileExists: { path in
                FileManager.default.fileExists(atPath: path)
            }),
            symbolName: ClipDisplay.symbolName(for: item),
            thumbnail: thumbnail,
            pinned: item.pinned,
            armed: item.id == armedID,
            pointed: row == cursor,
            showsSeparator: showsSeparator,
            tooltip: ClipDisplay.tooltip(for: item)
        ))
        let id = item.id
        cell.onActivate = { [weak self] in self?.arm(id) }
        cell.onPin = { [weak self] in self?.togglePin(id) }
        cell.onDelete = { [weak self] in self?.delete(id) }
        cell.onSuppress = { [weak self] in self?.suppressNextClick = true }
        cell.onUnsuppress = { [weak self] in self?.suppressNextClick = false }
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard shown.indices.contains(row) else { return nil }
        return PasteboardService.dragWriter(for: shown[row], blob: { [store] name in
            store.blob(name)
        })
    }

    func controlTextDidChange(_ notification: Notification) {
        applyQuery(search.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            moveCursor(-1)
            return true
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            moveCursor(1)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:))
            || commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
            confirmCursor()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            escape()
            return true
        }
        return false
    }

    private func dragOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        if (sender.draggingSource as AnyObject?) === table { return [] }
        let names = Set((sender.draggingPasteboard.types ?? []).map(\.rawValue))
        let known: Set<String> = [
            NSPasteboard.PasteboardType.string.rawValue,
            NSPasteboard.PasteboardType.rtf.rawValue,
            NSPasteboard.PasteboardType.png.rawValue,
            NSPasteboard.PasteboardType.tiff.rawValue,
            NSPasteboard.PasteboardType.fileURL.rawValue,
            "public.html",
            "public.url",
            "NSFilenamesPboardType"
        ]
        guard !names.isDisjoint(with: known) else { return [] }
        beginDropHighlight()
        return .copy
    }

    private func dragEnded() {
        guard dropActive else { return }
        dropActive = false
        background.dropHighlighted = false
        footer.stringValue = "Click an item, then press ⌘V"
    }

    private func beginDropHighlight() {
        guard !dropActive else { return }
        dropActive = true
        footer.stringValue = "Drop to keep it"
        background.dropHighlighted = true
    }

    private func performDrop(_ sender: NSDraggingInfo) -> Bool {
        dragEnded()
        if (sender.draggingSource as AnyObject?) === table { return false }
        guard let clip = PasteboardService.capture(from: sender.draggingPasteboard, sourceApp: nil) else {
            return false
        }
        _ = store.ingest(clip, armedID: armedID)
        stuck = true
        return true
    }
}

private enum MailboxIcon {
    static let menuBar: NSImage = {
        let pointSize = NSSize(width: 18, height: 18)
        let image = NSImage(size: pointSize)
        for scale in [1.0, 2.0] {
            let pixelsWide = Int((pointSize.width * scale).rounded())
            let pixelsHigh = Int((pointSize.height * scale).rounded())
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelsWide,
                pixelsHigh: pixelsHigh,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else { continue }
            rep.size = pointSize
            NSGraphicsContext.saveGraphicsState()
            if let context = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.current = context
                context.shouldAntialias = true
                draw(in: NSRect(x: 0, y: 0, width: CGFloat(pixelsWide), height: CGFloat(pixelsHigh)))
            }
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        return image
    }()

    private static func draw(in rect: NSRect) {
        // Same mailbox as the app icon, enlarged so it reads at menu-bar size.
        // Reference y grows downward; the transform flips it into AppKit's y-up space.
        let scale = 248.0 / (0.90 * rect.width)
        var flip = CGAffineTransform(translationX: rect.midX, y: rect.midY)
        flip = flip.scaledBy(x: 1 / scale, y: -1 / scale)
        flip = flip.translatedBy(x: -277, y: -277)
        let placed = AffineTransform(m11: flip.a, m12: flip.b, m21: flip.c, m22: flip.d, tX: flip.tx, tY: flip.ty)

        func fill(_ build: (NSBezierPath) -> Void) {
            let path = NSBezierPath()
            build(path)
            path.transform(using: placed)
            path.fill()
        }

        NSColor.black.setFill()
        fill { $0.appendRoundedRect(NSRect(x: 153, y: 222, width: 247, height: 146), xRadius: 44, yRadius: 44) }
        fill { $0.appendRoundedRect(NSRect(x: 286, y: 154, width: 68, height: 34), xRadius: 6, yRadius: 6) }
        fill { $0.appendRect(NSRect(x: 288, y: 168, width: 12, height: 70)) }
        fill { $0.appendRoundedRect(NSRect(x: 331, y: 362, width: 26, height: 38), xRadius: 2, yRadius: 2) }

        guard let graphics = NSGraphicsContext.current else { return }
        graphics.compositingOperation = .destinationOut
        NSColor.black.setFill()
        fill { $0.appendOval(in: NSRect(x: 164, y: 238, width: 80, height: 80)) }
        fill { $0.appendRect(NSRect(x: 164, y: 278, width: 80, height: 74)) }
        graphics.compositingOperation = .sourceOver
    }
}

private final class MailboxCatcher: NSView {
    var onClick: () -> Void = {}
    var onMenu: () -> Void = {}
    var onDragEntered: () -> Void = {}
    var onDragExited: () -> Void = {}
    var onDragEnded: (Bool) -> Void = { _ in }
    var accepts: (NSDraggingInfo) -> NSDragOperation = { _ in [] }
    var onPerform: (NSDraggingInfo) -> Bool = { _ in false }
    private var dropped = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(PasteboardService.acceptedDropTypes)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes(PasteboardService.acceptedDropTypes)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            onMenu()
            return
        }
        guard let window else {
            onClick()
            return
        }
        var inside = true
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            inside = bounds.contains(convert(next.locationInWindow, from: nil))
            if next.type == .leftMouseUp { break }
        }
        if inside { onClick() }
    }

    override func rightMouseDown(with event: NSEvent) {
        onMenu()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = accepts(sender)
        if !operation.isEmpty { onDragEntered() }
        return operation
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        accepts(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragExited()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !accepts(sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropped = onPerform(sender)
        return dropped
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        let didDrop = dropped
        dropped = false
        onDragEnded(didDrop)
    }
}
