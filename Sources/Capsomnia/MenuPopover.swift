import AppKit
import SwiftUI

// MARK: - Bridge model

/// Snapshot of the labels the glass menu renders, resolved from AppStrings so the
/// SwiftUI view stays free of localization lookups.
struct MenuStrings {
    var appName: String
    var keepAwakeHeading: String
    var modeOff: String
    var modeCapsLock: String
    var modeAuto: String
    var batteryFloorMenu: String
    var showMenuBarIcon: String
    var language: String
    var openCapsomnia: String
    var quit: String
    var statusHeld: String
    var batteryFloorHeldFormat: String
    var batteryFloorOverride: String
    var batteryFloorOverrideActive: String
    var batteryFloorOverrideSubtitleFormat: String
}

/// Observable state the glass menu binds to. The app delegate owns this, refreshes it
/// from `Preferences` before the popover opens, and wires the closures to its setters —
/// so the SwiftUI view never touches app state directly.
@MainActor
final class MenuModel: ObservableObject {
    @Published var mode: KeepAwakeMode = .capsLock
    @Published var floorEnabled: Bool = true
    @Published var floorPercent: Int = 15
    @Published var showMenuBarIcon: Bool = true
    @Published var language: AppLanguage = .english
    @Published var keepingAwake: Bool = false
    /// The battery floor is holding keep-awake off even though the mode wants it on.
    @Published var heldByFloor: Bool = false
    /// The user consented to run below the floor.
    @Published var overridingFloor: Bool = false
    /// The helper or its verification read is currently failing. The menu bar shows the
    /// error dot for this; the menu must not keep asserting a confirmed state beside it.
    @Published var helperFailing: Bool = false
    @Published var batteryPercent: Int?
    @Published var floorRecoverPercent: Int = 20
    @Published var floorCriticalPercent: Int = BatteryFloorPolicy.criticalPercent
    @Published var strings: MenuStrings

    var onSelectMode: (KeepAwakeMode) -> Void = { _ in }
    var onSetFloorEnabled: (Bool) -> Void = { _ in }
    var onSetFloorPercent: (Int) -> Void = { _ in }
    var onSetFloorOverride: (Bool) -> Void = { _ in }
    var onSetShowMenuBarIcon: (Bool) -> Void = { _ in }
    var onSelectLanguage: (AppLanguage) -> Void = { _ in }
    var onOpenCapsomnia: () -> Void = {}
    var onQuit: () -> Void = {}

    /// Keeping the Mac awake AND the last apply was confirmed against the system.
    var confirmedAwake: Bool { keepingAwake && !helperFailing }

    init(strings: MenuStrings) {
        self.strings = strings
    }
}

// MARK: - Palette bridge

private enum Palette {
    static let text = Color(nsColor: Brand.text)
    static let textDim = Color(nsColor: Brand.textDim)
    static let textFaint = Color(nsColor: Brand.textFaint)
    static let led = Color(nsColor: Brand.led)
    static let ledBright = Color(nsColor: Brand.ledBright)
    static let surface = Color(nsColor: Brand.surface2)
    static let border = Color(nsColor: Brand.border)
    static let bg = Color(nsColor: Brand.bg)
}

private let menuWidth: CGFloat = 300

// MARK: - Root view

/// Carries the laid-out height of the menu up to the hosting controller. Expanding a
/// row grows the content while the popover is already on screen, and `NSPopover` only
/// resizes when `preferredContentSize` changes — without this the extra rows are
/// squeezed into the collapsed frame and every row shifts.
struct MenuContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct CapsomniaMenuView: View {
    @ObservedObject var model: MenuModel
    /// Paints the brand wash behind the menu. Only wanted over legacy vibrancy — real
    /// Liquid Glass supplies its own depth, and the wash would flatten it.
    var tinted: Bool = true
    var onContentHeightChange: (CGFloat) -> Void = { _ in }
    @State private var customFloorText = ""
    @State private var editingCustomFloor = false
    @FocusState private var customFieldFocused: Bool

    /// 30 used to sit here; it is reachable by typing, and the slot buys a free-entry field.
    private let floorOptions = [10, 15, 20, 25]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            divider
            section(model.strings.keepAwakeHeading.uppercased()) {
                modeRow(.off, title: model.strings.modeOff)
                modeRow(.capsLock, title: model.strings.modeCapsLock)
                modeRow(.auto, title: model.strings.modeAuto)
            }
            divider
            batteryFloor
            divider
            toggleRow
            languageRow
            divider
            footer
        }
        .frame(width: menuWidth)
        .padding(.vertical, 8)
        .background {
            if tinted {
                // Barely-there brand wash so the frosted vibrancy dominates and the
                // desktop still shows through — real glass, not a dark panel.
                LinearGradient(
                    colors: [Palette.bg.opacity(0.08), Palette.bg.opacity(0.02)],
                    startPoint: .top, endPoint: .bottom
                )
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: MenuContentHeightKey.self, value: proxy.size.height)
            }
        }
        .onPreferenceChange(MenuContentHeightKey.self) { height in
            onContentHeightChange(height)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 11) {
            LEDDot(on: model.confirmedAwake, held: model.heldByFloor)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.strings.appName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(model.heldByFloor ? Palette.text.opacity(0.85) : Palette.textDim)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            statusPill
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    /// Carries the reason, not just the setting. When the floor is holding keep-awake
    /// off, the mode alone is a lie by omission: the row still reads "Auto" while
    /// nothing is being kept awake, which is how this looked like a malfunction.
    /// The line is single-height in every state so the panel never changes size.
    private var subtitle: String {
        if model.heldByFloor {
            return TextTemplate.fill(model.strings.batteryFloorHeldFormat, [
                "battery": model.batteryPercent ?? 0,
                "recover": model.floorRecoverPercent
            ])
        }
        if model.overridingFloor {
            return TextTemplate.fill(model.strings.batteryFloorOverrideSubtitleFormat, [
                "battery": model.batteryPercent ?? 0,
                "critical": model.floorCriticalPercent
            ])
        }
        return "\(model.strings.keepAwakeHeading) · \(currentModeLabel)"
    }

    private var currentModeLabel: String {
        switch model.mode {
        case .off: return model.strings.modeOff
        case .capsLock: return model.strings.modeCapsLock
        case .auto: return model.strings.modeAuto
        }
    }

    /// Three states, not two: OFF because you asked for it and OFF because the battery
    /// floor stepped in are different facts. Held reads as an outlined pill — armed, not
    /// running — so it is distinguishable from plain OFF at a glance.
    private var statusPill: some View {
        // `confirmedAwake`, not `keepingAwake`: the applied state is recorded optimistically
        // before the confirming read, so while the helper is failing this would otherwise
        // show a confident green ON next to the menu bar's red error dot.
        let awake = model.confirmedAwake
        let title = model.heldByFloor ? model.strings.statusHeld : (awake ? "ON" : "OFF")
        let accented = awake || model.heldByFloor
        return Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(awake ? Palette.led : (model.heldByFloor ? Palette.led.opacity(0.75) : Palette.textDim))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(awake ? Palette.led.opacity(0.14) : Palette.surface.opacity(0.6))
            )
            .overlay(
                Capsule().stroke(accented ? Palette.led.opacity(0.35) : Palette.border, lineWidth: 1)
            )
    }

    // MARK: Keep-awake modes

    private func modeRow(_ mode: KeepAwakeMode, title: String) -> some View {
        let selected = model.mode == mode
        return HoverRow {
            model.onSelectMode(mode)
        } content: { hovering in
            HStack(spacing: 11) {
                ZStack {
                    Circle()
                        .stroke(selected ? Palette.led : Palette.border, lineWidth: 1.5)
                        .frame(width: 15, height: 15)
                    if selected {
                        Circle().fill(Palette.led).frame(width: 8, height: 8)
                    }
                }
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Palette.text : Palette.text.opacity(0.92))
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(rowBackground(hovering: hovering, selected: selected))
            .padding(.horizontal, 8)
        }
    }

    // MARK: Battery floor

    /// The options are always on show rather than hidden behind a disclosure. Expanding a
    /// row changes the popover's height, and `NSPopover` re-places itself when it resizes
    /// — with several displays attached it lands on the wrong screen. A menu that never
    /// changes height cannot be re-placed at all, and it costs one click less.
    private var batteryFloor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "battery.50")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.textDim)
                    .frame(width: 16)
                Text(model.strings.batteryFloorMenu)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.text)
                Spacer(minLength: 4)
                floorTrailing
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .padding(.horizontal, 8)

            HStack(spacing: 6) {
                floorPill(title: model.strings.modeOff, active: !model.floorEnabled) {
                    model.onSetFloorEnabled(false)
                }
                ForEach(floorOptions, id: \.self) { pct in
                    floorPill(title: "\(pct)", active: model.floorEnabled && model.floorPercent == pct) {
                        model.onSetFloorEnabled(true)
                        model.onSetFloorPercent(pct)
                    }
                }
                customFloorField
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 6)
        }
    }

    /// The floor row's right-hand side. At rest it shows the floor in effect; while the
    /// floor is holding keep-awake off AND the override could actually take effect, it
    /// becomes the way out. Below the critical charge the floor refuses the override, so
    /// the control is not offered there — a button that silently does nothing is the
    /// exact failure this feature exists to remove, and it would have appeared on every
    /// hold at a floor of 10% or lower.
    ///
    /// The states swap in place inside a fixed height, so the panel does not resize under
    /// the cursor when the floor engages while the menu is open.
    @ViewBuilder
    private var floorTrailing: some View {
        Group {
            if model.overridingFloor {
                overrideChip(title: model.strings.batteryFloorOverrideActive, active: true) {
                    model.onSetFloorOverride(false)
                }
            } else if model.heldByFloor, overrideIsOffered {
                overrideChip(title: model.strings.batteryFloorOverride, active: false) {
                    model.onSetFloorOverride(true)
                }
            } else {
                Text(model.floorEnabled ? "\(model.floorPercent)%" : model.strings.modeOff)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(model.floorEnabled ? Palette.led : Palette.textDim)
            }
        }
        .frame(height: 22)
    }

    private var overrideIsOffered: Bool {
        BatteryFloorPolicy.overrideCanApply(
            percent: model.batteryPercent,
            criticalPercent: model.floorCriticalPercent
        )
    }

    private func overrideChip(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        HoverRow(action: action) { hovering in
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(active ? Palette.bg : Palette.text)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(active ? Palette.led : (hovering ? Palette.surface : Palette.surface.opacity(0.6)))
                )
                .overlay(Capsule().stroke(active ? .clear : Palette.led.opacity(0.45), lineWidth: 1))
        }
    }

    /// True when the active floor is a value the preset pills cannot express, so the
    /// typed field is the one that should read as selected.
    private var usingCustomFloor: Bool {
        model.floorEnabled && !floorOptions.contains(model.floorPercent)
    }

    /// Free-entry floor slot. At rest it is a pill like its neighbors (showing the
    /// custom value when one is active, "···" otherwise); clicking it switches to a
    /// text field — entry mode is something the user asks for, never the default.
    /// Commits on Return or when focus leaves, so a half-typed number never lands:
    /// "3" on its way to "35" would otherwise clamp to the 5% minimum.
    @ViewBuilder
    private var customFloorField: some View {
        if editingCustomFloor {
            TextField("", text: $customFloorText)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Palette.text)
                .tint(Palette.led)
                .focused($customFieldFocused)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.10)))
                .overlay(Capsule().strokeBorder(Palette.led.opacity(0.8), lineWidth: 1))
                .onAppear { customFieldFocused = true }
                .onSubmit { commitCustomFloor() }
                .onChange(of: customFieldFocused) { _, focused in
                    if !focused { commitCustomFloor() }
                }
        } else {
            floorPill(
                title: usingCustomFloor ? "\(model.floorPercent)" : "···",
                active: usingCustomFloor
            ) {
                customFloorText = usingCustomFloor ? "\(model.floorPercent)" : ""
                editingCustomFloor = true
            }
        }
    }

    private func commitCustomFloor() {
        // Return-key commits arrive twice: onSubmit runs this, whose defer drops the
        // focus, and the focus-loss onChange runs it again. The flag makes it once.
        guard editingCustomFloor else { return }
        defer {
            editingCustomFloor = false
            customFieldFocused = false
        }
        // Not a number: fall back to whatever is actually in effect, silently.
        guard let percent = BatteryFloorInput.parse(customFloorText) else { return }
        // onSetFloorPercent enables the floor itself (see makeMenuModel).
        model.onSetFloorPercent(percent)
    }

    private func floorPill(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        HoverRow(action: action) { hovering in
            Text(title)
                .font(.system(size: 11.5, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Palette.bg : Palette.textDim)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(active ? Palette.led : (hovering ? Palette.surface : Palette.surface.opacity(0.5)))
                )
        }
    }

    // MARK: Toggle + language

    private var toggleRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "menubar.arrow.up.rectangle")
                .font(.system(size: 12))
                .foregroundStyle(Palette.textDim)
                .frame(width: 16)
            Text(model.strings.showMenuBarIcon)
                .font(.system(size: 13))
                .foregroundStyle(Palette.text)
            Spacer(minLength: 8)
            GlassToggle(isOn: model.showMenuBarIcon) {
                model.onSetShowMenuBarIcon(!model.showMenuBarIcon)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }

    private var languageRow: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "globe")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textDim)
                    .frame(width: 16)
                Text(model.strings.language)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.text)
                Spacer(minLength: 4)
                Text(model.language.displayName)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textDim)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .padding(.horizontal, 8)

            // Same reasoning as the battery floor: always visible, so the height is fixed.
            HStack(spacing: 6) {
                ForEach(AppLanguage.allCases, id: \.self) { lang in
                    floorPill(title: lang.displayName, active: model.language == lang) {
                        model.onSelectLanguage(lang)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 6)
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 1) {
            actionRow(icon: "macwindow", title: model.strings.openCapsomnia, shortcut: "⌘O") {
                model.onOpenCapsomnia()
            }
            actionRow(icon: "power", title: model.strings.quit, shortcut: "⌘Q") {
                model.onQuit()
            }
        }
    }

    private func actionRow(icon: String, title: String, shortcut: String, action: @escaping () -> Void) -> some View {
        HoverRow(action: action) { hovering in
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textDim)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.text)
                Spacer(minLength: 8)
                Text(shortcut)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.textFaint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(rowBackground(hovering: hovering, selected: false))
            .padding(.horizontal, 8)
        }
    }

    // MARK: Shared bits

    private func section<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Palette.textFaint)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 4)
            content()
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Palette.border)
            .frame(height: 1)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
    }

    private func rowBackground(hovering: Bool, selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(selected ? Palette.led.opacity(0.10) : (hovering ? Palette.surface.opacity(0.75) : Color.clear))
    }
}

// MARK: - Small components

private struct LEDDot: View {
    let on: Bool
    /// Armed but held off. Hollow rather than another shade — the same distinction the
    /// menu-bar icon makes, so the two never disagree about what state the app is in.
    var held: Bool = false

    var body: some View {
        Circle()
            .fill(on ? Palette.led : Color(nsColor: Brand.offDot))
            .frame(width: 12, height: 12)
            .overlay(
                Circle().stroke(
                    on ? Palette.ledBright.opacity(0.9)
                       : (held ? Palette.led.opacity(0.75) : Color(nsColor: Brand.offDotBorder)),
                    lineWidth: held ? 1.5 : 1
                )
            )
            .shadow(color: on ? Palette.led.opacity(0.8) : .clear, radius: 5)
    }
}

/// A brand-tinted switch (the native NSSwitch never matches the lime glass, and it does
/// not render offscreen for design review).
private struct GlassToggle: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Capsule()
            .fill(isOn ? Palette.led : Palette.surface)
            .frame(width: 38, height: 22)
            .overlay(
                Capsule().stroke(isOn ? Palette.led.opacity(0.5) : Palette.border, lineWidth: 1)
            )
            .overlay(
                Circle()
                    .fill(isOn ? Palette.bg : Color.white.opacity(0.85))
                    .frame(width: 16, height: 16)
                    .offset(x: isOn ? 8 : -8)
                    .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
            )
            .contentShape(Capsule())
            .onTapGesture(perform: action)
            .animation(.easeOut(duration: 0.15), value: isOn)
    }
}

/// A tap target with a hover flag threaded into the content builder.
private struct HoverRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: (Bool) -> Content
    @State private var hovering = false

    var body: some View {
        content(hovering)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .onHover { hovering = $0 }
    }
}

// MARK: - Popover host (AppKit)

/// Wraps the SwiftUI menu in a dark vibrancy view so the panel reads as real glass.
@MainActor
final class StatusPopoverController: NSViewController {
    let model: MenuModel
    private var hostingView: NSHostingView<CapsomniaMenuView>?
    /// Called after the popover has been resized in place, so the owner can pin it back
    /// to the status item. Set by whoever presents the popover.
    var onContentSizeChanged: () -> Void = {}

    init(model: MenuModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        // The brand wash only exists to give legacy vibrancy some depth; over real glass
        // it would cancel out the transparency, so it is dropped on the Liquid Glass path.
        let host = NSHostingView(
            rootView: CapsomniaMenuView(
                model: model,
                tinted: !GlassBackdrop.usesLiquidGlass,
                onContentHeightChange: { [weak self] height in
                    self?.applyContentHeight(height)
                }
            )
        )
        self.hostingView = host

        // The menu panel is borderless and does no masking of its own, so the glass
        // supplies the rounded shape (NSPopover used to mask this to its popover shape).
        let backdrop = GlassBackdrop.wrap(host, cornerRadius: 13)
        backdrop.translatesAutoresizingMaskIntoConstraints = false

        let root = MenuRootView()
        root.wantsLayer = true
        root.onOpenCapsomnia = { [weak self] in self?.model.onOpenCapsomnia() }
        root.onQuit = { [weak self] in self?.model.onQuit() }
        root.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: root.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        view = root
        preferredContentSize = host.fittingSize
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // Re-fit in case content (expanded rows) changed the height. Measured on the
        // hosting view rather than `view`, because the glass backdrop owns its content's
        // layout and does not necessarily report a useful fitting size itself.
        if let hostingView {
            preferredContentSize = hostingView.fittingSize
        }
    }

    /// Grow or shrink the popover as rows expand while it is already on screen. Sub-point
    /// deltas are ignored so ordinary relayout noise cannot start a resize feedback loop.
    private func applyContentHeight(_ height: CGFloat) {
        guard height > 0 else { return }
        guard abs(preferredContentSize.height - height) > 0.5 else { return }
        preferredContentSize = CGSize(width: menuWidth, height: height)
        // AppKit re-places a resized popover itself, and with several displays attached it
        // can put it at another screen's origin instead of back under the menu-bar item.
        // Re-anchor on the next tick, once the new size has actually been applied.
        DispatchQueue.main.async { [weak self] in self?.onContentSizeChanged() }
    }

    /// The intro motion: the panel grows into place from its top edge (toward the
    /// menu-bar item) while fading in.
    ///
    /// Why this is smooth where the built-in animation stuttered: `NSPopover`'s own
    /// open animation resizes the *content view* from small to full, so `NSHostingView`
    /// re-runs a full SwiftUI layout pass every frame (CPU work → dropped frames). Here
    /// the popover shows with `animates = false`, so the content is laid out exactly
    /// once at final size and the intro is two Core Animation layer animations (GPU-only,
    /// no relayout) that run on the compositor at the display refresh rate.
    ///
    /// Both are *presentation-only*: the layer's model stays at identity / opacity 1, so
    /// if an animation is ever dropped (rapid re-open, tracking races) the panel is
    /// simply fully visible. It can never get stuck hidden — the earlier window-alpha
    /// approach could leave a "shown" popover stuck at alpha 0, i.e. invisible.
    func playOpenAnimation() {
        guard let layer = view.layer else { return }
        let bounds = layer.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        // Scale about the top-center so the panel appears to drop out of the menu bar.
        // NSVisualEffectView's layer is not geometry-flipped, so the top edge is maxY.
        let anchor = CGPoint(x: bounds.midX, y: bounds.maxY)
        func transform(scale: CGFloat) -> CATransform3D {
            var t = CATransform3DTranslate(CATransform3DIdentity, anchor.x, anchor.y, 0)
            t = CATransform3DScale(t, scale, scale, 1)
            return CATransform3DTranslate(t, -anchor.x, -anchor.y, 0)
        }

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.0
        fade.toValue = 1.0
        fade.duration = 0.20
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "open-fade")

        // Reduce Motion: keep the opacity reveal (a cross-fade is motion-safe) but drop
        // the scale. Direct Core Animation is not auto-suppressed by the accessibility
        // preference, so we gate it ourselves.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }

        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = NSValue(caTransform3D: transform(scale: 0.94))
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        grow.duration = 0.22
        // Gentle decelerate — settles without an overshoot wobble.
        grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        layer.add(grow, forKey: "open-grow")
    }
}
