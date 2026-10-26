import AppKit
import QuartzCore

enum PaperMetrics {
    static let corner: CGFloat = 18
    static let sidebar: CGFloat = 232
    static let header: CGFloat = 52
    // Wispr Flow's open scratchpad, measured from a 2x screenshot: 1000×840 px.
    static let padWidth: CGFloat = 500
    static let padHeight: CGFloat = 420
}

enum Paper {
    static let top = NSColor(srgbRed: 0.969, green: 0.949, blue: 0.910, alpha: 1)
    static let bottom = NSColor(srgbRed: 0.902, green: 0.863, blue: 0.796, alpha: 1)
    static let ink = NSColor(srgbRed: 0.176, green: 0.153, blue: 0.129, alpha: 1)
    static let muted = NSColor(srgbRed: 0.459, green: 0.420, blue: 0.373, alpha: 1)
    static let hairline = NSColor(srgbRed: 0.176, green: 0.153, blue: 0.129, alpha: 0.14)
    static let copyFill = NSColor(srgbRed: 0.11, green: 0.10, blue: 0.09, alpha: 1)
    static let font = NSFont(name: "Georgia", size: 17) ?? NSFont.systemFont(ofSize: 17)

    static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        return style
    }()
}

enum PaperNoise {
    static let side = 128

    // Bipolar grain, seeded so the sheet does not shimmer between launches.
    static let samples: [Double] = {
        var state: UInt64 = 0xC0FFEE
        var values = [Double](repeating: 0, count: side * side)
        for index in values.indices {
            state = state &* 6364136223846793005 &+ 1
            values[index] = Double((state >> 33) & 0xff) / 255.0 - 0.5
        }
        return values
    }()
}

final class PaperView: NSView {
    private var cache: NSImage?
    private var cachedPixels = NSSize.zero
    private var liveResizing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = PaperMetrics.corner
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override var isOpaque: Bool { false }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        cache = nil
        needsDisplay = true
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        liveResizing = true
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        liveResizing = false
        cache = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let pixels = NSSize(width: max(bounds.width, 1) * scale, height: max(bounds.height, 1) * scale)
        if cache == nil || (!liveResizing && cachedPixels != pixels) {
            cache = render(pixelWidth: max(Int(pixels.width.rounded()), 1), pixelHeight: max(Int(pixels.height.rounded()), 1))
            cachedPixels = pixels
        }
        cache?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
    }

    private func render(pixelWidth: Int, pixelHeight: Int) -> NSImage? {
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: pixelWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else { return nil }

        let pixels = data.bindMemory(to: UInt8.self, capacity: pixelWidth * pixelHeight * 4)
        let noise = PaperNoise.samples
        let side = PaperNoise.side
        let width = Double(pixelWidth)
        let height = Double(pixelHeight)
        for y in 0..<pixelHeight {
            let fade = Double(y) / Double(max(pixelHeight - 1, 1))
            let noiseY = y % side
            let dy = (Double(y) - (height - 1) / 2) / (height / 2)
            for x in 0..<pixelWidth {
                let noiseX = x % side
                let grain = noise[noiseY * side + noiseX] * 0.045
                var red = 0.969 * (1 - fade) + 0.902 * fade + grain
                var green = 0.949 * (1 - fade) + 0.863 * fade + grain
                var blue = 0.910 * (1 - fade) + 0.796 * fade + grain
                let dx = (Double(x) - (width - 1) / 2) / (width / 2)
                let distance = min(1, pow((dx * dx + dy * dy).squareRoot(), 1.6))
                let shade = distance * 0.10
                red = red * (1 - shade) + 0.45 * shade
                green = green * (1 - shade) + 0.36 * shade
                blue = blue * (1 - shade) + 0.24 * shade
                let offset = (y * pixelWidth + x) * 4
                pixels[offset] = byte(red)
                pixels[offset + 1] = byte(green)
                pixels[offset + 2] = byte(blue)
                pixels[offset + 3] = 255
            }
        }
        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: bounds.size)
    }

    private func byte(_ value: Double) -> UInt8 {
        let scaled = Int((value * 255).rounded())
        if scaled <= 0 { return 0 }
        if scaled >= 255 { return 255 }
        return UInt8(scaled)
    }
}

final class SidebarWash: NSView {
    var onLayout: (() -> Void)?

    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.36, green: 0.28, blue: 0.18, alpha: 0.06).setFill()
        bounds.fill()
    }
}

final class DragStrip: NSView {
    var onDrag: ((NSEvent) -> Void)?

    override var isOpaque: Bool { false }

    override func mouseDown(with event: NSEvent) {
        onDrag?(event)
    }
}
