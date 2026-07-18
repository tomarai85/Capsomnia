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
    @Published var strings: MenuStrings

    var onSelectMode: (KeepAwakeMode) -> Void = { _ in }
    var onSetFloorEnabled: (Bool) -> Void = { _ in }
    var onSetFloorPercent: (Int) -> Void = { _ in }
    var onSetShowMenuBarIcon: (Bool) -> Void = { _ in }
    var onSelectLanguage: (AppLanguage) -> Void = { _ in }
    var onOpenCapsomnia: () -> Void = {}
    var onQuit: () -> Void = {}

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

struct CapsomniaMenuView: View {
    @ObservedObject var model: MenuModel
    @State private var floorExpanded = false
    @State private var languageExpanded = false

    private let floorOptions = [10, 15, 20, 25, 30]

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
        .background(
            // Barely-there brand wash so the frosted vibrancy dominates and the desktop
            // clearly shows through — real glass, not a dark panel.
            LinearGradient(
                colors: [Palette.bg.opacity(0.14), Palette.bg.opacity(0.06)],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 11) {
            LEDDot(on: model.keepingAwake)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.strings.appName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textDim)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            statusPill
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var subtitle: String {
        "\(model.strings.keepAwakeHeading) · \(currentModeLabel)"
    }

    private var currentModeLabel: String {
        switch model.mode {
        case .off: return model.strings.modeOff
        case .capsLock: return model.strings.modeCapsLock
        case .auto: return model.strings.modeAuto
        }
    }

    private var statusPill: some View {
        Text(model.keepingAwake ? "ON" : "OFF")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(model.keepingAwake ? Palette.led : Palette.textDim)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(model.keepingAwake ? Palette.led.opacity(0.14) : Palette.surface.opacity(0.6))
            )
            .overlay(
                Capsule().stroke(model.keepingAwake ? Palette.led.opacity(0.35) : Palette.border, lineWidth: 1)
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

    private var batteryFloor: some View {
        VStack(spacing: 0) {
            HoverRow {
                withAnimation(.easeOut(duration: 0.16)) { floorExpanded.toggle() }
            } content: { hovering in
                HStack(spacing: 10) {
                    Image(systemName: "battery.50")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.textDim)
                        .frame(width: 16)
                    Text(model.strings.batteryFloorMenu)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.text)
                    Spacer(minLength: 4)
                    Text(model.floorEnabled ? "\(model.floorPercent)%" : model.strings.modeOff)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(model.floorEnabled ? Palette.led : Palette.textDim)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.textFaint)
                        .rotationEffect(.degrees(floorExpanded ? 180 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(rowBackground(hovering: hovering, selected: false))
                .padding(.horizontal, 8)
            }

            if floorExpanded {
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
                }
                .padding(.horizontal, 20)
                .padding(.top, 2)
                .padding(.bottom, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
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
            HoverRow {
                withAnimation(.easeOut(duration: 0.16)) { languageExpanded.toggle() }
            } content: { hovering in
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
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.textFaint)
                        .rotationEffect(.degrees(languageExpanded ? 180 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(rowBackground(hovering: hovering, selected: false))
                .padding(.horizontal, 8)
            }

            if languageExpanded {
                VStack(spacing: 1) {
                    ForEach(AppLanguage.allCases, id: \.self) { lang in
                        let selected = model.language == lang
                        HoverRow {
                            model.onSelectLanguage(lang)
                        } content: { hovering in
                            HStack {
                                Text(lang.displayName)
                                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                                    .foregroundStyle(selected ? Palette.led : Palette.text.opacity(0.9))
                                Spacer()
                                if selected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(Palette.led)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(rowBackground(hovering: hovering, selected: false))
                            .padding(.horizontal, 8)
                        }
                    }
                }
                .padding(.leading, 22)
                .padding(.bottom, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
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
    var body: some View {
        Circle()
            .fill(on ? Palette.led : Color(nsColor: Brand.offDot))
            .frame(width: 12, height: 12)
            .overlay(Circle().stroke(on ? Palette.ledBright.opacity(0.9) : Color(nsColor: Brand.offDotBorder), lineWidth: 1))
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

    init(model: MenuModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true

        let host = NSHostingView(rootView: CapsomniaMenuView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])

        view = effect
        preferredContentSize = host.fittingSize
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // Re-fit in case content (expanded rows) changed the height.
        preferredContentSize = view.fittingSize
    }
}
