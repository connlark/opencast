import Foundation
import OpenCastVoiceBoostC

/// Control state only, in the dB/LUFS or mean-square-energy domain, so it is portable across
/// sample rates and never replays audio. Signal state always starts fresh.
public struct VoiceBoostControlSnapshot: Sendable {
    var cSnapshot: OCVBControlSnapshot

    init(cSnapshot: OCVBControlSnapshot) {
        self.cSnapshot = cSnapshot
    }

    public var desiredGainDB: Double { cSnapshot.desiredGainDB }
    public var currentAutoGainDB: Double { cSnapshot.currentAutoGainDB }
    public var chainLossDB: Double? {
        cSnapshot.hasChainLoss == 1 ? cSnapshot.chainLossDB : nil
    }
    public var integratedInputLUFS: Double? {
        guard cSnapshot.hasIntegratedInput == 1, cSnapshot.integratedInputEnergy > 0 else {
            return nil
        }
        return -0.691 + 10 * log10(cSnapshot.integratedInputEnergy)
    }
    public var gatedBlockCount: Int { Int(cSnapshot.gatedBlockCount) }
}
