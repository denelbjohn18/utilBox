import AppKit
import QuartzCore

func activateUtilBox() {
    AppFocus.noteCurrentOwner()
    if #available(macOS 14.0, *) {
        NSApp.activate()
    } else {
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension ScratchFrame {
    init(_ rect: NSRect) {
        self.init(x: Double(rect.origin.x), y: Double(rect.origin.y), width: Double(rect.width), height: Double(rect.height))
    }

    var rect: NSRect {
        NSRect(x: x, y: y, width: width, height: height)
    }
}

final class ScratchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = Self.overlayLevel
        collectionBehavior = Self.overlayBehavior
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        isRestorable = false
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none
        title = "Scratchpad"
        minSize = NSSize(width: 360, height: 240)
        maxSize = NSSize(width: 1400, height: 1000)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, shouldActivate(for: event) {
            activateUtilBox()
        }
        super.sendEvent(event)
    }

    static let overlayLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
    static let overlayBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle
    ]

    private func shouldActivate(for event: NSEvent) -> Bool {
        guard let content = contentView else { return false }
        let inContent = content.convert(event.locationInWindow, from: nil)
        let inSuper = content.superview?.convert(inContent, from: content) ?? inContent
        guard let hit = content.hitTest(inSuper) else { return false }
        var allow = false
        var view: NSView? = hit
        while let current = view {
            if current is NSTextView || current is NSSearchField { allow = true }
            if current is DragStrip || current is NSButton || current is NSTableView { return false }
            view = current.superview
        }
        return allow
    }
}

final class PillPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = ScratchPanel.overlayLevel
        collectionBehavior = ScratchPanel.overlayBehavior
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        isRestorable = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        title = "Scratchpad"
    }

    required init?(coder: NSCoder) {
        return nil
    }
}

final class PadTextView: NSTextView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class ClearRow: NSTableRowView {
    override var isOpaque: Bool { false }
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}
}

final class NoteCell: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("NoteCell")

    var onDelete: (() -> Void)?

    private let titleLabel = PassText(labelWithString: "")
    private let detailLabel = PassText(labelWithString: "")
    private let deleteButton = NSButton(frame: .zero)
    private var tracking: NSTrackingArea?
    private var isPicked = false
    private var isHovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = Paper.muted
        detailLabel.lineBreakMode = .byTruncatingTail
        deleteButton.isBordered = false
        deleteButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Delete note")
        deleteButton.image?.isTemplate = true
        deleteButton.contentTintColor = Paper.muted
        deleteButton.target = self
        deleteButton.action = #selector(deletePressed)
        deleteButton.toolTip = "Delete note"
        for view in [titleLabel, detailLabel, deleteButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            deleteButton.widthAnchor.constraint(equalToConstant: 22),
            deleteButton.heightAnchor.constraint(equalToConstant: 22),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -6),
            titleLabel.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 0),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: centerYAnchor, constant: 2)
        ])
        updateChrome()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override var isOpaque: Bool { false }

    func apply(title: String, detail: String, untitled: Bool, selected: Bool) {
        titleLabel.stringValue = title
        titleLabel.textColor = untitled ? Paper.muted : Paper.ink
        detailLabel.stringValue = detail
        isPicked = selected
        updateChrome()
        needsDisplay = true
    }

    func setSelected(_ selected: Bool) {
        guard selected != isPicked else { return }
        isPicked = selected
        updateChrome()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        tracking = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateChrome()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateChrome()
    }

    override func draw(_ dirtyRect: NSRect) {
        if isPicked || isHovered {
            let color = isPicked
                ? Paper.ink.withAlphaComponent(0.07)
                : Paper.ink.withAlphaComponent(0.04)
            color.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 2), xRadius: 8, yRadius: 8).fill()
        }
    }

    private func updateChrome() {
        deleteButton.isHidden = !(isHovered || isPicked)
    }

    @objc private func deletePressed() {
        onDelete?()
    }
}

final class PillBody: NSView {
    let copyButton = NSButton(frame: .zero)
    var onOpen: (() -> Void)?
    var onDragFinished: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.09, green: 0.09, blue: 0.10, alpha: 1).cgColor
        layer?.cornerRadius = 24
        layer?.cornerCurve = .continuous
        copyButton.isBordered = false
        copyButton.imagePosition = .imageOnly
        copyButton.toolTip = "Copy note"
        copyButton.setAccessibilityLabel("Copy note")
        let icon = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        copyButton.image = icon?.withSymbolConfiguration(config)
        copyButton.contentTintColor = .white
        copyButton.wantsLayer = true
        copyButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        copyButton.layer?.cornerRadius = 16
        addSubview(copyButton)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        let side: CGFloat = 32
        copyButton.frame = NSRect(
            x: bounds.width - side - 8,
            y: (bounds.height - side) / 2,
            width: side,
            height: side
        )
        copyButton.layer?.cornerRadius = side / 2
    }

    override func draw(_ dirtyRect: NSRect) {
        let text = "Scratchpad" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: 18, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let path = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        guard path.contains(local) else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let start = window?.frame.origin ?? .zero
        window?.performDrag(with: event)
        let end = window?.frame.origin ?? start
        if abs(end.x - start.x) < 3, abs(end.y - start.y) < 3 {
            onOpen?()
        } else {
            onDragFinished?()
        }
    }
}

final class ScratchpadController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    private let store: ScratchStore
    private var rows: [ScratchNote] = []
    private var query = ""
    private var sidebarHidden = false
    private var alertSuspended = false
    private var suppressEditor = false
    private var suppressSelection = false
    var onVisibility: (Bool) -> Void = { _ in }
    private var saveWork: DispatchWorkItem?
    private var frameWork: DispatchWorkItem?
    private var copyReset: DispatchWorkItem?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var appObservers: [NSObjectProtocol] = []

    private let padWindow: ScratchPanel
    private let pillWindow: PillPanel
    private let paper = PaperView(frame: .zero)
    private let header = DragStrip(frame: .zero)
    private let sidebarButton = NSButton(frame: .zero)
    private let titleLabel = PassText(labelWithString: "Scratchpad")
    private let newHeaderButton = NSButton(frame: .zero)
    private let pillButton = NSButton(frame: .zero)
    private let closeButton = NSButton(frame: .zero)
    private let headerLine = NSView(frame: .zero)
    private let sidebar = SidebarWash(frame: .zero)
    private let collapseNotesButton = NSButton(frame: .zero)
    private let newNoteButton = NSButton(frame: .zero)
    private let search = NSSearchField(frame: .zero)
    private let listScroll = NSScrollView(frame: .zero)
    private let table = NSTableView(frame: .zero)
    private let emptyLabel = NSTextField(labelWithString: "No notes yet")
    private let verticalLine = NSView(frame: .zero)
    private let editor = NSView(frame: .zero)
    private let textScroll = NSScrollView(frame: .zero)
    private let textView = PadTextView(frame: .zero)
    private let placeholder = PassText(labelWithString: "Start writing. This stays on top while you switch apps.")
    private let prompt = NSTextField(labelWithString: "No notes yet")
    private let copyButton = NSButton(frame: .zero)
    private let pillBody = PillBody(frame: .zero)
    private var sidebarWidth: NSLayoutConstraint!
    private var sidebarStretch: [NSLayoutConstraint] = []
    private var dividerWidth: NSLayoutConstraint!

    init(store: ScratchStore) {
        self.store = store
        padWindow = ScratchPanel(contentRect: NSRect(x: 0, y: 0, width: PaperMetrics.padWidth, height: PaperMetrics.padHeight))
        pillWindow = PillPanel(contentRect: NSRect(x: 0, y: 0, width: 236, height: 48))
        super.init()
        sidebarHidden = store.session.sidebarHidden
        buildPad()
        buildPill()
        padWindow.delegate = self
        textView.delegate = self
        search.delegate = self
    }

    var isShowing: Bool {
        !NSApp.isHidden && (padWindow.isVisible || pillWindow.isVisible)
    }

    func start() {
        watchSpaces()
    }

    func alignUnderClipboard(_ clipboard: NSRect) {
        if store.notes.isEmpty {
            _ = store.create()
        }
        unhideIfNeeded()
        padWindow.appearance = NSAppearance(named: .aqua)
        applySidebar(hidden: store.session.sidebarHidden)
        padWindow.setFrame(stackedFrame(under: clipboard), display: false)
        reloadList()
        loadEditor()
        pillWindow.orderOut(nil)
        if padWindow.isVisible {
            raise(padWindow)
        } else {
            fadeIn(padWindow)
        }
        padWindow.invalidateShadow()
        remember(open: true, pill: false)
        updateHighlight()
    }

    func hideFromIcon() {
        closePad()
    }

    func restoreIfNeeded() {
        guard store.session.isOpen else { return }
        if store.session.isPill {
            showPill(anchoredToWindow: false)
        } else {
            showWindow()
        }
    }

    func bringForwardIfOpen() {
        guard !alertSuspended, store.session.isOpen else { return }
        if store.session.isPill {
            padWindow.orderOut(nil)
            raise(pillWindow)
        } else {
            pillWindow.orderOut(nil)
            raise(padWindow)
        }
    }

    func setAlertSuspended(_ suspended: Bool) {
        alertSuspended = suspended
        if suspended {
            padWindow.level = .normal
            pillWindow.level = .normal
        } else {
            bringForwardIfOpen()
        }
    }

    func flush() {
        frameWork?.cancel()
        flushEditing()
        remember(open: padWindow.isVisible || pillWindow.isVisible, pill: pillWindow.isVisible && !padWindow.isVisible)
    }

    deinit {
        saveWork?.cancel()
        frameWork?.cancel()
        copyReset?.cancel()
        let workspace = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            workspace.removeObserver(observer)
        }
        for observer in appObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func buildPad() {
        paper.appearance = NSAppearance(named: .aqua)
        padWindow.contentView = paper

        configure(sidebarButton, symbol: "sidebar.left", label: "Hide notes", action: #selector(toggleSidebar))
        configure(newHeaderButton, symbol: "plus", label: "New note", action: #selector(newNote))
        configure(pillButton, symbol: "minus", label: "Shrink to a pill", action: #selector(collapseToPill))
        configure(closeButton, symbol: "xmark", label: "Hide scratchpad", action: #selector(closePad))
        newHeaderButton.keyEquivalent = "n"
        closeButton.keyEquivalent = "w"

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = Paper.muted
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.alignment = .center

        headerLine.wantsLayer = true
        headerLine.layer?.backgroundColor = Paper.hairline.cgColor
        verticalLine.wantsLayer = true
        verticalLine.layer?.backgroundColor = Paper.hairline.cgColor

        styleRow(collapseNotesButton, symbol: "sidebar.left", title: "Collapse Notes", action: #selector(toggleSidebar))
        styleRow(newNoteButton, symbol: "square.and.pencil", title: "New note", action: #selector(newNote))

        search.placeholderString = "Search notes"
        search.focusRingType = .none
        search.controlSize = .small
        search.font = .systemFont(ofSize: 13)
        search.sendsSearchStringImmediately = true

        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false
        listScroll.borderType = .noBorder
        listScroll.autohidesScrollers = true
        listScroll.contentView.drawsBackground = false
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.rowHeight = 50
        table.intercellSpacing = .zero
        table.gridStyleMask = []
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("notes"))
        column.resizingMask = .autoresizingMask
        column.minWidth = 120
        column.maxWidth = 10_000
        column.width = PaperMetrics.sidebar
        table.addTableColumn(column)
        listScroll.documentView = table

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = Paper.muted
        emptyLabel.alignment = .center

        editor.wantsLayer = false
        textScroll.drawsBackground = false
        textScroll.borderType = .noBorder
        textScroll.hasVerticalScroller = true
        textScroll.autohidesScrollers = true
        textScroll.automaticallyAdjustsContentInsets = false
        textScroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 68, right: 8)
        textScroll.contentView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = Paper.ink
        textView.insertionPointColor = Paper.ink
        textView.font = Paper.font
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 28, height: 22)
        textView.textContainer?.widthTracksTextView = true
        textView.typingAttributes = [
            .font: Paper.font,
            .foregroundColor: Paper.ink,
            .paragraphStyle: Paper.paragraph
        ]
        textView.defaultParagraphStyle = Paper.paragraph
        textScroll.documentView = textView

        placeholder.font = Paper.font
        placeholder.textColor = Paper.muted
        placeholder.maximumNumberOfLines = 2
        placeholder.lineBreakMode = .byWordWrapping
        prompt.font = .systemFont(ofSize: 15, weight: .medium)
        prompt.textColor = Paper.muted
        prompt.alignment = .center

        copyButton.isBordered = false
        copyButton.focusRingType = .none
        copyButton.imagePosition = .imageLeading
        copyButton.wantsLayer = true
        copyButton.layer?.backgroundColor = Paper.copyFill.cgColor
        copyButton.layer?.cornerRadius = 18
        copyButton.contentTintColor = .white
        let copyIcon = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
        let copyConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        copyButton.image = copyIcon?.withSymbolConfiguration(copyConfig)
        copyButton.attributedTitle = copyTitle("Copy")
        copyButton.target = self
        copyButton.action = #selector(copyCurrent)
        copyButton.toolTip = "Copy the whole note"

        header.onDrag = { [weak self] event in
            self?.padWindow.performDrag(with: event)
            self?.scheduleFrameSave()
        }
        sidebar.onLayout = { [weak self] in
            self?.syncColumnWidth()
        }

        let views = [
            header, sidebarButton, titleLabel, newHeaderButton, pillButton, closeButton, headerLine,
            sidebar, collapseNotesButton, newNoteButton, search, listScroll, emptyLabel, verticalLine,
            editor, textScroll, placeholder, prompt, copyButton
        ]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        paper.addSubview(header)
        header.addSubview(sidebarButton)
        header.addSubview(titleLabel)
        header.addSubview(newHeaderButton)
        header.addSubview(pillButton)
        header.addSubview(closeButton)
        paper.addSubview(headerLine)
        paper.addSubview(sidebar)
        sidebar.addSubview(collapseNotesButton)
        sidebar.addSubview(newNoteButton)
        sidebar.addSubview(search)
        sidebar.addSubview(listScroll)
        sidebar.addSubview(emptyLabel)
        paper.addSubview(verticalLine)
        paper.addSubview(editor)
        editor.addSubview(textScroll)
        editor.addSubview(placeholder)
        editor.addSubview(prompt)
        editor.addSubview(copyButton)

        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: sidebarHidden ? 0 : PaperMetrics.sidebar)
        dividerWidth = verticalLine.widthAnchor.constraint(equalToConstant: sidebarHidden ? 0 : 1)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: paper.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: paper.trailingAnchor),
            header.topAnchor.constraint(equalTo: paper.topAnchor),
            header.heightAnchor.constraint(equalToConstant: PaperMetrics.header),

            sidebarButton.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            sidebarButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            sidebarButton.widthAnchor.constraint(equalToConstant: 28),
            sidebarButton.heightAnchor.constraint(equalToConstant: 28),

            closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
            closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.heightAnchor.constraint(equalToConstant: 28),
            pillButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2),
            pillButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            pillButton.widthAnchor.constraint(equalToConstant: 28),
            pillButton.heightAnchor.constraint(equalToConstant: 28),
            newHeaderButton.trailingAnchor.constraint(equalTo: pillButton.leadingAnchor, constant: -2),
            newHeaderButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            newHeaderButton.widthAnchor.constraint(equalToConstant: 28),
            newHeaderButton.heightAnchor.constraint(equalToConstant: 28),

            titleLabel.leadingAnchor.constraint(equalTo: sidebarButton.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: newHeaderButton.leadingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            headerLine.leadingAnchor.constraint(equalTo: paper.leadingAnchor, constant: 12),
            headerLine.trailingAnchor.constraint(equalTo: paper.trailingAnchor, constant: -12),
            headerLine.topAnchor.constraint(equalTo: header.bottomAnchor),
            headerLine.heightAnchor.constraint(equalToConstant: 1),

            sidebar.leadingAnchor.constraint(equalTo: paper.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: headerLine.bottomAnchor),
            sidebar.bottomAnchor.constraint(equalTo: paper.bottomAnchor),
            sidebarWidth,

            collapseNotesButton.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            collapseNotesButton.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 8),
            collapseNotesButton.heightAnchor.constraint(equalToConstant: 30),
            newNoteButton.leadingAnchor.constraint(equalTo: collapseNotesButton.leadingAnchor),
            newNoteButton.topAnchor.constraint(equalTo: collapseNotesButton.bottomAnchor, constant: 2),
            newNoteButton.heightAnchor.constraint(equalToConstant: 30),
            search.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            search.topAnchor.constraint(equalTo: newNoteButton.bottomAnchor, constant: 8),
            search.heightAnchor.constraint(equalToConstant: 26),
            listScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            listScroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            listScroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -8),
            emptyLabel.centerXAnchor.constraint(equalTo: listScroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: listScroll.centerYAnchor),

            verticalLine.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            verticalLine.topAnchor.constraint(equalTo: headerLine.bottomAnchor),
            verticalLine.bottomAnchor.constraint(equalTo: paper.bottomAnchor),
            dividerWidth,

            editor.leadingAnchor.constraint(equalTo: verticalLine.trailingAnchor),
            editor.trailingAnchor.constraint(equalTo: paper.trailingAnchor),
            editor.topAnchor.constraint(equalTo: headerLine.bottomAnchor),
            editor.bottomAnchor.constraint(equalTo: paper.bottomAnchor),

            textScroll.leadingAnchor.constraint(equalTo: editor.leadingAnchor),
            textScroll.trailingAnchor.constraint(equalTo: editor.trailingAnchor),
            textScroll.topAnchor.constraint(equalTo: editor.topAnchor),
            textScroll.bottomAnchor.constraint(equalTo: editor.bottomAnchor),
            placeholder.leadingAnchor.constraint(equalTo: editor.leadingAnchor, constant: 32),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: editor.trailingAnchor, constant: -36),
            placeholder.topAnchor.constraint(equalTo: editor.topAnchor, constant: 26),
            prompt.centerXAnchor.constraint(equalTo: editor.centerXAnchor),
            prompt.centerYAnchor.constraint(equalTo: editor.centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: editor.trailingAnchor, constant: -18),
            copyButton.bottomAnchor.constraint(equalTo: editor.bottomAnchor, constant: -16),
            copyButton.widthAnchor.constraint(equalToConstant: 132),
            copyButton.heightAnchor.constraint(equalToConstant: 36)
        ])
        let stretch = [
            collapseNotesButton.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -8),
            newNoteButton.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -8),
            search.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12)
        ]
        for constraint in stretch {
            constraint.priority = NSLayoutConstraint.Priority(rawValue: 999.0)
        }
        sidebarStretch = stretch
        sidebar.wantsLayer = true
        sidebar.layer?.masksToBounds = true
        applySidebar(hidden: sidebarHidden)
    }

    private func buildPill() {
        pillWindow.contentView = pillBody
        pillBody.copyButton.target = self
        pillBody.copyButton.action = #selector(copyCurrent)
        pillBody.onOpen = { [weak self] in
            self?.showWindow()
        }
        pillBody.onDragFinished = { [weak self] in
            guard let self else { return }
            let clamped = self.clampToScreen(self.pillWindow.frame)
            if clamped != self.pillWindow.frame {
                self.pillWindow.setFrame(clamped, display: true)
            }
            self.remember(open: true, pill: true)
        }
    }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.image?.isTemplate = true
        button.contentTintColor = Paper.ink
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    private func styleRow(_ button: NSButton, symbol: String, title: String, action: Selector) {
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.alignment = .left
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.image?.isTemplate = true
        button.contentTintColor = Paper.ink
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: Paper.ink
        ])
        button.target = self
        button.action = action
    }

    private func copyTitle(_ title: String) -> NSAttributedString {
        NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white
        ])
    }

    private func showWindow() {
        unhideIfNeeded()
        padWindow.appearance = NSAppearance(named: .aqua)
        applySidebar(hidden: store.session.sidebarHidden)
        padWindow.setFrame(frameForPad(), display: false)
        reloadList()
        loadEditor()
        pillWindow.orderOut(nil)
        if padWindow.isVisible {
            raise(padWindow)
        } else {
            fadeIn(padWindow)
        }
        padWindow.invalidateShadow()
        remember(open: true, pill: false)
        updateHighlight()
    }

    @objc private func collapseToPill() {
        showPill(anchoredToWindow: true)
    }

    private func showPill(anchoredToWindow: Bool) {
        flushEditing()
        unhideIfNeeded()
        let frame: NSRect
        if anchoredToWindow {
            frame = NSRect(x: padWindow.frame.maxX - 236, y: padWindow.frame.minY + 12, width: 236, height: 48)
        } else if let saved = store.session.pill?.rect {
            frame = NSRect(x: saved.origin.x, y: saved.origin.y, width: 236, height: 48)
        } else {
            let anchor = store.session.window?.rect ?? defaultPadFrame()
            frame = NSRect(x: anchor.maxX - 236, y: anchor.minY + 12, width: 236, height: 48)
        }
        pillWindow.setFrame(clampToScreen(frame), display: false)
        padWindow.orderOut(nil)
        if pillWindow.isVisible {
            raise(pillWindow)
        } else {
            fadeIn(pillWindow)
        }
        remember(open: true, pill: true)
        updateHighlight()
    }

    @objc private func closePad() {
        flushEditing()
        padWindow.orderOut(nil)
        pillWindow.orderOut(nil)
        remember(open: false, pill: false)
        updateHighlight()
    }

    private func fadeIn(_ window: NSWindow) {
        window.level = ScratchPanel.overlayLevel
        window.collectionBehavior = ScratchPanel.overlayBehavior
        window.hidesOnDeactivate = false
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            window.animator().alphaValue = 1
        }
    }

    @objc private func toggleSidebar() {
        applySidebar(hidden: !sidebarHidden)
        var session = store.session
        session.sidebarHidden = sidebarHidden
        store.setSession(session)
    }

    private func applySidebar(hidden: Bool) {
        sidebarHidden = hidden
        if hidden {
            for constraint in sidebarStretch { constraint.isActive = false }
            sidebarWidth.constant = 0
            dividerWidth.constant = 0
        } else {
            sidebarWidth.constant = PaperMetrics.sidebar
            dividerWidth.constant = 1
            for constraint in sidebarStretch { constraint.isActive = true }
        }
        sidebar.isHidden = hidden
        verticalLine.isHidden = hidden
        let symbol = hidden ? "sidebar.right" : "sidebar.left"
        let label = hidden ? "Show notes" : "Hide notes"
        sidebarButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        sidebarButton.toolTip = label
    }

    @objc private func newNote() {
        flushEditing()
        search.stringValue = ""
        query = ""
        guard store.create() != nil else {
            NSSound.beep()
            return
        }
        reloadList()
        loadEditor()
        activateUtilBox()
        padWindow.makeFirstResponder(textView)
    }

    @objc private func copyCurrent() {
        flushEditing()
        guard let note = store.selected(), !note.isBlank else {
            NSSound.beep()
            return
        }
        guard PasteboardService.writePlainText(note.body) else {
            NSSound.beep()
            return
        }
        copyButton.attributedTitle = copyTitle("Copied")
        pillBody.copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
        copyReset?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.copyButton.attributedTitle = self.copyTitle("Copy")
            let icon = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            self.pillBody.copyButton.image = icon?.withSymbolConfiguration(config)
        }
        copyReset = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
    }

    private func deleteNote(_ id: UUID) {
        flushEditing()
        store.delete(id)
        reloadList()
        loadEditor()
    }

    private func loadEditor() {
        let note = store.selected()
        setBody(note?.body ?? "")
        textView.undoManager?.removeAllActions()
        let blank = note?.isBlank ?? true
        placeholder.isHidden = note == nil || !blank
        textView.isHidden = note == nil
        copyButton.isHidden = note == nil
        prompt.isHidden = note != nil
        titleLabel.stringValue = note?.title ?? "Scratchpad"
        titleLabel.textColor = (note == nil || blank) ? Paper.muted : Paper.ink
        padWindow.title = titleLabel.stringValue
    }

    private func setBody(_ body: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Paper.font,
            .foregroundColor: Paper.ink,
            .paragraphStyle: Paper.paragraph
        ]
        textView.typingAttributes = attributes
        suppressEditor = true
        if let storage = textView.textStorage {
            storage.setAttributedString(NSAttributedString(string: body, attributes: attributes))
        } else {
            textView.string = body
        }
        suppressEditor = false
    }

    private func reloadList() {
        rows = store.filtered(query: query)
        emptyLabel.stringValue = store.notes.isEmpty ? "No notes yet" : "No matches"
        emptyLabel.isHidden = !rows.isEmpty
        table.reloadData()
        suppressSelection = true
        if let id = store.selectedID, let index = rows.firstIndex(where: { $0.id == id }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
        } else {
            table.deselectAll(nil)
        }
        suppressSelection = false
        syncColumnWidth()
    }

    private func applyQuery(_ text: String) {
        query = text
        reloadList()
    }

    private func flushEditing() {
        saveWork?.cancel()
        saveWork = nil
        guard let id = store.selectedID else { return }
        _ = store.updateBody(id, textView.string)
    }

    private func scheduleSave() {
        saveWork?.cancel()
        guard let id = store.selectedID else { return }
        let text = textView.string
        let work = DispatchWorkItem { [weak self] in
            self?.commit(id: id, text: text)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func commit(id: UUID, text: String) {
        guard store.updateBody(id, text), let note = store.note(id) else { return }
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index] = note
        let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? NoteCell
        cell?.apply(
            title: note.title,
            detail: RelativeTime.string(from: note.updatedAt),
            untitled: note.isBlank,
            selected: store.selectedID == id
        )
    }

    private func refreshSelectionHighlight() {
        for row in rows.indices {
            let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NoteCell
            cell?.setSelected(rows[row].id == store.selectedID)
        }
    }

    func textDidChange(_ notification: Notification) {
        guard !suppressEditor, notification.object as AnyObject === textView else { return }
        if textView.string.count > ScratchStore.maxBodyCharacters {
            NSSound.beep()
            if let id = store.selectedID, let note = store.note(id) {
                setBody(note.body)
                let blank = note.isBlank
                placeholder.isHidden = !blank
                titleLabel.stringValue = note.title
                titleLabel.textColor = blank ? Paper.muted : Paper.ink
            }
            return
        }
        let blank = textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        placeholder.isHidden = !blank
        titleLabel.stringValue = ScratchTitle.from(textView.string)
        titleLabel.textColor = blank ? Paper.muted : Paper.ink
        scheduleSave()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as AnyObject === search else { return }
        applyQuery(search.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), !search.stringValue.isEmpty {
            search.stringValue = ""
            applyQuery("")
            return true
        }
        return false
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("NoteRow")
        let rowView = tableView.makeView(withIdentifier: identifier, owner: self) as? ClearRow ?? ClearRow(frame: .zero)
        rowView.identifier = identifier
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let item = rows[row]
        let cell = tableView.makeView(withIdentifier: NoteCell.reuseID, owner: self) as? NoteCell ?? NoteCell(frame: .zero)
        cell.identifier = NoteCell.reuseID
        cell.apply(
            title: item.title,
            detail: RelativeTime.string(from: item.updatedAt),
            untitled: item.isBlank,
            selected: item.id == store.selectedID
        )
        let id = item.id
        cell.onDelete = { [weak self] in
            self?.deleteNote(id)
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }
        let row = table.selectedRow
        guard rows.indices.contains(row) else { return }
        let id = rows[row].id
        guard id != store.selectedID else { return }
        flushEditing()
        store.select(id)
        loadEditor()
        refreshSelectionHighlight()
    }

    func windowDidMove(_ notification: Notification) {
        guard notification.object as AnyObject === padWindow else { return }
        scheduleFrameSave()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard notification.object as AnyObject === padWindow else { return }
        scheduleFrameSave()
    }

    private func syncColumnWidth() {
        let width = listScroll.contentSize.width
        guard width > 40, let column = table.tableColumns.first else { return }
        if abs(column.width - width) > 0.5 {
            column.width = width
        }
    }

    private func scheduleFrameSave() {
        frameWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let pill = self.pillWindow.isVisible && !self.padWindow.isVisible
            self.remember(open: self.padWindow.isVisible || self.pillWindow.isVisible, pill: pill)
        }
        frameWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func remember(open: Bool, pill: Bool) {
        var session = store.session
        session.isOpen = open
        session.isPill = pill
        session.sidebarHidden = sidebarHidden
        if padWindow.frame.width > 100, padWindow.frame.height > 100 {
            session.window = ScratchFrame(padWindow.frame)
        }
        if pillWindow.frame.width > 40 {
            session.pill = ScratchFrame(pillWindow.frame)
        }
        store.setSession(session)
    }

    private func frameForPad() -> NSRect {
        if let saved = store.session.window?.rect, let usable = onScreen(saved) {
            return usable
        }
        return defaultPadFrame()
    }

    private func defaultPadFrame() -> NSRect {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let width = min(PaperMetrics.padWidth, max(400, screen.width - 48))
        let height = min(PaperMetrics.padHeight, max(320, screen.height - 96))
        var frame = NSRect(
            x: screen.maxX - width - 24,
            y: screen.minY + 24,
            width: width,
            height: height
        )
        if frame.maxX > screen.maxX - 8 { frame.origin.x = screen.maxX - 8 - frame.width }
        if frame.minX < screen.minX + 8 { frame.origin.x = screen.minX + 8 }
        if frame.maxY > screen.maxY - 8 { frame.origin.y = screen.maxY - 8 - frame.height }
        if frame.minY < screen.minY + 8 { frame.origin.y = screen.minY + 8 }
        return frame
    }

    private func onScreen(_ rect: NSRect) -> NSRect? {
        guard rect.width >= 320, rect.height >= 240 else { return nil }
        let fitted = NSRect(
            x: rect.origin.x,
            y: rect.origin.y,
            width: min(max(rect.width, 400), 1400),
            height: min(max(rect.height, 320), 1000)
        )
        guard NSScreen.screens.contains(where: { $0.visibleFrame.intersects(fitted) }) else { return nil }
        return fitted
    }

    private func clampToScreen(_ rect: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return rect }
        var fitted = rect
        if fitted.maxX > visible.maxX - 8 { fitted.origin.x = visible.maxX - 8 - fitted.width }
        if fitted.minX < visible.minX + 8 { fitted.origin.x = visible.minX + 8 }
        if fitted.minY < visible.minY + 8 { fitted.origin.y = visible.minY + 8 }
        if fitted.maxY > visible.maxY - 8 { fitted.origin.y = visible.maxY - 8 - fitted.height }
        return fitted
    }

    private func updateHighlight() {
        onVisibility(isShowing)
    }

    private func stackedFrame(under clipboard: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(clipboard) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let gap: CGFloat = 8
        let width = min(480, max(360, visible.width - 32))
        let top = clipboard.height > 20 ? clipboard.minY - gap : visible.maxY - 28
        let bottom = visible.minY + 12
        var height = min(560, top - bottom)
        if height < 240 { height = 240 }
        var frame = NSRect(x: clipboard.midX - width / 2, y: top - height, width: width, height: height)
        if frame.maxX > visible.maxX - 8 { frame.origin.x = visible.maxX - 8 - frame.width }
        if frame.minX < visible.minX + 8 { frame.origin.x = visible.minX + 8 }
        // The pad sits under the shelf. On a short screen the bottom gives way,
        // so the higher window never covers the clipboard.
        if frame.maxY > top {
            frame.origin.y = top - frame.height
        }
        if frame.minY < bottom, top - bottom >= 240 {
            frame.size.height = min(frame.height, top - bottom)
            frame.origin.y = top - frame.height
        }
        return frame
    }

    private func unhideIfNeeded() {
        guard NSApp.isHidden else { return }
        NSApp.unhide(nil)
    }

    private func raise(_ window: NSWindow) {
        window.level = ScratchPanel.overlayLevel
        window.collectionBehavior = ScratchPanel.overlayBehavior
        window.hidesOnDeactivate = false
        window.orderFrontRegardless()
    }

    private func watchSpaces() {
        guard workspaceObservers.isEmpty, appObservers.isEmpty else { return }
        let forward: (Notification) -> Void = { [weak self] _ in
            self?.bringForwardIfOpen()
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main,
            using: forward
        ))
        appObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main,
            using: forward
        ))
        appObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main,
            using: forward
        ))
    }
}
