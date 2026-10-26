import AppKit

final class IconButton: NSButton {
    var onMouseDown: (() -> Void)?
    var onMouseUpFinished: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        super.mouseDown(with: event)
        onMouseUpFinished?()
    }
}

final class ClickSearchField: NSSearchField {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class PassText: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class PassImage: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class PassWell: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct ClipRowModel {
    var id: UUID
    var title: String
    var detail: String
    var symbolName: String
    var thumbnail: NSImage?
    var pinned: Bool
    var armed: Bool
    var pointed: Bool
    var showsSeparator: Bool
    var tooltip: String
}

final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 100
    }

    func image(file: String, data: Data) -> NSImage? {
        if let hit = cache.object(forKey: file as NSString) { return hit }
        guard let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: file as NSString)
        return image
    }
}

final class ClipCell: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("ClipCell")

    var onActivate: (() -> Void)?
    var onPin: (() -> Void)?
    var onDelete: (() -> Void)?
    var onSuppress: (() -> Void)?
    var onUnsuppress: (() -> Void)?

    private let check = PassImage(frame: .zero)
    private let well = PassWell(frame: .zero)
    private let thumb = PassImage(frame: .zero)
    private let symbol = PassImage(frame: .zero)
    private let titleLabel = PassText(labelWithString: "")
    private let detailLabel = PassText(labelWithString: "")
    private let pinButton = IconButton(frame: .zero)
    private let deleteButton = IconButton(frame: .zero)
    private var tracking: NSTrackingArea?
    private var downPoint: NSPoint?
    private var isPinned = false
    private var isHovered = false
    private var isArmed = false
    private var isPointed = false
    private var showsSeparator = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override var isOpaque: Bool { false }

    func configure(_ model: ClipRowModel) {
        titleLabel.stringValue = model.title
        titleLabel.toolTip = model.tooltip
        detailLabel.stringValue = model.detail
        toolTip = model.tooltip
        isPinned = model.pinned
        isArmed = model.armed
        isPointed = model.pointed
        showsSeparator = model.showsSeparator
        if let thumbnail = model.thumbnail {
            thumb.image = thumbnail
            thumb.isHidden = false
            symbol.isHidden = true
        } else {
            thumb.image = nil
            thumb.isHidden = true
            symbol.isHidden = false
            let image = NSImage(systemSymbolName: model.symbolName, accessibilityDescription: nil)
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            symbol.image = image?.withSymbolConfiguration(config)
            symbol.contentTintColor = .secondaryLabelColor
        }
        applyWellColor()
        updateActions()
        check.isHidden = !model.armed
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(model.title), \(model.detail)")
        needsDisplay = true
        refreshHover()
    }

    func setPointed(_ pointed: Bool) {
        guard pointed != isPointed else { return }
        isPointed = pointed
        needsDisplay = true
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onActivate = nil
        onPin = nil
        onDelete = nil
        onSuppress = nil
        onUnsuppress = nil
        thumb.image = nil
        isHovered = false
        downPoint = nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        tracking = area
        addTrackingArea(area)
        refreshHover()
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    override func mouseDown(with event: NSEvent) {
        downPoint = event.locationInWindow
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { downPoint = nil }
        super.mouseUp(with: event)
        guard let downPoint else { return }
        let up = event.locationInWindow
        guard abs(up.x - downPoint.x) < 5, abs(up.y - downPoint.y) < 5 else { return }
        onActivate?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if showsSeparator {
            NSColor.separatorColor.withAlphaComponent(0.8).setFill()
            NSRect(x: 18, y: bounds.height - 1, width: max(0, bounds.width - 36), height: 1).fill()
        }
        guard isArmed || isHovered || isPointed else { return }
        let color = isArmed
            ? NSColor.controlAccentColor.withAlphaComponent(0.18)
            : NSColor.labelColor.withAlphaComponent(0.06)
        color.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 2), xRadius: 8, yRadius: 8).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            applyWellColor()
            needsDisplay = true
        }
    }

    private func build() {
        wantsLayer = false
        check.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Ready to paste")
        check.contentTintColor = .controlAccentColor
        check.image?.isTemplate = true
        check.imageScaling = .scaleProportionallyDown

        well.wantsLayer = true
        well.layer?.cornerRadius = 8
        well.layer?.masksToBounds = true

        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.imageAlignment = .alignCenter
        symbol.imageScaling = .scaleProportionallyDown
        symbol.imageAlignment = .alignCenter

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configure(pinButton)
        configure(deleteButton)
        deleteButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove")
        deleteButton.contentTintColor = .secondaryLabelColor
        deleteButton.toolTip = "Remove"
        pinButton.target = self
        pinButton.action = #selector(pinPressed)
        deleteButton.target = self
        deleteButton.action = #selector(deletePressed)
        let release: () -> Void = { [weak self] in
            DispatchQueue.main.async { self?.onUnsuppress?() }
        }
        pinButton.onMouseDown = { [weak self] in self?.onSuppress?() }
        pinButton.onMouseUpFinished = release
        deleteButton.onMouseDown = { [weak self] in self?.onSuppress?() }
        deleteButton.onMouseUpFinished = release

        let views = [check, well, thumb, symbol, titleLabel, detailLabel, pinButton, deleteButton]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(check)
        addSubview(well)
        well.addSubview(thumb)
        well.addSubview(symbol)
        addSubview(titleLabel)
        addSubview(detailLabel)
        addSubview(pinButton)
        addSubview(deleteButton)

        NSLayoutConstraint.activate([
            check.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 16),
            check.heightAnchor.constraint(equalToConstant: 16),

            well.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 8),
            well.centerYAnchor.constraint(equalTo: centerYAnchor),
            well.widthAnchor.constraint(equalToConstant: 36),
            well.heightAnchor.constraint(equalToConstant: 36),

            thumb.leadingAnchor.constraint(equalTo: well.leadingAnchor),
            thumb.trailingAnchor.constraint(equalTo: well.trailingAnchor),
            thumb.topAnchor.constraint(equalTo: well.topAnchor),
            thumb.bottomAnchor.constraint(equalTo: well.bottomAnchor),
            symbol.centerXAnchor.constraint(equalTo: well.centerXAnchor),
            symbol.centerYAnchor.constraint(equalTo: well.centerYAnchor),
            symbol.widthAnchor.constraint(equalToConstant: 18),
            symbol.heightAnchor.constraint(equalToConstant: 18),

            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            deleteButton.widthAnchor.constraint(equalToConstant: 22),
            deleteButton.heightAnchor.constraint(equalToConstant: 22),
            pinButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -2),
            pinButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            pinButton.widthAnchor.constraint(equalToConstant: 22),
            pinButton.heightAnchor.constraint(equalToConstant: 22),

            titleLabel.leadingAnchor.constraint(equalTo: well.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: pinButton.leadingAnchor, constant: -8),
            titleLabel.bottomAnchor.constraint(equalTo: centerYAnchor, constant: -1),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: centerYAnchor, constant: 1)
        ])
    }

    private func configure(_ button: NSButton) {
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func updateActions() {
        let showPin = isHovered || isPinned
        pinButton.isHidden = !showPin
        deleteButton.isHidden = !isHovered
        let name = isPinned ? "pin.fill" : "pin"
        let label = isPinned ? "Unpin" : "Pin"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: label)
        image?.isTemplate = true
        pinButton.image = image
        pinButton.contentTintColor = isPinned ? .controlAccentColor : .secondaryLabelColor
        pinButton.toolTip = label
    }

    private func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        updateActions()
        needsDisplay = true
    }

    private func refreshHover() {
        guard let window else {
            setHovered(false)
            return
        }
        let mouse = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let local = convert(mouse, from: nil)
        setHovered(bounds.contains(local))
    }

    private func applyWellColor() {
        let color = thumb.isHidden ? NSColor.labelColor.withAlphaComponent(0.08) : NSColor.clear
        well.layer?.backgroundColor = color.cgColor
    }

    @objc private func pinPressed() {
        onPin?()
    }

    @objc private func deletePressed() {
        onDelete?()
    }
}
