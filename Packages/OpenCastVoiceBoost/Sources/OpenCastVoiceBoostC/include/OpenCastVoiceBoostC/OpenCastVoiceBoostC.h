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
} OCVBConfiguration;

typedef struct {
    int32_t hasEstimatedInputLUFS;
    double estimatedInputLUFS;
    int32_t hasEstimatedOutputLUFS;
    double estimatedOutputLUFS;
    double currentAutoGainDB;
    double currentCompressorReductionDB;
    double currentLimiterReductionDB;
    int32_t hasOutputTruePeakDBTP;
    double outputTruePeakDBTP;
} OCVBMetrics;

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

void OCVBProcessorProcessInterleavedFloat32(
    OCVBProcessor *processor,
    float *buffer,
    int32_t frameCount
);

OCVBMetrics OCVBProcessorCopyMetrics(const OCVBProcessor *processor);

#ifdef __cplusplus
}
#endif

#endif
