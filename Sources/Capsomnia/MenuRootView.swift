import AppKit

/// Root view of the menu popover, responsible for the ⌘O / ⌘Q shortcuts the footer
/// advertises.
///
/// The original menu was an `NSMenu`, whose items carried real key equivalents. When it
/// was rebuilt as a SwiftUI popover the shortcut *labels* came across but the key
/// equivalents did not, so the panel showed ⌘O and ⌘Q while nothing handled them. The
/// popover window is made key on open, so answering `performKeyEquivalent` here restores
/// them without a global event monitor.
final class MenuRootView: NSView {
    var onOpenCapsomnia: () -> Void = {}
    var onQuit: () -> Void = {}

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command else {
            return super.performKeyEquivalent(with: event)
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "o":
            onOpenCapsomnia()
            return true
        case "q":
            onQuit()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}
