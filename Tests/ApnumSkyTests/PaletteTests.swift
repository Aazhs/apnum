import Testing
@testable import ApnumSky

@Test func paletteEndsMatchKeyframes() {
    #expect(SkyPalette.forSunAltitude(-40) == SkyPalette.forSunAltitude(-18))
    #expect(SkyPalette.forSunAltitude(0).rim == RGB(hex: "#fff6e3"))
}
