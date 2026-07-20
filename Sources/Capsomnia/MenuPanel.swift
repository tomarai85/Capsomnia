import AppKit

/// The status menu's window. `NSPopover` re-places itself whenever its content size
/// changes and, with several displays attached, re-places onto the wrong screen (the
/// menu teleported to another display's corner the moment a row changed the height).
/// A panel is never re-placed by AppKit: the presenter computes the frame, and any
/// resize keeps the top edge pinned under the status item. Root fix, not a workaround.
final class MenuPanel: NSPanel {
    /// Borderless panels refuse key status by default; the inline battery-floor text
    /// field needs it to accept typing (the app is an accessory, so taking key here
    /// does not activate the app or steal focus from the frontmost app's windows —
    /// `.nonactivatingPanel` guarantees that).
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var onEscape: () -> Void = {}

    override func cancelOperation(_ sender: Any?) {
        onEscape()
    }

    /// SwiftUI never resigns an inline TextField's focus when the user clicks some
    /// other, non-focusable part of the menu — the field editor keeps first-responder
    /// forever. Route every click through here: anything outside the field being
    /// edited ends editing (which commits the value via the focus-loss handler).
    /// The field editor is window-owned and clicks hit the NSTextField it serves,
    /// so the field itself (the editor's client) is what the hit is tested against.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown,
           let editor = firstResponder as? NSTextView, editor.isFieldEditor,
           let content = contentView {
            let field = editor.delegate as? NSView ?? editor
            let point = content.superview?.convert(event.locationInWindow, from: nil)
                ?? event.locationInWindow
            let hit = content.superview?.hitTest(point)
            let insideField = hit === field || hit?.isDescendant(of: field) == true
                || hit === editor || hit?.isDescendant(of: editor) == true
            if !insideField {
                makeFirstResponder(nil)
            }
        }
        super.sendEvent(event)
    }
}

/// Owns the panel's lifecycle: placement under the status item, outside-click and
/// Esc dismissal, and in-place resizes when the SwiftUI content changes height.
@MainActor
final class MenuPanelPresenter {
    private let panel: MenuPanel
    private let controller: StatusPopoverController
    private weak var statusButton: NSStatusBarButton?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private let gapBelowMenuBar: CGFloat = 5
    private let screenInset: CGFloat = 8

    var isShown: Bool { panel.isVisible }

    init(controller: StatusPopoverController) {
        self.controller = controller
        let panel = MenuPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        // moveToActiveSpace (not canJoinAllSpaces): a status menu belongs to the Space
        // it was opened on; joining all Spaces would leave it floating over unrelated
        // ones. transient keeps it out of Mission Control. (Codex-reviewed choice.)
        panel.collectionBehavior = [.moveToActiveSpace, .transient, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.contentViewController = controller
        self.panel = panel
        panel.onEscape = { [weak self] in self?.close() }
        controller.onContentSizeChanged = { [weak self] in self?.applyContentSize() }
    }

    func show(under button: NSStatusBarButton) {
        statusButton = button
        guard let buttonWindow = button.window else { return }

        controller.view.layoutSubtreeIfNeeded()
        var size = controller.preferredContentSize
        if size.width <= 0 || size.height <= 0 { size = controller.view.fittingSize }

        // The button's window is on whichever display's menu bar was clicked, so the
        // panel always opens on that display — the multi-screen case NSPopover got wrong.
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var x = buttonRect.midX - size.width / 2
        // The clamp screen must be the one actually holding the clicked menu bar —
        // falling back to NSScreen.main here would re-create the wrong-display bug.
        let screen = buttonWindow.screen
            ?? NSScreen.screens.first { $0.frame.contains(CGPoint(x: buttonRect.midX, y: buttonRect.midY - 1)) }
        if let visible = screen?.visibleFrame {
            x = min(max(x, visible.minX + screenInset), visible.maxX - size.width - screenInset)
        }
        let y = buttonRect.minY - gapBelowMenuBar - size.height
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: false)

        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        controller.playOpenAnimation()
        installMonitors()
    }

    func close() {
        removeMonitors()
        guard panel.isVisible else { return }
        // Ends any in-progress text-field edit so its focus-loss commit runs before
        // the window goes away.
        panel.makeFirstResponder(nil)
        panel.orderOut(nil)
    }

    /// Resize in place, top edge pinned, so growth extends downward from the menu bar.
    private func applyContentSize() {
        guard panel.isVisible else { return }
        let size = controller.preferredContentSize
        guard size.width > 0, size.height > 0 else { return }
        var frame = panel.frame
        let top = frame.maxY
        frame.size = size
        frame.origin.y = top - size.height
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    private func installMonitors() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.close() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            // Clicks inside the panel are the menu's own; clicks on the status item's
            // window are the toggle button's — closing here too would re-open it.
            if event.window !== self.panel, event.window !== self.statusButton?.window {
                self.close()
            }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.close() }
        }
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        globalMonitor = nil
        localMonitor = nil
        resignObserver = nil
    }
}
