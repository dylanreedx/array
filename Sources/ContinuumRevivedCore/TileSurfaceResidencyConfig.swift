import Foundation

/// Resolves whether an agent tile renders from a cached surface **while the
/// camera is moving**, from UserDefaults. Mirrors `ResizeHUDConfig` /
/// `DragMagnetizeConfig`. OFF by default — this is the first production slice of
/// the unbounded-canvas rendering program (`.plans/36`), not a shipped feature.
///
/// The residency it gates has exactly two states, both driven by the camera and
/// by nothing else: settled means every tile mounts its real body, so the app at
/// rest is what it is today; moving means each tile holding a fresh, sharp-enough
/// surface swaps its body for that surface while its real body is parked outside
/// the world plane. Measured: 140 ms -> 0.19 ms per camera step at 50 real agent
/// tiles (`canvas.surface-host-slope`, docs/internals/performance-budgets.md).
///
/// The invariant that makes it safe to leave in the binary: **anything uncertain
/// stays native.** No surface, stale surface, surface less sharp than the screen
/// needs, a family that has not opted in, or this flag off — the tile mounts its
/// real body and costs exactly what it costs today.
public enum TileSurfaceResidencyConfig {
    public static let enabledKey = "continuum.tileSurfaceResidency.enabled"
    public static let defaultEnabled = false

    /// Env override, so `scripts/dev-app.sh` can flip it for one dogfood session.
    /// Checked FIRST and deliberately: the preview app is rebuilt constantly, and a
    /// `defaults write` outlives every rebuild — a flag left on in the dev domain
    /// months later reads as a code change, which is the expensive kind of
    /// confusion. An env var dies with the launch.
    public static let environmentKey = "ARRAY_TILE_SURFACE_RESIDENCY"

    public static func enabled(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if let raw = environment[environmentKey] {
            return raw == "1"
        }
        return defaults.object(forKey: enabledKey) != nil
            ? defaults.bool(forKey: enabledKey)
            : defaultEnabled
    }

    /// How many surfaces one transition may produce. A bake is a main-thread
    /// `cacheDisplay` of a real tile body, so this cap is the whole defence
    /// against a spike landing on the frame a gesture STARTS on — which is
    /// precisely the seam a user feels. Tiles that miss the budget stay native.
    public static let maxBakesPerTransition = 4

    /// Fidelity injection for the negative witness. The pixel-equivalence gate
    /// must be able to FAIL, or it is decoration: with this set, every bake is
    /// round-tripped through a half-size bitmap, degrading it exactly as a
    /// half-resolution producer would.
    public static let degradeBakesEnvironmentKey = "TILE_SURFACE_HALF_SCALE"

    public static func degradesBakes(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[degradeBakesEnvironmentKey] == "1"
    }
}
