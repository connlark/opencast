import Foundation
import simd

struct NowPlayingPeelMeshTopology: Equatable, Sendable {
    let columns: Int
    let rows: Int
    let indices: [UInt16]
    let structuralConstraints: [NowPlayingPeelConstraint]
    let shearConstraints: [NowPlayingPeelConstraint]
    let bendingConstraints: [NowPlayingPeelConstraint]

    var vertexCount: Int {
        columns * rows
    }

    init(parameters: NowPlayingPeelSimulationParameters) {
        columns = max(parameters.columns, 3)
        rows = max(parameters.rows, 3)
        indices = Self.makeIndices(columns: columns, rows: rows)
        structuralConstraints = Self.makeStructuralConstraints(
            columns: columns,
            rows: rows,
            compliance: parameters.structuralCompliance
        )
        shearConstraints = Self.makeShearConstraints(
            columns: columns,
            rows: rows,
            compliance: parameters.shearCompliance
        )
        bendingConstraints = Self.makeBendingConstraints(
            columns: columns,
            rows: rows,
            compliance: parameters.bendingCompliance
        )
    }

    func index(column: Int, row: Int) -> Int {
        row * columns + column
    }

    func column(for index: Int) -> Int {
        index % columns
    }

    func row(for index: Int) -> Int {
        index / columns
    }

    func normalizedPosition(column: Int, row: Int) -> SIMD3<Float> {
        SIMD3(
            Float(column) / Float(columns - 1),
            Float(row) / Float(rows - 1),
            0
        )
    }

    private static func makeIndices(columns: Int, rows: Int) -> [UInt16] {
        var result: [UInt16] = []
        result.reserveCapacity((columns - 1) * (rows - 1) * 6)

        for row in 0..<(rows - 1) {
            for column in 0..<(columns - 1) {
                let topLeft = UInt16(row * columns + column)
                let topRight = UInt16(row * columns + column + 1)
                let bottomLeft = UInt16((row + 1) * columns + column)
                let bottomRight = UInt16((row + 1) * columns + column + 1)
                result.append(topLeft)
                result.append(bottomLeft)
                result.append(topRight)
                result.append(topRight)
                result.append(bottomLeft)
                result.append(bottomRight)
            }
        }

        return result
    }

    private static func makeStructuralConstraints(
        columns: Int,
        rows: Int,
        compliance: Float
    ) -> [NowPlayingPeelConstraint] {
        var constraints: [NowPlayingPeelConstraint] = []
        constraints.reserveCapacity((columns - 1) * rows + (rows - 1) * columns)

        for row in 0..<rows {
            for column in 0..<(columns - 1) {
                constraints.append(
                    makeConstraint(
                        columns: columns,
                        rows: rows,
                        aColumn: column,
                        aRow: row,
                        bColumn: column + 1,
                        bRow: row,
                        compliance: compliance,
                        kind: .structural
                    )
                )
            }
        }

        for row in 0..<(rows - 1) {
            for column in 0..<columns {
                constraints.append(
                    makeConstraint(
                        columns: columns,
                        rows: rows,
                        aColumn: column,
                        aRow: row,
                        bColumn: column,
                        bRow: row + 1,
                        compliance: compliance,
                        kind: .structural
                    )
                )
            }
        }

        return constraints
    }

    private static func makeShearConstraints(
        columns: Int,
        rows: Int,
        compliance: Float
    ) -> [NowPlayingPeelConstraint] {
        var constraints: [NowPlayingPeelConstraint] = []
        constraints.reserveCapacity((columns - 1) * (rows - 1) * 2)

        for row in 0..<(rows - 1) {
            for column in 0..<(columns - 1) {
                constraints.append(
                    makeConstraint(
                        columns: columns,
                        rows: rows,
                        aColumn: column,
                        aRow: row,
                        bColumn: column + 1,
                        bRow: row + 1,
                        compliance: compliance,
                        kind: .shear
                    )
                )
                constraints.append(
                    makeConstraint(
                        columns: columns,
                        rows: rows,
                        aColumn: column + 1,
                        aRow: row,
                        bColumn: column,
                        bRow: row + 1,
                        compliance: compliance,
                        kind: .shear
                    )
                )
            }
        }

        return constraints
    }

    private static func makeBendingConstraints(
        columns: Int,
        rows: Int,
        compliance: Float
    ) -> [NowPlayingPeelConstraint] {
        var constraints: [NowPlayingPeelConstraint] = []
        constraints.reserveCapacity(max(columns - 2, 0) * rows + max(rows - 2, 0) * columns)

        for row in 0..<rows {
            for column in 0..<(columns - 2) {
                constraints.append(
                    makeConstraint(
                        columns: columns,
                        rows: rows,
                        aColumn: column,
                        aRow: row,
                        bColumn: column + 2,
                        bRow: row,
                        compliance: compliance,
                        kind: .bending
                    )
                )
            }
        }

        for row in 0..<(rows - 2) {
            for column in 0..<columns {
                constraints.append(
                    makeConstraint(
                        columns: columns,
                        rows: rows,
                        aColumn: column,
                        aRow: row,
                        bColumn: column,
                        bRow: row + 2,
                        compliance: compliance,
                        kind: .bending
                    )
                )
            }
        }

        return constraints
    }

    private static func makeConstraint(
        columns: Int,
        rows: Int,
        aColumn: Int,
        aRow: Int,
        bColumn: Int,
        bRow: Int,
        compliance: Float,
        kind: NowPlayingPeelConstraint.Kind
    ) -> NowPlayingPeelConstraint {
        let a = aRow * columns + aColumn
        let b = bRow * columns + bColumn
        let dx = Float(bColumn - aColumn) / Float(columns - 1)
        let dy = Float(bRow - aRow) / Float(rows - 1)
        return NowPlayingPeelConstraint(
            a: a,
            b: b,
            restLength: simd_length(SIMD2(dx, dy)),
            compliance: compliance,
            kind: kind
        )
    }
}
