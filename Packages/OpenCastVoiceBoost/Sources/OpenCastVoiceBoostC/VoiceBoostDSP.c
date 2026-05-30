#include <OpenCastVoiceBoostC/OpenCastVoiceBoostC.h>

#include <float.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#define OCVB_MAX_CHANNELS 2
#define OCVB_PI 3.14159265358979323846

typedef struct {
    double b0;
    double b1;
    double b2;
    double a1;
    double a2;
    double z1;
    double z2;
} OCVBBiquad;

struct OCVBProcessor {
    double sampleRate;
    int32_t channelCount;
    OCVBConfiguration configuration;
    OCVBBiquad highPass[OCVB_MAX_CHANNELS];
    OCVBBiquad lowMid[OCVB_MAX_CHANNELS];
    OCVBBiquad presence[OCVB_MAX_CHANNELS];
    OCVBBiquad highShelf[OCVB_MAX_CHANNELS];
    OCVBBiquad loudnessPreFilter[OCVB_MAX_CHANNELS];
    OCVBBiquad loudnessRLBFilter[OCVB_MAX_CHANNELS];
    double wetMix;
    double currentAutoGainDB;
    double compressorEnvelopeSquared;
    double currentCompressorReductionDB;
    double currentLimiterReductionDB;
    double rollingInputMeanSquare;
    double rollingOutputMeanSquare;
    int32_t hasInputLoudness;
    int32_t hasOutputLoudness;
    int32_t confidenceBlockCount;
    double outputTruePeakAmplitude;
    double lastOutput[OCVB_MAX_CHANNELS];
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

static void ocvb_biquad_set_coefficients(
    OCVBBiquad *filter,
    double b0,
    double b1,
    double b2,
    double a1,
    double a2
) {
    filter->b0 = b0;
    filter->b1 = b1;
    filter->b2 = b2;
    filter->a1 = a1;
    filter->a2 = a2;
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

static void ocvb_biquad_set_loudness_pre_filter(OCVBBiquad *filter, double sampleRate) {
    if (fabs(sampleRate - 44100.0) < 1.0) {
        ocvb_biquad_set_coefficients(
            filter,
            1.530841230050347,
            -2.650979995154729,
            1.169079079921906,
            -1.663655113256020,
            0.712595428073225
        );
        return;
    }

    ocvb_biquad_set_coefficients(
        filter,
        1.53512485958697,
        -2.69169618940638,
        1.19839281085285,
        -1.69065929318241,
        0.73248077421585
    );
}

static void ocvb_biquad_set_loudness_rlb_filter(OCVBBiquad *filter, double sampleRate) {
    if (fabs(sampleRate - 44100.0) < 1.0) {
        ocvb_biquad_set_coefficients(
            filter,
            1.0,
            -2.0,
            1.0,
            -1.989169673629796,
            0.989199035787039
        );
        return;
    }

    ocvb_biquad_set_coefficients(
        filter,
        1.0,
        -2.0,
        1.0,
        -1.99004745483398,
        0.99007225036621
    );
}

static double ocvb_biquad_process(OCVBBiquad *filter, double input) {
    double output = filter->b0 * input + filter->z1;
    filter->z1 = filter->b1 * input - filter->a1 * output + filter->z2;
    filter->z2 = filter->b2 * input - filter->a2 * output;
    return output;
}

static void ocvb_configure_filters(OCVBProcessor *processor) {
    for (int32_t channel = 0; channel < processor->channelCount; channel += 1) {
        ocvb_biquad_set_high_pass(&processor->highPass[channel], processor->sampleRate, 70.0, 0.707);
        ocvb_biquad_set_peaking(&processor->lowMid[channel], processor->sampleRate, 260.0, 1.0, -1.25);
        ocvb_biquad_set_peaking(&processor->presence[channel], processor->sampleRate, 3000.0, 0.85, 1.25);
        ocvb_biquad_set_high_shelf(&processor->highShelf[channel], processor->sampleRate, 6500.0, 0.75);
        ocvb_biquad_set_loudness_pre_filter(&processor->loudnessPreFilter[channel], processor->sampleRate);
        ocvb_biquad_set_loudness_rlb_filter(&processor->loudnessRLBFilter[channel], processor->sampleRate);
    }
}

static void ocvb_reset_filter_state(OCVBProcessor *processor) {
    for (int32_t channel = 0; channel < processor->channelCount; channel += 1) {
        processor->highPass[channel].z1 = 0.0;
        processor->highPass[channel].z2 = 0.0;
        processor->lowMid[channel].z1 = 0.0;
        processor->lowMid[channel].z2 = 0.0;
        processor->presence[channel].z1 = 0.0;
        processor->presence[channel].z2 = 0.0;
        processor->highShelf[channel].z1 = 0.0;
        processor->highShelf[channel].z2 = 0.0;
        processor->loudnessPreFilter[channel].z1 = 0.0;
        processor->loudnessPreFilter[channel].z2 = 0.0;
        processor->loudnessRLBFilter[channel].z1 = 0.0;
        processor->loudnessRLBFilter[channel].z2 = 0.0;
        processor->lastOutput[channel] = 0.0;
    }
}

static void ocvb_reset_state(OCVBProcessor *processor) {
    processor->wetMix = processor->configuration.isEnabled ? 1.0 : 0.0;
    processor->currentAutoGainDB = 0.0;
    processor->compressorEnvelopeSquared = 0.0;
    processor->currentCompressorReductionDB = 0.0;
    processor->currentLimiterReductionDB = 0.0;
    processor->rollingInputMeanSquare = 0.0;
    processor->rollingOutputMeanSquare = 0.0;
    processor->hasInputLoudness = 0;
    processor->hasOutputLoudness = 0;
    processor->confidenceBlockCount = 0;
    processor->outputTruePeakAmplitude = 0.0;
    ocvb_reset_filter_state(processor);
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
    return configuration;
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
    ocvb_configure_filters(processor);
    ocvb_reset_state(processor);
    return processor;
}

void OCVBProcessorDestroy(OCVBProcessor *processor) {
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
    processor->configuration = ocvb_sanitized_configuration(configuration);
}

static void ocvb_update_loudness_estimate(
    OCVBProcessor *processor,
    double blockMeanSquare,
    int32_t frameCount
) {
    double blockLUFS = ocvb_mean_square_to_lufs(blockMeanSquare);
    double duration = (double)frameCount / processor->sampleRate;

    if (isfinite(blockLUFS) && blockLUFS > -70.0) {
        double alpha = 1.0 - exp(-duration / 3.0);
        if (!processor->hasInputLoudness) {
            processor->rollingInputMeanSquare = blockMeanSquare;
            processor->hasInputLoudness = 1;
        } else {
            processor->rollingInputMeanSquare =
                (1.0 - alpha) * processor->rollingInputMeanSquare + alpha * blockMeanSquare;
        }
        if (processor->confidenceBlockCount < 8) {
            processor->confidenceBlockCount += 1;
        }
    }

    double desiredGainDB = 0.0;
    if (processor->configuration.isEnabled && processor->configuration.usesAdaptiveGain && processor->hasInputLoudness) {
        double rollingLUFS = ocvb_mean_square_to_lufs(processor->rollingInputMeanSquare);
        desiredGainDB = processor->configuration.targetLUFS - rollingLUFS;
        desiredGainDB = ocvb_clamp(
            desiredGainDB,
            processor->configuration.maximumNegativeGainDB,
            processor->configuration.maximumPositiveGainDB
        );
        if (processor->confidenceBlockCount < 3 && desiredGainDB > 3.0) {
            desiredGainDB = 3.0;
        }
        if (fabs(desiredGainDB - processor->currentAutoGainDB) < 0.5) {
            desiredGainDB = processor->currentAutoGainDB;
        }
    }

    double timeConstant = desiredGainDB < processor->currentAutoGainDB ? 0.025 : 0.800;
    double alpha = 1.0 - exp(-duration / timeConstant);
    processor->currentAutoGainDB += alpha * (desiredGainDB - processor->currentAutoGainDB);
}

void OCVBProcessorProcessInterleavedFloat32(
    OCVBProcessor *processor,
    float *buffer,
    int32_t frameCount
) {
    if (processor == NULL || buffer == NULL || frameCount <= 0) {
        return;
    }

    int32_t channelCount = processor->channelCount;
    int64_t sampleCount = (int64_t)frameCount * (int64_t)channelCount;
    double inputSumSquares = 0.0;

    for (int32_t frame = 0; frame < frameCount; frame += 1) {
        for (int32_t channel = 0; channel < channelCount; channel += 1) {
            int64_t index = ((int64_t)frame * channelCount) + channel;
            double sample = ocvb_sanitize_sample(buffer[index]);
            buffer[index] = (float)sample;
            double weighted = ocvb_biquad_process(&processor->loudnessPreFilter[channel], sample);
            weighted = ocvb_biquad_process(&processor->loudnessRLBFilter[channel], weighted);
            inputSumSquares += weighted * weighted;
        }
    }

    double blockInputMeanSquare = inputSumSquares / (double)frameCount;
    ocvb_update_loudness_estimate(processor, blockInputMeanSquare, frameCount);

    double targetWetMix = processor->configuration.isEnabled ? 1.0 : 0.0;
    double wetStep = 1.0 / fmax(1.0, 0.050 * processor->sampleRate);
    double autoGain = ocvb_db_to_linear(processor->currentAutoGainDB);
    double ceiling = ocvb_db_to_linear(processor->configuration.truePeakCeilingDBTP);
    double limiterCeiling = ceiling * 0.85;
    double outputSumSquares = 0.0;
    double blockTruePeak = 0.0;
    double maximumCompressorReduction = 0.0;
    double maximumLimiterReduction = 0.0;

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

        double attackCoefficient = exp(-1.0 / (0.010 * processor->sampleRate));
        double releaseCoefficient = exp(-1.0 / (0.250 * processor->sampleRate));
        double envelopeCoefficient = frameDetector > processor->compressorEnvelopeSquared
            ? attackCoefficient
            : releaseCoefficient;
        processor->compressorEnvelopeSquared =
            envelopeCoefficient * processor->compressorEnvelopeSquared
            + (1.0 - envelopeCoefficient) * frameDetector;

        double envelopeDB = ocvb_mean_square_to_lufs(processor->compressorEnvelopeSquared) + 0.691;
        double compressorReductionDB = 0.0;
        double compressorThresholdDB = -16.0;
        double compressorRatio = 1.35;
        double compressorOverDB = envelopeDB - compressorThresholdDB;
        if (processor->configuration.usesCompression && compressorOverDB > 0.0) {
            compressorReductionDB = compressorOverDB * (1.0 - (1.0 / compressorRatio));
            compressorReductionDB = ocvb_clamp(compressorReductionDB, 0.0, 5.0);
        }
        double compressorGain = ocvb_db_to_linear(-compressorReductionDB);
        maximumCompressorReduction = fmax(maximumCompressorReduction, compressorReductionDB);

        double limitedFramePeak = 0.0;
        for (int32_t channel = 0; channel < channelCount; channel += 1) {
            wetValues[channel] *= compressorGain;
            limitedFramePeak = fmax(limitedFramePeak, fabs(wetValues[channel]));
        }

        double limiterGain = 1.0;
        double limiterReductionDB = 0.0;
        if (limitedFramePeak > limiterCeiling && limitedFramePeak > DBL_MIN) {
            limiterGain = limiterCeiling / limitedFramePeak;
            limiterReductionDB = -ocvb_amplitude_to_db(limiterGain);
        }
        maximumLimiterReduction = fmax(maximumLimiterReduction, limiterReductionDB);

        for (int32_t channel = 0; channel < channelCount; channel += 1) {
            int64_t index = ((int64_t)frame * channelCount) + channel;
            double dry = dryValues[channel];
            double wet = wetValues[channel] * limiterGain;
            double output = dry * (1.0 - processor->wetMix) + wet * processor->wetMix;

            if (processor->wetMix > 0.0 && fabs(output) > limiterCeiling) {
                output = copysign(limiterCeiling, output);
            }
            if (!isfinite(output)) {
                output = 0.0;
            }

            double midpoint = 0.5 * (processor->lastOutput[channel] + output);
            blockTruePeak = fmax(blockTruePeak, fabs(output));
            blockTruePeak = fmax(blockTruePeak, fabs(midpoint));
            processor->lastOutput[channel] = output;
            outputSumSquares += output * output;
            buffer[index] = (float)output;
        }
    }

    double blockOutputMeanSquare = outputSumSquares / (double)sampleCount;
    double duration = (double)frameCount / processor->sampleRate;
    double alpha = 1.0 - exp(-duration / 3.0);
    if (!processor->hasOutputLoudness) {
        processor->rollingOutputMeanSquare = blockOutputMeanSquare;
        processor->hasOutputLoudness = 1;
    } else {
        processor->rollingOutputMeanSquare =
            (1.0 - alpha) * processor->rollingOutputMeanSquare + alpha * blockOutputMeanSquare;
    }

    processor->currentCompressorReductionDB = maximumCompressorReduction;
    processor->currentLimiterReductionDB = maximumLimiterReduction;
    processor->outputTruePeakAmplitude = blockTruePeak;
}

OCVBMetrics OCVBProcessorCopyMetrics(const OCVBProcessor *processor) {
    OCVBMetrics metrics;
    memset(&metrics, 0, sizeof(metrics));

    if (processor == NULL) {
        return metrics;
    }

    metrics.hasEstimatedInputLUFS = processor->hasInputLoudness;
    metrics.estimatedInputLUFS = ocvb_mean_square_to_lufs(processor->rollingInputMeanSquare);
    metrics.hasEstimatedOutputLUFS = processor->hasOutputLoudness;
    metrics.estimatedOutputLUFS = ocvb_mean_square_to_lufs(processor->rollingOutputMeanSquare);
    metrics.currentAutoGainDB = processor->currentAutoGainDB;
    metrics.currentCompressorReductionDB = processor->currentCompressorReductionDB;
    metrics.currentLimiterReductionDB = processor->currentLimiterReductionDB;
    metrics.hasOutputTruePeakDBTP = processor->outputTruePeakAmplitude > 0.0 ? 1 : 0;
    metrics.outputTruePeakDBTP = ocvb_amplitude_to_db(processor->outputTruePeakAmplitude);
    return metrics;
}
