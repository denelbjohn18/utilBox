import AppKit
import Darwin

extension Notification.Name {
    static let utilBoxShow = Notification.Name("app.utilbox.show")
}

enum AppFocus {
    private static var previous: NSRunningApplication?
    private static var observer: NSObjectProtocol?

    static func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            let key = NSWorkspace.applicationUserInfoKey
            guard let app = notification.userInfo?[key] as? NSRunningApplication else { return }
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            previous = app
        }
    }

    static func noteCurrentOwner() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        previous = app
    }

    @discardableResult
    static func returnToPreviousApp() -> Bool {
        guard let previous, !previous.isTerminated else { return false }
        guard previous.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        return previous.activate(options: [.activateIgnoringOtherApps])
    }
}

// The macOS SDK also declares `struct flock`, which hides the POSIX function of the same name.
@_silgen_name("flock")
private func lockFileDescriptor(_ fileDescriptor: Int32, _ operation: Int32) -> Int32

enum InstanceLock {
    // Held open for the life of the process. Closing it would release the lock.
    static var fd: Int32 = -1

    static func acquire() -> Bool {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("app.utilbox.lock")
        fd = Darwin.open(url.path, O_CREAT | O_RDWR, mode_t(0o644))
        if fd < 0 { return true }
        if lockFileDescriptor(fd, LOCK_EX | LOCK_NB) != 0 {
            return false
        }
        return true
    }
}

@main
enum AppMain {
    static func main() {
        if !InstanceLock.acquire() {
            DistributedNotificationCenter.default().post(name: .utilBoxShow, object: nil)
            exit(0)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        guard let delegate = AppDelegate.make() else {
            Log.error("utilBox could not start.")
            exit(1)
        }
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store: ClipStore
    private let notes: ScratchStore
    private let monitor: ClipboardMonitor
    private let shelf: ShelfController
    private let scratch: ScratchpadController
    private var showObserver: NSObjectProtocol?

    private init(store: ClipStore, notes: ScratchStore) {
        self.store = store
        self.notes = notes
        let monitor = ClipboardMonitor(store: store)
        let shelf = ShelfController(store: store)
        let scratch = ScratchpadController(store: notes)
        self.monitor = monitor
        self.shelf = shelf
        self.scratch = scratch
        super.init()
        shelf.writer = monitor
        shelf.keepsOverlay = { [weak scratch] in
            scratch?.isShowing ?? false
        }
        shelf.suspendOverlay = { [weak scratch] suspended in
            scratch?.setAlertSuspended(suspended)
        }
        shelf.overlayFront = { [weak scratch] in
            scratch?.bringForwardIfOpen()
        }
        shelf.stackIsOpen = { [weak scratch] in
            scratch?.isShowing ?? false
        }
        shelf.onOpenStack = { [weak scratch] clipboard in
            scratch?.alignUnderClipboard(clipboard)
        }
        shelf.onCloseStack = { [weak scratch] in
            scratch?.hideFromIcon()
        }
        scratch.onVisibility = { [weak shelf] visible in
            shelf?.setScratchVisible(visible)
        }
        monitor.onIngest = { [weak shelf] effect in
            shelf?.apply(effect)
        }
        monitor.onUnknownClipboard = { [weak shelf] in
            shelf?.clearArm()
        }
        monitor.currentArm = { [weak shelf] in
            shelf?.armedID
        }
        store.onChange = { [weak shelf] in
            shelf?.reload()
        }
    }

    static func make() -> AppDelegate? {
        guard let store = try? ClipStore.live(),
              let notes = try? ScratchStore.live() else {
            return nil
        }
        return AppDelegate(store: store, notes: notes)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppFocus.start()
        AppFocus.noteCurrentOwner()
        shelf.start()
        scratch.start()
        scratch.restoreIfNeeded()
        monitor.start()
        showObserver = DistributedNotificationCenter.default().addObserver(
            forName: .utilBoxShow,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.shelf.showPinned()
            self?.scratch.bringForwardIfOpen()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        scratch.flush()
        store.flush()
    }
}
