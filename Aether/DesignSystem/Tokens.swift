import AppKit
import SwiftUI

/// Aether design tokens. Dark-only app: values are tuned for darkAqua, with
/// Increase Contrast variants resolved dynamically by AppKit.
enum Tokens {
    static let canvas = Color(red: 11 / 255, green: 12 / 255, blue: 14 / 255)
    static let surface = Color(red: 18 / 255, green: 20 / 255, blue: 23 / 255)
    static let hairline = Color.adaptive(
        .white.withAlphaComponent(0.08),
        highContrast: .white.withAlphaComponent(0.16))
    /// Phosphor green: verified / bit-perfect. The only brand color.
    static let signal = Color.adaptive(
        NSColor(srgbRed: 0.424, green: 0.922, blue: 0.620, alpha: 1),
        highContrast: NSColor(srgbRed: 0.62, green: 1.0, blue: 0.76, alpha: 1))
    static let fault = Color.adaptive(
        NSColor(srgbRed: 1.0, green: 0.420, blue: 0.369, alpha: 1),
        highContrast: NSColor(srgbRed: 1.0, green: 0.60, blue: 0.55, alpha: 1))

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 32
    }

    enum Motion {
        /// Elements entering/leaving (occasional events only).
        static let enter = Animation.easeOut(duration: 0.22)
        /// State/color changes.
        static let state = Animation.easeOut(duration: 0.18)
        /// Progress fills: constant motion is linear.
        static let progress = Animation.linear(duration: 0.12)
    }
}

extension Color {
    static func adaptive(_ normal: NSColor, highContrast: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .accessibilityHighContrastDarkAqua])
            return match == .accessibilityHighContrastDarkAqua ? highContrast : normal
        })
    }
}

extension Font {
    /// Technical readouts: sample rates, sizes, hashes, speeds.
    static var readout: Font { .system(.caption, design: .monospaced).monospacedDigit() }
    static var readoutEmphasis: Font { .system(.callout, design: .monospaced).weight(.medium).monospacedDigit() }
}
