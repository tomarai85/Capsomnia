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
    /// Callers use this to skip the dark tint they paint over legacy vibrancy. The glass
    /// path is not untinted — it carries its own tint via `NSGlassEffectView.tintColor`
    /// (see `wrap`) — it just must not have a second tint view stacked on top of it.
    static var usesLiquidGlass: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    /// How much of the app's own dark surface is carried into the glass.
    ///
    /// Liquid Glass adapts to whatever is behind the window. This app is near-black with a
    /// single lime accent, so with no tint at all its panels take their colour entirely from
    /// the desktop behind them and the UI stops feeling like the app. A tint restores that
    /// identity and buys contrast for the text sitting on it.
    ///
    /// Tuning: raise toward 1 for a more solid panel, lower toward 0 for more see-through.
    /// This is the one number to change; everything else about the backdrop is Apple's.
    private static let tintStrength: CGFloat = 0.38

    /// Wraps `content` in glass and returns the view to install as the window or popover
    /// content view.
    ///
    /// Pass `cornerRadius: 0` when the host (an `NSPopover`, or a titled window) already
    /// masks its content — rounding here as well insets the glass and reveals the host's
    /// own background in the corners.
    static func wrap(_ content: NSView, cornerRadius: CGFloat = 0) -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            // `.regular`, not `.clear`. Apple frames the regular variant as legible regardless
            // of what is behind it, and reserves clear for surfaces meant to show content
            // through — media, mostly. Both surfaces this wraps (the menu popover and the
            // settings window) are text and controls someone is reading and clicking, so they
            // are exactly the case regular exists for. Shipping clear made both of them hard
            // to work in (Tom, 2026-07-20).
            glass.style = .regular
            // The tint rides INSIDE the content, not on `glass.tintColor`.
            //
            // Measured on macOS 26.5 with a standalone harness: with the tint set on the glass, the
            // panel's mean luminance jumps from 17.2 to 61.6 the moment the window stops being key
            // — the system drops the glass's own tint when inactive, so the surface visibly pales
            // when you click anything else (Tom, 2026-07-20: "the look changes a lot"). Moving the
            // same tint into the content the glass composites cuts that shift from +44 to +17 while
            // leaving the active appearance where it was (15.6 vs 17.2, indistinguishable).
            //
            // The residual shift is Liquid Glass itself: NSGlassEffectView exposes only
            // contentView / cornerRadius / tintColor / style, with no equivalent of the legacy
            // `NSVisualEffectView.state = .active` that pins appearance across activation. Pinning
            // it to vibrancy instead measured a perfect 0.00 shift, but stops being real glass.
            let scrim = NSView(frame: content.bounds)
            scrim.autoresizingMask = [.width, .height]
            scrim.wantsLayer = true
            scrim.layer?.backgroundColor = Brand.bg.withAlphaComponent(Self.tintStrength).cgColor
            content.addSubview(scrim, positioned: .below, relativeTo: nil)
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
