// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// Theme — the shared "Console" design language for the iOS app: a self-contained
// graphite instrument panel with one amber phosphor accent and monospaced
// readouts. One palette, panel / readout / gauge / chip primitives, a primary
// button style, and haptics, so every tab (Review, Palace, Scores, Practice,
// Account) shares a cohesive look that matches the desktop `sass/mcat-tools.scss`
// Console tokens.
//
// SELF-CONTAINED: the app is pinned to `.preferredColorScheme(.dark)` (see
// AnkiMCATApp) and every surface uses explicit Console colours rather than the
// system semantic greys, so the graphite ground is identical on every device.
//
// HONESTY RULE (see README "The three scores"): memory-recall visuals must stay
// NEUTRAL — never a red→green scale, and never the amber accent (amber reads as
// "good/go"). Use `MCATGauge(style: .neutral)` / `MCATTheme.steel` there.
// Semantic colour (green / red) is reserved for *real* correctness.

import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

// MARK: - Palette

enum MCATTheme {
    // Cool graphite grounds — near-black with a faint blue cast (a screen, not
    // warm paper). Mirrors the desktop Console tokens.
    static let bg = Color(hex: 0x0A0E13) // page ground
    static let panel = Color(hex: 0x10161D) // panel surface
    static let panel2 = Color(hex: 0x161E27) // nested / raised
    static let well = Color(hex: 0x0C1116) // inset wells (tracks)

    // Ink.
    static let ink = Color(hex: 0xDFE6EE) // primary text
    static let inkDim = Color(hex: 0x94A2B2) // secondary
    static let inkFaint = Color(hex: 0x5F6C7B) // captions / disabled

    // Amber phosphor — the single accent (interaction & wayfinding, NOT a
    // verdict). `amber` is the alias the rest of the app tints against.
    static let amber = Color(hex: 0xFFB020)
    static let amberBright = Color(hex: 0xFFC65C)
    static let amberInk = Color(hex: 0x1A1206) // text on a solid amber fill

    // Semantic — REAL correctness only.
    static let correct = Color(hex: 0x3FB950)
    static let incorrect = Color(hex: 0xF85149)

    // Steel — honest neutral magnitude (recall). Monochrome; no judgement.
    static let steel = Color(hex: 0x8B98A8)

    // Hairline overlay strengths (used with `.opacity` on white/steel).
    static let line = Color.white.opacity(0.12)
    static let lineStrong = Color.white.opacity(0.22)

    static let cornerRadius: CGFloat = 10
    static let cornerRadiusSmall: CGFloat = 6

    // Back-compat aliases so any lingering callers keep compiling but pick up
    // the Console palette. `brand`/`brandBright` now resolve to amber.
    static let brand = amber
    static let brandBright = amberBright
    static let indigo = amber
    static let violet = amber
    static let amberDeep = amberBright

    // Console has no decorative gradients; these stay as flat amber fills so
    // legacy `.fill(MCATTheme.aurora)` sites read on-brand.
    static let aurora = LinearGradient(colors: [amber], startPoint: .top, endPoint: .bottom)
    static let brandGradient = LinearGradient(colors: [amber], startPoint: .top, endPoint: .bottom)
    static let amberGradient = LinearGradient(colors: [amber], startPoint: .top, endPoint: .bottom)
}

extension Color {
    /// Build a colour from a 0xRRGGBB literal (keeps the palette terse).
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

// MARK: - Fonts

extension Font {
    /// The instrument voice: monospaced digits & labels.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Surfaces

/// The self-contained Console ground: solid graphite + a faint amber scanline
/// glow at the top so the panel reads as "powered on".
struct MCATScreenBackground: View {
    var body: some View {
        ZStack(alignment: .top) {
            MCATTheme.bg
            LinearGradient(
                colors: [MCATTheme.amber.opacity(0.07), .clear],
                startPoint: .top, endPoint: .center
            )
        }
        .ignoresSafeArea()
    }
}

/// Panel: graphite surface + hairline border + small radius. Applied to content
/// that has already been padded (drop-in for the old `cardBackground`).
private struct MCATCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                MCATTheme.panel,
                in: RoundedRectangle(cornerRadius: MCATTheme.cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MCATTheme.cornerRadius, style: .continuous)
                    .strokeBorder(MCATTheme.line, lineWidth: 1)
            )
    }
}

/// Readout frame: the featured panel for a hero metric (Readiness). Graphite
/// surface with an amber border + a faint amber corner glow. Content colours
/// itself (amber number, dim labels) — no white-on-gradient.
private struct MCATHeroModifier: ViewModifier {
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: MCATTheme.cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            // `.background(_:in:)` only accepts a ShapeStyle, so compose the
            // graphite fill + amber corner glow via the ViewBuilder overload and
            // clip the gradient to the same shape.
            .background {
                shape
                    .fill(MCATTheme.panel)
                    .overlay {
                        RadialGradient(
                            colors: [MCATTheme.amber.opacity(0.10), .clear],
                            center: .topTrailing, startRadius: 4, endRadius: 260
                        )
                        .clipShape(shape)
                    }
            }
            .overlay(
                shape.strokeBorder(MCATTheme.amber.opacity(0.42), lineWidth: 1)
            )
    }
}

extension View {
    func mcatCard() -> some View { modifier(MCATCardModifier()) }
    func mcatHero() -> some View { modifier(MCATHeroModifier()) }
}

// MARK: - Section header

/// A labelled instrument channel: leading amber block + mono uppercase label +
/// a hairline rule filling the row. Replaces the old icon+headline header.
struct MCATSectionHeader: View {
    var title: String
    /// Optional SF Symbol kept for call-site compatibility (rendered small,
    /// dim) — the amber block is the primary marker.
    var icon: String? = nil

    init(_ title: String, icon: String? = nil) {
        self.title = title
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(MCATTheme.amber)
                .frame(width: 9, height: 9)
                .shadow(color: MCATTheme.amber.opacity(0.6), radius: 5)
            Text(title.uppercased())
                .font(.mono(12, .semibold))
                .kerning(1.4)
                .foregroundStyle(MCATTheme.inkDim)
            Rectangle()
                .fill(MCATTheme.line)
                .frame(height: 1)
        }
    }
}

// MARK: - Bracketed range scale

/// The signature honest device: a fixed axis with the *likely range* shown as a
/// lit band and the point estimate as a bright marker. `lo`/`hi`/`pt` are 0…1.
struct MCATScale: View {
    var lo: Double
    var hi: Double
    var pt: Double
    var accent: Color = MCATTheme.steel

    private func clamp(_ v: Double) -> Double { max(0, min(1, v)) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(MCATTheme.well)
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(MCATTheme.line))
                    .frame(height: 8)
                RoundedRectangle(cornerRadius: 2)
                    .fill(accent.opacity(0.42))
                    .frame(width: w * max(0, clamp(hi) - clamp(lo)), height: 8)
                    .offset(x: w * clamp(lo))
                Rectangle()
                    .fill(accent)
                    .frame(width: 2, height: 18)
                    .shadow(color: accent.opacity(0.7), radius: 5)
                    .offset(x: w * clamp(pt) - 1)
            }
            .frame(height: 18)
        }
        .frame(height: 18)
    }
}

// MARK: - Gauge ring

enum MCATGaugeStyle { case neutral, brand, aurora }

/// A circular gauge with a big centred value. `.neutral` is the honest style
/// (monochrome steel — for memory recall); `.brand` / `.aurora` use the amber
/// accent for scored metrics (performance / readiness).
struct MCATGauge: View {
    var fraction: Double
    var value: String
    var label: String? = nil
    var style: MCATGaugeStyle = .brand
    var size: CGFloat = 128
    var lineWidth: CGFloat = 13

    private var clamped: Double { max(0, min(1, fraction)) }

    private var stroke: Color {
        switch style {
        case .neutral: return MCATTheme.steel
        case .brand, .aurora: return MCATTheme.amber
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(MCATTheme.well, lineWidth: lineWidth)
            Circle().stroke(MCATTheme.line, lineWidth: 1)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(stroke, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                .rotationEffect(.degrees(-90))
                .shadow(color: stroke.opacity(0.5), radius: 6)
                .animation(.easeOut(duration: 0.6), value: clamped)
            VStack(spacing: 4) {
                Text(value)
                    .font(.mono(size * 0.24, .bold))
                    .foregroundStyle(style == .neutral ? MCATTheme.steel : MCATTheme.amber)
                if let label {
                    Text(label.uppercased())
                        .font(.mono(size * 0.075, .semibold))
                        .kerning(1)
                        .foregroundStyle(MCATTheme.inkFaint)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Chip

/// A bracketed mono tag: reads as a machine token, not a pill.
struct MCATChip: View {
    var text: String
    var systemImage: String? = nil
    var tint: Color = MCATTheme.steel

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text.uppercased())
        }
        .font(.mono(11, .semibold))
        .kerning(0.6)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(tint)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: MCATTheme.cornerRadiusSmall))
        .overlay(
            RoundedRectangle(cornerRadius: MCATTheme.cornerRadiusSmall)
                .strokeBorder(tint.opacity(0.4), lineWidth: 1)
        )
    }
}

// MARK: - Bars

/// Honest neutral magnitude bar (steel). For recall.
struct MCATNeutralBar: View {
    var fraction: Double
    var height: CGFloat = 6
    var tint: Color = MCATTheme.steel

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(MCATTheme.well)
                RoundedRectangle(cornerRadius: 2)
                    .fill(tint)
                    .frame(width: geo.size.width * max(0, min(1, fraction)))
            }
        }
        .frame(height: height)
    }
}

// MARK: - Buttons

/// Primary action button: solid amber (phosphor) fill with dark ink, mono
/// uppercase label, small radius, springy press.
struct MCATPrimaryButtonStyle: ButtonStyle {
    var gradient: LinearGradient = MCATTheme.brandGradient // legacy param; unused
    var tintShadow: Color = MCATTheme.amber

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.mono(15, .bold))
            .textCase(.uppercase)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(MCATTheme.amberInk)
            .background(
                MCATTheme.amber,
                in: RoundedRectangle(cornerRadius: MCATTheme.cornerRadiusSmall, style: .continuous)
            )
            .shadow(color: MCATTheme.amber.opacity(configuration.isPressed ? 0.15 : 0.4), radius: 12, y: 4)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Secondary / ghost button: hairline border, ink text, amber border on press.
struct MCATSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.mono(15, .semibold))
            .textCase(.uppercase)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .foregroundStyle(MCATTheme.ink)
            .background(
                configuration.isPressed ? MCATTheme.panel2 : Color.clear,
                in: RoundedRectangle(cornerRadius: MCATTheme.cornerRadiusSmall, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MCATTheme.cornerRadiusSmall)
                    .strokeBorder(configuration.isPressed ? MCATTheme.amber.opacity(0.42) : MCATTheme.lineStrong, lineWidth: 1)
            )
    }
}

// MARK: - Haptics

/// Thin wrapper over UIKit feedback generators so views can add tactile
/// confirmation without repeating `#if canImport(UIKit)` everywhere.
enum Haptics {
    static func tap() {
        #if canImport(UIKit)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    static func selection() {
        #if canImport(UIKit)
            UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }

    static func success() {
        #if canImport(UIKit)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    static func warning() {
        #if canImport(UIKit)
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }
}
