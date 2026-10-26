import AppKit
import QuartzCore

enum Metrics {
    static let width: CGFloat = 360
    static let rowHeight: CGFloat = 54
    static let maxVisibleRows = 7
    static let topInset: CGFloat = 12
    static let titleHeight: CGFloat = 18
    static let titleGap: CGFloat = 8
    static let searchHeight: CGFloat = 26
    static let searchGap: CGFloat = 8
    static let listGap: CGFloat = 4
    static let dividerHeight: CGFloat = 1
    static let footerGap: CGFloat = 6
    static let footerHeight: CGFloat = 16
    static let bottomInset: CGFloat = 10
    static let emptyListHeight: CGFloat = 112
    static let corner: CGFloat = 16

    static var chrome: CGFloat {
        topInset + titleHeight + titleGap + searchHeight + searchGap
            + listGap + dividerHeight + footerGap + footerHeight + bottomInset
    }
}

final class ShelfPanel: NSPanel {
    // Nonactivating so the app you copied from stays frontmost.
    // Command-V then pastes there, and utilBox never asks for Accessibility.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        worksWhenModal = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
    }

    required init?(coder: NSCoder) {
        return nil
    }
}

final class ShelfBackground: NSVisualEffectView {
    var dragOperation: ((NSDraggingInfo) -> NSDragOperation)?
    var dragExit: (() -> Void)?
    var dragPerform: ((NSDraggingInfo) -> Bool)?
    var onLayout: (() -> Void)?
    var onAppearance: (() -> Void)?
    var dropHighlighted = false {
        didSet { updateBorder() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        updateBorder()
        registerForDraggedTypes(PasteboardService.acceptedDropTypes)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            updateBorder()
            onAppearance?()
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation?(sender) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation?(sender) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dragExit?()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dragExit?()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let accepted = dragPerform?(sender) ?? false
        dragExit?()
        return accepted
    }

    private func updateBorder() {
        layer?.cornerRadius = Metrics.corner
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        let color = dropHighlighted ? NSColor.controlAccentColor : NSColor.separatorColor.withAlphaComponent(0.55)
        layer?.borderWidth = dropHighlighted ? 2 : 1
        layer?.borderColor = color.cgColor
    }
}

final class ShelfTable: NSTableView {
    var dragOperation: ((NSDraggingInfo) -> NSDragOperation)?
    var dragExit: (() -> Void)?
    var dragPerform: ((NSDraggingInfo) -> Bool)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation?(sender) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation?(sender) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dragExit?()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dragExit?()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let accepted = dragPerform?(sender) ?? false
        dragExit?()
        return accepted
    }
}
