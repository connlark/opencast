import Foundation
import simd
import Testing
@testable import OpenCast

@MainActor
@Suite("Now Playing peel simulation")
struct NowPlayingPeelSimulationTests {
    @Test("Closed frame equals rest")
    func closedFrameEqualsRest() {
        let simulation = NowPlayingPeelSimulation()
        simulation.reset(progress: 0)

        let frame = simulation.currentFrame()
        #expect(frame.progress == 0)
        for vertex in frame.vertices {
            #expect(simd_distance(vertex.position, vertex.restPosition) < 0.000_1)
            #expect(vertex.uv == SIMD2(vertex.restPosition.x, vertex.restPosition.y))
        }
    }

    @Test("Vertices stay finite across open and close cycles")
    func verticesStayFiniteAcrossCycles() {
        let simulation = NowPlayingPeelSimulation()

        for _ in 0..<3 {
            stepInteractive(simulation, from: 0, to: 1, touchY: 0.78, count: 80)
            stepSettling(simulation, target: 1, count: 60)
            stepInteractive(simulation, from: 1, to: 0, touchY: 0.38, count: 80)
            stepSettling(simulation, target: 0, count: 60)
        }

        let frame = simulation.currentFrame()
        for vertex in frame.vertices {
            #expect(vertex.position.x.isFinite)
            #expect(vertex.position.y.isFinite)
            #expect(vertex.position.z.isFinite)
            #expect(vertex.lift.isFinite)
            #expect(vertex.foldIntensity.isFinite)
        }
    }

    @Test("Left tack strip stays pinned while opening")
    func tackStripStaysPinned() {
        let simulation = NowPlayingPeelSimulation()
        stepInteractive(simulation, from: 0, to: 0.82, touchY: 0.72, count: 90)

        let pinnedVertices = simulation.currentFrame().vertices.filter { $0.tack > 0.5 }
        #expect(!pinnedVertices.isEmpty)
        for vertex in pinnedVertices {
            #expect(simd_distance(vertex.position, vertex.restPosition) < 0.000_1)
        }
    }

    @Test("Structural lengths stay bounded after opening")
    func structuralLengthsStayBoundedAfterOpening() {
        let simulation = NowPlayingPeelSimulation()
        stepInteractive(simulation, from: 0, to: 1, touchY: 0.70, count: 100)
        stepSettling(simulation, target: 1, count: 80)

        #expect(simulation.maximumStructuralStrain() < 0.55)
    }

    @Test("Resting open pose stays a thin flap")
    func restingOpenPoseStaysThinFlap() {
        let simulation = NowPlayingPeelSimulation()
        simulation.reset(progress: 1)

        let frame = simulation.currentFrame()
        let releasedVertices = frame.vertices.filter { $0.released > 0.5 && $0.tack < 0.5 }
        let outerEdge = frame.vertices.filter { $0.restPosition.x > 0.97 }
        let maxFlapX = releasedVertices.map(\.position.x).max() ?? 1
        let maxLift = releasedVertices.map(\.lift).max() ?? 1
        let outerEdgeXValues = outerEdge.map(\.position.x)
        let outerEdgeRange = (outerEdgeXValues.max() ?? 1) - (outerEdgeXValues.min() ?? 0)

        #expect(maxFlapX < 0.34)
        #expect(maxLift < 0.08)
        #expect(outerEdgeRange < 0.08)
    }

    @Test("Touch position changes curl without moving tack strip")
    func touchPositionChangesCurlWithoutMovingTackStrip() {
        let highTouch = NowPlayingPeelSimulation()
        let lowTouch = NowPlayingPeelSimulation()
        stepInteractive(highTouch, from: 0, to: 0.74, touchY: 0.22, count: 90)
        stepInteractive(lowTouch, from: 0, to: 0.74, touchY: 0.86, count: 90)

        let highFrame = highTouch.currentFrame()
        let lowFrame = lowTouch.currentFrame()
        let highLift = averageLift(in: highFrame, rowRange: 0.05...0.35)
        let lowLift = averageLift(in: lowFrame, rowRange: 0.65...0.95)
        #expect(abs(highLift - lowLift) > 0.002)

        for pair in zip(highFrame.vertices, lowFrame.vertices) where pair.0.tack > 0.5 {
            #expect(simd_distance(pair.0.position, pair.0.restPosition) < 0.000_1)
            #expect(simd_distance(pair.1.position, pair.1.restPosition) < 0.000_1)
        }
    }

    @Test("Release hysteresis prevents immediate chatter")
    func releaseHysteresisPreventsImmediateChatter() {
        let simulation = NowPlayingPeelSimulation()
        stepInteractive(simulation, from: 0, to: 0.52, touchY: 0.70, count: 70)
        let releasedAtPeak = releasedColumns(in: simulation)

        stepInteractive(simulation, from: 0.52, to: 0.50, touchY: 0.70, count: 8)
        #expect(releasedColumns(in: simulation) == releasedAtPeak)

        stepInteractive(simulation, from: 0.50, to: 0.25, touchY: 0.70, count: 40)
        #expect(releasedColumns(in: simulation).count < releasedAtPeak.count)
    }

    @Test("Reset is deterministic")
    func resetIsDeterministic() {
        let first = NowPlayingPeelSimulation()
        let second = NowPlayingPeelSimulation()
        stepInteractive(first, from: 0, to: 0.88, touchY: 0.64, count: 100)
        stepInteractive(second, from: 0, to: 0.88, touchY: 0.64, count: 100)

        first.reset(progress: 0)
        second.reset(progress: 0)

        let firstFrame = first.currentFrame()
        let secondFrame = second.currentFrame()
        #expect(firstFrame.vertices == secondFrame.vertices)
        #expect(firstFrame.indices == secondFrame.indices)
    }

    @Test("Reduce Motion produces a low-curvature frame")
    func reduceMotionProducesLowCurvatureFrame() {
        let simulation = NowPlayingPeelSimulation()
        simulation.step(
            input: NowPlayingPeelSimulationInput(
                progress: 0.86,
                touchY: 0.82,
                targetProgress: 0.86,
                normalizedVelocity: 0,
                isInteracting: true,
                reduceMotion: true
            ),
            deltaTime: 1 / 60
        )

        let frame = simulation.currentFrame()
        let maxLift = frame.vertices.map(\.lift).max() ?? 0
        let maxDepth = frame.vertices.map { abs($0.position.z) }.max() ?? 0
        #expect(maxLift < 0.001)
        #expect(maxDepth < 0.001)
    }

    @Test("Topology remains stable across steps")
    func topologyRemainsStableAcrossSteps() {
        let simulation = NowPlayingPeelSimulation()
        let initialIndices = simulation.currentFrame().indices
        let initialVertexCount = simulation.currentFrame().vertices.count

        stepInteractive(simulation, from: 0, to: 1, touchY: 0.5, count: 120)
        stepSettling(simulation, target: 1, count: 60)

        #expect(simulation.currentFrame().indices == initialIndices)
        #expect(simulation.currentFrame().vertices.count == initialVertexCount)
    }

    private func stepInteractive(
        _ simulation: NowPlayingPeelSimulation,
        from start: Float,
        to end: Float,
        touchY: Float,
        count: Int
    ) {
        for step in 0..<count {
            let t = Float(step) / Float(max(count - 1, 1))
            let progress = start + (end - start) * t
            simulation.step(
                input: NowPlayingPeelSimulationInput(
                    progress: progress,
                    touchY: touchY,
                    targetProgress: end,
                    normalizedVelocity: end - start,
                    isInteracting: true,
                    reduceMotion: false
                ),
                deltaTime: 1 / 120
            )
        }
    }

    private func stepSettling(
        _ simulation: NowPlayingPeelSimulation,
        target: Float,
        count: Int
    ) {
        for _ in 0..<count {
            simulation.step(
                input: NowPlayingPeelSimulationInput(
                    progress: simulation.progress,
                    touchY: 0.70,
                    targetProgress: target,
                    normalizedVelocity: 0,
                    isInteracting: false,
                    reduceMotion: false
                ),
                deltaTime: 1 / 120
            )
        }
    }

    private func averageLift(
        in frame: NowPlayingPeelSimulationFrame,
        rowRange: ClosedRange<Float>
    ) -> Float {
        let vertices = frame.vertices.filter {
            rowRange.contains($0.restPosition.y) && $0.restPosition.x > 0.58
        }
        guard !vertices.isEmpty else {
            return 0
        }
        return vertices.reduce(Float(0)) { $0 + $1.lift } / Float(vertices.count)
    }

    private func releasedColumns(in simulation: NowPlayingPeelSimulation) -> [Int] {
        (0..<simulation.topology.columns).filter { simulation.isColumnReleased($0) }
    }
}
