import AppKit

final class FileDragWriter: NSObject, NSPasteboardWriting {
    private let paths: [String]

    init(paths: [String]) {
        self.paths = paths
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        return [.fileURL, .string, NSPasteboard.PasteboardType("NSFilenamesPboardType")]
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .fileURL:
            guard let first = paths.first else { return nil }
            return URL(fileURLWithPath: first).absoluteString
        case .string:
            return paths
                .map { URL(fileURLWithPath: $0).lastPathComponent }
                .joined(separator: "\n")
        default:
            if type.rawValue == "NSFilenamesPboardType" { return paths }
            return nil
        }
    }
}

enum PasteboardService {
    static let acceptedDropTypes: [NSPasteboard.PasteboardType] = [
        .string,
        .rtf,
        .png,
        .tiff,
        .fileURL,
        NSPasteboard.PasteboardType("public.html"),
        NSPasteboard.PasteboardType("public.url"),
        NSPasteboard.PasteboardType("NSFilenamesPboardType")
    ]

    static func frontmostAppName() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return nil }
        return app.localizedName
    }

    static func capture(from pasteboard: NSPasteboard, sourceApp: String?) -> CapturedClip? {
        let typeNames = (pasteboard.types ?? []).map(\.rawValue)
        if ClipClassifier.isSensitive(typeNames) { return nil }

        var raw = RawPaste()
        raw.typeNames = typeNames
        raw.sourceApp = sourceApp
        raw.filePaths = filePaths(from: pasteboard)

        if let data = pasteboard.data(forType: .string), data.count > Limits.maxTextBytes {
            raw.rejectedOversizedText = true
        } else {
            raw.string = pasteboard.string(forType: .string)
                ?? pasteboard.string(forType: NSPasteboard.PasteboardType("public.url"))
            raw.rtf = pasteboard.data(forType: .rtf)
            raw.html = pasteboard.data(forType: NSPasteboard.PasteboardType("public.html"))
        }

        if let image = imagePNG(from: pasteboard) {
            raw.imagePNG = image.data
            raw.imageWidth = image.width
            raw.imageHeight = image.height
        }
        return ClipClassifier.classify(raw)
    }

    @discardableResult
    static func writePlainText(_ string: String, to pasteboard: NSPasteboard = .general) -> Bool {
        if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        let entry = NSPasteboardItem()
        entry.setString(string, forType: .string)
        pasteboard.clearContents()
        return pasteboard.writeObjects([entry])
    }

    @discardableResult
    static func write(_ item: ClipItem, blob: (String) -> Data?, to pasteboard: NSPasteboard) -> Bool {
        guard let objects = writers(for: item, blob: blob), !objects.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects(objects)
    }

    static func dragWriter(for item: ClipItem, blob: (String) -> Data?) -> NSPasteboardWriting? {
        switch item.kind {
        case .text(let body):
            let entry = NSPasteboardItem()
            entry.setString(body.string, forType: .string)
            if let name = body.rtfFile, let data = blob(name), !data.isEmpty {
                entry.setData(data, forType: .rtf)
            }
            if let name = body.htmlFile, let data = blob(name), !data.isEmpty {
                entry.setData(data, forType: NSPasteboard.PasteboardType("public.html"))
            }
            return entry
        case .image(let body):
            guard let png = blob(body.file), !png.isEmpty else { return nil }
            let entry = NSPasteboardItem()
            entry.setData(png, forType: .png)
            if let rep = NSBitmapImageRep(data: png),
               let tiff = rep.representation(using: .tiff, properties: [:]) {
                entry.setData(tiff, forType: .tiff)
            }
            return entry
        case .files(let body):
            let paths = body.paths.filter { !$0.isEmpty }
            guard !paths.isEmpty else { return nil }
            return FileDragWriter(paths: paths)
        }
    }

    private static func writers(for item: ClipItem, blob: (String) -> Data?) -> [NSPasteboardWriting]? {
        switch item.kind {
        case .text(let body):
            let entry = NSPasteboardItem()
            entry.setString(body.string, forType: .string)
            if let name = body.rtfFile, let data = blob(name), !data.isEmpty {
                entry.setData(data, forType: .rtf)
            }
            if let name = body.htmlFile, let data = blob(name), !data.isEmpty {
                entry.setData(data, forType: NSPasteboard.PasteboardType("public.html"))
            }
            return [entry]
        case .image(let body):
            guard let png = blob(body.file), !png.isEmpty else { return nil }
            let entry = NSPasteboardItem()
            entry.setData(png, forType: .png)
            if let rep = NSBitmapImageRep(data: png),
               let tiff = rep.representation(using: .tiff, properties: [:]) {
                entry.setData(tiff, forType: .tiff)
            }
            return [entry]
        case .files(let body):
            let urls = body.paths.filter { !$0.isEmpty }.map { NSURL(fileURLWithPath: $0) }
            guard !urls.isEmpty else { return nil }
            return urls as [NSPasteboardWriting]
        }
    }

    private static func filePaths(from pasteboard: NSPasteboard) -> [String] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) ?? []
        var paths: [String] = []
        for object in objects {
            guard let url = object as? URL else { continue }
            if !url.path.isEmpty {
                paths.append(url.path)
            }
        }
        if !paths.isEmpty { return paths }
        let legacy = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let list = pasteboard.propertyList(forType: legacy) as? [String] {
            return list.filter { !$0.isEmpty }
        }
        return []
    }

    private static func imagePNG(from pasteboard: NSPasteboard) -> (data: Data, width: Int, height: Int)? {
        if let blob = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            if blob.count > Limits.maxImageBytes { return nil }
            if let decoded = png(from: blob) { return decoded }
        }
        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              tiff.count <= Limits.maxImageBytes else { return nil }
        return png(from: tiff)
    }

    private static func png(from data: Data) -> (data: Data, width: Int, height: Int)? {
        guard let rep = NSBitmapImageRep(data: data),
              let png = rep.representation(using: .png, properties: [:]),
              png.count <= Limits.maxImageBytes,
              rep.pixelsWide > 0,
              rep.pixelsHigh > 0 else { return nil }
        return (png, rep.pixelsWide, rep.pixelsHigh)
    }
}
