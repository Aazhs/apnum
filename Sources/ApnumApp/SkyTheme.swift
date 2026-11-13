import ApnumSky
import SwiftUI

/// The app's colours for the current sky. Like aarshj.me, the chrome is taken
/// from the land under the sky: deep green by day, plum at dusk, indigo at night.
/// Text stays light, so the whole app runs in the dark appearance while themed.
struct SkyTheme: Equatable {
    /// False when the user has turned sky colours off; system colours are used.
    var isActive: Bool
    /// Window and page background.
    var background: Color
    /// Sidebar, one step darker than the page.
    var sidebar: Color
    /// Raised surfaces: fields, tiles, grouped rows.
    var panel: Color
    /// Hairlines and borders around panels.
    var edge: Color
    /// Selected or hovered surfaces.
    var raised: Color
    /// Accent for controls and highlights.
    var accent: Color
    /// A soft tint of the horizon for secondary highlights.
    var glow: Color

    static let system = SkyTheme(
        isActive: false, background: Color(nsColor: .windowBackgroundColor), sidebar: .clear,
        panel: Color.primary.opacity(0.06), edge: Color.primary.opacity(0.1), raised: Color.primary.opacity(0.1),
        accent: .accentColor, glow: .accentColor)

    init(isActive: Bool, background: Color, sidebar: Color, panel: Color, edge: Color, raised: Color, accent: Color, glow: Color) {
        self.isActive = isActive
        self.background = background
        self.sidebar = sidebar
        self.panel = panel
        self.edge = edge
        self.raised = raised
        self.accent = accent
        self.glow = glow
    }

    /// aarshj.me: night = mix(ground, near, .25), panel = mix(near, mid, .35), edge = mix(ground, black, .35).
    init(scene: SkyScene) {
        let p = scene.palette
        let black = RGB(0, 0, 0)
        let night = p.ground.mix(p.near, 0.25)
        self.init(
            isActive: true,
            background: night.color,
            sidebar: p.ground.mix(black, 0.18).color,
            panel: p.near.mix(p.mid, 0.35).color,
            edge: p.mid.mix(p.far, 0.3).color.opacity(0.55),
            raised: p.mid.color,
            accent: scene.accent,
            glow: p.haze.mix(RGB(1, 1, 1), 0.35).color)
    }
}

extension EnvironmentValues {
    @Entry var skyTheme = SkyTheme.system
}

extension View {
    /// Fills a page with the sky theme's background and lets lists, forms and tables show it.
    func skyPage(_ theme: SkyTheme) -> some View {
        self
            .scrollContentBackground(theme.isActive ? .hidden : .automatic)
            .background(theme.isActive ? theme.background : Color.clear)
    }

    /// A raised, bordered surface in the theme's panel colour.
    func skyPanel(_ theme: SkyTheme, cornerRadius: CGFloat = 16) -> some View {
        self
            .background(theme.panel, in: .rect(cornerRadius: cornerRadius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(theme.edge, lineWidth: 1) }
    }
}

extension AppModel {
    /// The theme for the live sky, or system colours when sky colours are off.
    func theme(enabled: Bool) -> SkyTheme {
        guard enabled, let scene = skyScene else { return .system }
        return SkyTheme(scene: scene)
    }
}
