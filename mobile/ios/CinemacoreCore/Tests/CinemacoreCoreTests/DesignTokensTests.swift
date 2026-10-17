import Testing
import Foundation
@testable import CinemacoreCore

@Suite("RGB")
struct RGBTests {
    @Test("hex round-trips exactly")
    func hexRoundTrip() {
        for hex: UInt32 in [0x000000, 0xFFFFFF, 0x090A10, 0x141622, 0xE50914, 0x9E9EAF, 0xFF8C00] {
            #expect(RGB(hex: hex).hex == String(format: "%06X", hex))
        }
    }

    @Test("channel values land in the unit range")
    func channelsInRange() {
        let white = RGB(hex: 0xFFFFFF)
        #expect(white.red == 1 && white.green == 1 && white.blue == 1)

        let black = RGB(hex: 0x000000)
        #expect(black.red == 0 && black.green == 0 && black.blue == 0)
    }

    @Test("blend endpoints are exact")
    func blendEndpoints() {
        let black = RGB(hex: 0x000000)
        let white = RGB(hex: 0xFFFFFF)
        #expect(black.blended(over: white, amount: 1) == black)
        #expect(black.blended(over: white, amount: 0) == white)
    }

    @Test("blend is clamped outside the unit range")
    func blendClamps() {
        let black = RGB(hex: 0x000000)
        let white = RGB(hex: 0xFFFFFF)
        #expect(black.blended(over: white, amount: 5) == black)
        #expect(black.blended(over: white, amount: -5) == white)
    }

    @Test("contrast ratio matches known extremes")
    func contrastExtremes() {
        let black = RGB(hex: 0x000000)
        let white = RGB(hex: 0xFFFFFF)
        #expect(abs(white.contrastRatio(against: black) - 21) < 0.01)
        #expect(abs(white.contrastRatio(against: white) - 1) < 0.001)
    }
}

@Suite("Cinematic Obsidian palette")
struct PaletteTests {
    @Test("brand colours match the Genga-World source exactly")
    func brandColoursAreVerbatim() {
        #expect(CinematicObsidian.obsidianDark.hex == "090A10")
        #expect(CinematicObsidian.obsidianCard.hex == "141622")
        #expect(CinematicObsidian.cinematicRed.hex == "E50914")
        #expect(CinematicObsidian.crimsonRed.hex == "B81D24")
        #expect(CinematicObsidian.accentAmber.hex == "FF8C00")
        #expect(CinematicObsidian.textPrimary.hex == "F5F5F7")
        #expect(CinematicObsidian.textSecondary.hex == "9E9EAF")
        #expect(CinematicObsidian.surfaceVariant.hex == "1F2235")
    }
}

@Suite("Theme")
struct ThemeTests {
    private let theme = Theme.cinematic

    @Test("roles resolve to the palette")
    func rolesResolve() {
        #expect(theme.background == CinematicObsidian.obsidianDark)
        #expect(theme.brand == CinematicObsidian.cinematicRed)
        #expect(theme.brandPressed == CinematicObsidian.crimsonRed)
        #expect(theme.accent == CinematicObsidian.accentAmber)
    }

    @Test("body text clears the WCAG AA 4.5:1 gate on every surface")
    func textContrastPassesAA() {
        for surface in [theme.background, theme.surface, theme.surfaceElevated] {
            #expect(
                theme.textPrimary.contrastRatio(against: surface) >= 4.5,
                "textPrimary on \(surface.hex)"
            )
        }
    }

    @Test("primary text is the stronger of the two text roles")
    func textPrimaryIsStronger() {
        #expect(
            theme.textPrimary.contrastRatio(against: theme.background)
                > theme.textSecondary.contrastRatio(against: theme.background)
        )
    }

    @Test("secondary text still clears 4.5:1 on the base background")
    func secondaryTextPassesAA() {
        #expect(theme.textSecondary.contrastRatio(against: theme.background) >= 4.5)
    }

    @Test("separator is a slight lift off the card, not a new colour")
    func separatorIsDerived() {
        #expect(theme.separator.hex != theme.surface.hex)
        #expect(
            theme.separator.relativeLuminance > theme.surface.relativeLuminance,
            "separator should be lighter than the card it sits on"
        )
    }
}

@Suite("Layout")
struct LayoutTests {
    @Test("spacing follows the 4pt grid")
    func spacingIsOnGrid() {
        for value in [
            Layout.spacing1, Layout.spacing2, Layout.spacing3, Layout.spacing4,
            Layout.spacing5, Layout.spacing6, Layout.spacing8,
        ] {
            #expect(value.truncatingRemainder(dividingBy: 4) == 0)
        }
    }

    @Test("tap targets meet the 44pt minimum")
    func targetMinimum() {
        #expect(Layout.minimumTarget >= 44)
    }

    @Test("poster ratio is portrait 2:3")
    func posterRatio() {
        #expect(abs(Layout.posterAspectRatio - (2.0 / 3.0)) < 0.0001)
    }
}
