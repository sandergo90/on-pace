import AppKit
import Sparkle
import SwiftUI

@main
enum UsageNotchApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private var notch: NotchPanel?
    private var watcher: UsageLogWatcher?
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        notch = NotchPanel(store: store)
        notch?.installMainMenu()
        notch?.reposition()
        notch?.playFirstLaunchMark()
        watcher = UsageLogWatcher { [weak store] in store?.logsChanged() }
        refresh()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(wokeUp), name: NSWorkspace.didWakeNotification, object: nil
        )
        let timer = Timer(timeInterval: 60, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        notch?.startUpdates()
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        watcher?.stop()
        notch?.stopMonitoringMouse()
        CLIConnection.stopAll()
    }

    @objc private func screenChanged() { notch?.reposition() }
    @objc private func refresh() {
        watcher?.updateRoots()
        store.refresh()
    }
    @objc private func wokeUp() {
        notch?.reposition()
        refresh()
    }
}

@MainActor
private final class NotchPanel: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
    private let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "On pace."
    private let store: UsageStore
    private let panel = PassivePanel(
        contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
    )
    private let surface = NotchSurface()
    private let presentation = NotchPresentation()
    private lazy var updateController = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self
    )
    private let updateSettings = UpdateSettings()
    private var updateObservations: [NSKeyValueObservation] = []
    private var placement: Placement?
    private var compactWidth: CGFloat = 0
    private var expandedHeight: CGFloat = 0
    private var hoverTask: Task<Void, Never>?
    private var displayLink: CADisplayLink?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var inside = false
    private var expanded: Bool { presentation.expanded }
    private var pinned: Bool { presentation.pinned }
    private var menuOpen = false
    private var aboutWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var dashboardWindow: NSWindow?
    private var opensOnHover: Bool {
        store.preferences.opensOnHover
    }

    init(store: UsageStore) {
        self.store = store
        super.init()
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.title = displayName
        panel.contentView = surface

        let movement: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: movement) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePointer() }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: movement) { [weak self] event in
            self?.updatePointer()
            return event
        }
    }

    func startUpdates() {
        updateController.startUpdater()
        if updateController.updater.automaticallyChecksForUpdates {
            updateController.updater.checkForUpdatesInBackground()
        }
    }

    func stopMonitoringMouse() {
        stopTrackingShape()
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
    }

    func playFirstLaunchMark() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "hasSeenTrailLaunch") else { return }
        defaults.set(true, forKey: "hasSeenTrailLaunch")
        presentation.showsLaunchMark = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            self?.presentation.showsLaunchMark = false
        }
    }

    func reposition() {
        hoverTask?.cancel()
        stopTrackingShape()
        guard let screen = NSScreen.usageDisplay(in: NSScreen.screens, preferred: store.preferences.preferredDisplay) else {
            placement = nil
            panel.orderOut(nil)
            return
        }
        let placement = Placement(screen)
        self.placement = placement
        compactWidth = placement.compactStyle.notchWidth ?? 0
        expandedHeight = placement.detailSize.height
        inside = false
        presentation.animates = false
        presentation.expanded = pinned
        panel.setFrame(placement.frame, display: false)
        let host = NotchHostingView(rootView: NotchView(
            store: store, compactStyle: placement.compactStyle, detailSize: placement.detailSize,
            presentation: presentation,
            togglePin: { [weak self] in self?.togglePin() },
            openDashboard: { [weak self] in self?.showDashboard() },
            openSettings: { [weak self] in self?.settingsMenu() },
            compactWidthChanged: { [weak self] in self?.updateCompactWidth($0) },
            expandedHeightChanged: { [weak self] in self?.updateExpandedHeight($0) }
        ))
        host.sizingOptions = []
        surface.install(host)
        showShape(on: placement, animated: false)
        panel.orderFrontRegardless()
        updatePointer()
    }

    private func updateCompactWidth(_ width: CGFloat) {
        guard let placement, case .pill = placement.compactStyle, width > 0, width != compactWidth else { return }
        compactWidth = width
        guard !expanded else { return }
        showShape(on: placement, animated: false)
        updatePointer()
    }

    private func showShape(on placement: Placement, animated: Bool) {
        let size = expanded
            ? CGSize(width: placement.detailSize.width, height: expandedHeight)
            : CGSize(width: compactWidth, height: placement.compactStyle.height)
        surface.show(size: size, style: placement.compactStyle, expanded: expanded, animated: animated)
    }

    private func updateExpandedHeight(_ measured: CGFloat) {
        guard let placement, measured > 0 else { return }
        let height = min(ceil(measured), placement.detailSize.height)
        guard height != expandedHeight else { return }
        expandedHeight = height
        guard expanded else { return }
        showShape(on: placement, animated: false)
        updatePointer()
    }

    private func updatePointer() {
        guard placement != nil else { return }
        let screenPoint = NSEvent.mouseLocation
        // A fast move can leave the pointer exactly on the screen's top edge.
        let hit = NSMouseInRect(screenPoint, panel.frame, false) && surface.contains(panel.convertPoint(fromScreen: screenPoint))
        if panel.ignoresMouseEvents == hit { panel.ignoresMouseEvents = !hit }
        guard inside != hit else { return }
        inside = hit
        scheduleHover()
    }

    private func scheduleHover() {
        hoverTask?.cancel()
        guard opensOnHover, !pinned, !menuOpen, inside != expanded else { return }
        let entered = inside
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(entered ? 100 : 155))
            guard !Task.isCancelled, let self, self.inside == entered, !self.pinned, !self.menuOpen else { return }
            self.setExpanded(entered)
        }
    }

    private func togglePin() {
        hoverTask?.cancel()
        presentation.pinned.toggle()
        setExpanded(pinned || (opensOnHover && inside))
    }

    private func setExpanded(_ expanded: Bool) {
        guard let placement, expanded != self.expanded else { return }
        let animated = panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        presentation.animates = animated
        presentation.expanded = expanded
        showShape(on: placement, animated: animated)
        if animated {
            if displayLink == nil {
                let link = surface.displayLink(target: self, selector: #selector(trackMovingShape(_:)))
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
        } else {
            stopTrackingShape()
        }
        updatePointer()
    }

    @objc private func trackMovingShape(_ link: CADisplayLink) {
        // Only hit testing runs on AppKit's display link. Core Animation owns rendering.
        updatePointer()
        if !surface.isAnimating { stopTrackingShape() }
    }

    private func stopTrackingShape() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func settingsMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        item(String(localized: "dashboard.title"), action: #selector(showDashboard), in: menu)
        item("Settings…", action: #selector(showSettings), in: menu).keyEquivalent = ","
        menu.addItem(.separator())
        item("About \(displayName)", action: #selector(showAbout), in: menu)
        let version = presentation.updateVersion
        let updateTitle = version.map { "Update Available (\($0))…" } ?? "Check for Updates…"
        let updateItem = item(updateTitle, action: #selector(checkForUpdates), in: menu)
        updateItem.isEnabled = updateController.updater.canCheckForUpdates
        if version != nil {
            let row = UpdateMenuItemView(item: updateItem)
            updateItem.view = row
            menu.delegate = row
        }
        item("Quit \(displayName)", action: #selector(quit), in: menu).keyEquivalent = "q"
        showMenu(menu)
    }

    @objc private func checkForUpdates() {
        guard updateController.updater.canCheckForUpdates else { return }
        // The notch sits above Sparkle's normal and modal windows.
        panel.level = .normal
        updateController.checkForUpdates(nil)
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                             andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                  state: SPUUserUpdateState) {
        if !handleShowingUpdate { presentation.updateVersion = update.displayVersionString }
    }

    func standardUserDriverWillFinishUpdateSession() {
        presentation.updateVersion = nil
        panel.level = .statusBar
    }

    @discardableResult
    private func item(_ title: String, action: Selector, in menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func showMenu(_ menu: NSMenu) {
        hoverTask?.cancel()
        menuOpen = true
        let frame = panel.frame
        let menuTop = min(frame.maxY - 31, panel.screen?.visibleFrame.maxY ?? frame.maxY) - 8
        let anchor = NSPoint(x: frame.maxX - NotchShape.shadowSide - 80, y: menuTop)
        menu.popUp(positioning: nil, at: anchor, in: nil)
        menuOpen = false
        updatePointer()
        scheduleHover()
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let updater = updateController.updater
            let settings = updateSettings
            // Sparkle changes these KVO properties on the main thread.
            updateObservations = [
                updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { updater, _ in
                    MainActor.assumeIsolated { settings.automaticallyChecks = updater.automaticallyChecksForUpdates }
                },
                updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { updater, _ in
                    MainActor.assumeIsolated { settings.canCheck = updater.canCheckForUpdates }
                },
                updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { updater, _ in
                    MainActor.assumeIsolated { settings.lastCheck = updater.lastUpdateCheckDate }
                },
            ]
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: SettingsView.size),
                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false
            )
            window.title = "General"
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentViewController = NSHostingController(rootView: SettingsView(
                store: store,
                updates: settings,
                presentation: presentation,
                setAutomaticChecks: { updater.automaticallyChecksForUpdates = $0 },
                checkForUpdates: { [weak self] in self?.checkForUpdates() },
                generalChanged: { [weak self] in self?.settingsChanged() },
                titleChanged: { [weak window] title in window?.title = title }
            ))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func showDashboard() {
        if dashboardWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: NotchShape.expandedWidth, height: NotchShape.expandedHeight),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
            )
            window.title = String(localized: "dashboard.title")
            window.contentMinSize = NSSize(width: 600, height: 400)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentViewController = NSHostingController(rootView:
                TimelineView(.periodic(from: .now, by: 1)) { [store] timeline in
                    ScrollView {
                        UsageDashboard(store: store, now: timeline.date, animateHighlights: true)
                            .padding(20)
                    }
                    .background(.black)
                }
            )
            window.center()
            dashboardWindow = window
        }
        if !pinned { setExpanded(false) }
        NSApp.activate(ignoringOtherApps: true)
        dashboardWindow?.makeKeyAndOrderFront(nil)
    }

    private func settingsChanged() {
        reposition()
        if !opensOnHover && !pinned { setExpanded(false) }
        scheduleHover()
    }

    func installMainMenu() {
        let main = NSMenu()
        let application = NSMenu()
        let root = NSMenuItem()
        root.submenu = application
        main.addItem(root)
        item("About \(displayName)", action: #selector(showAbout), in: application)
        application.addItem(.separator())
        item("Settings…", action: #selector(showSettings), in: application).keyEquivalent = ","
        application.addItem(.separator())
        item("Quit \(displayName)", action: #selector(quit), in: application).keyEquivalent = "q"
        NSApp.mainMenu = main
    }

    @objc private func showAbout() {
        let window = aboutWindow ?? NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 182),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false
        )
        if !window.isVisible {
            window.title = "About \(displayName)"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: AboutOnPace())
            window.center()
        }
        aboutWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

private final class UpdateMenuItemView: NSView, NSMenuDelegate {
    private weak var item: NSMenuItem?
    private let font = NSFont.menuFont(ofSize: 0)
    private let inset: CGFloat = 12
    private let dotSize: CGFloat = 6
    private var highlighted = false

    init(item: NSMenuItem) {
        self.item = item
        let titleWidth = (item.title as NSString).size(withAttributes: [.font: font]).width
        super.init(frame: NSRect(x: 0, y: 0, width: ceil(titleWidth) + 2 * inset + 22 + dotSize, height: 24))
        autoresizingMask = [.width]
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let item else { return }
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        let color: NSColor = if !item.isEnabled {
            .disabledControlTextColor
        } else if highlighted {
            .alternateSelectedControlTextColor
        } else {
            .labelColor
        }
        let title = NSAttributedString(string: item.title, attributes: [.font: font, .foregroundColor: color])
        title.draw(at: NSPoint(x: inset, y: (bounds.height - title.size().height) / 2))

        let lime = TrailGeometry.lime
        NSColor(srgbRed: lime.red, green: lime.green, blue: lime.blue, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: bounds.maxX - inset - dotSize, y: bounds.midY - dotSize / 2,
                                    width: dotSize, height: dotSize)).fill()
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        highlighted = self.item === item && item?.isEnabled == true
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        activate()
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "\r", "\u{3}", " ": activate()
        default: super.keyDown(with: event)
        }
    }

    private func activate() {
        guard let item, item.isEnabled, let menu = item.menu else { return }
        menu.cancelTracking()
        menu.performActionForItem(at: menu.index(of: item))
    }
}

private final class NotchHostingView: NSHostingView<NotchView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class PassivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct Placement {
    let centerX: CGFloat
    let top: CGFloat
    let compactStyle: CompactStyle
    let detailSize: CGSize

    var frame: NSRect {
        let width = detailSize.width + 2 * NotchShape.shadowSide
        let height = detailSize.height + NotchShape.shadowBottom
        return NSRect(x: centerX - width / 2, y: top - height, width: width, height: height)
    }

    @MainActor
    init(_ screen: NSScreen) {
        compactStyle = screen.compactStyle
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           right.minX > left.maxX {
            centerX = (left.maxX + right.minX) / 2
        } else {
            centerX = screen.frame.midX
        }
        top = screen.frame.maxY
        detailSize = CGSize(width: min(NotchShape.expandedWidth, screen.frame.width - 20),
                            height: min(NotchShape.expandedHeight, top - screen.visibleFrame.minY))
    }
}
