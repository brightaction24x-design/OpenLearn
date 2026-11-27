//
//  Theme.swift
//  OpenLearn
//
//  The website's look: near-black surfaces, indigo-to-violet accents and
//  monospaced section labels. Change a colour here and every screen follows.
//

import SwiftUI
import AppKit

// MARK: - Colours
enum OLTheme {
    static let background = Color(olRGB: 0x06060B)
    static let surface = Color(olRGB: 0x111116)
    static let surfaceLow = Color(olRGB: 0x0B0B10)
    static let border = Color(olRGB: 0x28282C)
    static let borderSoft = Color(olRGB: 0x1F1F24)
    static let divider = Color(olRGB: 0x131317)
    static let selection = Color(olRGB: 0x14142D)

    static let textBright = Color(olRGB: 0xE0E7FF)
    static let textPrimary = Color(olRGB: 0xE2E8F0)
    static let textBody = Color(olRGB: 0xCBD5E1)
    static let textSecondary = Color(olRGB: 0x94A3B8)
    static let textMuted = Color(olRGB: 0x64748B)
    static let textFaint = Color(olRGB: 0x475569)

    static let indigo = Color(olRGB: 0x5C59DA)
    static let violet = Color(olRGB: 0x6E38D7)
    static let accent = Color(olRGB: 0x685EF0)
    static let accentSoft = Color(olRGB: 0xA5B4FC)
    static let green = Color(olRGB: 0x5BBC97)
    static let greenDeep = Color(olRGB: 0x2F8F6D)
    static let amber = Color(olRGB: 0xF3CB4B)
    static let rose = Color(olRGB: 0xF49EA9)
    static let sky = Color(olRGB: 0x67ACCE)

    static var accentGradient: LinearGradient {
        LinearGradient(colors: [indigo, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension Color {
    init(olRGB value: UInt32) {
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}

// MARK: - Surfaces and motion
extension View {
    /// A rounded card with a thin border.
    func olPanel(radius: CGFloat = 16, fill: Color = OLTheme.surface, border: Color = OLTheme.border) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(fill, in: shape)
            .overlay { shape.strokeBorder(border, lineWidth: 1).allowsHitTesting(false) }
    }

    /// The box around a text field.
    func olField(focused: Bool = false) -> some View {
        padding(.horizontal, 14)
            .padding(.vertical, 10)
            .olPanel(radius: 12, fill: OLTheme.surfaceLow, border: focused ? OLTheme.accent : OLTheme.border)
    }

    /// Fades and lifts a view into place once, when it appears.
    func olRiseIn(_ delay: Double = 0) -> some View {
        modifier(OLRiseIn(delay: delay))
    }
}

private struct OLRiseIn: ViewModifier {
    let delay: Double
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .onAppear {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.85).delay(delay)) {
                    shown = true
                }
            }
    }
}

/// Slow drifting glows. Driven by the clock, so the motion can't leak into
/// the layout of anything drawn on top of it.
struct OLAmbientBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                ZStack {
                    glow(OLTheme.indigo, in: geo.size, x: -0.28, y: -0.22, phase: time * 0.35)
                    glow(OLTheme.violet, in: geo.size, x: 0.30, y: 0.20, phase: time * 0.27 + 2)
                    glow(Color(olRGB: 0xC026D3), in: geo.size, x: 0.18, y: -0.34, phase: time * 0.21 + 4)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .background(OLTheme.background)
        .clipped()
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func glow(_ color: Color, in size: CGSize, x: CGFloat, y: CGFloat, phase: Double) -> some View {
        let diameter = max(size.width, size.height) * 0.8
        let driftX = CGFloat(cos(phase)) * size.width * 0.08
        let driftY = CGFloat(sin(phase * 0.8)) * size.height * 0.10

        return Circle()
            .fill(RadialGradient(
                colors: [color.opacity(0.30), color.opacity(0)],
                center: .center,
                startRadius: 0,
                endRadius: diameter / 2
            ))
            .frame(width: diameter, height: diameter)
            .offset(x: size.width * x + driftX, y: size.height * y + driftY)
    }
}

/// Three pulsing dots shown while the AI is thinking.
struct OLTypingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(OLTheme.accentSoft)
                        .frame(width: 6, height: 6)
                        .opacity(strength(at: time, dot: index))
                }
            }
        }
    }

    private func strength(at time: Double, dot: Int) -> Double {
        let wave: Double = sin(time * 5 - Double(dot) * 0.9)
        return 0.3 + 0.7 * max(0, wave)
    }
}

// MARK: - Small pieces
/// Spaced-out monospaced section label.
struct OLEyebrow: View {
    let text: String
    var color: Color = OLTheme.textFaint

    init(_ text: String, color: Color = OLTheme.textFaint) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .tracking(2.4)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// A file name with a coloured icon for its type.
struct OLFileChip: View {
    let name: String
    var onRemove: (() -> Void)? = nil

    private var icon: (symbol: String, color: Color) {
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": return ("doc.text", OLTheme.rose)
        case "ppt", "pptx": return ("rectangle.on.rectangle", OLTheme.amber)
        case "xls", "xlsx", "csv", "tsv": return ("tablecells", OLTheme.green)
        case "png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp":
            return ("photo", OLTheme.accentSoft)
        default: return ("doc.plaintext", OLTheme.sky)
        }
    }

    /// Long names are cut in the middle, so the file type stays visible.
    private var shortName: String {
        guard name.count > 34 else { return name }
        return String(name.prefix(20)) + "…" + String(name.suffix(12))
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon.symbol)
                .foregroundStyle(icon.color)
            Text(shortName)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(OLTheme.textSecondary)
                .lineLimit(1)
                .help(name)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(OLTheme.textMuted)
                        .padding(3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove this file")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .olPanel(radius: 10)
    }
}

// MARK: - Buttons
struct OLAccentButtonStyle: ButtonStyle {
    var colors: [Color] = [OLTheme.indigo, OLTheme.violet]

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, colors: colors)
    }

    struct Chrome: View {
        let configuration: ButtonStyleConfiguration
        let colors: [Color]
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(
                    LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .shadow(color: (colors.first ?? .clear).opacity(isEnabled ? 0.4 : 0), radius: 12, y: 5)
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
        }
    }
}

struct OLGhostButtonStyle: ButtonStyle {
    var tint: Color = OLTheme.textBody

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, tint: tint)
    }

    struct Chrome: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .olPanel(radius: 12, fill: hovering && isEnabled ? OLTheme.borderSoft : OLTheme.surface)
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == OLAccentButtonStyle {
    static var olAccent: OLAccentButtonStyle { OLAccentButtonStyle() }
}

extension ButtonStyle where Self == OLGhostButtonStyle {
    static var olGhost: OLGhostButtonStyle { OLGhostButtonStyle() }
}

// MARK: - Window chrome
/// Lets the app draw its own header behind the traffic-light buttons.
struct OLWindowStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { StylerView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class StylerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            // An empty unified toolbar centres the traffic lights in a taller header
            if window.toolbar == nil { window.toolbar = NSToolbar(identifier: "OpenLearnHeader") }
            window.toolbarStyle = .unified
            window.titlebarSeparatorStyle = .none
            window.backgroundColor = NSColor(srgbRed: 6 / 255, green: 6 / 255, blue: 11 / 255, alpha: 1)
        }
    }
}
