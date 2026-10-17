import Foundation

/// A colour in the sRGB space.
///
/// Deliberately not `SwiftUI.Color`: `CinemacoreCore` stays free of UI
/// frameworks so it builds and tests on Linux. The app target maps these to
/// `Color` in `Color+Cinematic.swift`.
public struct RGB: Sendable, Hashable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Creates a colour from a 24-bit `0xRRGGBB` literal.
    public init(hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    /// The `RRGGBB` hex string, uppercase and without a leading `#`.
    public var hex: String {
        let r = Int((red * 255).rounded())
        let g = Int((green * 255).rounded())
        let b = Int((blue * 255).rounded())
        return String(format: "%02X%02X%02X", r, g, b)
    }

    /// Blends this colour over `other`; `amount` is this colour's weight in 0...1.
    public func blended(over other: RGB, amount: Double) -> RGB {
        let t = min(max(amount, 0), 1)
        return RGB(
            red: red * t + other.red * (1 - t),
            green: green * t + other.green * (1 - t),
            blue: blue * t + other.blue * (1 - t)
        )
    }

    /// Relative luminance per WCAG 2.1, used to keep text contrast honest.
    public var relativeLuminance: Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// WCAG 2.1 contrast ratio against `other`, from 1 (identical) to 21.
    public func contrastRatio(against other: RGB) -> Double {
        let a = relativeLuminance
        let b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// The raw "Cinematic Obsidian" palette.
///
/// Extracted verbatim from the Genga-World Android theme
/// (`app/src/main/java/com/example/ui/theme/Color.kt`) so both surfaces share a
/// single brand definition. These are the only literal colours in the codebase.
public enum CinematicObsidian {
    public static let obsidianDark = RGB(hex: 0x090A10)
    public static let obsidianCard = RGB(hex: 0x141622)
    public static let cinematicRed = RGB(hex: 0xE50914)
    public static let crimsonRed = RGB(hex: 0xB81D24)
    public static let accentAmber = RGB(hex: 0xFF8C00)
    public static let textPrimary = RGB(hex: 0xF5F5F7)
    public static let textSecondary = RGB(hex: 0x9E9EAF)
    public static let surfaceVariant = RGB(hex: 0x1F2235)
    public static let pureWhite = RGB(hex: 0xFFFFFF)
}

/// Semantic colour roles, resolved from the palette.
///
/// Screens reference roles (`theme.brand`), never palette entries, so a palette
/// change stays a one-line edit.
public struct Theme: Sendable {
    public let background: RGB
    public let surface: RGB
    public let surfaceElevated: RGB
    public let brand: RGB
    public let brandPressed: RGB
    public let accent: RGB
    public let textPrimary: RGB
    public let textSecondary: RGB
    public let separator: RGB
    public let posterPlaceholder: RGB

    public init(
        background: RGB,
        surface: RGB,
        surfaceElevated: RGB,
        brand: RGB,
        brandPressed: RGB,
        accent: RGB,
        textPrimary: RGB,
        textSecondary: RGB,
        separator: RGB,
        posterPlaceholder: RGB
    ) {
        self.background = background
        self.surface = surface
        self.surfaceElevated = surfaceElevated
        self.brand = brand
        self.brandPressed = brandPressed
        self.accent = accent
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.separator = separator
        self.posterPlaceholder = posterPlaceholder
    }

    /// The one theme the app ships.
    ///
    /// Genga-World's "light" scheme is byte-identical to its dark scheme (both
    /// set `background = ObsidianDark`), so the brand is dark-only. We lock the
    /// interface to dark rather than inventing a light theme nobody designed.
    public static let cinematic = Theme(
        background: CinematicObsidian.obsidianDark,
        surface: CinematicObsidian.obsidianCard,
        surfaceElevated: CinematicObsidian.surfaceVariant,
        brand: CinematicObsidian.cinematicRed,
        brandPressed: CinematicObsidian.crimsonRed,
        accent: CinematicObsidian.accentAmber,
        textPrimary: CinematicObsidian.textPrimary,
        textSecondary: CinematicObsidian.textSecondary,
        separator: CinematicObsidian.pureWhite.blended(over: CinematicObsidian.obsidianCard, amount: 0.10),
        posterPlaceholder: CinematicObsidian.pureWhite.blended(over: CinematicObsidian.obsidianCard, amount: 0.06)
    )
}

/// Spacing, corner radii, and motion.
///
/// A 4pt base grid, matching the density Genga-World uses in Compose.
public enum Layout {
    public static let spacing1: Double = 4
    public static let spacing2: Double = 8
    public static let spacing3: Double = 12
    public static let spacing4: Double = 16
    public static let spacing5: Double = 20
    public static let spacing6: Double = 24
    public static let spacing8: Double = 32

    public static let radiusSmall: Double = 8
    public static let radiusMedium: Double = 12
    public static let radiusLarge: Double = 18
    public static let radiusPoster: Double = 10

    /// Minimum tappable target per Apple HIG.
    public static let minimumTarget: Double = 44

    /// Poster aspect ratio used by every rail and grid.
    public static let posterAspectRatio: Double = 2.0 / 3.0

    public static let railHeight: Double = 210
    public static let gridMinimum: Double = 104
}
