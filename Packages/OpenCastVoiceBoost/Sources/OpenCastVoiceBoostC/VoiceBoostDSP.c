#include <OpenCastVoiceBoostC/OpenCastVoiceBoostC.h>

#include <Accelerate/Accelerate.h>
#include <float.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#define OCVB_MAX_CHANNELS 2
#define OCVB_PI 3.14159265358979323846

/* BS.1770 gated loudness engine geometry: 100 ms sub-blocks; momentary =
   4 sub-blocks (400 ms at 75% overlap), short-term = 30 sub-blocks (3 s);
   rolling integrated window = 600 momentary energies (60 s at 100 ms hop,
   the top of the spec's 20-60 s range so full-length EBU Tech 3341 cases
   read inside tolerance). */
#define OCVB_MOMENTARY_SUB_BLOCKS 4
#define OCVB_SHORT_TERM_SUB_BLOCKS 30
#define OCVB_INTEGRATED_CAPACITY 600

#define OCVB_ABSOLUTE_GATE_LUFS (-70.0)

/* Gated momentary blocks required before the integrated estimate drives the
   full gain range; below this the +3 dB low-confidence cap applies. */
#define OCVB_CONFIDENT_GATED_BLOCKS 20
#define OCVB_LOW_CONFIDENCE_GAIN_CAP_DB 3.0

/* Auto-gain scheduling: deadband and asymmetric smoothing per the spec
   (cut 10-50 ms, rise 500 ms-2 s); the desired-gain slew bound keeps a
   jumpy early integrated estimate from producing audible gain steps. */
#define OCVB_GAIN_DEADBAND_DB 0.5
#define OCVB_GAIN_CUT_SECONDS 0.025
#define OCVB_GAIN_RISE_SECONDS 0.800
#define OCVB_DESIRED_GAIN_SLEW_DB_PER_HOP 1.2

/* True-peak lookahead limiter geometry. The delay line is sized for a 10 ms
   lookahead ceiling at the created sample rate; the working lookahead is
   5 ms. Release is a 100 ms exponential: fast enough to recover between
   speech transients without audible ducking tails, slow enough that closely
   spaced peaks ride one smooth gain contour instead of rippling it at an
   audible rate. The attack is a moving average over the sliding-window
   minimum of per-frame target gains; the margin keeps the window guarantee
   intact despite the true-peak FIR's ~6-sample group delay, so gain always
   fully reaches a peak's target before that peak leaves the delay line. */
#define OCVB_LOOKAHEAD_SECONDS 0.005
#define OCVB_MAX_LOOKAHEAD_SECONDS 0.010
#define OCVB_LIMITER_RELEASE_SECONDS 0.100
#define OCVB_LIMITER_ATTACK_MARGIN_FRAMES 16

/* Measured wet-chain loudness loss (EQ + compressor + limiter) folded back
   into the desired gain so output program loudness converges on target. */
#define OCVB_CHAIN_LOSS_SECONDS 4.0
#define OCVB_CHAIN_LOSS_MIN_DB (-2.0)
#define OCVB_CHAIN_LOSS_MAX_DB 4.0

/* Vectorized engine geometry. Process calls split into engine blocks
   (sub-block-boundary and OCVB_ENGINE_BLOCK_FRAMES bounded); sanitizing and
   metering run block-wide to amortize vDSP call overhead, while the wet
   chain runs in cache-resident tiles (48 k stereo sweep: 128 beat 64/96/
   160/256/512/1024). Delay-ring copies sub-segment internally, so the tile
   is not bound by the lookahead. The compressor's static curve (dB
   conversion + knee + dB->linear) runs at control-rate ticks with linear
   gain interpolation between ticks; the envelope itself stays per-frame.
   At 48 kHz a 32-frame tick is 0.67 ms of gain quantization against
   10/250 ms ballistics. */
#define OCVB_ENGINE_BLOCK_FRAMES 4096
#define OCVB_TILE_FRAMES 128
#define OCVB_COMPRESSOR_TICK_FRAMES 16

typedef struct {
    double b0;
    double b1;
    double b2;
    double a1;
    double a2;
    double z1;
    double z2;
} OCVBBiquad;

#define OCVB_TP_FIR_PHASES 4
#define OCVB_TP_FIR_TAPS 12

/* ITU-R BS.1770-4/5 Annex 2: one set of coefficients for the order-48,
   4-phase interpolating FIR that satisfies the true-peak measurement
   requirements. Stored transposed and tap-reversed so evaluation walks the
   sample window ascending with one load per window sample feeding all four
   phase accumulators: ocvb_true_peak_taps[i][p] is the Annex 2 table's
   phase-p coefficient at row (11 - i). */
static const double ocvb_true_peak_taps[OCVB_TP_FIR_TAPS][OCVB_TP_FIR_PHASES] = {
    { -0.0083007812500, -0.0189208984375, -0.0291748046875, 0.0017089843750 },
    { 0.0148925781250, 0.0330810546875, 0.0292968750000, 0.0109863281250 },
    { -0.0266113281250, -0.0582275390625, -0.0517578125000, -0.0196533203125 },
    { 0.0476074218750, 0.1015625000000, 0.0891113281250, 0.0332031250000 },
    { -0.1022949218750, -0.2003173828125, -0.1665039062500, -0.0594482421875 },
    { 0.9721679687500, 0.7797851562500, 0.4650878906250, 0.1373291015625 },
    { 0.1373291015625, 0.4650878906250, 0.7797851562500, 0.9721679687500 },
    { -0.0594482421875, -0.1665039062500, -0.2003173828125, -0.1022949218750 },
    { 0.0332031250000, 0.0891113281250, 0.1015625000000, 0.0476074218750 },
    { -0.0196533203125, -0.0517578125000, -0.0582275390625, -0.0266113281250 },
    { 0.0109863281250, 0.0292968750000, 0.0330810546875, 0.0148925781250 },
    { 0.0017089843750, -0.0291748046875, -0.0189208984375, -0.0083007812500 },
};

/* Largest per-phase sum of absolute coefficients (exact: the taps are
   dyadic rationals). No interpolated value can exceed this multiple of the
   largest window sample, so a caller that keeps every window sample below
   threshold / OCVB_TP_FIR_MAX_L1 may skip evaluation and use the raw
   sample magnitude without any approximation. */
#define OCVB_TP_FIR_MAX_L1 2.0228271484375

/* Streaming per-channel state for the Annex 2 FIR. Each sample is stored
   twice so the newest OCVB_TP_FIR_TAPS samples are always contiguous. */
typedef struct {
    double history[2 * OCVB_TP_FIR_TAPS];
    int32_t head;
} OCVBTruePeakState;

static void ocvb_true_peak_state_reset(OCVBTruePeakState *state) {
    memset(state->history, 0, sizeof(state->history));
    state->head = 0;
}

static inline void ocvb_true_peak_store(OCVBTruePeakState *state, double sample) {
    int32_t head = state->head;
    state->history[head] = sample;
    state->history[head + OCVB_TP_FIR_TAPS] = sample;
    state->head = head + 1 == OCVB_TP_FIR_TAPS ? 0 : head + 1;
}

/// Largest interpolated magnitude across the selected polyphase branches
/// for the most recently stored window. phaseStride 1 evaluates all four
/// phases (4x); phaseStride 2 evaluates phases 0 and 2 (2x, for >= 96 kHz).
/// The raw sample magnitude is the caller's responsibility, so the combined
/// estimate never under-reads the sample peak.
static inline double ocvb_true_peak_evaluate(
    const OCVBTruePeakState *state,
    int32_t phaseStride
) {
    int32_t base = state->head == 0 ? OCVB_TP_FIR_TAPS : state->head;
    const double *window = &state->history[base];

    if (phaseStride == 1) {
        double phase0 = 0.0;
        double phase1 = 0.0;
        double phase2 = 0.0;
        double phase3 = 0.0;
        for (int32_t tap = 0; tap < OCVB_TP_FIR_TAPS; tap += 1) {
            double sample = window[tap];
            phase0 += ocvb_true_peak_taps[tap][0] * sample;
            phase1 += ocvb_true_peak_taps[tap][1] * sample;
            phase2 += ocvb_true_peak_taps[tap][2] * sample;
            phase3 += ocvb_true_peak_taps[tap][3] * sample;
        }
        return fmax(fmax(fabs(phase0), fabs(phase1)), fmax(fabs(phase2), fabs(phase3)));
    }

    double phase0 = 0.0;
    double phase2 = 0.0;
    for (int32_t tap = 0; tap < OCVB_TP_FIR_TAPS; tap += 1) {
        double sample = window[tap];
        phase0 += ocvb_true_peak_taps[tap][0] * sample;
        phase2 += ocvb_true_peak_taps[tap][2] * sample;
    }
    return fmax(fabs(phase0), fabs(phase2));
}

static int32_t ocvb_true_peak_phase_stride(double sampleRate) {
    return sampleRate >= 96000.0 ? 2 : 1;
}

struct OCVBProcessor {
    double sampleRate;
    int32_t channelCount;
    OCVBConfiguration configuration;
    OCVBBiquad highPass[OCVB_MAX_CHANNELS];
    OCVBBiquad lowMid[OCVB_MAX_CHANNELS];
    OCVBBiquad presence[OCVB_MAX_CHANNELS];
    OCVBBiquad highShelf[OCVB_MAX_CHANNELS];
    OCVBBiquad inputPreFilter[OCVB_MAX_CHANNELS];
    OCVBBiquad inputRLBFilter[OCVB_MAX_CHANNELS];
    OCVBBiquad outputPreFilter[OCVB_MAX_CHANNELS];
    OCVBBiquad outputRLBFilter[OCVB_MAX_CHANNELS];
    double wetMix;
    double currentAutoGainDB;
    double desiredGainDB;
    double compressorAttackCoefficient;
    double compressorReleaseCoefficient;
    /* Static-curve terms derived from the configuration so the per-frame
       knee is pure arithmetic: slope = 1 - 1/ratio, and the quadratic knee
       factor slope / (2 * kneeWidth) (0 for a hard knee). */
    double compressorSlope;
    double compressorHalfKneeDB;
    double compressorKneeCurveFactor;
    double compressorEnvelopeSquared;
    double currentCompressorReductionDB;
    double currentLimiterReductionDB;
    double maximumLimiterReductionDB;
    double outputTruePeakAmplitude;
    int64_t safetyClampCount;

    /* Lookahead limiter: the wet chain writes into a preallocated delay
       ring; the output stage reads lookaheadFrames behind. The dry leg of
       the wet/dry crossfade reads the same ring so enable/disable ramps
       blend time-aligned signals. */
    int32_t lookaheadFrames;
    int32_t delayFrames;
    int32_t attackFrames;
    int32_t delayIndex;
    int64_t limiterFrameCounter;
    double *delayDry;
    double *delayWet;
    /* Monotonic deque holding the sliding minimum of per-frame target gains
       over the last lookaheadFrames + 1 frames. */
    double *minimumDequeValues;
    int64_t *minimumDequeIndices;
    int32_t minimumDequeHead;
    int32_t minimumDequeCount;
    int32_t minimumDequeCapacity;
    /* Moving-average attack smoother over the release-shaped gain. */
    double *attackRing;
    int32_t attackIndex;
    double attackSum;
    double limiterReleaseAlpha;
    double releasedGain;
    /* While quiescent the whole gain pipeline is provably at exact unity
       (every window target 1.0, release fully recovered, attack ring
       saturated), so the deque/release/average work is skipped without
       approximation. settleCountdown counts the attack-length run of
       exactly-unity release frames needed before re-entering quiescence. */
    int32_t limiterQuiescent;
    int32_t limiterSettleCountdown;
    int32_t truePeakPhaseStride;
    /* FIR evaluation gates: while a countdown is zero, every sample in the
       corresponding window is provably too small for the interpolation to
       cross the relevant bound (the L1-norm argument above), so evaluation
       is skipped exactly. */
    int32_t detectorHotCountdown;
    int32_t meterHotCountdown;
    OCVBTruePeakState detectorState[OCVB_MAX_CHANNELS];
    OCVBTruePeakState outputMeterState[OCVB_MAX_CHANNELS];

    double absoluteGateEnergy;
    double chainLossAlpha;

    int32_t subBlockFrames;
    int32_t subBlockFill;
    double inputSubBlockEnergy;
    double outputSubBlockEnergy;
    double inputSubBlocks[OCVB_SHORT_TERM_SUB_BLOCKS];
    double outputSubBlocks[OCVB_SHORT_TERM_SUB_BLOCKS];
    int32_t subBlockHead;
    int64_t subBlockCount;

    double integratedInputEnergies[OCVB_INTEGRATED_CAPACITY];
    double integratedOutputEnergies[OCVB_INTEGRATED_CAPACITY];
    double integratedGainEnergies[OCVB_INTEGRATED_CAPACITY];
    int32_t integratedHead;
    int32_t integratedCount;
    int64_t gatedBlockCount;

    double chainLossDB;
    int32_t hasChainLoss;

    double momentaryInputEnergy;
    int32_t hasMomentaryInput;
    double shortTermInputEnergy;
    int32_t hasShortTermInput;
    double bootstrapInputEnergy;
    int32_t hasBootstrapInput;
    double integratedInputEnergy;
    int32_t hasIntegratedInput;
    double integratedOutputEnergy;
    int32_t hasIntegratedOutput;

    /* ---- Vectorized planar engine ----
       The production path processes planar float32 tiles through vDSP with
       double-precision coefficients (meter biquads stay double end to end).
       The per-frame scalar implementation above is retained,
       selectable via usesScalarReference, as the permanent test oracle; it
       keeps its own interleaved double delay rings and filter states, so an
       instance must use one path consistently from creation. */
    int32_t usesScalarReference;
    int32_t tileFrames;
    /* 5D precision decisions, each measured (all IIR kernel variants cost
       the same within noise, so precision was chosen on numerics alone):
       the signal EQ cascade (HPF + 3 sections) and the K-weighting meters
       (pre + RLB) both filter in double. A float32 EQ experiment cost the
       same and pushed the no-compression oracle null from ~1e-6 to ~7e-4
       (float coefficient quantization at the 70 Hz high-pass pole); a
       float-meter experiment likewise bought no time for ~1e-4 LU drift.
       Samples convert float->double->float around the double cascades. */
    vDSP_biquad_SetupD eqSetup;
    double eqDelay[OCVB_MAX_CHANNELS][2 * 4 + 2];
    vDSP_biquad_SetupD meterSetup;
    double inputMeterDelay[OCVB_MAX_CHANNELS][2 * 2 + 2];
    double outputMeterDelay[OCVB_MAX_CHANNELS][2 * 2 + 2];
    /* Planar float delay rings (delayFrames each); delayIndex above is the
       shared cursor (only one engine path ever runs per instance). */
    float *ringDry[OCVB_MAX_CHANNELS];
    float *ringWet[OCVB_MAX_CHANNELS];
    /* True-peak FIR history: the 11 samples preceding the current tile,
       plus the running magnitude maximum of that history for the exact
       chunk-granular evaluation gates. */
    float tpDetectorHistory[OCVB_MAX_CHANNELS][OCVB_TP_FIR_TAPS - 1];
    float tpMeterHistory[OCVB_MAX_CHANNELS][OCVB_TP_FIR_TAPS - 1];
    float tpDetectorHistoryMax;
    float tpMeterHistoryMax;
    /* Annex 2 taps regrouped per phase in window-ascending order — the
       correlation kernels for vDSP_conv. Dyadic rationals, exact in float. */
    float truePeakPhaseTaps[OCVB_TP_FIR_PHASES][OCVB_TP_FIR_TAPS];
    /* Compressor gain at the last control tick (linear), interpolation
       anchor for the next tick segment. */
    double compressorTickGain;
    /* Tile workspace, all preallocated at create. */
    float *vectorFloatBlock;
    double *vectorDoubleBlock;
    float *wsStage[OCVB_MAX_CHANNELS];      /* interleaved-wrapper staging */
    float *wsWet[OCVB_MAX_CHANNELS];
    float *wsDelayedDry[OCVB_MAX_CHANNELS];
    float *wsDelayedWet[OCVB_MAX_CHANNELS];
    float *wsExt;                           /* FIR history + tile */
    float *wsPhase;                         /* one polyphase conv output */
    float *wsFrameMax;                      /* per-frame detector magnitude */
    float *wsGain;                          /* per-frame gain ramp */
    double *wsTargetGain;
    double *wsMeterIn;                      /* tile doubles, meter convert/filter */
    double *wsMeterOut;
    double *wsEqIn;                         /* tile doubles, EQ convert/filter */
    double *wsEqOut;
};

static double ocvb_clamp(double value, double lowerBound, double upperBound) {
    if (value < lowerBound) {
        return lowerBound;
    }
    if (value > upperBound) {
        return upperBound;
    }
    return value;
}

static double ocvb_db_to_linear(double db) {
    return pow(10.0, db / 20.0);
}

static double ocvb_amplitude_to_db(double amplitude) {
    if (amplitude <= DBL_MIN) {
        return -INFINITY;
    }
    return 20.0 * log10(amplitude);
}

static double ocvb_mean_square_to_lufs(double meanSquare) {
    if (meanSquare <= DBL_MIN) {
        return -INFINITY;
    }
    return -0.691 + 10.0 * log10(meanSquare);
}

static double ocvb_sanitize_sample(float sample) {
    if (!isfinite(sample)) {
        return 0.0;
    }
    return ocvb_clamp((double)sample, -4.0, 4.0);
}

static void ocvb_biquad_set_identity(OCVBBiquad *filter) {
    filter->b0 = 1.0;
    filter->b1 = 0.0;
    filter->b2 = 0.0;
    filter->a1 = 0.0;
    filter->a2 = 0.0;
    filter->z1 = 0.0;
    filter->z2 = 0.0;
}

static void ocvb_biquad_normalize(
    OCVBBiquad *filter,
    double b0,
    double b1,
    double b2,
    double a0,
    double a1,
    double a2
) {
    if (fabs(a0) <= DBL_MIN) {
        ocvb_biquad_set_identity(filter);
        return;
    }

    filter->b0 = b0 / a0;
    filter->b1 = b1 / a0;
    filter->b2 = b2 / a0;
    filter->a1 = a1 / a0;
    filter->a2 = a2 / a0;
    filter->z1 = 0.0;
    filter->z2 = 0.0;
}

static void ocvb_biquad_set_coefficients(OCVBBiquad *filter, OCVBBiquadCoefficients coefficients) {
    filter->b0 = coefficients.b0;
    filter->b1 = coefficients.b1;
    filter->b2 = coefficients.b2;
    filter->a1 = coefficients.a1;
    filter->a2 = coefficients.a2;
    filter->z1 = 0.0;
    filter->z2 = 0.0;
}

static void ocvb_biquad_set_high_pass(
    OCVBBiquad *filter,
    double sampleRate,
    double frequency,
    double q
) {
    double w0 = 2.0 * OCVB_PI * frequency / sampleRate;
    double cosW0 = cos(w0);
    double sinW0 = sin(w0);
    double alpha = sinW0 / (2.0 * q);
    double b0 = (1.0 + cosW0) * 0.5;
    double b1 = -(1.0 + cosW0);
    double b2 = (1.0 + cosW0) * 0.5;
    double a0 = 1.0 + alpha;
    double a1 = -2.0 * cosW0;
    double a2 = 1.0 - alpha;
    ocvb_biquad_normalize(filter, b0, b1, b2, a0, a1, a2);
}

static void ocvb_biquad_set_peaking(
    OCVBBiquad *filter,
    double sampleRate,
    double frequency,
    double q,
    double gainDB
) {
    double a = pow(10.0, gainDB / 40.0);
    double w0 = 2.0 * OCVB_PI * frequency / sampleRate;
    double cosW0 = cos(w0);
    double sinW0 = sin(w0);
    double alpha = sinW0 / (2.0 * q);
    double b0 = 1.0 + alpha * a;
    double b1 = -2.0 * cosW0;
    double b2 = 1.0 - alpha * a;
    double a0 = 1.0 + alpha / a;
    double a1 = -2.0 * cosW0;
    double a2 = 1.0 - alpha / a;
    ocvb_biquad_normalize(filter, b0, b1, b2, a0, a1, a2);
}

static void ocvb_biquad_set_high_shelf(
    OCVBBiquad *filter,
    double sampleRate,
    double frequency,
    double gainDB
) {
    double a = pow(10.0, gainDB / 40.0);
    double w0 = 2.0 * OCVB_PI * frequency / sampleRate;
    double cosW0 = cos(w0);
    double sinW0 = sin(w0);
    double sqrtA = sqrt(a);
    double alpha = sinW0 / sqrt(2.0);
    double b0 = a * ((a + 1.0) + (a - 1.0) * cosW0 + 2.0 * sqrtA * alpha);
    double b1 = -2.0 * a * ((a - 1.0) + (a + 1.0) * cosW0);
    double b2 = a * ((a + 1.0) + (a - 1.0) * cosW0 - 2.0 * sqrtA * alpha);
    double a0 = (a + 1.0) - (a - 1.0) * cosW0 + 2.0 * sqrtA * alpha;
    double a1 = 2.0 * ((a - 1.0) - (a + 1.0) * cosW0);
    double a2 = (a + 1.0) - (a - 1.0) * cosW0 - 2.0 * sqrtA * alpha;
    ocvb_biquad_normalize(filter, b0, b1, b2, a0, a1, a2);
}

OCVBBiquadCoefficients OCVBLoudnessPreFilterCoefficients(double sampleRate) {
    OCVBBiquadCoefficients coefficients = {1.0, 0.0, 0.0, 0.0, 0.0};
    if (!isfinite(sampleRate) || sampleRate <= 0.0) {
        return coefficients;
    }

    /* Analog prototype parameters of the BS.1770 stage-1 shelving filter;
       this bilinear redesign reproduces the standard's 44.1/48 kHz tables
       to <= 4e-13 per coefficient. */
    const double frequency = 1681.9744509555319;
    const double gainDB = 3.999843853973347;
    const double q = 0.7071752369554196;
    const double shelfBandExponent = 0.4996667741545416;

    double k = tan(OCVB_PI * frequency / sampleRate);
    double vh = pow(10.0, gainDB / 20.0);
    double vb = pow(vh, shelfBandExponent);
    double a0 = 1.0 + k / q + k * k;

    coefficients.b0 = (vh + vb * k / q + k * k) / a0;
    coefficients.b1 = 2.0 * (k * k - vh) / a0;
    coefficients.b2 = (vh - vb * k / q + k * k) / a0;
    coefficients.a1 = 2.0 * (k * k - 1.0) / a0;
    coefficients.a2 = (1.0 - k / q + k * k) / a0;
    return coefficients;
}

OCVBBiquadCoefficients OCVBLoudnessRLBFilterCoefficients(double sampleRate) {
    OCVBBiquadCoefficients coefficients = {1.0, 0.0, 0.0, 0.0, 0.0};
    if (!isfinite(sampleRate) || sampleRate <= 0.0) {
        return coefficients;
    }

    const double frequency = 38.13547087602444;
    const double q = 0.5003270373238773;

    double k = tan(OCVB_PI * frequency / sampleRate);
    double a0 = 1.0 + k / q + k * k;

    coefficients.b0 = 1.0;
    coefficients.b1 = -2.0;
    coefficients.b2 = 1.0;
    coefficients.a1 = 2.0 * (k * k - 1.0) / a0;
    coefficients.a2 = (1.0 - k / q + k * k) / a0;
    return coefficients;
}

static double ocvb_biquad_process(OCVBBiquad *filter, double input) {
    double output = filter->b0 * input + filter->z1;
    filter->z1 = filter->b1 * input - filter->a1 * output + filter->z2;
    filter->z2 = filter->b2 * input - filter->a2 * output;
    return output;
}

static void ocvb_configure_filters(OCVBProcessor *processor) {
    OCVBBiquadCoefficients preFilter = OCVBLoudnessPreFilterCoefficients(processor->sampleRate);
    OCVBBiquadCoefficients rlbFilter = OCVBLoudnessRLBFilterCoefficients(processor->sampleRate);
    for (int32_t channel = 0; channel < processor->channelCount; channel += 1) {
        ocvb_biquad_set_high_pass(&processor->highPass[channel], processor->sampleRate, 70.0, 0.707);
        ocvb_biquad_set_peaking(&processor->lowMid[channel], processor->sampleRate, 260.0, 1.0, -1.25);
        ocvb_biquad_set_peaking(&processor->presence[channel], processor->sampleRate, 3000.0, 0.85, 1.25);
        ocvb_biquad_set_high_shelf(&processor->highShelf[channel], processor->sampleRate, 6500.0, 0.75);
        ocvb_biquad_set_coefficients(&processor->inputPreFilter[channel], preFilter);
        ocvb_biquad_set_coefficients(&processor->inputRLBFilter[channel], rlbFilter);
        ocvb_biquad_set_coefficients(&processor->outputPreFilter[channel], preFilter);
        ocvb_biquad_set_coefficients(&processor->outputRLBFilter[channel], rlbFilter);
    }
}

static void ocvb_biquad_clear_state(OCVBBiquad *filter) {
    filter->z1 = 0.0;
    filter->z2 = 0.0;
}

static void ocvb_reset_filter_state(OCVBProcessor *processor) {
    for (int32_t channel = 0; channel < processor->channelCount; channel += 1) {
        ocvb_biquad_clear_state(&processor->highPass[channel]);
        ocvb_biquad_clear_state(&processor->lowMid[channel]);
        ocvb_biquad_clear_state(&processor->presence[channel]);
        ocvb_biquad_clear_state(&processor->highShelf[channel]);
        ocvb_biquad_clear_state(&processor->inputPreFilter[channel]);
        ocvb_biquad_clear_state(&processor->inputRLBFilter[channel]);
        ocvb_biquad_clear_state(&processor->outputPreFilter[channel]);
        ocvb_biquad_clear_state(&processor->outputRLBFilter[channel]);
    }
}

static void ocvb_reset_limiter_state(OCVBProcessor *processor) {
    memset(
        processor->delayDry,
        0,
        (size_t)processor->delayFrames * (size_t)processor->channelCount * sizeof(double)
    );
    memset(
        processor->delayWet,
        0,
        (size_t)processor->delayFrames * (size_t)processor->channelCount * sizeof(double)
    );
    processor->delayIndex = 0;
    processor->limiterFrameCounter = 0;
    processor->minimumDequeHead = 0;
    processor->minimumDequeCount = 0;
    for (int32_t frame = 0; frame < processor->attackFrames; frame += 1) {
        processor->attackRing[frame] = 1.0;
    }
    processor->attackIndex = 0;
    processor->attackSum = (double)processor->attackFrames;
    processor->releasedGain = 1.0;
    processor->limiterQuiescent = 1;
    processor->limiterSettleCountdown = processor->attackFrames;
    processor->maximumLimiterReductionDB = 0.0;
    processor->safetyClampCount = 0;
    processor->detectorHotCountdown = 0;
    processor->meterHotCountdown = 0;
    for (int32_t channel = 0; channel < processor->channelCount; channel += 1) {
        ocvb_true_peak_state_reset(&processor->detectorState[channel]);
        ocvb_true_peak_state_reset(&processor->outputMeterState[channel]);
    }
}

static void ocvb_reset_vector_state(OCVBProcessor *processor) {
    for (int32_t channel = 0; channel < processor->channelCount; channel += 1) {
        memset(processor->ringDry[channel], 0, (size_t)processor->delayFrames * sizeof(float));
        memset(processor->ringWet[channel], 0, (size_t)processor->delayFrames * sizeof(float));
    }
    memset(processor->eqDelay, 0, sizeof(processor->eqDelay));
    memset(processor->inputMeterDelay, 0, sizeof(processor->inputMeterDelay));
    memset(processor->outputMeterDelay, 0, sizeof(processor->outputMeterDelay));
    memset(processor->tpDetectorHistory, 0, sizeof(processor->tpDetectorHistory));
    memset(processor->tpMeterHistory, 0, sizeof(processor->tpMeterHistory));
    processor->tpDetectorHistoryMax = 0.0f;
    processor->tpMeterHistoryMax = 0.0f;
    processor->compressorTickGain = 1.0;
}

static void ocvb_reset_loudness_state(OCVBProcessor *processor) {
    processor->subBlockFill = 0;
    processor->inputSubBlockEnergy = 0.0;
    processor->outputSubBlockEnergy = 0.0;
    processor->subBlockHead = 0;
    processor->subBlockCount = 0;
    processor->integratedHead = 0;
    processor->integratedCount = 0;
    processor->gatedBlockCount = 0;
    processor->chainLossDB = 0.0;
    processor->hasChainLoss = 0;
    processor->momentaryInputEnergy = 0.0;
    processor->hasMomentaryInput = 0;
    processor->shortTermInputEnergy = 0.0;
    processor->hasShortTermInput = 0;
    processor->bootstrapInputEnergy = 0.0;
    processor->hasBootstrapInput = 0;
    processor->integratedInputEnergy = 0.0;
    processor->hasIntegratedInput = 0;
    processor->integratedOutputEnergy = 0.0;
    processor->hasIntegratedOutput = 0;
}

static void ocvb_reset_state(OCVBProcessor *processor) {
    processor->wetMix = processor->configuration.isEnabled ? 1.0 : 0.0;
    processor->currentAutoGainDB = 0.0;
    processor->desiredGainDB = 0.0;
    processor->compressorEnvelopeSquared = 0.0;
    processor->currentCompressorReductionDB = 0.0;
    processor->currentLimiterReductionDB = 0.0;
    processor->outputTruePeakAmplitude = 0.0;
    ocvb_reset_loudness_state(processor);
    ocvb_reset_filter_state(processor);
    ocvb_reset_limiter_state(processor);
    ocvb_reset_vector_state(processor);
}

static OCVBConfiguration ocvb_sanitized_configuration(OCVBConfiguration configuration) {
    if (!isfinite(configuration.targetLUFS)) {
        configuration.targetLUFS = -14.0;
    }
    if (!isfinite(configuration.truePeakCeilingDBTP) || configuration.truePeakCeilingDBTP > -0.1) {
        configuration.truePeakCeilingDBTP = -1.0;
    }
    if (!isfinite(configuration.maximumPositiveGainDB) || configuration.maximumPositiveGainDB < 0.0) {
        configuration.maximumPositiveGainDB = 12.0;
    }
    if (!isfinite(configuration.maximumNegativeGainDB) || configuration.maximumNegativeGainDB > 0.0) {
        configuration.maximumNegativeGainDB = -10.0;
    }
    configuration.maximumPositiveGainDB = ocvb_clamp(configuration.maximumPositiveGainDB, 0.0, 24.0);
    configuration.maximumNegativeGainDB = ocvb_clamp(configuration.maximumNegativeGainDB, -24.0, 0.0);
    if (!isfinite(configuration.compressorThresholdDB)) {
        configuration.compressorThresholdDB = -20.0;
    }
    if (!isfinite(configuration.compressorRatio) || configuration.compressorRatio < 1.0) {
        configuration.compressorRatio = 1.35;
    }
    if (!isfinite(configuration.compressorKneeWidthDB) || configuration.compressorKneeWidthDB < 0.0) {
        configuration.compressorKneeWidthDB = 6.0;
    }
    if (!isfinite(configuration.compressorAttackSeconds) || configuration.compressorAttackSeconds <= 0.0) {
        configuration.compressorAttackSeconds = 0.010;
    }
    if (!isfinite(configuration.compressorReleaseSeconds) || configuration.compressorReleaseSeconds <= 0.0) {
        configuration.compressorReleaseSeconds = 0.250;
    }
    if (!isfinite(configuration.compressorMaximumReductionDB)
        || configuration.compressorMaximumReductionDB < 0.0) {
        configuration.compressorMaximumReductionDB = 5.0;
    }
    configuration.compressorThresholdDB = ocvb_clamp(configuration.compressorThresholdDB, -60.0, 0.0);
    configuration.compressorRatio = ocvb_clamp(configuration.compressorRatio, 1.0, 20.0);
    configuration.compressorKneeWidthDB = ocvb_clamp(configuration.compressorKneeWidthDB, 0.0, 24.0);
    configuration.compressorAttackSeconds = ocvb_clamp(configuration.compressorAttackSeconds, 0.0005, 1.0);
    configuration.compressorReleaseSeconds = ocvb_clamp(configuration.compressorReleaseSeconds, 0.010, 5.0);
    configuration.compressorMaximumReductionDB =
        ocvb_clamp(configuration.compressorMaximumReductionDB, 0.0, 24.0);
    return configuration;
}

static void ocvb_configure_compressor(OCVBProcessor *processor) {
    const OCVBConfiguration *configuration = &processor->configuration;
    processor->compressorAttackCoefficient =
        exp(-1.0 / (configuration->compressorAttackSeconds * processor->sampleRate));
    processor->compressorReleaseCoefficient =
        exp(-1.0 / (configuration->compressorReleaseSeconds * processor->sampleRate));
    processor->compressorSlope = 1.0 - 1.0 / configuration->compressorRatio;
    processor->compressorHalfKneeDB = 0.5 * configuration->compressorKneeWidthDB;
    processor->compressorKneeCurveFactor = configuration->compressorKneeWidthDB > 0.0
        ? processor->compressorSlope / (2.0 * configuration->compressorKneeWidthDB)
        : 0.0;
}

OCVBProcessor *OCVBProcessorCreate(
    double sampleRate,
    int32_t channelCount,
    OCVBConfiguration configuration
) {
    if (!isfinite(sampleRate) || sampleRate < 8000.0 || channelCount < 1 || channelCount > OCVB_MAX_CHANNELS) {
        return NULL;
    }

    OCVBProcessor *processor = (OCVBProcessor *)calloc(1, sizeof(OCVBProcessor));
    if (processor == NULL) {
        return NULL;
    }

    processor->sampleRate = sampleRate;
    processor->channelCount = channelCount;
    processor->configuration = ocvb_sanitized_configuration(configuration);
    ocvb_configure_compressor(processor);
    processor->absoluteGateEnergy = pow(10.0, (OCVB_ABSOLUTE_GATE_LUFS + 0.691) / 10.0);
    processor->chainLossAlpha = 1.0 - exp(-0.1 / OCVB_CHAIN_LOSS_SECONDS);
    processor->subBlockFrames = (int32_t)ceil(0.1 * sampleRate);

    processor->lookaheadFrames = (int32_t)ceil(OCVB_LOOKAHEAD_SECONDS * sampleRate);
    processor->delayFrames = (int32_t)ceil(OCVB_MAX_LOOKAHEAD_SECONDS * sampleRate);
    processor->attackFrames = processor->lookaheadFrames > OCVB_LIMITER_ATTACK_MARGIN_FRAMES + 1
        ? processor->lookaheadFrames - OCVB_LIMITER_ATTACK_MARGIN_FRAMES
        : 1;
    processor->minimumDequeCapacity = processor->lookaheadFrames + 2;
    processor->limiterReleaseAlpha = 1.0 - exp(-1.0 / (OCVB_LIMITER_RELEASE_SECONDS * sampleRate));
    processor->truePeakPhaseStride = ocvb_true_peak_phase_stride(sampleRate);

    /* One preallocated block for every lookahead-sized buffer; the process
       path never allocates. All carved regions are 8-byte elements. */
    size_t delaySamples = (size_t)processor->delayFrames * (size_t)channelCount;
    size_t limiterElements = 2 * delaySamples
        + (size_t)processor->minimumDequeCapacity * 2
        + (size_t)processor->attackFrames;
    double *limiterBlock = (double *)calloc(limiterElements, sizeof(double));
    if (limiterBlock == NULL) {
        free(processor);
        return NULL;
    }
    processor->delayDry = limiterBlock;
    processor->delayWet = limiterBlock + delaySamples;
    processor->minimumDequeValues = limiterBlock + 2 * delaySamples;
    processor->minimumDequeIndices =
        (int64_t *)(limiterBlock + 2 * delaySamples + processor->minimumDequeCapacity);
    processor->attackRing =
        limiterBlock + 2 * delaySamples + 2 * (size_t)processor->minimumDequeCapacity;

    /* Vectorized-engine allocations (create-time only; the process path
       never allocates). Block-wide arrays serve sanitize/metering/staging;
       tile-sized arrays serve the wet chain. */
    processor->tileFrames = OCVB_TILE_FRAMES;

    size_t tile = (size_t)processor->tileFrames;
    size_t block = (size_t)OCVB_ENGINE_BLOCK_FRAMES;
    size_t floatElements = 2 * (size_t)channelCount * (size_t)processor->delayFrames
        + (size_t)channelCount * block              /* wsStage */
        + 3 * (size_t)channelCount * tile           /* wsWet, wsDelayedDry, wsDelayedWet */
        + (block + OCVB_TP_FIR_TAPS - 1)            /* wsExt */
        + block                                     /* wsPhase */
        + 2 * tile;                                 /* wsFrameMax, wsGain */
    processor->vectorFloatBlock = (float *)calloc(floatElements, sizeof(float));
    processor->vectorDoubleBlock = (double *)calloc(5 * tile, sizeof(double));
    if (processor->vectorFloatBlock == NULL || processor->vectorDoubleBlock == NULL) {
        OCVBProcessorDestroy(processor);
        return NULL;
    }

    float *floatCursor = processor->vectorFloatBlock;
    for (int32_t channel = 0; channel < channelCount; channel += 1) {
        processor->ringDry[channel] = floatCursor;
        floatCursor += processor->delayFrames;
        processor->ringWet[channel] = floatCursor;
        floatCursor += processor->delayFrames;
    }
    for (int32_t channel = 0; channel < channelCount; channel += 1) {
        processor->wsStage[channel] = floatCursor;
        floatCursor += block;
        processor->wsWet[channel] = floatCursor;
        floatCursor += tile;
        processor->wsDelayedDry[channel] = floatCursor;
        floatCursor += tile;
        processor->wsDelayedWet[channel] = floatCursor;
        floatCursor += tile;
    }
    processor->wsExt = floatCursor;
    floatCursor += block + OCVB_TP_FIR_TAPS - 1;
    processor->wsPhase = floatCursor;
    floatCursor += block;
    processor->wsFrameMax = floatCursor;
    floatCursor += tile;
    processor->wsGain = floatCursor;

    processor->wsTargetGain = processor->vectorDoubleBlock;
    processor->wsMeterIn = processor->vectorDoubleBlock + tile;
    processor->wsMeterOut = processor->vectorDoubleBlock + 2 * tile;
    processor->wsEqIn = processor->vectorDoubleBlock + 3 * tile;
    processor->wsEqOut = processor->vectorDoubleBlock + 4 * tile;

    for (int32_t phase = 0; phase < OCVB_TP_FIR_PHASES; phase += 1) {
        for (int32_t tap = 0; tap < OCVB_TP_FIR_TAPS; tap += 1) {
            processor->truePeakPhaseTaps[phase][tap] = (float)ocvb_true_peak_taps[tap][phase];
        }
    }

    ocvb_configure_filters(processor);

    /* vDSP cascade setups: double-precision coefficients on both paths, the
       signal EQ filtered in float32 and the K-weighting meters in double
       (the 38 Hz RLB pole is the precision-sensitive case). */
    double eqCoefficients[4 * 5];
    const OCVBBiquad *eqSections[4] = {
        &processor->highPass[0],
        &processor->lowMid[0],
        &processor->presence[0],
        &processor->highShelf[0],
    };
    for (int32_t section = 0; section < 4; section += 1) {
        eqCoefficients[section * 5 + 0] = eqSections[section]->b0;
        eqCoefficients[section * 5 + 1] = eqSections[section]->b1;
        eqCoefficients[section * 5 + 2] = eqSections[section]->b2;
        eqCoefficients[section * 5 + 3] = eqSections[section]->a1;
        eqCoefficients[section * 5 + 4] = eqSections[section]->a2;
    }
    OCVBBiquadCoefficients meterPre = OCVBLoudnessPreFilterCoefficients(sampleRate);
    OCVBBiquadCoefficients meterRLB = OCVBLoudnessRLBFilterCoefficients(sampleRate);
    double meterCoefficients[2 * 5] = {
        meterPre.b0, meterPre.b1, meterPre.b2, meterPre.a1, meterPre.a2,
        meterRLB.b0, meterRLB.b1, meterRLB.b2, meterRLB.a1, meterRLB.a2,
    };
    processor->eqSetup = vDSP_biquad_CreateSetupD(eqCoefficients, 4);
    processor->meterSetup = vDSP_biquad_CreateSetupD(meterCoefficients, 2);
    if (processor->eqSetup == NULL || processor->meterSetup == NULL) {
        OCVBProcessorDestroy(processor);
        return NULL;
    }

    ocvb_reset_state(processor);
    return processor;
}

void OCVBProcessorDestroy(OCVBProcessor *processor) {
    if (processor == NULL) {
        return;
    }
    if (processor->eqSetup != NULL) {
        vDSP_biquad_DestroySetupD(processor->eqSetup);
    }
    if (processor->meterSetup != NULL) {
        vDSP_biquad_DestroySetupD(processor->meterSetup);
    }
    free(processor->vectorFloatBlock);
    free(processor->vectorDoubleBlock);
    free(processor->delayDry);
    free(processor);
}

void OCVBProcessorReset(OCVBProcessor *processor) {
    if (processor == NULL) {
        return;
    }
    ocvb_reset_state(processor);
}

void OCVBProcessorUpdateConfiguration(
    OCVBProcessor *processor,
    OCVBConfiguration configuration
) {
    if (processor == NULL) {
        return;
    }
    OCVBConfiguration sanitizedConfiguration = ocvb_sanitized_configuration(configuration);
    if (!sanitizedConfiguration.usesCompression) {
        processor->compressorEnvelopeSquared = 0.0;
        processor->currentCompressorReductionDB = 0.0;
        processor->compressorTickGain = 1.0;
    }
    if (sanitizedConfiguration.usesCompression != processor->configuration.usesCompression
        || sanitizedConfiguration.usesEqualization != processor->configuration.usesEqualization) {
        processor->chainLossDB = 0.0;
        processor->hasChainLoss = 0;
    }
    processor->configuration = sanitizedConfiguration;
    ocvb_configure_compressor(processor);
}

static double ocvb_sub_block_ring_mean(
    const double *ring,
    int32_t head,
    int64_t totalCount,
    int32_t windowLength
) {
    int64_t available = totalCount < (int64_t)windowLength ? totalCount : (int64_t)windowLength;
    if (available <= 0) {
        return 0.0;
    }

    double sum = 0.0;
    for (int64_t offset = 1; offset <= available; offset += 1) {
        int32_t index = head - (int32_t)offset;
        if (index < 0) {
            index += OCVB_SHORT_TERM_SUB_BLOCKS;
        }
        sum += ring[index];
    }
    return sum / (double)available;
}

/// Recomputes the rolling relative-gated integrated estimates and the
/// measured wet-chain loudness loss from the (absolutely gated) ring of
/// momentary energies. Bounded work: two passes over <= 600 entries.
static void ocvb_recompute_integrated(OCVBProcessor *processor) {
    int32_t count = processor->integratedCount;
    if (count <= 0) {
        return;
    }

    double inputSum = 0.0;
    double outputSum = 0.0;
    for (int32_t index = 0; index < count; index += 1) {
        inputSum += processor->integratedInputEnergies[index];
        outputSum += processor->integratedOutputEnergies[index];
    }

    /* Relative gate: -10 LU below the absolute-gated mean, i.e. one tenth
       of the mean energy. */
    double inputRelativeThreshold = (inputSum / (double)count) * 0.1;
    double outputRelativeThreshold = (outputSum / (double)count) * 0.1;

    double gatedInputSum = 0.0;
    int32_t gatedInputCount = 0;
    double expectedOutputSum = 0.0;
    double actualOutputSum = 0.0;
    double gatedOutputSum = 0.0;
    int32_t gatedOutputCount = 0;

    for (int32_t index = 0; index < count; index += 1) {
        double inputEnergy = processor->integratedInputEnergies[index];
        double outputEnergy = processor->integratedOutputEnergies[index];
        if (inputEnergy > inputRelativeThreshold) {
            gatedInputSum += inputEnergy;
            gatedInputCount += 1;
            expectedOutputSum += inputEnergy * processor->integratedGainEnergies[index];
            actualOutputSum += outputEnergy;
        }
        if (outputEnergy > outputRelativeThreshold && outputEnergy > processor->absoluteGateEnergy) {
            gatedOutputSum += outputEnergy;
            gatedOutputCount += 1;
        }
    }

    if (gatedInputCount > 0) {
        processor->integratedInputEnergy = gatedInputSum / (double)gatedInputCount;
        processor->hasIntegratedInput = 1;
    }
    if (gatedOutputCount > 0) {
        processor->integratedOutputEnergy = gatedOutputSum / (double)gatedOutputCount;
        processor->hasIntegratedOutput = 1;
    }

    /* Loudness delta between what the applied gain alone predicts and what
       actually left the chain, over the same gated window. Only sampled
       while the wet path is audible so bypass ramps do not pollute it. */
    if (processor->configuration.isEnabled
        && expectedOutputSum > DBL_MIN
        && actualOutputSum > DBL_MIN) {
        double lossDB = 10.0 * log10(expectedOutputSum / actualOutputSum);
        lossDB = ocvb_clamp(lossDB, OCVB_CHAIN_LOSS_MIN_DB, OCVB_CHAIN_LOSS_MAX_DB);
        if (!processor->hasChainLoss) {
            processor->chainLossDB = lossDB;
            processor->hasChainLoss = 1;
        } else {
            processor->chainLossDB += processor->chainLossAlpha * (lossDB - processor->chainLossDB);
        }
    }
}

/// Updates the slew-limited desired gain from the current loudness estimates.
/// Runs once per completed 100 ms sub-block. Holds (gate freeze) when no
/// estimate exists or during silence: the estimates simply do not move.
static void ocvb_update_desired_gain(OCVBProcessor *processor) {
    double rawGainDB = 0.0;

    if (processor->configuration.isEnabled && processor->configuration.usesAdaptiveGain) {
        double estimateLUFS = 0.0;
        int32_t hasEstimate = 0;

        if (processor->hasIntegratedInput) {
            estimateLUFS = ocvb_mean_square_to_lufs(processor->integratedInputEnergy);
            hasEstimate = isfinite(estimateLUFS);
        } else if (processor->hasBootstrapInput) {
            double bootstrapLUFS = ocvb_mean_square_to_lufs(processor->bootstrapInputEnergy);
            if (isfinite(bootstrapLUFS) && bootstrapLUFS > OCVB_ABSOLUTE_GATE_LUFS) {
                estimateLUFS = bootstrapLUFS;
                hasEstimate = 1;
            }
        }

        if (!hasEstimate) {
            return;
        }

        rawGainDB = processor->configuration.targetLUFS - estimateLUFS;
        if (processor->hasChainLoss) {
            rawGainDB += processor->chainLossDB;
        }
        rawGainDB = ocvb_clamp(
            rawGainDB,
            processor->configuration.maximumNegativeGainDB,
            processor->configuration.maximumPositiveGainDB
        );
        if (processor->gatedBlockCount < OCVB_CONFIDENT_GATED_BLOCKS
            && rawGainDB > OCVB_LOW_CONFIDENCE_GAIN_CAP_DB) {
            rawGainDB = OCVB_LOW_CONFIDENCE_GAIN_CAP_DB;
        }
        if (fabs(rawGainDB - processor->currentAutoGainDB) < OCVB_GAIN_DEADBAND_DB) {
            rawGainDB = processor->currentAutoGainDB;
        }
    }

    double step = ocvb_clamp(
        rawGainDB - processor->desiredGainDB,
        -OCVB_DESIRED_GAIN_SLEW_DB_PER_HOP,
        OCVB_DESIRED_GAIN_SLEW_DB_PER_HOP
    );
    processor->desiredGainDB += step;
}

static void ocvb_complete_sub_block(OCVBProcessor *processor) {
    double frameCount = (double)processor->subBlockFrames;
    double inputMeanSquare = processor->inputSubBlockEnergy / frameCount;
    double outputMeanSquare = processor->outputSubBlockEnergy / frameCount;
    processor->inputSubBlockEnergy = 0.0;
    processor->outputSubBlockEnergy = 0.0;
    processor->subBlockFill = 0;

    processor->inputSubBlocks[processor->subBlockHead] = inputMeanSquare;
    processor->outputSubBlocks[processor->subBlockHead] = outputMeanSquare;
    processor->subBlockHead = (processor->subBlockHead + 1) % OCVB_SHORT_TERM_SUB_BLOCKS;
    processor->subBlockCount += 1;

    processor->bootstrapInputEnergy = ocvb_sub_block_ring_mean(
        processor->inputSubBlocks,
        processor->subBlockHead,
        processor->subBlockCount,
        OCVB_SHORT_TERM_SUB_BLOCKS
    );
    processor->hasBootstrapInput = processor->bootstrapInputEnergy > DBL_MIN;

    if (processor->subBlockCount >= OCVB_SHORT_TERM_SUB_BLOCKS) {
        processor->shortTermInputEnergy = processor->bootstrapInputEnergy;
        processor->hasShortTermInput = processor->shortTermInputEnergy > DBL_MIN;
    }

    if (processor->subBlockCount < OCVB_MOMENTARY_SUB_BLOCKS) {
        ocvb_update_desired_gain(processor);
        return;
    }

    double momentaryInput = ocvb_sub_block_ring_mean(
        processor->inputSubBlocks,
        processor->subBlockHead,
        processor->subBlockCount,
        OCVB_MOMENTARY_SUB_BLOCKS
    );
    double momentaryOutput = ocvb_sub_block_ring_mean(
        processor->outputSubBlocks,
        processor->subBlockHead,
        processor->subBlockCount,
        OCVB_MOMENTARY_SUB_BLOCKS
    );

    processor->momentaryInputEnergy = momentaryInput;
    processor->hasMomentaryInput = momentaryInput > DBL_MIN;

    if (momentaryInput > processor->absoluteGateEnergy) {
        processor->integratedInputEnergies[processor->integratedHead] = momentaryInput;
        processor->integratedOutputEnergies[processor->integratedHead] = momentaryOutput;
        processor->integratedGainEnergies[processor->integratedHead] =
            pow(10.0, processor->currentAutoGainDB / 10.0);
        processor->integratedHead = (processor->integratedHead + 1) % OCVB_INTEGRATED_CAPACITY;
        if (processor->integratedCount < OCVB_INTEGRATED_CAPACITY) {
            processor->integratedCount += 1;
        }
        processor->gatedBlockCount += 1;
        ocvb_recompute_integrated(processor);
    }

    ocvb_update_desired_gain(processor);
}

static void ocvb_smooth_auto_gain(OCVBProcessor *processor, int32_t frameCount) {
    double duration = (double)frameCount / processor->sampleRate;
    double timeConstant = processor->desiredGainDB < processor->currentAutoGainDB
        ? OCVB_GAIN_CUT_SECONDS
        : OCVB_GAIN_RISE_SECONDS;
    double alpha = 1.0 - exp(-duration / timeConstant);
    processor->currentAutoGainDB += alpha * (processor->desiredGainDB - processor->currentAutoGainDB);
}

/// Processes one chunk that never crosses a 100 ms sub-block boundary.
/// Accumulates per-call maxima into the pointer arguments.
static void ocvb_process_chunk(
    OCVBProcessor *processor,
    float *buffer,
    int32_t frameCount,
    double *maximumCompressorReduction,
    double *minimumLimiterGain,
    double *maximumTruePeak
) {
    int32_t channelCount = processor->channelCount;
    int32_t usesCompression = processor->configuration.usesCompression;
    double chunkEnergy = 0.0;

    for (int32_t frame = 0; frame < frameCount; frame += 1) {
        for (int32_t channel = 0; channel < channelCount; channel += 1) {
            int64_t index = ((int64_t)frame * channelCount) + channel;
            double sample = ocvb_sanitize_sample(buffer[index]);
            buffer[index] = (float)sample;
            double weighted = ocvb_biquad_process(&processor->inputPreFilter[channel], sample);
            weighted = ocvb_biquad_process(&processor->inputRLBFilter[channel], weighted);
            chunkEnergy += weighted * weighted;
        }
    }
    processor->inputSubBlockEnergy += chunkEnergy;

    ocvb_smooth_auto_gain(processor, frameCount);

    double targetWetMix = processor->configuration.isEnabled ? 1.0 : 0.0;
    double wetStep = 1.0 / fmax(1.0, 0.050 * processor->sampleRate);
    double autoGain = ocvb_db_to_linear(processor->currentAutoGainDB);
    /* The limiter honors the configured ceiling exactly: no hidden headroom
       scaling anywhere. The safety threshold's relative epsilon only absorbs
       last-bit rounding in the gain arithmetic. */
    double ceiling = ocvb_db_to_linear(processor->configuration.truePeakCeilingDBTP);
    double safetyThreshold = ceiling * (1.0 + 1e-9);
    double detectorSkipThreshold = ceiling / OCVB_TP_FIR_MAX_L1;
    int32_t lookaheadFrames = processor->lookaheadFrames;
    int32_t phaseStride = processor->truePeakPhaseStride;

    for (int32_t frame = 0; frame < frameCount; frame += 1) {
        if (processor->wetMix < targetWetMix) {
            processor->wetMix = fmin(targetWetMix, processor->wetMix + wetStep);
        } else if (processor->wetMix > targetWetMix) {
            processor->wetMix = fmax(targetWetMix, processor->wetMix - wetStep);
        }

        double dryValues[OCVB_MAX_CHANNELS] = {0.0, 0.0};
        double wetValues[OCVB_MAX_CHANNELS] = {0.0, 0.0};
        double frameDetector = 0.0;

        for (int32_t channel = 0; channel < channelCount; channel += 1) {
            int64_t index = ((int64_t)frame * channelCount) + channel;
            double dry = ocvb_sanitize_sample(buffer[index]);
            double wet = dry;
            if (processor->configuration.usesEqualization) {
                wet = ocvb_biquad_process(&processor->highPass[channel], wet);
            }
            wet *= autoGain;
            if (processor->configuration.usesEqualization) {
                wet = ocvb_biquad_process(&processor->lowMid[channel], wet);
                wet = ocvb_biquad_process(&processor->presence[channel], wet);
                wet = ocvb_biquad_process(&processor->highShelf[channel], wet);
            }
            dryValues[channel] = dry;
            wetValues[channel] = wet;
            frameDetector = fmax(frameDetector, wet * wet);
        }

        double compressorReductionDB = 0.0;
        double compressorGain = 1.0;
        if (usesCompression) {
            double envelopeCoefficient = frameDetector > processor->compressorEnvelopeSquared
                ? processor->compressorAttackCoefficient
                : processor->compressorReleaseCoefficient;
            processor->compressorEnvelopeSquared =
                envelopeCoefficient * processor->compressorEnvelopeSquared
                + (1.0 - envelopeCoefficient) * frameDetector;

            /* Soft-knee static curve in the dB domain: exact unity below
               threshold - knee/2, quadratic through the knee, the ratio
               line above threshold + knee/2. Arithmetic only on top of the
               one existing envelope dB conversion. */
            double envelopeDB = ocvb_mean_square_to_lufs(processor->compressorEnvelopeSquared) + 0.691;
            double compressorOverDB = envelopeDB - processor->configuration.compressorThresholdDB;
            if (compressorOverDB > processor->compressorHalfKneeDB) {
                compressorReductionDB = processor->compressorSlope * compressorOverDB;
            } else if (compressorOverDB > -processor->compressorHalfKneeDB) {
                double kneeInputDB = compressorOverDB + processor->compressorHalfKneeDB;
                compressorReductionDB =
                    processor->compressorKneeCurveFactor * kneeInputDB * kneeInputDB;
            }
            if (compressorReductionDB > processor->configuration.compressorMaximumReductionDB) {
                compressorReductionDB = processor->configuration.compressorMaximumReductionDB;
            }
            compressorGain = ocvb_db_to_linear(-compressorReductionDB);
            *maximumCompressorReduction = fmax(*maximumCompressorReduction, compressorReductionDB);
        }

        /* True-peak detection on the pre-limiter wet signal. One target gain
           across channels preserves the stereo image. Evaluation is skipped
           while the whole window provably interpolates below the ceiling. */
        double detectorPeak = 0.0;
        for (int32_t channel = 0; channel < channelCount; channel += 1) {
            wetValues[channel] *= compressorGain;
            ocvb_true_peak_store(&processor->detectorState[channel], wetValues[channel]);
            detectorPeak = fmax(detectorPeak, fabs(wetValues[channel]));
        }
        if (detectorPeak > detectorSkipThreshold) {
            processor->detectorHotCountdown = OCVB_TP_FIR_TAPS;
        }
        if (processor->detectorHotCountdown > 0) {
            processor->detectorHotCountdown -= 1;
            for (int32_t channel = 0; channel < channelCount; channel += 1) {
                detectorPeak = fmax(detectorPeak, ocvb_true_peak_evaluate(
                    &processor->detectorState[channel],
                    phaseStride
                ));
            }
        }

        double targetGain = detectorPeak > ceiling ? ceiling / detectorPeak : 1.0;

        int64_t frameIndex = processor->limiterFrameCounter;
        processor->limiterFrameCounter = frameIndex + 1;

        double limiterGain = 1.0;
        if (!processor->limiterQuiescent || targetGain < 1.0) {
            processor->limiterQuiescent = 0;

            /* Sliding minimum over the last lookaheadFrames + 1 targets: the
               gain applied when a peak leaves the delay line is bounded by
               that peak's own target (the deque window plus attack margin
               covers the detector's group delay). Frames elided while
               quiescent were all exactly 1.0, so an empty deque loses
               nothing. */
            int32_t dequeCapacity = processor->minimumDequeCapacity;
            while (processor->minimumDequeCount > 0) {
                int32_t backSlot = processor->minimumDequeHead + processor->minimumDequeCount - 1;
                backSlot = backSlot >= dequeCapacity ? backSlot - dequeCapacity : backSlot;
                if (processor->minimumDequeValues[backSlot] < targetGain) {
                    break;
                }
                processor->minimumDequeCount -= 1;
            }
            int32_t pushSlot = processor->minimumDequeHead + processor->minimumDequeCount;
            pushSlot = pushSlot >= dequeCapacity ? pushSlot - dequeCapacity : pushSlot;
            processor->minimumDequeValues[pushSlot] = targetGain;
            processor->minimumDequeIndices[pushSlot] = frameIndex;
            processor->minimumDequeCount += 1;
            while (processor->minimumDequeIndices[processor->minimumDequeHead]
                   <= frameIndex - (int64_t)(lookaheadFrames + 1)) {
                processor->minimumDequeHead += 1;
                if (processor->minimumDequeHead == dequeCapacity) {
                    processor->minimumDequeHead = 0;
                }
                processor->minimumDequeCount -= 1;
            }
            double windowMinimumGain = processor->minimumDequeValues[processor->minimumDequeHead];

            /* Instant cut toward the window minimum, exponential recovery.
               Fully recovered release snaps to exact unity (the residual is
               under a millionth of a decibel) so the pipeline can settle
               back into the quiescent fast path. */
            if (windowMinimumGain < processor->releasedGain) {
                processor->releasedGain = windowMinimumGain;
            } else {
                processor->releasedGain +=
                    processor->limiterReleaseAlpha * (windowMinimumGain - processor->releasedGain);
            }
            if (windowMinimumGain >= 1.0 && 1.0 - processor->releasedGain < 1e-7) {
                processor->releasedGain = 1.0;
            }

            /* Moving-average attack shaping; the running sum is recomputed
               on every ring wrap to bound floating-point drift. */
            processor->attackSum += processor->releasedGain - processor->attackRing[processor->attackIndex];
            processor->attackRing[processor->attackIndex] = processor->releasedGain;
            processor->attackIndex += 1;
            if (processor->attackIndex == processor->attackFrames) {
                processor->attackIndex = 0;
                double exactSum = 0.0;
                for (int32_t slot = 0; slot < processor->attackFrames; slot += 1) {
                    exactSum += processor->attackRing[slot];
                }
                processor->attackSum = exactSum;
            }
            limiterGain = processor->attackSum / (double)processor->attackFrames;
            if (limiterGain > 1.0) {
                limiterGain = 1.0;
            }
            *minimumLimiterGain = fmin(*minimumLimiterGain, limiterGain);

            if (processor->releasedGain >= 1.0) {
                processor->limiterSettleCountdown -= 1;
                if (processor->limiterSettleCountdown <= 0) {
                    /* The attack ring now holds an unbroken run of exact
                       unity, so the pipeline output is exactly 1.0. */
                    processor->limiterQuiescent = 1;
                    processor->limiterSettleCountdown = processor->attackFrames;
                    processor->minimumDequeHead = 0;
                    processor->minimumDequeCount = 0;
                    processor->attackSum = (double)processor->attackFrames;
                }
            } else {
                processor->limiterSettleCountdown = processor->attackFrames;
            }
        }

        int32_t readIndex = processor->delayIndex - lookaheadFrames;
        if (readIndex < 0) {
            readIndex += processor->delayFrames;
        }

        double outputFramePeak = 0.0;
        for (int32_t channel = 0; channel < channelCount; channel += 1) {
            int64_t index = ((int64_t)frame * channelCount) + channel;
            int64_t writeOffset = ((int64_t)processor->delayIndex * channelCount) + channel;
            int64_t readOffset = ((int64_t)readIndex * channelCount) + channel;
            double delayedDry = processor->delayDry[readOffset];
            double delayedWet = processor->delayWet[readOffset];
            processor->delayDry[writeOffset] = dryValues[channel];
            processor->delayWet[writeOffset] = wetValues[channel];

            double limited = delayedWet * limiterGain;
            double output = delayedDry * (1.0 - processor->wetMix) + limited * processor->wetMix;

            /* Belt and braces only: because the detector never under-reads
               the sample peak, the lookahead guarantee keeps the fully wet
               output at or under the ceiling. During crossfades the dry leg
               legitimately carries whatever the source carries. */
            if (processor->wetMix >= 1.0 && fabs(output) > safetyThreshold) {
                output = copysign(ceiling, output);
                processor->safetyClampCount += 1;
            }
            if (!isfinite(output)) {
                output = 0.0;
                processor->safetyClampCount += 1;
            }

            ocvb_true_peak_store(&processor->outputMeterState[channel], output);
            outputFramePeak = fmax(outputFramePeak, fabs(output));
            buffer[index] = (float)output;

            double weighted = ocvb_biquad_process(&processor->outputPreFilter[channel], output);
            weighted = ocvb_biquad_process(&processor->outputRLBFilter[channel], weighted);
            processor->outputSubBlockEnergy += weighted * weighted;
        }

        /* Output true-peak metering through the same FIR; evaluation is
           skipped while the whole window provably cannot exceed the running
           per-call maximum. */
        if (outputFramePeak * OCVB_TP_FIR_MAX_L1 > *maximumTruePeak) {
            processor->meterHotCountdown = OCVB_TP_FIR_TAPS;
        }
        *maximumTruePeak = fmax(*maximumTruePeak, outputFramePeak);
        if (processor->meterHotCountdown > 0) {
            processor->meterHotCountdown -= 1;
            for (int32_t channel = 0; channel < channelCount; channel += 1) {
                *maximumTruePeak = fmax(*maximumTruePeak, ocvb_true_peak_evaluate(
                    &processor->outputMeterState[channel],
                    phaseStride
                ));
            }
        }

        processor->delayIndex += 1;
        if (processor->delayIndex == processor->delayFrames) {
            processor->delayIndex = 0;
        }
    }

    processor->subBlockFill += frameCount;
    if (processor->subBlockFill >= processor->subBlockFrames) {
        ocvb_complete_sub_block(processor);
    }
}

/* ==================== Vectorized planar engine =============================
   Stage-structured tile processing (planar float32 through vDSP, double
   coefficients everywhere, double samples on the meter path) that reproduces
   the scalar reference implementation above: identical control decisions and
   gating outcomes, with floating-point drift bounded by the oracle null
   tests. Each exactness argument lives with its stage below. */

static inline void ocvb_ring_read(
    const float *ring,
    int32_t ringFrames,
    int32_t start,
    float *destination,
    int32_t frameCount
) {
    int32_t first = ringFrames - start;
    if (first > frameCount) {
        first = frameCount;
    }
    memcpy(destination, ring + start, (size_t)first * sizeof(float));
    if (first < frameCount) {
        memcpy(destination + first, ring, (size_t)(frameCount - first) * sizeof(float));
    }
}

static inline void ocvb_ring_write(
    float *ring,
    int32_t ringFrames,
    int32_t start,
    const float *source,
    int32_t frameCount
) {
    int32_t first = ringFrames - start;
    if (first > frameCount) {
        first = frameCount;
    }
    memcpy(ring + start, source, (size_t)first * sizeof(float));
    if (first < frameCount) {
        memcpy(ring, source + first, (size_t)(frameCount - first) * sizeof(float));
    }
}

/// Shifts the newest frameCount samples into an 11-sample FIR history and
/// returns its refreshed magnitude maximum — the carry term that keeps the
/// chunk-granular evaluation gates exact for windows straddling a tile
/// boundary.
static inline float ocvb_tp_history_update(
    float *history,
    const float *samples,
    int32_t frameCount
) {
    const int32_t historyLength = OCVB_TP_FIR_TAPS - 1;
    if (frameCount >= historyLength) {
        memcpy(
            history,
            samples + frameCount - historyLength,
            (size_t)historyLength * sizeof(float)
        );
    } else {
        memmove(
            history,
            history + frameCount,
            (size_t)(historyLength - frameCount) * sizeof(float)
        );
        memcpy(
            history + historyLength - frameCount,
            samples,
            (size_t)frameCount * sizeof(float)
        );
    }
    float maximum = 0.0f;
    for (int32_t index = 0; index < historyLength; index += 1) {
        float magnitude = fabsf(history[index]);
        if (magnitude > maximum) {
            maximum = magnitude;
        }
    }
    return maximum;
}

/// The compressor's static curve — the same soft-knee formulas as the scalar
/// reference, evaluated once per control tick instead of per frame.
static inline double ocvb_compressor_tick_gain(
    OCVBProcessor *processor,
    double envelopeSquared,
    double *maximumCompressorReduction
) {
    double compressorReductionDB = 0.0;
    double envelopeDB = ocvb_mean_square_to_lufs(envelopeSquared) + 0.691;
    double compressorOverDB = envelopeDB - processor->configuration.compressorThresholdDB;
    if (compressorOverDB > processor->compressorHalfKneeDB) {
        compressorReductionDB = processor->compressorSlope * compressorOverDB;
    } else if (compressorOverDB > -processor->compressorHalfKneeDB) {
        double kneeInputDB = compressorOverDB + processor->compressorHalfKneeDB;
        compressorReductionDB =
            processor->compressorKneeCurveFactor * kneeInputDB * kneeInputDB;
    }
    if (compressorReductionDB > processor->configuration.compressorMaximumReductionDB) {
        compressorReductionDB = processor->configuration.compressorMaximumReductionDB;
    }
    *maximumCompressorReduction = fmax(*maximumCompressorReduction, compressorReductionDB);
    return ocvb_db_to_linear(-compressorReductionDB);
}

/// The limiter gain pipeline (sliding-minimum deque, release, moving-average
/// attack, quiescence bookkeeping), frame by frame — a verbatim port of the
/// scalar reference loop with the detector factored out into targetGains.
/// NULL targetGains means every target is exactly 1.0.
static void ocvb_limiter_gains_scalar(
    OCVBProcessor *processor,
    const double *targetGains,
    int32_t frameCount,
    float *gainsOut,
    double *minimumLimiterGain
) {
    int32_t lookaheadFrames = processor->lookaheadFrames;
    int32_t dequeCapacity = processor->minimumDequeCapacity;

    for (int32_t frame = 0; frame < frameCount; frame += 1) {
        double targetGain = targetGains != NULL ? targetGains[frame] : 1.0;
        int64_t frameIndex = processor->limiterFrameCounter;
        processor->limiterFrameCounter = frameIndex + 1;

        double limiterGain = 1.0;
        if (!processor->limiterQuiescent || targetGain < 1.0) {
            processor->limiterQuiescent = 0;

            while (processor->minimumDequeCount > 0) {
                int32_t backSlot = processor->minimumDequeHead + processor->minimumDequeCount - 1;
                backSlot = backSlot >= dequeCapacity ? backSlot - dequeCapacity : backSlot;
                if (processor->minimumDequeValues[backSlot] < targetGain) {
                    break;
                }
                processor->minimumDequeCount -= 1;
            }
            int32_t pushSlot = processor->minimumDequeHead + processor->minimumDequeCount;
            pushSlot = pushSlot >= dequeCapacity ? pushSlot - dequeCapacity : pushSlot;
            processor->minimumDequeValues[pushSlot] = targetGain;
            processor->minimumDequeIndices[pushSlot] = frameIndex;
            processor->minimumDequeCount += 1;
            while (processor->minimumDequeIndices[processor->minimumDequeHead]
                   <= frameIndex - (int64_t)(lookaheadFrames + 1)) {
                processor->minimumDequeHead += 1;
                if (processor->minimumDequeHead == dequeCapacity) {
                    processor->minimumDequeHead = 0;
                }
                processor->minimumDequeCount -= 1;
            }
            double windowMinimumGain = processor->minimumDequeValues[processor->minimumDequeHead];

            if (windowMinimumGain < processor->releasedGain) {
                processor->releasedGain = windowMinimumGain;
            } else {
                processor->releasedGain +=
                    processor->limiterReleaseAlpha * (windowMinimumGain - processor->releasedGain);
            }
            if (windowMinimumGain >= 1.0 && 1.0 - processor->releasedGain < 1e-7) {
                processor->releasedGain = 1.0;
            }

            processor->attackSum += processor->releasedGain - processor->attackRing[processor->attackIndex];
            processor->attackRing[processor->attackIndex] = processor->releasedGain;
            processor->attackIndex += 1;
            if (processor->attackIndex == processor->attackFrames) {
                processor->attackIndex = 0;
                double exactSum = 0.0;
                for (int32_t slot = 0; slot < processor->attackFrames; slot += 1) {
                    exactSum += processor->attackRing[slot];
                }
                processor->attackSum = exactSum;
            }
            limiterGain = processor->attackSum / (double)processor->attackFrames;
            if (limiterGain > 1.0) {
                limiterGain = 1.0;
            }
            *minimumLimiterGain = fmin(*minimumLimiterGain, limiterGain);

            if (processor->releasedGain >= 1.0) {
                processor->limiterSettleCountdown -= 1;
                if (processor->limiterSettleCountdown <= 0) {
                    processor->limiterQuiescent = 1;
                    processor->limiterSettleCountdown = processor->attackFrames;
                    processor->minimumDequeHead = 0;
                    processor->minimumDequeCount = 0;
                    processor->attackSum = (double)processor->attackFrames;
                }
            } else {
                processor->limiterSettleCountdown = processor->attackFrames;
            }
        }
        gainsOut[frame] = (float)limiterGain;
    }
}

/// Processes one tile (1...tileFrames frames, never crossing a 100 ms
/// sub-block boundary) in place through per-channel pointers. The whole
/// stage sequence runs per tile so a tile's working set stays cache-hot
/// from sanitize through output metering (measured faster than block-wide
/// stage passes).
static void ocvb_process_tile_vectorized(
    OCVBProcessor *processor,
    float *const *channels,
    int32_t frameCount,
    double autoGainLinear,
    double *maximumCompressorReduction,
    double *minimumLimiterGain,
    double *maximumTruePeak
) {
    int32_t channelCount = processor->channelCount;
    vDSP_Length n = (vDSP_Length)frameCount;

    /* Sanitize in place, scalar: the one stage that must be NaN-robust
       (vDSP propagates NaN). The fast path is a read and one compare —
       NaN fails the magnitude test, so only non-finite or out-of-range
       samples take the store, and ocvb_sanitize_sample keeps the fixup
       bit-identical to the reference for those. */
    for (int32_t channel = 0; channel < channelCount; channel += 1) {
        float *data = channels[channel];
        for (int32_t frame = 0; frame < frameCount; frame += 1) {
            float sample = data[frame];
            if (!(fabsf(sample) <= 4.0f)) {
                data[frame] = (float)ocvb_sanitize_sample(sample);
            }
        }
    }

    /* Input K-weighted metering, double end to end like the reference. */
    for (int32_t channel = 0; channel < channelCount; channel += 1) {
        vDSP_vspdp(channels[channel], 1, processor->wsMeterIn, 1, n);
        vDSP_biquadD(
            processor->meterSetup,
            processor->inputMeterDelay[channel],
            processor->wsMeterIn, 1,
            processor->wsMeterOut, 1,
            n
        );
        double energy = 0.0;
        vDSP_svesqD(processor->wsMeterOut, 1, &energy, n);
        processor->inputSubBlockEnergy += energy;
    }

    /* Wet chain: EQ cascade (float32 samples, double coefficients), then
       the chunk-constant auto gain. Gain commutes with the LTI cascade, so
       gain-after-EQ matches the reference's HPF -> gain -> EQ order to
       floating-point drift. An exactly-unity gain multiplies bit-exactly,
       which the limiterOnly null-transparency contract relies on. When the
       compressor runs, the auto gain folds into its interpolated gain ramp
       (one combined multiply); the envelope detector then reads the
       pre-gain wet with autoGain^2 folded into the energy, the same values
       to floating-point drift. */
    for (int32_t channel = 0; channel < channelCount; channel += 1) {
        if (processor->configuration.usesEqualization) {
            vDSP_vspdp(channels[channel], 1, processor->wsEqIn, 1, n);
            vDSP_biquadD(
                processor->eqSetup,
                processor->eqDelay[channel],
                processor->wsEqIn, 1,
                processor->wsEqOut, 1,
                n
            );
            vDSP_vdpsp(processor->wsEqOut, 1, processor->wsWet[channel], 1, n);
        } else {
            memcpy(
                processor->wsWet[channel],
                channels[channel],
                (size_t)frameCount * sizeof(float)
            );
        }
    }

    /* Compressor (D9 closed): the envelope EMA stays per frame in the
       energy domain — multiplies and compares only — while the static
       curve's transcendentals run at control-rate ticks with linear gain
       interpolation across each tick segment. */
    if (processor->configuration.usesCompression) {
        const float *wetLeft = processor->wsWet[0];
        const float *wetRight = channelCount > 1 ? processor->wsWet[1] : NULL;
        double envelope = processor->compressorEnvelopeSquared;
        double attackCoefficient = processor->compressorAttackCoefficient;
        double releaseCoefficient = processor->compressorReleaseCoefficient;
        double autoGainSquared = autoGainLinear * autoGainLinear;
        double previousGain = processor->compressorTickGain;
        int32_t segmentStart = 0;

        for (int32_t frame = 0; frame < frameCount; frame += 1) {
            double left = wetLeft[frame];
            double detector = left * left;
            if (wetRight != NULL) {
                double right = wetRight[frame];
                double rightSquared = right * right;
                if (rightSquared > detector) {
                    detector = rightSquared;
                }
            }
            detector *= autoGainSquared;
            double coefficient = detector > envelope ? attackCoefficient : releaseCoefficient;
            envelope = coefficient * envelope + (1.0 - coefficient) * detector;

            int32_t segmentLength = frame - segmentStart + 1;
            if (segmentLength == OCVB_COMPRESSOR_TICK_FRAMES || frame == frameCount - 1) {
                double tickGain = ocvb_compressor_tick_gain(
                    processor,
                    envelope,
                    maximumCompressorReduction
                );
                double gainStep = (tickGain - previousGain) / (double)segmentLength;
                double gain = previousGain;
                for (int32_t index = segmentStart; index <= frame; index += 1) {
                    gain += gainStep;
                    processor->wsGain[index] = (float)(gain * autoGainLinear);
                }
                previousGain = tickGain;
                segmentStart = frame + 1;
            }
        }
        processor->compressorEnvelopeSquared = envelope;
        processor->compressorTickGain = previousGain;

        for (int32_t channel = 0; channel < channelCount; channel += 1) {
            vDSP_vmul(processor->wsWet[channel], 1, processor->wsGain, 1, processor->wsWet[channel], 1, n);
        }
    } else {
        float autoGainFloat = (float)autoGainLinear;
        for (int32_t channel = 0; channel < channelCount; channel += 1) {
            vDSP_vsmul(processor->wsWet[channel], 1, &autoGainFloat, processor->wsWet[channel], 1, n);
        }
    }

    /* True-peak limiter detection, chunk-granular. The L1 gate stays exact
       in both directions: when every sample of every window this tile
       touches (tile plus carried 11-sample history) is below ceiling / L1,
       no interpolated peak can cross the ceiling and every target gain is
       exactly 1; when the gate opens, evaluating frames the per-frame gate
       would have skipped cannot change any target either, because those
       windows still bound the interpolation below the ceiling. */
    double ceiling = ocvb_db_to_linear(processor->configuration.truePeakCeilingDBTP);
    double detectorSkipThreshold = ceiling / OCVB_TP_FIR_MAX_L1;
    int32_t phaseStride = processor->truePeakPhaseStride;

    float wetRawMax = 0.0f;
    for (int32_t channel = 0; channel < channelCount; channel += 1) {
        float channelMax = 0.0f;
        vDSP_maxmgv(processor->wsWet[channel], 1, &channelMax, n);
        if (channelMax > wetRawMax) {
            wetRawMax = channelMax;
        }
    }

    int32_t detectorHot = (double)wetRawMax > detectorSkipThreshold
        || (double)processor->tpDetectorHistoryMax > detectorSkipThreshold;
    int32_t anyBelowUnity = 0;
    if (detectorHot) {
        if (channelCount > 1) {
            vDSP_vmaxmg(processor->wsWet[0], 1, processor->wsWet[1], 1, processor->wsFrameMax, 1, n);
        } else {
            vDSP_vabs(processor->wsWet[0], 1, processor->wsFrameMax, 1, n);
        }
        for (int32_t channel = 0; channel < channelCount; channel += 1) {
            memcpy(
                processor->wsExt,
                processor->tpDetectorHistory[channel],
                (OCVB_TP_FIR_TAPS - 1) * sizeof(float)
            );
            memcpy(
                processor->wsExt + OCVB_TP_FIR_TAPS - 1,
                processor->wsWet[channel],
                (size_t)frameCount * sizeof(float)
            );
            for (int32_t phase = 0; phase < OCVB_TP_FIR_PHASES; phase += phaseStride) {
                vDSP_conv(
                    processor->wsExt, 1,
                    processor->truePeakPhaseTaps[phase], 1,
                    processor->wsPhase, 1,
                    n,
                    OCVB_TP_FIR_TAPS
                );
                vDSP_vmaxmg(processor->wsPhase, 1, processor->wsFrameMax, 1, processor->wsFrameMax, 1, n);
            }
        }
        for (int32_t frame = 0; frame < frameCount; frame += 1) {
            double detectorPeak = processor->wsFrameMax[frame];
            double targetGain = 1.0;
            if (detectorPeak > ceiling) {
                targetGain = ceiling / detectorPeak;
                anyBelowUnity = 1;
            }
            processor->wsTargetGain[frame] = targetGain;
        }
    }

    {
        float historyMax = 0.0f;
        for (int32_t channel = 0; channel < channelCount; channel += 1) {
            float channelHistoryMax = ocvb_tp_history_update(
                processor->tpDetectorHistory[channel],
                processor->wsWet[channel],
                frameCount
            );
            if (channelHistoryMax > historyMax) {
                historyMax = channelHistoryMax;
            }
        }
        processor->tpDetectorHistoryMax = historyMax;
    }

    /* Limiter gains: skipped exactly while the pipeline is quiescent with
       all-unity targets (the same per-frame condition the reference
       evaluates); otherwise the data-dependent scalar machinery runs. */
    int32_t limiterRan = 0;
    if (!processor->limiterQuiescent || anyBelowUnity) {
        ocvb_limiter_gains_scalar(
            processor,
            detectorHot ? processor->wsTargetGain : NULL,
            frameCount,
            processor->wsGain,
            minimumLimiterGain
        );
        limiterRan = 1;
    } else {
        processor->limiterFrameCounter += frameCount;
    }

    /* Delay line, sub-segmented so a tile may exceed the lookahead: within
       each segment (<= lookahead and <= delayFrames - lookahead frames) the
       read range cannot overlap the write range, and across segments the
       ordering is exactly right — segment k+1's delayed read returns what
       segment k just wrote, the samples from lookahead frames earlier.
       Reads precede writes inside a segment, and the whole stage runs
       before the output stage overwrites the caller buffer (the dry
       source). The delayed-dry leg is only consumed while the wet mix is
       away from steady fully-wet, so its read is skipped otherwise. */
    double targetWetMix = processor->configuration.isEnabled ? 1.0 : 0.0;
    int32_t needsDelayedDry = !(processor->wetMix == 1.0 && targetWetMix == 1.0);
    {
        int32_t segmentCap = processor->delayFrames - processor->lookaheadFrames;
        if (processor->lookaheadFrames < segmentCap) {
            segmentCap = processor->lookaheadFrames;
        }
        if (segmentCap < 1) {
            segmentCap = 1;
        }
        int32_t segmentStart = 0;
        while (segmentStart < frameCount) {
            int32_t remaining = frameCount - segmentStart;
            int32_t segmentFrames = remaining < segmentCap ? remaining : segmentCap;
            int32_t writeIndex = (processor->delayIndex + segmentStart) % processor->delayFrames;
            int32_t readIndex = writeIndex - processor->lookaheadFrames;
            if (readIndex < 0) {
                readIndex += processor->delayFrames;
            }
            for (int32_t channel = 0; channel < channelCount; channel += 1) {
                if (needsDelayedDry) {
                    ocvb_ring_read(
                        processor->ringDry[channel],
                        processor->delayFrames,
                        readIndex,
                        processor->wsDelayedDry[channel] + segmentStart,
                        segmentFrames
                    );
                }
                ocvb_ring_read(
                    processor->ringWet[channel],
                    processor->delayFrames,
                    readIndex,
                    processor->wsDelayedWet[channel] + segmentStart,
                    segmentFrames
                );
                ocvb_ring_write(
                    processor->ringDry[channel],
                    processor->delayFrames,
                    writeIndex,
                    channels[channel] + segmentStart,
                    segmentFrames
                );
                ocvb_ring_write(
                    processor->ringWet[channel],
                    processor->delayFrames,
                    writeIndex,
                    processor->wsWet[channel] + segmentStart,
                    segmentFrames
                );
            }
            segmentStart += segmentFrames;
        }
        processor->delayIndex = (processor->delayIndex + frameCount) % processor->delayFrames;
    }

    /* Output stage. Steady fully-wet and steady dry are vectorized; a
       wet-mix ramp in flight (C-level enable/disable, ~60-80 ms per toggle)
       blends scalar per frame with the reference semantics. */
    double safetyThreshold = ceiling * (1.0 + 1e-9);
    if (processor->wetMix == targetWetMix && targetWetMix == 1.0) {
        for (int32_t channel = 0; channel < channelCount; channel += 1) {
            if (limiterRan) {
                vDSP_vmul(
                    processor->wsDelayedWet[channel], 1,
                    processor->wsGain, 1,
                    channels[channel], 1,
                    n
                );
            } else {
                memcpy(
                    channels[channel],
                    processor->wsDelayedWet[channel],
                    (size_t)frameCount * sizeof(float)
                );
            }
        }
        /* Belt-and-braces clamp, chunk-gated: the scalar scan runs only
           when the tile's magnitude maximum crosses the safety threshold
           or reads non-finite (NaN poisons maxmgv, so a poisoned tile also
           lands in the scan). The wet path is structurally finite after
           sanitize, so this matches the reference's per-frame dead-code
           checks in every reachable case. */
        for (int32_t channel = 0; channel < channelCount; channel += 1) {
            float outputMax = 0.0f;
            vDSP_maxmgv(channels[channel], 1, &outputMax, n);
            if ((double)outputMax > safetyThreshold || !isfinite(outputMax)) {
                float *data = channels[channel];
                for (int32_t frame = 0; frame < frameCount; frame += 1) {
                    double output = data[frame];
                    if (fabs(output) > safetyThreshold) {
                        output = copysign(ceiling, output);
                        processor->safetyClampCount += 1;
                    }
                    if (!isfinite(output)) {
                        output = 0.0;
                        processor->safetyClampCount += 1;
                    }
                    data[frame] = (float)output;
                }
            }
        }
    } else if (processor->wetMix == targetWetMix) {
        /* Steady disabled: bit-identical delayed dry (the C-level disabled
           invariant), byte copies of sanitized floats. */
        for (int32_t channel = 0; channel < channelCount; channel += 1) {
            memcpy(
                channels[channel],
                processor->wsDelayedDry[channel],
                (size_t)frameCount * sizeof(float)
            );
        }
    } else {
        double wetStep = 1.0 / fmax(1.0, 0.050 * processor->sampleRate);
        for (int32_t frame = 0; frame < frameCount; frame += 1) {
            if (processor->wetMix < targetWetMix) {
                processor->wetMix = fmin(targetWetMix, processor->wetMix + wetStep);
            } else if (processor->wetMix > targetWetMix) {
                processor->wetMix = fmax(targetWetMix, processor->wetMix - wetStep);
            }
            double limiterGain = limiterRan ? (double)processor->wsGain[frame] : 1.0;
            for (int32_t channel = 0; channel < channelCount; channel += 1) {
                double delayedDry = processor->wsDelayedDry[channel][frame];
                double limited = (double)processor->wsDelayedWet[channel][frame] * limiterGain;
                double output = delayedDry * (1.0 - processor->wetMix) + limited * processor->wetMix;
                if (processor->wetMix >= 1.0 && fabs(output) > safetyThreshold) {
                    output = copysign(ceiling, output);
                    processor->safetyClampCount += 1;
                }
                if (!isfinite(output)) {
                    output = 0.0;
                    processor->safetyClampCount += 1;
                }
                channels[channel][frame] = (float)output;
            }
        }
    }

    /* Output metering: K-weighted energy (double) plus the true-peak meter
       behind its tile-granular gate. Gating against the running maximum at
       tile start is conservative — it can only evaluate more windows than
       the reference's per-frame gate, never fewer — so the reported call
       maximum is exact. */
    float outputRawMax = 0.0f;
    for (int32_t channel = 0; channel < channelCount; channel += 1) {
        vDSP_vspdp(channels[channel], 1, processor->wsMeterIn, 1, n);
        vDSP_biquadD(
            processor->meterSetup,
            processor->outputMeterDelay[channel],
            processor->wsMeterIn, 1,
            processor->wsMeterOut, 1,
            n
        );
        double energy = 0.0;
        vDSP_svesqD(processor->wsMeterOut, 1, &energy, n);
        processor->outputSubBlockEnergy += energy;

        float channelMax = 0.0f;
        vDSP_maxmgv(channels[channel], 1, &channelMax, n);
        if (channelMax > outputRawMax) {
            outputRawMax = channelMax;
        }
    }

    double runningMaximum = *maximumTruePeak;
    int32_t meterHot = (double)outputRawMax * OCVB_TP_FIR_MAX_L1 > runningMaximum
        || (double)processor->tpMeterHistoryMax * OCVB_TP_FIR_MAX_L1 > runningMaximum;
    if ((double)outputRawMax > runningMaximum) {
        runningMaximum = outputRawMax;
    }
    if (meterHot) {
        for (int32_t channel = 0; channel < channelCount; channel += 1) {
            memcpy(
                processor->wsExt,
                processor->tpMeterHistory[channel],
                (OCVB_TP_FIR_TAPS - 1) * sizeof(float)
            );
            memcpy(
                processor->wsExt + OCVB_TP_FIR_TAPS - 1,
                channels[channel],
                (size_t)frameCount * sizeof(float)
            );
            for (int32_t phase = 0; phase < OCVB_TP_FIR_PHASES; phase += phaseStride) {
                vDSP_conv(
                    processor->wsExt, 1,
                    processor->truePeakPhaseTaps[phase], 1,
                    processor->wsPhase, 1,
                    n,
                    OCVB_TP_FIR_TAPS
                );
                float phaseMax = 0.0f;
                vDSP_maxmgv(processor->wsPhase, 1, &phaseMax, n);
                if ((double)phaseMax > runningMaximum) {
                    runningMaximum = phaseMax;
                }
            }
        }
    }
    *maximumTruePeak = runningMaximum;

    {
        float historyMax = 0.0f;
        for (int32_t channel = 0; channel < channelCount; channel += 1) {
            float channelHistoryMax = ocvb_tp_history_update(
                processor->tpMeterHistory[channel],
                channels[channel],
                frameCount
            );
            if (channelHistoryMax > historyMax) {
                historyMax = channelHistoryMax;
            }
        }
        processor->tpMeterHistoryMax = historyMax;
    }
}

/// One engine block (<= OCVB_ENGINE_BLOCK_FRAMES frames, never crossing a
/// 100 ms sub-block boundary) through the vectorized engine, planar in
/// place. Auto-gain smoothing runs once per block — the same cadence and
/// arithmetic as the scalar reference for callers delivering up to
/// OCVB_ENGINE_BLOCK_FRAMES per process call — and the resulting gain is
/// constant across the block's tiles.
static void ocvb_process_planar_chunk_vectorized(
    OCVBProcessor *processor,
    float *const *channels,
    int32_t frameOffset,
    int32_t frameCount,
    double *maximumCompressorReduction,
    double *minimumLimiterGain,
    double *maximumTruePeak
) {
    ocvb_smooth_auto_gain(processor, frameCount);
    double autoGainLinear = ocvb_db_to_linear(processor->currentAutoGainDB);

    int32_t processedFrames = 0;
    while (processedFrames < frameCount) {
        int32_t remaining = frameCount - processedFrames;
        int32_t tileFrames = remaining < processor->tileFrames ? remaining : processor->tileFrames;
        float *tileChannels[OCVB_MAX_CHANNELS];
        for (int32_t channel = 0; channel < processor->channelCount; channel += 1) {
            tileChannels[channel] = channels[channel] + frameOffset + processedFrames;
        }
        ocvb_process_tile_vectorized(
            processor,
            tileChannels,
            tileFrames,
            autoGainLinear,
            maximumCompressorReduction,
            minimumLimiterGain,
            maximumTruePeak
        );
        processedFrames += tileFrames;
    }

    processor->subBlockFill += frameCount;
    if (processor->subBlockFill >= processor->subBlockFrames) {
        ocvb_complete_sub_block(processor);
    }
}

/// Interleaved-stereo variant: deinterleaves the whole engine block once
/// into the staging workspace (vDSP_ctoz), processes planar, and
/// reinterleaves (vDSP_ztoc) — exact byte copies, so the wrapper is
/// bit-equivalent to the planar entry on the same samples.
static void ocvb_process_interleaved_chunk_vectorized(
    OCVBProcessor *processor,
    float *buffer,
    int32_t frameCount,
    double *maximumCompressorReduction,
    double *minimumLimiterGain,
    double *maximumTruePeak
) {
    DSPSplitComplex split = {processor->wsStage[0], processor->wsStage[1]};
    vDSP_ctoz((const DSPComplex *)buffer, 2, &split, 1, (vDSP_Length)frameCount);
    float *const chunkChannels[2] = {processor->wsStage[0], processor->wsStage[1]};
    ocvb_process_planar_chunk_vectorized(
        processor,
        chunkChannels,
        0,
        frameCount,
        maximumCompressorReduction,
        minimumLimiterGain,
        maximumTruePeak
    );
    vDSP_ztoc(&split, 1, (DSPComplex *)buffer, 2, (vDSP_Length)frameCount);
}

static void ocvb_store_call_metrics(
    OCVBProcessor *processor,
    double maximumCompressorReduction,
    double minimumLimiterGain,
    double maximumTruePeak
) {
    double maximumLimiterReduction = minimumLimiterGain < 1.0
        ? -ocvb_amplitude_to_db(minimumLimiterGain)
        : 0.0;
    processor->currentCompressorReductionDB = maximumCompressorReduction;
    processor->currentLimiterReductionDB = maximumLimiterReduction;
    processor->maximumLimiterReductionDB = fmax(
        processor->maximumLimiterReductionDB,
        maximumLimiterReduction
    );
    processor->outputTruePeakAmplitude = maximumTruePeak;
}

void OCVBProcessorSetScalarReferenceProcessing(
    OCVBProcessor *processor,
    int32_t usesScalarReference
) {
    if (processor == NULL) {
        return;
    }
    processor->usesScalarReference = usesScalarReference ? 1 : 0;
}

void OCVBProcessorProcessPlanarFloat32(
    OCVBProcessor *processor,
    float *const *channels,
    int32_t frameCount
) {
    if (processor == NULL || channels == NULL || frameCount <= 0) {
        return;
    }
    for (int32_t channel = 0; channel < processor->channelCount; channel += 1) {
        if (channels[channel] == NULL) {
            return;
        }
    }

    double maximumCompressorReduction = 0.0;
    double minimumLimiterGain = 1.0;
    double maximumTruePeak = 0.0;

    int32_t processedFrames = 0;
    while (processedFrames < frameCount) {
        int32_t framesToBoundary = processor->subBlockFrames - processor->subBlockFill;
        int32_t remaining = frameCount - processedFrames;
        int32_t chunkFrames = remaining < framesToBoundary ? remaining : framesToBoundary;
        if (chunkFrames > OCVB_ENGINE_BLOCK_FRAMES) {
            chunkFrames = OCVB_ENGINE_BLOCK_FRAMES;
        }
        ocvb_process_planar_chunk_vectorized(
            processor,
            channels,
            processedFrames,
            chunkFrames,
            &maximumCompressorReduction,
            &minimumLimiterGain,
            &maximumTruePeak
        );
        processedFrames += chunkFrames;
    }

    ocvb_store_call_metrics(
        processor,
        maximumCompressorReduction,
        minimumLimiterGain,
        maximumTruePeak
    );
}

void OCVBProcessorProcessInterleavedFloat32(
    OCVBProcessor *processor,
    float *buffer,
    int32_t frameCount
) {
    if (processor == NULL || buffer == NULL || frameCount <= 0) {
        return;
    }

    double maximumCompressorReduction = 0.0;
    double minimumLimiterGain = 1.0;
    double maximumTruePeak = 0.0;

    int32_t processedFrames = 0;
    while (processedFrames < frameCount) {
        int32_t framesToBoundary = processor->subBlockFrames - processor->subBlockFill;
        int32_t remaining = frameCount - processedFrames;
        int32_t chunkFrames = remaining < framesToBoundary ? remaining : framesToBoundary;
        if (!processor->usesScalarReference && chunkFrames > OCVB_ENGINE_BLOCK_FRAMES) {
            chunkFrames = OCVB_ENGINE_BLOCK_FRAMES;
        }
        if (processor->usesScalarReference) {
            ocvb_process_chunk(
                processor,
                buffer + ((int64_t)processedFrames * processor->channelCount),
                chunkFrames,
                &maximumCompressorReduction,
                &minimumLimiterGain,
                &maximumTruePeak
            );
        } else if (processor->channelCount == 1) {
            /* Mono interleaved is already planar: process the caller
               buffer in place with no staging copies. */
            float *const channels[1] = {buffer};
            ocvb_process_planar_chunk_vectorized(
                processor,
                channels,
                processedFrames,
                chunkFrames,
                &maximumCompressorReduction,
                &minimumLimiterGain,
                &maximumTruePeak
            );
        } else {
            ocvb_process_interleaved_chunk_vectorized(
                processor,
                buffer + 2 * (int64_t)processedFrames,
                chunkFrames,
                &maximumCompressorReduction,
                &minimumLimiterGain,
                &maximumTruePeak
            );
        }
        processedFrames += chunkFrames;
    }

    ocvb_store_call_metrics(
        processor,
        maximumCompressorReduction,
        minimumLimiterGain,
        maximumTruePeak
    );
}

double OCVBTruePeakAmplitudeInterleavedFloat32(
    const float *buffer,
    int32_t frameCount,
    int32_t channelCount,
    double sampleRate
) {
    if (buffer == NULL || frameCount <= 0 || channelCount <= 0) {
        return 0.0;
    }

    int32_t phaseStride = isfinite(sampleRate)
        ? ocvb_true_peak_phase_stride(sampleRate)
        : 1;
    double peak = 0.0;
    for (int32_t channel = 0; channel < channelCount; channel += 1) {
        OCVBTruePeakState state;
        ocvb_true_peak_state_reset(&state);
        for (int32_t frame = 0; frame < frameCount; frame += 1) {
            double sample = (double)buffer[((int64_t)frame * channelCount) + channel];
            if (!isfinite(sample)) {
                sample = 0.0;
            }
            ocvb_true_peak_store(&state, sample);
            peak = fmax(peak, fabs(sample));
            peak = fmax(peak, ocvb_true_peak_evaluate(&state, phaseStride));
        }
        for (int32_t flush = 0; flush < OCVB_TP_FIR_TAPS; flush += 1) {
            ocvb_true_peak_store(&state, 0.0);
            peak = fmax(peak, ocvb_true_peak_evaluate(&state, phaseStride));
        }
    }
    return peak;
}

OCVBControlSnapshot OCVBProcessorCopyControlSnapshot(const OCVBProcessor *processor) {
    OCVBControlSnapshot snapshot;
    memset(&snapshot, 0, sizeof(snapshot));

    if (processor == NULL) {
        return snapshot;
    }

    snapshot.desiredGainDB = processor->desiredGainDB;
    snapshot.currentAutoGainDB = processor->currentAutoGainDB;
    snapshot.hasIntegratedInput = processor->hasIntegratedInput;
    snapshot.integratedInputEnergy = processor->integratedInputEnergy;
    snapshot.hasIntegratedOutput = processor->hasIntegratedOutput;
    snapshot.integratedOutputEnergy = processor->integratedOutputEnergy;
    snapshot.hasChainLoss = processor->hasChainLoss;
    snapshot.chainLossDB = processor->chainLossDB;
    snapshot.gatedBlockCount = processor->gatedBlockCount;
    return snapshot;
}

void OCVBProcessorApplyControlSnapshot(
    OCVBProcessor *processor,
    OCVBControlSnapshot snapshot
) {
    if (processor == NULL) {
        return;
    }

    if (isfinite(snapshot.desiredGainDB)) {
        processor->desiredGainDB = ocvb_clamp(
            snapshot.desiredGainDB,
            processor->configuration.maximumNegativeGainDB,
            processor->configuration.maximumPositiveGainDB
        );
    }
    if (isfinite(snapshot.currentAutoGainDB)) {
        processor->currentAutoGainDB = ocvb_clamp(
            snapshot.currentAutoGainDB,
            processor->configuration.maximumNegativeGainDB,
            processor->configuration.maximumPositiveGainDB
        );
    }
    if (snapshot.hasIntegratedInput
        && isfinite(snapshot.integratedInputEnergy)
        && snapshot.integratedInputEnergy > 0.0) {
        processor->integratedInputEnergy = snapshot.integratedInputEnergy;
        processor->hasIntegratedInput = 1;
    }
    if (snapshot.hasIntegratedOutput
        && isfinite(snapshot.integratedOutputEnergy)
        && snapshot.integratedOutputEnergy > 0.0) {
        processor->integratedOutputEnergy = snapshot.integratedOutputEnergy;
        processor->hasIntegratedOutput = 1;
    }
    if (snapshot.hasChainLoss && isfinite(snapshot.chainLossDB)) {
        processor->chainLossDB = ocvb_clamp(
            snapshot.chainLossDB,
            OCVB_CHAIN_LOSS_MIN_DB,
            OCVB_CHAIN_LOSS_MAX_DB
        );
        processor->hasChainLoss = 1;
    }
    if (snapshot.gatedBlockCount > 0) {
        processor->gatedBlockCount = snapshot.gatedBlockCount;
    }
}

double OCVBProcessorCurrentWetMix(const OCVBProcessor *processor) {
    if (processor == NULL) {
        return 0.0;
    }
    return processor->wetMix;
}

OCVBMetrics OCVBProcessorCopyMetrics(const OCVBProcessor *processor) {
    OCVBMetrics metrics;
    memset(&metrics, 0, sizeof(metrics));

    if (processor == NULL) {
        return metrics;
    }

    if (processor->hasIntegratedInput) {
        metrics.estimatedInputLUFS = ocvb_mean_square_to_lufs(processor->integratedInputEnergy);
        metrics.hasEstimatedInputLUFS = isfinite(metrics.estimatedInputLUFS) ? 1 : 0;
    } else if (processor->hasBootstrapInput) {
        double bootstrapLUFS = ocvb_mean_square_to_lufs(processor->bootstrapInputEnergy);
        if (isfinite(bootstrapLUFS) && bootstrapLUFS > OCVB_ABSOLUTE_GATE_LUFS) {
            metrics.estimatedInputLUFS = bootstrapLUFS;
            metrics.hasEstimatedInputLUFS = 1;
        }
    }

    if (processor->hasIntegratedOutput) {
        metrics.estimatedOutputLUFS = ocvb_mean_square_to_lufs(processor->integratedOutputEnergy);
        metrics.hasEstimatedOutputLUFS = isfinite(metrics.estimatedOutputLUFS) ? 1 : 0;
    }

    metrics.currentAutoGainDB = processor->currentAutoGainDB;
    metrics.currentCompressorReductionDB = processor->currentCompressorReductionDB;
    metrics.currentLimiterReductionDB = processor->currentLimiterReductionDB;
    metrics.maximumLimiterReductionDB = processor->maximumLimiterReductionDB;
    metrics.hasOutputTruePeakDBTP = processor->outputTruePeakAmplitude > 0.0 ? 1 : 0;
    metrics.outputTruePeakDBTP = ocvb_amplitude_to_db(processor->outputTruePeakAmplitude);
    metrics.latencyFrames = processor->lookaheadFrames;
    metrics.safetyClampCount = processor->safetyClampCount;

    if (processor->hasMomentaryInput) {
        metrics.momentaryInputLUFS = ocvb_mean_square_to_lufs(processor->momentaryInputEnergy);
        metrics.hasMomentaryInputLUFS = isfinite(metrics.momentaryInputLUFS) ? 1 : 0;
    }
    if (processor->hasShortTermInput) {
        metrics.shortTermInputLUFS = ocvb_mean_square_to_lufs(processor->shortTermInputEnergy);
        metrics.hasShortTermInputLUFS = isfinite(metrics.shortTermInputLUFS) ? 1 : 0;
    }
    if (processor->hasIntegratedInput) {
        metrics.integratedInputLUFS = ocvb_mean_square_to_lufs(processor->integratedInputEnergy);
        metrics.hasIntegratedInputLUFS = isfinite(metrics.integratedInputLUFS) ? 1 : 0;
    }
    return metrics;
}
