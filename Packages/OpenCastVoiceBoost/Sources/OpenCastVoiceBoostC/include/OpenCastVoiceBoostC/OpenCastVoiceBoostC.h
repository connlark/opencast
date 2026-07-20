#ifndef OPENCAST_VOICE_BOOST_C_H
#define OPENCAST_VOICE_BOOST_C_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct OCVBProcessor OCVBProcessor;

typedef struct {
    int32_t isEnabled;
    double targetLUFS;
    double truePeakCeilingDBTP;
    double maximumPositiveGainDB;
    double maximumNegativeGainDB;
    int32_t usesAdaptiveGain;
    int32_t usesEqualization;
    int32_t usesCompression;
    /* Compressor static curve and ballistics. The envelope is measured
       post-auto-gain (and post-EQ), so the threshold is referenced to the
       gain-staged signal per the design spec. The knee is centered on the
       threshold: reduction is exactly zero below threshold - knee/2,
       follows the ratio line above threshold + knee/2, and interpolates
       quadratically (dB domain, arithmetic only) in between. */
    double compressorThresholdDB;
    double compressorRatio;
    double compressorKneeWidthDB;
    double compressorAttackSeconds;
    double compressorReleaseSeconds;
    double compressorMaximumReductionDB;
} OCVBConfiguration;

typedef struct {
    int32_t hasEstimatedInputLUFS;
    double estimatedInputLUFS;
    int32_t hasEstimatedOutputLUFS;
    double estimatedOutputLUFS;
    double currentAutoGainDB;
    double currentCompressorReductionDB;
    double currentLimiterReductionDB;
    double maximumLimiterReductionDB;
    int32_t hasOutputTruePeakDBTP;
    double outputTruePeakDBTP;
    int32_t hasMomentaryInputLUFS;
    double momentaryInputLUFS;
    int32_t hasShortTermInputLUFS;
    double shortTermInputLUFS;
    int32_t hasIntegratedInputLUFS;
    double integratedInputLUFS;
    /* Frames of delay the processor's output path carries (the limiter
       lookahead). Constant for the life of the processor; the zero-latency
       boost-off path is the tap-level short-circuit, which never invokes the
       processor. */
    int32_t latencyFrames;
    /* Times the belt-and-braces output safety clamp fired since reset. The
       lookahead limiter's window guarantee makes this structurally zero;
       any nonzero value is an algorithm defect, not headroom management. */
    int64_t safetyClampCount;
} OCVBMetrics;

typedef struct {
    double b0;
    double b1;
    double b2;
    double a1;
    double a2;
} OCVBBiquadCoefficients;

/// BS.1770 K-weighting stage 1 (high-frequency shelving pre-filter), derived
/// analytically for any positive sample rate. Reproduces the ITU-R BS.1770
/// reference tables at 44.1 kHz and 48 kHz to well below 1e-6 per coefficient.
OCVBBiquadCoefficients OCVBLoudnessPreFilterCoefficients(double sampleRate);

/// BS.1770 K-weighting stage 2 (RLB revised low-frequency B-curve high-pass),
/// derived analytically for any positive sample rate. The numerator is fixed
/// at (1, -2, 1) per the standard's tables.
OCVBBiquadCoefficients OCVBLoudnessRLBFilterCoefficients(double sampleRate);

/// True-peak amplitude (linear, absolute) of an interleaved Float32 buffer
/// per ITU-R BS.1770-4/5 Annex 2: the order-48, 4-phase interpolating FIR,
/// evaluated at 4x for sample rates below 96 kHz and 2x (phases 0 and 2)
/// otherwise. The raw sample magnitude participates in the maximum so the
/// estimate never under-reads the sample peak, and the FIR tail is flushed
/// with zeros so peaks near the end of the buffer are measured. Non-finite
/// samples are treated as zero. This is the same kernel the runtime limiter
/// detector and output true-peak meter use.
double OCVBTruePeakAmplitudeInterleavedFloat32(
    const float *buffer,
    int32_t frameCount,
    int32_t channelCount,
    double sampleRate
);

/* Adaptation control state that survives processor recreation: everything is
   in the dB/LUFS or mean-square-energy domain, so a snapshot is portable
   across sample rates and can never replay audio. Signal state (delay lines,
   filter/FIR state, energy rings) is intentionally excluded and always starts
   fresh. */
typedef struct {
    double desiredGainDB;
    double currentAutoGainDB;
    int32_t hasIntegratedInput;
    double integratedInputEnergy;
    int32_t hasIntegratedOutput;
    double integratedOutputEnergy;
    int32_t hasChainLoss;
    double chainLossDB;
    int64_t gatedBlockCount;
} OCVBControlSnapshot;

OCVBProcessor *OCVBProcessorCreate(
    double sampleRate,
    int32_t channelCount,
    OCVBConfiguration configuration
);

void OCVBProcessorDestroy(OCVBProcessor *processor);

void OCVBProcessorReset(OCVBProcessor *processor);

void OCVBProcessorUpdateConfiguration(
    OCVBProcessor *processor,
    OCVBConfiguration configuration
);

/// Processes interleaved Float32 in place. A thin wrapper over the planar
/// engine: mono processes the caller buffer directly, stereo deinterleaves
/// tile-by-tile into the preallocated planar workspace and reinterleaves the
/// result, bit-equivalent to OCVBProcessorProcessPlanarFloat32 on the same
/// samples.
void OCVBProcessorProcessInterleavedFloat32(
    OCVBProcessor *processor,
    float *buffer,
    int32_t frameCount
);

/// Processes planar (non-interleaved) Float32 in place: channels[c] points
/// at frameCount samples for channel c, exactly channelCount pointers. This
/// is the production tap path — no marshalling copies anywhere.
void OCVBProcessorProcessPlanarFloat32(
    OCVBProcessor *processor,
    float *const *channels,
    int32_t frameCount
);

/// Test-only oracle switch: routes OCVBProcessorProcessInterleavedFloat32
/// through the retained pre-vectorization scalar implementation (its own
/// filter states and interleaved double delay rings). Set it once right
/// after creation and leave it — the two engines keep independent signal
/// state, so switching mid-stream is undefined. The planar entry point
/// always uses the vectorized engine regardless of this flag.
void OCVBProcessorSetScalarReferenceProcessing(
    OCVBProcessor *processor,
    int32_t usesScalarReference
);

OCVBMetrics OCVBProcessorCopyMetrics(const OCVBProcessor *processor);

/// Copies the adaptation control state (gains, integrated-loudness summary,
/// chain-loss EMA, gate confidence). Not synchronized: callers serialize
/// against process/update/reset externally, like every other entry point.
OCVBControlSnapshot OCVBProcessorCopyControlSnapshot(const OCVBProcessor *processor);

/// Re-seeds the adaptation control state, sanitizing each field (non-finite
/// values are ignored; gains and chain loss are clamped to the processor's
/// configured bounds). Intended for the non-realtime prepare path right
/// after creation or reset; measurement rings keep filling from scratch and
/// take over the integrated summary as fresh gated blocks land.
void OCVBProcessorApplyControlSnapshot(
    OCVBProcessor *processor,
    OCVBControlSnapshot snapshot
);

/// Current wet/dry crossfade position: 1 is fully wet, 0 is fully dry.
/// Reaches exactly 0.0/1.0 at the ramp ends, so a caller can poll for the
/// fully-drained moment. Realtime-safe (a single load).
double OCVBProcessorCurrentWetMix(const OCVBProcessor *processor);

#ifdef __cplusplus
}
#endif

#endif
