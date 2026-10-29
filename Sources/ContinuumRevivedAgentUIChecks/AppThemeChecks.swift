import ContinuumRevivedAgentUI
import Foundation

func runAppThemeChecks() {
    let previous = AppTheme.current
    defer { AppTheme.current = previous }
    expect(AppTheme.allCases.count == 10, "AppTheme: ten selectable themes")
    expect(AppTheme.resolve("unknown") == .neutral, "AppTheme: unknown values fall back")
    var signatures = Set<String>()
    var measurements = 0
    for theme in AppTheme.allCases {
        AppTheme.current = theme
        expect(AppTheme.resolve(theme.rawValue) == theme, "AppTheme: persisted choice round trips")
        var signature = ""
        signature = (SurfaceToken.allCases.map(\.color) + AgentSurfaceRole.allCases.map(\.color)).map { $0.resolved(for: theme.appearance).hexKey }.joined()
        for appearance in TokenTheme.allCases {
            for token in SurfaceToken.allCases.map(\.color) + AgentSurfaceRole.allCases.map(\.color) {
                let c = token.resolved(for: appearance)
                expect(c.r == c.g && c.g == c.b, "AppTheme: \(theme) has a colour cast")
            }
            for pair in DesignTokens.documentedPairs + AgentTileTokens.documentedPairs + SidebarTokens.documentedPairs + DesignTokens.recededTextPairs {
                expect(pair.ratio(for: appearance) >= pair.floor,
                       "AppTheme: \(theme) \(appearance) \(pair.foreground) on \(pair.background) below contrast floor: \(pair.ratio(for: appearance))")
                measurements += 1
            }
            expect(AgentTileTokens.rowEmphasisRatio(.rowSelected, theme: appearance) > AgentTileTokens.rowEmphasisRatio(.rowHover, theme: appearance),
                   "AppTheme: selected row must remain stronger than hover")
            expect(AgentTileTokens.rowEmphasisRatio(.rowHover, theme: appearance) >= 1.05,
                   "AppTheme: \(theme) \(appearance) hover must remain visible")
        }
        expect(signatures.insert(signature).inserted, "AppTheme: each theme paints a distinct palette")
    }
    print("AppTheme: ten neutral palettes, \(measurements) contrast measurements including faded text, distinct renders and persisted IDs")
}
