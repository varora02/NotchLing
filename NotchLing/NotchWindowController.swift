import AppKit
import Combine
import QuartzCore
import SwiftUI

struct ScreenNotchGeometry {
    let screenFrame: NSRect
    let notchMinX: CGFloat
    let notchMaxX: CGFloat
    let menuBarHeight: CGFloat
}

enum RexPresentationPolicy {
    static func nativeStatusVisibility(frame: NSRect, occluded: Bool, screenFrame: NSRect, barHeight: CGFloat) -> Bool? {
        let band = NSRect(x: screenFrame.minX, y: screenFrame.maxY - barHeight,
                          width: screenFrame.width, height: barHeight)
        // Never let the status bar on a different display control the pet.
        guard frame.intersects(band) else { return nil }
        return !occluded
    }

    static func shouldHidePassiveRex(
        statusAreaSuppressed: Bool,
        panelExpanded: Bool,
        transientAlertActive: Bool
    ) -> Bool {
        statusAreaSuppressed && !panelExpanded && !transientAlertActive
    }
}

/// Only the newest visibility request may finish an asynchronous fade.
struct PetVisibilityTransition {
    private(set) var generation = 0
    private(set) var wantsVisible = false

    @discardableResult
    mutating func request(visible: Bool) -> Int {
        generation += 1
        wantsVisible = visible
        return generation
    }

    func mayFinishHide(_ token: Int) -> Bool {
        !wantsVisible && token == generation
    }
}

@MainActor
final class StatusAreaVisibilityMonitor {
    private var timer: Timer?
    private var screenProvider: (() -> NSScreen?)?
    private var onChange: ((Bool) -> Void)?
    private var lastVisible: Bool?
    private var visibilityItem: NSStatusItem?

    func start(
        screenProvider: @escaping () -> NSScreen?,
        onChange: @escaping (Bool) -> Void
    ) {
        stop()
        self.screenProvider = screenProvider
        self.onChange = onChange
        // A blank native item supplies an app-owned visibility signal even
        // when CGWindowList omits other processes' status windows. It has no
        // icon, menu or action; the pet remains the only entry point.
        let item = NSStatusBar.system.statusItem(withLength: 1)
        item.button?.title = ""
        item.button?.isEnabled = false
        item.button?.setAccessibilityElement(false)
        visibilityItem = item
        checkNow()

        // Common modes keep visibility polling alive while a menu is tracking.
        let timer = Timer(
            timeInterval: 0.25,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkNow()
            }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        screenProvider = nil
        onChange = nil
        lastVisible = nil
        if let visibilityItem { NSStatusBar.system.removeStatusItem(visibilityItem) }
        visibilityItem = nil
    }

    func checkNow() {
        guard let screen = screenProvider?() else {
            publish(false)
            return
        }

        publish(statusItemsAreVisible(on: screen))
    }

    private func publish(_ visible: Bool) {
        guard visible != lastVisible else { return }
        lastVisible = visible
        onChange?(visible)
    }

    func statusItemsAreVisible(on screen: NSScreen) -> Bool {
        if let window = visibilityItem?.button?.window,
           let visible = RexPresentationPolicy.nativeStatusVisibility(
               frame: window.frame,
               occluded: !window.occlusionState.contains(.visible),
               screenFrame: screen.frame,
               barHeight: max(screen.safeAreaInsets.top, NSStatusBar.system.thickness) + 6
           ) {
            return visible
        }
        return Self.externalStatusItemsAreVisible(on: screen)
    }

    static func externalStatusItemsAreVisible(
        on screen: NSScreen,
        excludingPID: pid_t = getpid()
    ) -> Bool {
        guard
            let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber
        else {
            return true
        }

        let displayID = CGDirectDisplayID(number.uint32Value)
        let displayBounds = CGDisplayBounds(displayID)
        let barHeight = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness) + 6
        let statusBand = CGRect(
            x: displayBounds.minX,
            y: displayBounds.minY,
            width: displayBounds.width,
            height: barHeight
        )

        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return true
        }

        return windows.contains { window in
            guard
                let ownerPID = window[kCGWindowOwnerPID as String] as? NSNumber,
                ownerPID.int32Value != excludingPID,
                let layer = window[kCGWindowLayer as String] as? NSNumber,
                layer.intValue == NSWindow.Level.statusBar.rawValue,
                let alpha = window[kCGWindowAlpha as String] as? NSNumber,
                alpha.doubleValue > 0.01,
                let boundsObject = window[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(
                    dictionaryRepresentation: boundsObject as CFDictionary
                )
            else {
                return false
            }

            return Self.looksLikeStatusItem(
                bounds: bounds,
                statusBand: statusBand
            )
        }
    }

    static func looksLikeStatusItem(
        bounds: CGRect,
        statusBand: CGRect
    ) -> Bool {
        guard bounds.intersects(statusBand),
              bounds.width > 1,
              bounds.height > 1,
              bounds.height <= statusBand.height + 8 else {
            return false
        }

        // Exclude menu-bar-sized overlays. Actual status items are compact
        // windows (Control Center, battery, third-party menu extras, etc.).
        return bounds.width < statusBand.width * 0.8
    }
}

final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class DetailPanel: NSPanel {
    var allowsKeyWindow = false
    /// Escape; returns whether the current content handled it.
    var onCancel: (() -> Bool)?

    override var canBecomeKey: Bool { allowsKeyWindow }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, onCancel?() == true { return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if onCancel?() != true { super.cancelOperation(sender) }
    }
}

/// The one-time "Manage agents anytime" hint beside the pet.
final class TipPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class RexInteractionView: NSView {
    private let model: AppModel
    private let hostingView: NSHostingView<PetBarView>
    private var isTrackingClick = false

    init(model: AppModel) {
        self.model = model
        self.hostingView = NSHostingView(rootView: PetBarView(model: model))
        super.init(frame: NSRect(origin: .zero, size: CGSize(width: 52, height: 32)))

        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        addSubview(hostingView)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        interactiveRect.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        isTrackingClick = interactiveRect.contains(point)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        isTrackingClick = interactiveRect.contains(point)
    }

    override func mouseUp(with event: NSEvent) {
        defer { isTrackingClick = false }

        let point = convert(event.locationInWindow, from: nil)
        guard isTrackingClick, interactiveRect.contains(point) else { return }

        // Double-clicks collapse to the same primary action: the first click
        // toggles the panel and the second click is ignored.
        guard event.clickCount == 1 else { return }
        model.toggleExpanded()
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard interactiveRect.contains(point) else { return }

        let menu = NSMenu()

        let quickNote = NSMenuItem(
            title: "Quick Note",
            action: #selector(openQuickNoteFromMenu(_:)),
            keyEquivalent: ""
        )
        quickNote.target = self
        menu.addItem(quickNote)

        let quit = NSMenuItem(
            title: "Quit NotchLing",
            action: #selector(quitFromMenu(_:)),
            keyEquivalent: ""
        )
        quit.target = self
        menu.addItem(quit)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func openQuickNoteFromMenu(_ sender: Any?) {
        model.openQuickNote()
    }

    @objc private func quitFromMenu(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private var interactiveRect: NSRect {
        switch model.petMode {
        case .resting:
            return NSRect(x: 4, y: 3, width: 43, height: 26)
        case .working:
            return NSRect(x: 4, y: 2, width: 43, height: 28)
        case .needsYou:
            return NSRect(x: 6, y: 2, width: 32, height: 28)
        case .hidePeek:
            return NSRect(x: 22, y: 2, width: 23, height: 28)
        }
    }
}

final class OutsideClickController {
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var menuObservers: [NSObjectProtocol] = []
    private var menuTrackingDepth = 0

    var isMonitoring: Bool {
        localMonitor != nil || globalMonitor != nil
    }

    func start(
        anchorWindow: NSWindow,
        detailWindow: NSWindow,
        onDismiss: @escaping @MainActor () -> Void
    ) {
        guard !isMonitoring else { return }

        // A menu's window is separate from the floating detail panel. Keep
        // that panel alive until its menu has delivered the selected action.
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
            menuObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let self else { return }
                self.menuTrackingDepth = max(0, self.menuTrackingDepth + (notification.name == NSMenu.didBeginTrackingNotification ? 1 : -1))
            })
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            if self?.menuTrackingDepth ?? 0 > 0 { return event }
            if event.window === anchorWindow || event.window === detailWindow {
                return event
            }

            Task { @MainActor in onDismiss() }
            return event
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { _ in
            Task { @MainActor in onDismiss() }
        }
    }

    func stop() {
        menuObservers.forEach(NotificationCenter.default.removeObserver)
        menuObservers.removeAll()
        menuTrackingDepth = 0
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }

        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }
}

/// Hosts the tip and turns any click on it into a dismissal.
@MainActor
final class TipHostingView: NSHostingView<ConnectionsTipView> {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        super.init(rootView: ConnectionsTipView())
    }

    @MainActor required init(rootView: ConnectionsTipView) {
        fatalError("init(rootView:) is not used")
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        model.dismissConnectionsTip()
    }
}

@MainActor
final class NotchWindowController: NSObject {
    private let model: AppModel
    private let petPanel: PetPanel
    private let detailPanel: DetailPanel
    private let tipPanel: TipPanel
    private let outsideClickController = OutsideClickController()
    private let statusAreaVisibilityMonitor = StatusAreaVisibilityMonitor()

    private var cancellables: Set<AnyCancellable> = []
    private var screenObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var idleAnimationTask: Task<Void, Never>?
    private var ambientPeekTask: Task<Void, Never>?
    /// True from the moment a peek is started until it finishes or is
    /// cancelled, including the first moments before the model reports it.
    private var isPeekInFlight = false
    private var hasPeekBegun = false
    private var nextAmbientPeekVariant: PeekAnimationVariant = .two
    private var transientTask: Task<Void, Never>?
    private var isForcedDeveloperPeekActive = false
    private var forcedDeveloperPeekGeneration = 0
    private var peekAnimationGeneration = 0
    private var presentationRecheckTask: Task<Void, Never>?
    private var isStatusAreaSuppressed = false
    private var lastObservedMode: PetMode = .resting
    private var visibilityTransition = PetVisibilityTransition()

    private let petSize = CGSize(width: 52, height: 32)
    private let petGapFromNotch: CGFloat = 2

    private var detailPanelSize: CGSize {
        NotchLingPanelLayout.size(for: model)
    }

    init(model: AppModel) {
        self.model = model

        petPanel = PetPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        detailPanel = DetailPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        tipPanel = TipPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init()

        detailPanel.onCancel = { [weak self] in
            guard let self else { return false }
            switch self.model.panelRoute {
            case .moveToApplications: self.model.skipMoveToApplications()
            case .onboarding: self.model.finishOnboarding()
            case .connections: self.model.closeConnections()
            case .agents: return false
            }
            return true
        }
        configurePanels()
        rebuildContent()
        lastObservedMode = model.petMode
        installObservers()
        reevaluatePresentation()
        ensureAmbientPeekScheduled(initial: true)
    }

    deinit {
        idleAnimationTask?.cancel()
        ambientPeekTask?.cancel()
        transientTask?.cancel()
        presentationRecheckTask?.cancel()
        outsideClickController.stop()
        MainActor.assumeIsolated {
            statusAreaVisibilityMonitor.stop()
        }

        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }

        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func show() {
        guard movePetHome(animated: false) else {
            closeDetailPanelWindow()
            petPanel.orderOut(nil)
            return
        }

        // Let presentation policy decide whether startup should show Rex.
        // This avoids a visible flash when NotchLing launches into a
        // fullscreen/status-suppressed Space.
        reevaluatePresentation()
        updateDetailPanelVisibility()
    }

    private func configurePanels() {
        petPanel.backgroundColor = .clear
        petPanel.isOpaque = false
        petPanel.hasShadow = false
        petPanel.hidesOnDeactivate = false
        petPanel.isMovable = false
        petPanel.animationBehavior = .none
        petPanel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary
        ]
        petPanel.level = .statusBar
        petPanel.ignoresMouseEvents = false

        detailPanel.backgroundColor = .clear
        detailPanel.isOpaque = false
        detailPanel.hasShadow = true
        detailPanel.hidesOnDeactivate = false
        detailPanel.isMovable = false
        detailPanel.animationBehavior = .none
        detailPanel.isReleasedWhenClosed = false
        detailPanel.collectionBehavior = [
            .moveToActiveSpace,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle
        ]
        detailPanel.level = .statusBar
        detailPanel.ignoresMouseEvents = false

        tipPanel.backgroundColor = .clear
        tipPanel.isOpaque = false
        tipPanel.hasShadow = true
        tipPanel.hidesOnDeactivate = false
        tipPanel.isMovable = false
        tipPanel.animationBehavior = .none
        tipPanel.isReleasedWhenClosed = false
        tipPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        tipPanel.level = .statusBar
    }

    private func installObservers() {
        model.$isExpanded
            .removeDuplicates()
            .sink { [weak self] expanded in
                Task { @MainActor in
                    guard let self else { return }

                    if expanded {
                        self.cancelAmbientPeek()
                        self.idleAnimationTask?.cancel()
                        self.forcedDeveloperPeekGeneration += 1
                        self.isForcedDeveloperPeekActive = false
                        self.model.finishPeek()
                        self.cancelTransient()
                        self.showPetImmediately()
                        self.updateDetailPanelVisibility()
                    } else {
                        self.updateDetailPanelVisibility()
                        self.reevaluatePresentation()
                        self.ensureAmbientPeekScheduled(initial: true)
                    }
                }
            }
            .store(in: &cancellables)

        model.$panelRoute
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.model.isExpanded else { return }
                    self.resizeDetailPanel()
                    self.updateDetailPanelVisibility()
                }
            }
            .store(in: &cancellables)

        // The onboarding step, connection errors and event times change the
        // content height of the setup panels.
        let relayout: () -> Void = { [weak self] in
            Task { @MainActor in
                guard let self, self.model.isExpanded, self.model.panelRoute != .agents else { return }
                self.resizeDetailPanel()
            }
        }
        model.onboarding.objectWillChange.sink { relayout() }.store(in: &cancellables)
        model.connections.objectWillChange.sink { relayout() }.store(in: &cancellables)
        model.$lastEventAt.sink { _ in relayout() }.store(in: &cancellables)

        model.$isConnectionsTipVisible
            .removeDuplicates()
            .sink { [weak self] visible in
                Task { @MainActor in self?.setTipVisible(visible) }
            }
            .store(in: &cancellables)

        model.$isQuickNoteEditor
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.model.isExpanded else { return }
                    self.resizeDetailPanel()
                    self.updateDetailPanelVisibility()
                }
            }
            .store(in: &cancellables)

        model.$sessions
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.handleModelStateMutation()

                    if self.model.isExpanded && !self.model.isQuickNoteEditor {
                        self.resizeDetailPanel()
                    }
                }
            }
            .store(in: &cancellables)

        model.$isAttentionPresenting
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.handleModelStateMutation()
                }
            }
            .store(in: &cancellables)

        model.$attentionPulse
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }

                    let suppressedNow = self.statusAreaIsSuppressedOnNotchDisplay()
                    self.isStatusAreaSuppressed = suppressedNow

                    guard suppressedNow,
                          self.model.petMode == .needsYou else {
                        return
                    }

                    // A fresh alert starts or extends the brief Needs You beat.
                    self.showFullscreenAttentionTransient()
                }
            }
            .store(in: &cancellables)

        model.$devPeekNonce
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }

                    // Developer Peek buttons are explicit user actions.
                    // Keep them testable even when a fullscreen menu bar has
                    // auto-hidden behind the already-open developer panel.
                    self.playHideAndPeek(
                        variant: self.model.devPeekVariant,
                        force: true
                    )
                }
            }
            .store(in: &cancellables)

        let workspaceCenter = NSWorkspace.shared.notificationCenter

        workspaceObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.handleActiveSpaceChange()
                }
            }
        )

        workspaceObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor in
                    guard let self else { return }

                    if self.model.isExpanded,
                       let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                            as? NSRunningApplication,
                       app.bundleIdentifier != Bundle.main.bundleIdentifier {
                        self.dismissDetailPanelFromOutside()
                    }

                    self.handlePresentationEnvironmentChange()
                }
            }
        )

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.movePetHome(animated: false)
                if self.model.isExpanded {
                    self.resizeDetailPanel()
                }
                self.statusAreaVisibilityMonitor.checkNow()
                self.reevaluatePresentation()
            }
        }

        statusAreaVisibilityMonitor.start(
            screenProvider: { [weak self] in
                self?.notchScreen()
            },
            onChange: { [weak self] visible in
                guard let self else { return }
                let needsRecovery = visible && (!self.petPanel.isVisible || !self.petPanel.isOnActiveSpace)
                if visible == self.isStatusAreaSuppressed || needsRecovery {
                    self.reevaluatePresentation()
                }
            }
        )
    }

    private func rebuildContent() {
        petPanel.contentView = RexInteractionView(model: model)
        detailPanel.contentView = NSHostingView(
            rootView: AgentPanelRootView(model: model)
        )
        tipPanel.contentView = TipHostingView(model: model)
        resizeDetailPanel()
    }

    private func notchScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let left = screen.auxiliaryTopLeftArea,
                  let right = screen.auxiliaryTopRightArea else {
                return false
            }

            return screen.safeAreaInsets.top > 0 && right.minX > left.maxX
        }
    }

    private func geometry() -> ScreenNotchGeometry? {
        guard let screen = notchScreen(),
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else {
            return nil
        }

        return ScreenNotchGeometry(
            screenFrame: screen.frame,
            notchMinX: left.maxX,
            notchMaxX: right.minX,
            menuBarHeight: max(screen.safeAreaInsets.top, 24)
        )
    }

    private func petHomeFrame() -> NSRect? {
        guard let g = geometry() else { return nil }

        return NSRect(
            x: g.notchMaxX + petGapFromNotch,
            y: g.screenFrame.maxY - g.menuBarHeight,
            width: petSize.width,
            height: min(petSize.height, g.menuBarHeight)
        )
    }

    @discardableResult
    private func movePetHome(animated: Bool) -> Bool {
        guard let frame = petHomeFrame() else { return false }
        setPetFrame(frame, animated: animated, duration: 0.28)
        return true
    }

    private func setPetFrame(_ frame: NSRect, animated: Bool, duration: TimeInterval) {
        guard animated else {
            petPanel.setFrame(frame, display: true)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            petPanel.animator().setFrame(frame, display: true)
        }
    }

    private func detailPanelFrame() -> NSRect? {
        guard let screen = petPanel.screen ?? notchScreen() else { return nil }

        let size = detailPanelSize
        let gap: CGFloat = 7
        let horizontalMargin: CGFloat = 8

        let unclampedX = petPanel.frame.midX - size.width / 2
        let minX = screen.frame.minX + horizontalMargin
        let maxX = screen.frame.maxX - size.width - horizontalMargin
        let x = min(max(unclampedX, minX), maxX)
        let y = petPanel.frame.minY - size.height - gap

        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func resizeDetailPanel() {
        guard let frame = detailPanelFrame() else {
            closeDetailPanelWindow()
            return
        }

        detailPanel.setFrame(frame, display: detailPanel.isVisible)
    }

    private func updateDetailPanelVisibility() {
        guard model.isExpanded, petPanel.isVisible else {
            closeDetailPanelWindow()
            return
        }

        idleAnimationTask?.cancel()
        guard movePetHome(animated: false) else {
            model.isExpanded = false
            closeDetailPanelWindow()
            return
        }

        resizeDetailPanel()
        // Setup and Connections take key focus (Escape, Return) without
        // activating the app, so another app keeps its place in front.
        let wantsKey = model.isQuickNoteEditor || model.panelRoute != .agents
        detailPanel.allowsKeyWindow = wantsKey

        // Setup is not dismissed by clicking elsewhere.
        if model.panelRoute.isSetup {
            outsideClickController.stop()
        } else {
            outsideClickController.start(
                anchorWindow: petPanel,
                detailWindow: detailPanel,
                onDismiss: { [weak self] in
                    self?.dismissDetailPanelFromOutside()
                }
            )
        }

        if model.isQuickNoteEditor {
            NSApp.activate(ignoringOtherApps: true)
            detailPanel.makeKeyAndOrderFront(nil)
        } else if wantsKey {
            let dropping = !detailPanel.isVisible && model.panelRoute.isSetup
            if dropping { prepareDrop() }
            detailPanel.makeKeyAndOrderFront(nil)
            petPanel.orderFrontRegardless()
            if dropping { runDrop() }
        } else {
            if detailPanel.isKeyWindow {
                detailPanel.resignKey()
            }
            detailPanel.orderFrontRegardless()
            petPanel.orderFrontRegardless()
        }
    }

    /// The setup panel drops out of the notch instead of appearing in place.
    private func prepareDrop() {
        guard var frame = detailPanelFrame() else { return }
        frame.origin.y += 18
        detailPanel.alphaValue = 0
        detailPanel.setFrame(frame, display: false)
    }

    private func runDrop() {
        guard let target = detailPanelFrame() else {
            detailPanel.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.34
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            detailPanel.animator().setFrame(target, display: true)
            detailPanel.animator().alphaValue = 1
        }
    }

    private func closeDetailPanelWindow() {
        outsideClickController.stop()
        detailPanel.allowsKeyWindow = false

        if detailPanel.isVisible {
            detailPanel.orderOut(nil)
        }
        detailPanel.alphaValue = 1
    }

    private func setTipVisible(_ visible: Bool) {
        guard visible, petPanel.isVisible, !model.isExpanded, let screen = petPanel.screen ?? notchScreen() else {
            if tipPanel.isVisible { tipPanel.orderOut(nil) }
            return
        }
        let size = ConnectionsTipView.size
        let margin: CGFloat = 8
        let x = min(max(petPanel.frame.midX - size.width / 2, screen.frame.minX + margin),
                    screen.frame.maxX - size.width - margin)
        let frame = NSRect(x: x, y: petPanel.frame.minY - size.height - 6, width: size.width, height: size.height)
        tipPanel.setFrame(frame, display: true)
        tipPanel.alphaValue = 0
        tipPanel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            tipPanel.animator().alphaValue = 1
        }
    }

    private func dismissDetailPanelFromOutside() {
        // Setup ends only with Escape or one of its buttons.
        guard !model.panelRoute.isSetup else { return }
        guard model.isExpanded else {
            closeDetailPanelWindow()
            return
        }

        if model.isQuickNoteEditor {
            model.dismissQuickNotePreservingDraft()
        } else {
            model.isExpanded = false
        }
    }

    private func handleModelStateMutation() {
        let newMode = model.petMode

        // A new alert interrupts a peek, as does the model ending it
        // underneath the animation (demo replays). Other session changes leave
        // a pending or playing peek alone; the peek's own pose is not a mode
        // change either, so it never counts as one below.
        if newMode == .needsYou || (hasPeekBegun && !model.isPeekActive) {
            idleAnimationTask?.cancel()
            forcedDeveloperPeekGeneration += 1
            isForcedDeveloperPeekActive = false
            if model.isPeekActive { model.finishPeek() }
        }
        let changed = newMode != .hidePeek && newMode != lastObservedMode
        if newMode != .hidePeek { lastObservedMode = newMode }

        let suppressedNow = statusAreaIsSuppressedOnNotchDisplay()
        if suppressedNow != isStatusAreaSuppressed {
            isStatusAreaSuppressed = suppressedNow
        }

        if isStatusAreaSuppressed {
            cancelAmbientPeek()
            idleAnimationTask?.cancel()

            if model.isPeekActive && !isForcedDeveloperPeekActive {
                model.finishPeek()
            }

            guard changed else { return }

            // Fullscreen/status-area-suppressed presentation is intentionally
            // quiet. Working, Resting and Peek never surface Rex. Entering
            // Needs You is handled by attentionPulse for each fresh alert.
            if newMode != .needsYou {
                cancelTransient()
                if !model.isExpanded {
                    hidePet(animated: true)
                }
            }
        } else {
            // Session churn, including Working <-> Resting, must not snap the
            // pet home mid-peek or drop an alert transient. Needs You has
            // already cancelled the peek above.
            if !isPeekInFlight || (changed && newMode == .needsYou) {
                cancelTransient()
                showPetImmediately()
            }

            if changed && (newMode == .resting || newMode == .working) {
                cancelAmbientPeek()
            }

            if newMode == .resting || newMode == .working {
                ensureAmbientPeekScheduled(initial: true)
            } else {
                cancelAmbientPeek()
            }
        }
    }

    private func handleActiveSpaceChange() {
        // A real Space change is still a hard boundary, even for a forced
        // developer Peek.
        idleAnimationTask?.cancel()
        forcedDeveloperPeekGeneration += 1
        isForcedDeveloperPeekActive = false
        if model.isPeekActive {
            model.finishPeek()
            movePetHome(animated: false)
        }

        // Space changes are a dismissal boundary for the detail panel. The
        // presentation rechecks below only control Rex visibility; they never
        // open the detail panel.
        if model.panelRoute.isSetup {
            // Setup follows the user to the new Space instead of closing.
            updateDetailPanelVisibility()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let self, self.model.panelRoute.isSetup else { return }
                self.updateDetailPanelVisibility()
            }
        } else if model.isExpanded {
            dismissDetailPanelFromOutside()
        } else {
            closeDetailPanelWindow()
        }

        handlePresentationEnvironmentChange()
    }

    private func handlePresentationEnvironmentChange() {
        reevaluatePresentation()

        presentationRecheckTask?.cancel()
        presentationRecheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            self.reevaluatePresentation()

            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            self.reevaluatePresentation()
        }
    }

    private func reevaluatePresentation() {
        guard notchScreen() != nil else {
            cancelAmbientPeek()
            idleAnimationTask?.cancel()
            cancelTransient()

            if model.isPeekActive && !isForcedDeveloperPeekActive {
                model.finishPeek()
            }

            if model.isExpanded {
                model.isExpanded = false
            }

            closeDetailPanelWindow()
            hidePet(animated: false)
            return
        }

        let suppressedNow = statusAreaIsSuppressedOnNotchDisplay()
        let changed = suppressedNow != isStatusAreaSuppressed
        isStatusAreaSuppressed = suppressedNow

        if isStatusAreaSuppressed {
            cancelAmbientPeek()
            idleAnimationTask?.cancel()

            if model.isPeekActive {
                model.finishPeek()
            }

            // Explicit user interaction outranks passive status-bar mirroring.
            // Once the user opens Rex's panel, macOS may auto-hide the menu bar
            // again as the pointer moves downward; that must not dismiss the
            // panel they just opened. A real Space change is still a hard
            // dismissal boundary in handleActiveSpaceChange().
            if model.isExpanded {
                cancelTransient()
                ensurePetVisible()
            }

            guard RexPresentationPolicy.shouldHidePassiveRex(
                statusAreaSuppressed: true,
                panelExpanded: model.isExpanded,
                transientAlertActive: transientTask != nil
            ) else {
                return
            }

            hidePet(animated: changed)
        } else {
            cancelTransient()
            ensurePetVisible()
            ensureAmbientPeekScheduled(initial: true)
        }
    }

    private func cancelTransient() {
        transientTask?.cancel()
        transientTask = nil
    }

    private func cancelAmbientPeek() {
        ambientPeekTask?.cancel()
        ambientPeekTask = nil
    }

    private func ensureAmbientPeekScheduled(initial: Bool) {
        // A playing peek ends by scheduling its own cooldown; scheduling here
        // would bypass it.
        guard ambientPeekTask == nil,
              !isPeekInFlight,
              [.resting, .working].contains(model.petMode),
              !model.isExpanded,
              !isStatusAreaSuppressed,
              petPanel.isVisible else {
            return
        }

        let delaySeconds: Double
        if model.petMode == .working {
            delaySeconds = initial ? Double.random(in: 60...100) : Double.random(in: 180...300)
        } else {
            delaySeconds = initial ? Double.random(in: 90...150) : Double.random(in: 240...480)
        }

        ambientPeekTask = Task { @MainActor [weak self] in
            let nanoseconds = UInt64(delaySeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)

            guard let self, !Task.isCancelled else { return }
            self.ambientPeekTask = nil

            guard [.resting, .working].contains(self.model.petMode),
                  !self.model.isExpanded,
                  !self.isStatusAreaSuppressed,
                  self.petPanel.isVisible else {
                self.ensureAmbientPeekScheduled(initial: true)
                return
            }

            let variant = self.nextAmbientPeekVariant
            self.nextAmbientPeekVariant = variant == .one ? .two : .one
            self.playHideAndPeek(variant: variant, force: false)
        }
    }

    private func ensurePetVisible() {
        guard notchScreen() != nil else {
            hidePet(animated: false)
            return
        }

        if !visibilityTransition.wantsVisible {
            visibilityTransition.request(visible: true)
            petPanel.alphaValue = 1
        }
        guard !petPanel.isVisible || !petPanel.isOnActiveSpace else { return }
        guard movePetHome(animated: false) else { return }

        petPanel.alphaValue = 1
        petPanel.orderFrontRegardless()
    }

    private func showPetImmediately() {
        guard movePetHome(animated: false) else {
            closeDetailPanelWindow()
            hidePet(animated: false)
            return
        }

        visibilityTransition.request(visible: true)
        petPanel.alphaValue = 1
        petPanel.orderFrontRegardless()
    }

    private func hidePet(animated: Bool) {
        // Repeated visibility polls must not restart an in-flight fade.
        guard visibilityTransition.wantsVisible || !animated else { return }
        let token = visibilityTransition.request(visible: false)
        guard petPanel.isVisible else { return }

        guard animated else {
            petPanel.orderOut(nil)
            petPanel.alphaValue = 1
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            petPanel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard self.visibilityTransition.mayFinishHide(token) else {
                    if self.visibilityTransition.wantsVisible { self.petPanel.alphaValue = 1 }
                    return
                }
                self.petPanel.orderOut(nil)
                self.petPanel.alphaValue = 1
            }
        }
    }

    private func showFullscreenAttentionTransient() {
        guard isStatusAreaSuppressed,
              model.petMode == .needsYou else {
            return
        }

        cancelTransient()
        // An open panel owns presentation, including subsequent alerts.
        if model.isExpanded {
            showPetImmediately()
            return
        }
        guard movePetHome(animated: false) else { return }

        visibilityTransition.request(visible: true)
        petPanel.alphaValue = 0
        petPanel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            petPanel.animator().alphaValue = 1
        }

        transientTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_700_000_000)

            guard let self,
                  !Task.isCancelled,
                  self.isStatusAreaSuppressed,
                  !self.model.isExpanded else {
                return
            }

            self.hidePet(animated: true)
            self.transientTask = nil
        }
    }

    private func statusAreaIsSuppressedOnNotchDisplay() -> Bool {
        guard let screen = notchScreen() else { return true }
        return !statusAreaVisibilityMonitor.statusItemsAreVisible(on: screen)
    }

    private func playHideAndPeek(
        variant: PeekAnimationVariant = .one,
        force: Bool = false
    ) {
        guard (force || [.resting, .working].contains(model.petMode)),
              !model.isExpanded || force,
              petPanel.isVisible else { return }

        peekAnimationGeneration += 1
        let peekGeneration = peekAnimationGeneration
        idleAnimationTask?.cancel()
        isPeekInFlight = true
        hasPeekBegun = false

        let developerGeneration: Int?
        if force {
            forcedDeveloperPeekGeneration += 1
            developerGeneration = forcedDeveloperPeekGeneration
            isForcedDeveloperPeekActive = true
        } else {
            developerGeneration = nil
        }

        idleAnimationTask = Task { @MainActor [weak self] in
            guard let self else { return }

            defer {
                if peekGeneration == self.peekAnimationGeneration {
                    self.isPeekInFlight = false
                    self.hasPeekBegun = false
                    if Task.isCancelled {
                        if self.model.isPeekActive { self.model.finishPeek() }
                        self.movePetHome(animated: false)
                        self.ensureAmbientPeekScheduled(initial: true)
                    }
                }

                if let developerGeneration,
                   developerGeneration == self.forcedDeveloperPeekGeneration {
                    self.isForcedDeveloperPeekActive = false
                }
            }

            guard let g = self.geometry(),
                  let base = self.petHomeFrame() else {
                return
            }

            let peek = NSRect(
                x: g.notchMaxX - self.petSize.width + 29,
                y: base.origin.y,
                width: base.width,
                height: base.height
            )

            let hidden = NSRect(
                x: g.notchMaxX - base.width - 3,
                y: base.origin.y,
                width: base.width,
                height: base.height
            )

            // The real notch masks both pose swaps. Every species uses the
            // same registered edge, entrance, action timing and retreat.
            self.setPetFrame(hidden, animated: true, duration: 0.28)
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self.model.beginPeek()
            self.hasPeekBegun = true
            self.setPetFrame(peek, animated: true, duration: 0.32)
            try? await Task.sleep(nanoseconds: 340_000_000)
            guard !Task.isCancelled else { return }

            switch variant {
            case .one:
                // Peek 1: same stare timing as Peek 2, but Rex waves instead
                // of blinking. Two quick paw beats read better at menu-bar size.
                try? await Task.sleep(nanoseconds: 1_650_000_000)
                guard !Task.isCancelled else { return }

                for _ in 0..<2 {
                    self.model.setPeekWaving(true)
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    guard !Task.isCancelled else { return }
                    self.model.setPeekWaving(false)
                    try? await Task.sleep(nanoseconds: 170_000_000)
                    guard !Task.isCancelled else { return }
                }

                try? await Task.sleep(nanoseconds: 300_000_000)

            case .two:
                // Product-default Peek: longer eye contact, one quick blink,
                // then a final look while Rex remains in the peek pose.
                try? await Task.sleep(nanoseconds: 1_650_000_000)
                guard !Task.isCancelled else { return }

                self.model.setPeekBlinking(true)
                try? await Task.sleep(nanoseconds: 140_000_000)
                guard !Task.isCancelled else { return }
                self.model.setPeekBlinking(false)
                guard !Task.isCancelled else { return }

                try? await Task.sleep(nanoseconds: 500_000_000)
            }

            guard !Task.isCancelled else { return }

            // Hold eye contact, hide, then return to the current agent state.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self.setPetFrame(hidden, animated: true, duration: 0.26)
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled else { return }
            self.model.finishPeek()
            self.movePetHome(animated: true)

            // Both ambient variants use a randomized cooldown.
            self.isPeekInFlight = false
            self.hasPeekBegun = false
            self.ensureAmbientPeekScheduled(initial: false)
        }
    }
}
