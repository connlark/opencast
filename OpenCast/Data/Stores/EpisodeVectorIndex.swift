import Accelerate
import Foundation

/// Exact cosine search over one show's line vectors: a row-major
/// `positions.count × dimension` matrix of unit rows, so a query is a single
/// matrix-vector product. A row with no vector stays zero and scores 0.
nonisolated struct EpisodeVectorIndex: Sendable {
    let dimension: Int
    let positions: [Int]
    private let matrix: [Float]

    init(dimension: Int, positions: [Int], vectors: [[Float]?]) {
        let dimension = max(0, dimension)
        var matrix = [Float](repeating: 0, count: positions.count * dimension)
        for (row, vector) in vectors.prefix(positions.count).enumerated() {
            guard let vector, vector.count == dimension, let unit = Self.unitRow(vector) else {
                continue
            }
            matrix.replaceSubrange(row * dimension..<(row + 1) * dimension, with: unit)
        }
        self.dimension = dimension
        self.positions = positions
        self.matrix = matrix
    }

    /// One similarity per row, in row order. A query of the wrong size or
    /// with a non-finite component scores every row 0.
    func similarities(_ query: [Float]) -> [Float] {
        var result = [Float](repeating: 0, count: positions.count)
        guard !positions.isEmpty, dimension > 0, query.count == dimension, query.allSatisfy(\.isFinite) else {
            return result
        }
        let rows = vDSP_Length(positions.count)
        let columns = vDSP_Length(dimension)
        matrix.withUnsafeBufferPointer { matrixBuffer in
            query.withUnsafeBufferPointer { queryBuffer in
                result.withUnsafeMutableBufferPointer { resultBuffer in
                    guard let matrixBase = matrixBuffer.baseAddress,
                          let queryBase = queryBuffer.baseAddress,
                          let resultBase = resultBuffer.baseAddress
                    else {
                        return
                    }
                    vDSP_mmul(matrixBase, 1, queryBase, 1, resultBase, 1, rows, 1, columns)
                }
            }
        }
        return result
    }

    /// Every row, most similar first, ties by position (newest first).
    func rank(_ query: [Float]) -> [EpisodeMetadataMatch] {
        zip(positions, similarities(query))
            .map { EpisodeMetadataMatch(position: $0, score: Double($1)) }
            .sorted { lhs, rhs in
                lhs.score == rhs.score ? lhs.position < rhs.position : lhs.score > rhs.score
            }
    }

    /// Rows already within rounding of unit length are stored bit for bit, so
    /// the embedder's own normalisation decides every tie; anything else is
    /// scaled to unit length, and an empty or non-finite row stays zero.
    private static func unitRow(_ vector: [Float]) -> [Float]? {
        let squaredLength = vector.reduce(0) { $0 + $1 * $1 }
        guard squaredLength.isFinite, squaredLength > 0 else {
            return nil
        }
        if abs(squaredLength - 1) <= 1e-4 {
            return vector
        }
        let length = squaredLength.squareRoot()
        return vector.map { $0 / length }
    }
}
