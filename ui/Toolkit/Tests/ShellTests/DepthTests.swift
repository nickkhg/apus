import Render
@testable import Shell
import Testing
import Toolkit

// The shell draws depth in one of two ways, and `Appearance` holds both. A
// mode is not the other mode with the effects turned off, so these tests
// hold what each mode asks the renderer for.

private let screen = Rect(x: 0, y: 0, width: 1280, height: 800)

private func list(_ mode: RenderMode, summonIsOpen: Bool = false) -> DisplayList {
    let state = ShellState(apps: [], windows: [], mode: mode, summonIsOpen: summonIsOpen,
                           canvas: RootView.windowArea(screen: screen))
    return ViewRenderer.displayList(for: RootView(state: state), in: screen)
}

private func shadows(_ list: DisplayList) -> Int {
    list.filter { if case .shadow = $0 { true } else { false } }.count
}

private func blurs(_ list: DisplayList) -> Int {
    list.filter { if case .blur = $0 { true } else { false } }.count
}

private func gradients(_ list: DisplayList) -> Int {
    list.filter { if case .gradient = $0 { true } else { false } }.count
}

@Suite("What each mode asks the renderer for")
struct DepthTests {
    @Test("CPU mode asks for no shadow, no blur and no gradient")
    func theCPUAsksForNone() {
        let items = list(.cpu, summonIsOpen: true)
        #expect(shadows(items) == 0)
        #expect(blurs(items) == 0)
        #expect(gradients(items) == 0)
    }

    @Test("GPU mode holds the rail off the desktop with a shadow")
    func theRailHasAShadow() {
        #expect(shadows(list(.gpu)) > 0)
        #expect(shadows(list(.cpu)) == 0)
    }

    @Test("GPU mode makes the layer under Summon soft")
    func summonIsSoft() {
        #expect(blurs(list(.gpu, summonIsOpen: true)) > 0)
        #expect(blurs(list(.gpu)) == 0, "a blur when Summon is closed")
    }

    @Test("GPU mode puts some light in the face of a surface")
    func theSurfaceHasAFace() {
        #expect(gradients(list(.gpu)) > 0)
    }
}

@Suite("The values of the two modes")
struct AppearanceValueTests {
    @Test("A surface over a blur is not solid, and one over nothing is")
    func theSurfaceLetsTheBlurThrough() {
        #expect(Appearance(.cpu).surfaceOpacity == 1)
        #expect(Appearance(.gpu).surfaceOpacity < 1)
    }

    @Test("A cell sits nearer the canvas than the rail does")
    func theCellShadowIsShorter() {
        #expect(Appearance(.gpu).cellShadow.radius < Appearance(.gpu).surfaceShadow.radius)
        #expect(!Appearance(.cpu).cellShadow.isVisible)
        #expect(Appearance(.gpu).cellShadow.isVisible)
    }

    @Test("The face of a surface is one colour in CPU mode")
    func theCPUFaceIsFlat() {
        let cpu = Appearance(.cpu).surfaceFace
        #expect(cpu.from == cpu.to)
        let gpu = Appearance(.gpu).surfaceFace
        #expect(gpu.from != gpu.to)
    }

    @Test("A move is shorter on the CPU")
    func theCPUMovesLess() {
        #expect(Appearance(.cpu).motion(.surface).duration < Animation.surface.duration)
        #expect(Appearance(.gpu).motion(.surface) == .surface)
    }

    @Test("A spring is a plain arrival on the CPU, because an overshoot costs frames")
    func theCPUHasNoSpring() {
        let spring = Animation.spring()
        #expect(Appearance(.gpu).motion(spring).curve == spring.curve)
        #expect(Appearance(.cpu).motion(spring).curve == .easeOut)
    }
}
