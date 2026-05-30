import Foundation
import simd

final class NowPlayingPeelSimulation {
    let parameters: NowPlayingPeelSimulationParameters
    let topology: NowPlayingPeelMeshTopology

    private(set) var progress: Float = 0
    private var progressVelocity: Float = 0
    private var touchY: Float = 0.76
    private var reduceMotion = false
    private var isInteracting = false
    private var restPositions: [SIMD3<Float>]
    private var positions: [SIMD3<Float>]
    private var previousPositions: [SIMD3<Float>]
    private var velocities: [SIMD3<Float>]
    private var goals: [SIMD3<Float>]
    private var outputVertices: [NowPlayingPeelSimulationVertex]
    private var releasedColumns: [Bool]

    init(parameters: NowPlayingPeelSimulationParameters = .default) {
        self.parameters = parameters
        topology = NowPlayingPeelMeshTopology(parameters: parameters)
        restPositions = Self.makeRestPositions(topology: topology)
        positions = restPositions
        previousPositions = restPositions
        velocities = Array(repeating: .zero, count: topology.vertexCount)
        goals = restPositions
        releasedColumns = Array(repeating: false, count: topology.columns)
        outputVertices = Self.makeOutputVertices(restPositions: restPositions, topology: topology)
        fillOutputVertices()
    }

    var vertexCapacity: Int {
        topology.vertexCount
    }

    var indexCount: Int {
        topology.indices.count
    }

    func reset(progress: Float = 0) {
        let nextProgress = progress.clamped01
        self.progress = nextProgress
        progressVelocity = 0
        isInteracting = false
        releasedColumns = Array(repeating: nextProgress > 0.98, count: topology.columns)
        for column in 0..<topology.columns where columnRestX(column) <= parameters.tackWidth {
            releasedColumns[column] = false
        }
        updateReleaseColumns(progress: nextProgress)
        for index in positions.indices {
            let goal = goalPosition(for: index, progress: nextProgress, touchY: touchY, reduceMotion: reduceMotion)
            positions[index] = goal
            previousPositions[index] = goal
            velocities[index] = .zero
            goals[index] = goal
        }
        fillOutputVertices()
    }

    func step(input: NowPlayingPeelSimulationInput, deltaTime: Float) {
        let dt = deltaTime.clamped(to: (1 / 240)...(1 / 30))
        touchY = input.touchY.clamped(to: 0.08...0.94)
        reduceMotion = input.reduceMotion
        isInteracting = input.isInteracting

        updateProgress(input: input, deltaTime: dt)
        updateReleaseColumns(progress: progress)
        fillGoals(progress: progress, touchY: touchY, reduceMotion: input.reduceMotion)

        if input.reduceMotion {
            applyReduceMotionFrame()
            return
        }

        integrate(deltaTime: dt)
        solveConstraints(deltaTime: dt)
        updateVelocities(deltaTime: dt)
        fillOutputVertices()
    }

    func currentFrame() -> NowPlayingPeelSimulationFrame {
        NowPlayingPeelSimulationFrame(
            vertices: outputVertices,
            indices: topology.indices,
            progress: progress
        )
    }

    func withCurrentFrame<T>(_ body: ([NowPlayingPeelSimulationVertex], [UInt16], Float) -> T) -> T {
        body(outputVertices, topology.indices, progress)
    }

    func isColumnReleased(_ column: Int) -> Bool {
        releasedColumns[min(max(column, 0), topology.columns - 1)]
    }

    func maximumStructuralStrain() -> Float {
        topology.structuralConstraints.reduce(Float(0)) { maximum, constraint in
            let length = simd_length(positions[constraint.b] - positions[constraint.a])
            let strain = abs(length - constraint.restLength) / max(constraint.restLength, 0.000_1)
            return max(maximum, strain)
        }
    }

    private func updateProgress(input: NowPlayingPeelSimulationInput, deltaTime: Float) {
        if input.reduceMotion {
            progress = (input.isInteracting ? input.progress : input.targetProgress).clamped01
            progressVelocity = 0
            return
        }

        if input.isInteracting {
            progress = input.progress.clamped01
            progressVelocity = input.normalizedVelocity.clamped(to: -8...8)
            return
        }

        if input.normalizedVelocity != 0 {
            progressVelocity = input.normalizedVelocity.clamped(to: -8...8)
        }

        let target = input.targetProgress.clamped01
        let displacement = progress - target
        progressVelocity += (-parameters.settleStiffness * displacement - parameters.settleDamping * progressVelocity) * deltaTime
        progress = (progress + progressVelocity * deltaTime).clamped01

        if target == 1, progress > 0.998, abs(progressVelocity) < 0.035 {
            progress = 1
            progressVelocity = 0
        } else if target == 0, progress < 0.002, abs(progressVelocity) < 0.035 {
            progress = 0
            progressVelocity = 0
        }
    }

    private func updateReleaseColumns(progress: Float) {
        if progress <= 0.002 {
            releasedColumns = Array(repeating: false, count: topology.columns)
            return
        }

        let frontX = releaseFrontX(progress: progress)
        let hysteresis = parameters.releaseHysteresis
        for column in 0..<topology.columns {
            let x = columnRestX(column)
            guard x > parameters.tackWidth else {
                releasedColumns[column] = false
                continue
            }

            if progress >= 0.995 {
                releasedColumns[column] = true
            } else if releasedColumns[column] {
                releasedColumns[column] = x >= frontX - hysteresis
            } else {
                releasedColumns[column] = x >= frontX + hysteresis
            }
        }
    }

    private func fillGoals(progress: Float, touchY: Float, reduceMotion: Bool) {
        for index in goals.indices {
            goals[index] = goalPosition(
                for: index,
                progress: progress,
                touchY: touchY,
                reduceMotion: reduceMotion
            )
        }
    }

    private func goalPosition(
        for index: Int,
        progress: Float,
        touchY: Float,
        reduceMotion: Bool
    ) -> SIMD3<Float> {
        let rest = restPositions[index]
        guard !isPinned(index) else {
            return rest
        }

        let released = isReleased(index)
        if reduceMotion {
            let free = freeProgress(x: rest.x)
            let openX = parameters.tackWidth + 0.26 * free
            let x = rest.x + (openX - rest.x) * smoothStep(progress)
            return SIMD3(x, rest.y, 0)
        }

        guard released else {
            return rest
        }

        let p = smoothStep(progress)
        let free = freeProgress(x: rest.x)
        let touchFalloff = exp(-pow((rest.y - touchY) * 3.0, 2))
        let verticalBell = sin(rest.y * .pi).clamped01
        let interaction = isInteracting ? Float(1) : 0
        let edgeLift = pow(free, 1.35)
        let openX = parameters.tackWidth + 0.020 + 0.205 * pow(free, 0.58)
        let frontBand = peelFrontBand(x: rest.x, progress: progress)
        let lowerBias = 0.62 + 0.85 * smoothStep(rest.y)
        let centerBow = verticalBell * (0.018 + 0.014 * interaction * touchFalloff) * p * pow(free, 0.82)
        let endTaper = (1 - verticalBell) * 0.020 * p * edgeLift
        let touchTug = touchFalloff * interaction * 0.026 * p * edgeLift
        let creaseBend = frontBand * 0.026 * p * (0.65 + 0.35 * verticalBell)

        let x = rest.x + (openX - rest.x) * p + centerBow - endTaper - touchTug + creaseBend
        var y = rest.y
        y += (touchY - rest.y) * p * edgeLift * touchFalloff * interaction * 0.040 * lowerBias
        y += sin((free - 0.1) * .pi) * p * (rest.y - 0.5) * 0.010

        let lift = (
            verticalBell * sin(free * .pi) * 0.034
                + frontBand * 0.032
                + edgeLift * touchFalloff * interaction * 0.046 * lowerBias
        ) * p
        let z = max(lift, 0)
        return SIMD3(x, y, z)
    }

    private func integrate(deltaTime: Float) {
        for index in positions.indices {
            previousPositions[index] = positions[index]
            guard !isPinned(index) else {
                positions[index] = restPositions[index]
                velocities[index] = .zero
                continue
            }

            let released = isReleased(index)
            let pull = released ? (0.20 + 0.22 * smoothStep(progress)) : 0.76
            velocities[index] += (goals[index] - positions[index]) * pull / max(deltaTime, 0.000_1)
            velocities[index] *= parameters.damping
            positions[index] += velocities[index] * deltaTime
            positions[index] = mix(positions[index], goals[index], t: released ? 0.12 : 0.64)
        }
    }

    private func solveConstraints(deltaTime: Float) {
        let iterations = max(parameters.solverIterations, 1)
        for _ in 0..<iterations {
            applyAnchors()
            solve(topology.structuralConstraints, deltaTime: deltaTime)
            solve(topology.shearConstraints, deltaTime: deltaTime)
            solve(topology.bendingConstraints, deltaTime: deltaTime)
            applyAnchors()
        }
    }

    private func solve(_ constraints: [NowPlayingPeelConstraint], deltaTime: Float) {
        for constraint in constraints {
            solveDistance(constraint, deltaTime: deltaTime)
        }
    }

    private func solveDistance(_ constraint: NowPlayingPeelConstraint, deltaTime: Float) {
        let weightA = inverseWeight(for: constraint.a)
        let weightB = inverseWeight(for: constraint.b)
        let weightSum = weightA + weightB
        guard weightSum > 0 else {
            return
        }

        let delta = positions[constraint.b] - positions[constraint.a]
        let length = simd_length(delta)
        guard length > 0.000_001 else {
            return
        }

        let compliance = constraint.compliance / max(deltaTime * deltaTime, 0.000_001)
        let correctionMagnitude = (length - constraint.restLength) / (weightSum + compliance)
        let correction = delta / length * correctionMagnitude
        positions[constraint.a] += correction * weightA
        positions[constraint.b] -= correction * weightB
    }

    private func applyAnchors() {
        for index in positions.indices {
            if isPinned(index) {
                positions[index] = restPositions[index]
            } else if !isReleased(index) {
                positions[index] = mix(positions[index], restPositions[index], t: 0.70)
            } else {
                positions[index] = mix(positions[index], goals[index], t: 0.035)
            }
        }
    }

    private func updateVelocities(deltaTime: Float) {
        for index in velocities.indices {
            if isPinned(index) {
                velocities[index] = .zero
            } else {
                velocities[index] = (positions[index] - previousPositions[index]) / deltaTime * parameters.damping
            }
        }
    }

    private func applyReduceMotionFrame() {
        for index in positions.indices {
            positions[index] = goals[index]
            previousPositions[index] = goals[index]
            velocities[index] = .zero
        }
        fillOutputVertices()
    }

    private func fillOutputVertices() {
        let frontX = releaseFrontX(progress: progress)
        for index in outputVertices.indices {
            let rest = restPositions[index]
            let position = positions[index]
            let lift = reduceMotion ? 0 : abs(position.z).clamped01
            let released = isReleased(index) ? Float(1) : 0
            let tack = isPinned(index) ? Float(1) : 0
            let frontBand = reduceMotion ? 0 : peelFrontBand(x: rest.x, frontX: frontX)
            let edgeBand = smoothStep(freeProgress(x: rest.x))
            let fold = (max(frontBand * 0.72, lift * 5.0) * released + edgeBand * progress * 0.08).clamped01
            outputVertices[index] = NowPlayingPeelSimulationVertex(
                position: position,
                restPosition: rest,
                uv: SIMD2(rest.x, rest.y),
                lift: lift,
                foldIntensity: fold,
                released: released,
                tack: tack
            )
        }
    }

    private func isPinned(_ index: Int) -> Bool {
        restPositions[index].x <= parameters.tackWidth
    }

    private func isReleased(_ index: Int) -> Bool {
        releasedColumns[topology.column(for: index)]
    }

    private func inverseWeight(for index: Int) -> Float {
        if isPinned(index) {
            return 0
        }

        return isReleased(index) ? 1 : 0.12
    }

    private func columnRestX(_ column: Int) -> Float {
        Float(column) / Float(topology.columns - 1)
    }

    private func freeProgress(x: Float) -> Float {
        ((x - parameters.tackWidth) / (1 - parameters.tackWidth)).clamped01
    }

    private func releaseFrontX(progress: Float) -> Float {
        1 - (1 - parameters.tackWidth) * smoothStep(progress)
    }

    private func peelFrontBand(x: Float, progress: Float) -> Float {
        peelFrontBand(x: x, frontX: releaseFrontX(progress: progress))
    }

    private func peelFrontBand(x: Float, frontX: Float) -> Float {
        (1 - smoothStep((abs(x - frontX) / 0.16).clamped01)).clamped01
    }

    private func smoothStep(_ value: Float) -> Float {
        let x = value.clamped01
        return x * x * (3 - 2 * x)
    }

    private func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, t: Float) -> SIMD3<Float> {
        a + (b - a) * t.clamped01
    }

    private static func makeRestPositions(topology: NowPlayingPeelMeshTopology) -> [SIMD3<Float>] {
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(topology.vertexCount)
        for row in 0..<topology.rows {
            for column in 0..<topology.columns {
                positions.append(topology.normalizedPosition(column: column, row: row))
            }
        }
        return positions
    }

    private static func makeOutputVertices(
        restPositions: [SIMD3<Float>],
        topology: NowPlayingPeelMeshTopology
    ) -> [NowPlayingPeelSimulationVertex] {
        restPositions.map { rest in
            NowPlayingPeelSimulationVertex(
                position: rest,
                restPosition: rest,
                uv: SIMD2(rest.x, rest.y),
                lift: 0,
                foldIntensity: 0,
                released: 0,
                tack: 0
            )
        }
    }
}
