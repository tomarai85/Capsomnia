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

    /// Opacity of the inner working panel. Near-solid on purpose.
    ///
    /// Glass shows whatever is behind it, so a translucent surface reads dark over a dark desktop
    /// and bright over a white page — measured, a 0.38 full-surface tint moved the panel's inner
    /// luminance from 3 over black to 177 over white, which is the bright page bleeding through the
    /// top of the popover (Tom, 2026-07-21). The working surface must NOT do that: it is where text
    /// and controls live and it has to stay the app's near-black regardless of what is behind the
    /// window. At 0.98 the same black/white swing is 9.7 vs 18.1 — a delta of 8 instead of 174.
    private static let panelOpacity: CGFloat = 0.98

    /// Width of the exposed glass rim around the working panel. This margin is where real Liquid
    /// Glass still shows — its lensing, edge highlight and shadow — while the inset panel it frames
    /// carries the content. Glass as the frame, solid panel as the surface (Codex review, 2026-07-21).
    private static let rimInset: CGFloat = 8

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
            // Glass frames a solid panel; it is not the working surface itself.
            //
            // A single translucent tint over the whole surface cannot win: measured over black vs
            // white backgrounds it swings 3 -> 177 in inner luminance, which is the bright page
            // behind the window bleeding through the sparse top of the popover. Insetting a
            // near-opaque panel and letting glass show only in the rim brings that swing to 9.7 ->
            // 18.1, so the surface you read and click on stays the app's near-black over ANY
            // background, while the rim still refracts, highlights and shadows as real Liquid Glass.
            //
            // Pinned with constraints, not a frame: the popover's content is an NSHostingView whose
            // bounds are zero at wrap time, so a frame-sized child would start collapsed.
            // Only the rounded popover shows a glass rim; a titled window (cornerRadius 0) already
            // has its own frame as the boundary, so an inner margin there would just read as a bug.
            let inset = cornerRadius > 0 ? Self.rimInset : 0
            let panel = NSView()
            panel.translatesAutoresizingMaskIntoConstraints = false
            panel.wantsLayer = true
            panel.layer?.backgroundColor = Brand.bg.withAlphaComponent(Self.panelOpacity).cgColor
            // Concentric with the outer glass corner, minus the rim, so the rounded panel nests
            // inside the rounded glass instead of poking square corners into it.
            panel.layer?.cornerRadius = max(0, cornerRadius - inset)
            content.addSubview(panel, positioned: .below, relativeTo: nil)
            NSLayoutConstraint.activate([
                panel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset),
                panel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset),
                panel.topAnchor.constraint(equalTo: content.topAnchor, constant: inset),
                panel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -inset)
            ])
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
