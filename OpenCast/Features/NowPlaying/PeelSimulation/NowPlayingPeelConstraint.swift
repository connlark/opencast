import Foundation

struct NowPlayingPeelConstraint: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case structural
        case shear
        case bending
    }

    var a: Int
    var b: Int
    var restLength: Float
    var compliance: Float
    var kind: Kind
}
