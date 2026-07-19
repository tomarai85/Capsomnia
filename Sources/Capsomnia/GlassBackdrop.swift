import AppKit

/// Builds the frosted backdrop that both the menu popover and the settings window sit on.
///
/// macOS 26 replaced the old vibrancy materials with Liquid Glass. On 26 the legacy
/// `NSVisualEffectView` materials render close enough to each other that swapping between
/// them (`.hudWindow` -> `.underWindowBackground`) and lightening the tints painted over
/// them produced no visible change — the ceiling was the API generation, not the values.
/// `NSGlassEffectView` is the real glass on that OS; the vibrancy path stays for macOS
/// 14 through 25, which is what the package still deploys to.
enum GlassBackdrop {
    /// True when the real Liquid Glass path is in use.
    ///
    /// Callers use this to skip the dark tint they paint over legacy vibrancy: that tint
    /// exists to give the old material some depth, and over real glass it would just
    /// cancel out the transparency the glass buys.
    static var usesLiquidGlass: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    /// Wraps `content` in the strongest glass the running OS supports and returns the view
    /// to install as the window or popover content view.
    ///
    /// Pass `cornerRadius: 0` when the host (an `NSPopover`, or a titled window) already
    /// masks its content — rounding here as well insets the glass and reveals the host's
    /// own background in the corners.
    static func wrap(_ content: NSView, cornerRadius: CGFloat = 0) -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            // .clear is the more transparent of the two styles; .regular reads closer to
            // the old frosted panel.
            glass.style = .clear
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            glass.wantsLayer = true
            return glass
        }

        let effect = NSVisualEffectView()
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true

        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])
        return effect
    }
}
