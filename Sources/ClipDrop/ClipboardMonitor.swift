import AppKit

protocol ClipboardWriting: AnyObject {
    func writeToClipboard(_ item: ClipItem) -> Bool
}

final class ClipboardMonitor: ClipboardWriting {
    var onIngest: (IngestEffect) -> Void = { _ in }
    var onUnknownClipboard: () -> Void = {}
    var currentArm: () -> UUID? = { nil }

    private let store: ClipStore
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    private var lastCount = -1
    private var ignoredCount: Int?
    private var suppress = false

    init(store: ClipStore) {
        self.store = store
    }

    func start() {
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    func writeToClipboard(_ item: ClipItem) -> Bool {
        pending?.cancel()
        pending = nil
        suppress = true
        defer { suppress = false }
        let wrote = PasteboardService.write(item, blob: { [store] name in
            store.blob(name)
        }, to: .general)
        guard wrote else { return false }
        let count = NSPasteboard.general.changeCount
        ignoredCount = count
        lastCount = count
        return true
    }

    private func poll() {
        let count = NSPasteboard.general.changeCount
        guard count != lastCount else { return }
        lastCount = count
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.capture()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func capture() {
        if suppress { return }
        let pasteboard = NSPasteboard.general
        if pasteboard.changeCount == ignoredCount { return }
        guard let clip = PasteboardService.capture(
            from: pasteboard,
            sourceApp: PasteboardService.frontmostAppName()
        ) else {
            onUnknownClipboard()
            return
        }
        let effect = store.ingest(clip, armedID: currentArm())
        onIngest(effect)
    }

    deinit {
        timer?.invalidate()
        pending?.cancel()
    }
}
