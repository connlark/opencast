@preconcurrency import AVFoundation
import AudioToolbox
import OpenCastVoiceBoost

nonisolated struct VoiceBoostAudioTapRuntimeState {
    /// The tap's engagement state machine. Steady states are `bypassed`
    /// (untouched zero-latency dry) and `engaged`
    /// (pure processor output). The transitions exist because the processor
    /// output is delayed by its lookahead: leaving or entering the C path
    /// needs a drain (wet ramps to dry inside C on time-aligned legs) and a
    /// latency splice (a short live/delayed crossfade of bit-identical dry
    /// programme ~5 ms apart), never a cut or a forward skip.
    enum EnginePhase: Equatable {
        case bypassed
        /// Delay-line warmup (pure live output while the freshly reset
        /// processor fills its lookahead), then the splice ramps toward
        /// processor output.
        case engaging(warmupFramesRemaining: Int)
        case engaged
        /// Processor keeps running with a disabled configuration until its
        /// wet mix reaches exactly zero, then the splice ramps toward live
        /// and the phase parks in `bypassed`.
        case disengaging
    }

    var configuration: VoiceBoostConfiguration
    // VoiceBoostProcessor has no internal synchronization; every access is serialized by VoiceBoostAudioTapContext.stateLock.
    var processor: VoiceBoostProcessor?
    var channelCount = 0
    var isFloat32 = false
    var isNonInterleaved = false
    /// Preallocated copy of the incoming (live, undelayed) buffer, needed
    /// only while a transition blends live against processor output. The
    /// planar path stores channel-major slices (channel c at offset
    /// c * frameCount); the interleaved path stores frames interleaved.
    var dryScratch: [Float] = []
    private(set) var phase: EnginePhase = .bypassed
    /// Blend position of the latency splice: 1 is pure live input, 0 is
    /// pure processor output. Steps by `spliceStep` per frame.
    private(set) var liveMixWeight: Double = 1
    private var latencyFrames = 0
    private var spliceStep = 1.0
    /// Adaptation control state carried across processor recreation (I3).
    /// Captured on unprepare and at disable time (pre-drain), applied on
    /// prepare; the controller hands it across track-bound tap reinstalls.
    private(set) var pendingControlSnapshot: VoiceBoostControlSnapshot?

    init(configuration: VoiceBoostConfiguration) {
        self.configuration = configuration
    }

    mutating func prepare(
        maximumFrames: Int,
        sampleRate: Double,
        channelCount: Int,
        isFloat32: Bool,
        isNonInterleaved: Bool,
        isSupported: Bool
    ) {
        self.channelCount = channelCount
        self.isFloat32 = isFloat32
        self.isNonInterleaved = isNonInterleaved

        guard isSupported else {
            processor = nil
            dryScratch.removeAll(keepingCapacity: false)
            phase = .bypassed
            liveMixWeight = 1
            return
        }

        let processor = VoiceBoostProcessor(
            sampleRate: sampleRate,
            channelCount: channelCount,
            configuration: configuration
        )
        if let pendingControlSnapshot {
            processor.apply(controlSnapshot: pendingControlSnapshot)
        }
        self.processor = processor
        latencyFrames = processor.metrics.latencyFrames
        spliceStep = 1 / Double(max(1, latencyFrames))
        dryScratch = Array(repeating: 0, count: maximumFrames * channelCount)
        if configuration.isEnabled {
            phase = .engaging(warmupFramesRemaining: latencyFrames)
        } else {
            phase = .bypassed
        }
        liveMixWeight = 1
    }

    mutating func unprepare() {
        if let processor {
            switch phase {
            case .engaged, .engaging:
                pendingControlSnapshot = processor.controlSnapshot
            case .bypassed, .disengaging:
                // Keep the pre-drain snapshot captured at disable time; the
                // live state is either idle or mid-drain with the desired
                // gain sliding toward zero.
                break
            }
        }
        processor = nil
        dryScratch.removeAll(keepingCapacity: true)
        phase = .bypassed
        liveMixWeight = 1
    }

    mutating func update(configuration newConfiguration: VoiceBoostConfiguration) {
        let wasEnabled = configuration.isEnabled
        configuration = newConfiguration

        guard let processor else {
            phase = .bypassed
            liveMixWeight = 1
            return
        }

        guard newConfiguration.isEnabled != wasEnabled else {
            processor.update(configuration: newConfiguration)
            return
        }

        if newConfiguration.isEnabled {
            switch phase {
            case .bypassed:
                // The idle delay line holds stale pre-bypass audio and
                // bypass durations are unbounded: reset (while the
                // processor is still configured dry, so the wet mix
                // restarts at zero), then re-seed the adaptation state so
                // gain does not re-bootstrap through the low-confidence cap.
                let controlSnapshot = pendingControlSnapshot ?? processor.controlSnapshot
                processor.reset()
                processor.update(configuration: newConfiguration)
                processor.apply(controlSnapshot: controlSnapshot)
                phase = .engaging(warmupFramesRemaining: latencyFrames)
                liveMixWeight = 1
            case .disengaging:
                // The delay line is warm (the drain kept feeding it), so no
                // reset and no warmup: ramp back from wherever the splice is.
                processor.update(configuration: newConfiguration)
                phase = liveMixWeight == 0 ? .engaged : .engaging(warmupFramesRemaining: 0)
            case .engaging, .engaged:
                processor.update(configuration: newConfiguration)
            }
        } else {
            switch phase {
            case .engaged:
                pendingControlSnapshot = processor.controlSnapshot
                processor.update(configuration: newConfiguration)
                phase = .disengaging
            case .engaging:
                pendingControlSnapshot = processor.controlSnapshot
                processor.update(configuration: newConfiguration)
                // Still inside the warmup window means the output has been
                // pure live throughout; parking in bypass is seamless.
                phase = liveMixWeight == 1 ? .bypassed : .disengaging
            case .bypassed, .disengaging:
                processor.update(configuration: newConfiguration)
            }
        }
    }

    /// Seek policy: signal and measurement state reset, adaptation
    /// control state re-seeded — a skip inside the same programme must not
    /// step gain or re-engage the low-confidence cap.
    func reset() {
        guard let processor else {
            return
        }
        let controlSnapshot = processor.controlSnapshot
        processor.reset()
        processor.apply(controlSnapshot: controlSnapshot)
    }

    func captureControlSnapshot() -> VoiceBoostControlSnapshot? {
        guard let processor else {
            return pendingControlSnapshot
        }
        switch phase {
        case .engaged, .engaging:
            return processor.controlSnapshot
        case .bypassed, .disengaging:
            return pendingControlSnapshot ?? processor.controlSnapshot
        }
    }

    mutating func seedControlSnapshot(_ snapshot: VoiceBoostControlSnapshot) {
        // Applied at the next prepare; never touches a live processor, so
        // seeding cannot step gain mid-buffer.
        pendingControlSnapshot = snapshot
    }

    @discardableResult
    mutating func process(
        bufferList: UnsafeMutablePointer<AudioBufferList>,
        frameCount: Int
    ) -> VoiceBoostTapProcessOutcome {
        if !configuration.isEnabled, case .bypassed = phase {
            return .bypassedDisabled
        }
        guard let processor, frameCount > 0, isFloat32 else {
            return .bypassedUnsupported
        }
        if case .bypassed = phase {
            return .bypassedDisabled
        }

        var buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        if isNonInterleaved {
            return processPlanar(buffers: &buffers, frameCount: frameCount, processor: processor)
        } else {
            return processInterleaved(buffers: &buffers, frameCount: frameCount, processor: processor)
        }
    }

    private mutating func processInterleaved(
        buffers: inout UnsafeMutableAudioBufferListPointer,
        frameCount: Int,
        processor: VoiceBoostProcessor
    ) -> VoiceBoostTapProcessOutcome {
        guard buffers.count == 1,
              buffers[0].mNumberChannels == channelCount,
              let data = buffers[0].mData
        else {
            return .bypassedUnsupported
        }

        let sampleCount = frameCount * channelCount
        guard Int(buffers[0].mDataByteSize) >= sampleCount * MemoryLayout<Float>.size else {
            return .bypassedUnsupported
        }

        let samples = data.assumingMemoryBound(to: Float.self)
        let buffer = UnsafeMutableBufferPointer(start: samples, count: sampleCount)
        return runEngine(on: buffer, frameCount: frameCount, processor: processor)
    }

    /// The production path on the simulator and (per format) devices: the
    /// tap's non-interleaved channel pointers go straight into the planar C
    /// engine — no marshalling copies (the per-sample Swift copy
    /// loops this replaces were most of the Debug-build CPU delta).
    private mutating func processPlanar(
        buffers: inout UnsafeMutableAudioBufferListPointer,
        frameCount: Int,
        processor: VoiceBoostProcessor
    ) -> VoiceBoostTapProcessOutcome {
        guard buffers.count >= channelCount, channelCount <= 2 else {
            return .bypassedUnsupported
        }

        // The pointer pair lives on the stack: the audio thread cannot
        // allocate, and the C entry wants a contiguous pointer array.
        var pointers: (UnsafeMutablePointer<Float>?, UnsafeMutablePointer<Float>?) = (nil, nil)
        for channel in 0..<channelCount {
            guard let data = buffers[channel].mData,
                  Int(buffers[channel].mDataByteSize) >= frameCount * MemoryLayout<Float>.size
            else {
                return .bypassedUnsupported
            }

            let samples = data.assumingMemoryBound(to: Float.self)
            if channel == 0 {
                pointers.0 = samples
            } else {
                pointers.1 = samples
            }
        }

        return withUnsafeMutablePointer(to: &pointers) { tuplePointer in
            tuplePointer.withMemoryRebound(
                to: Optional<UnsafeMutablePointer<Float>>.self,
                capacity: 2
            ) { channels in
                runEnginePlanar(channels: channels, frameCount: frameCount, processor: processor)
            }
        }
    }

    private mutating func runEnginePlanar(
        channels: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>,
        frameCount: Int,
        processor: VoiceBoostProcessor
    ) -> VoiceBoostTapProcessOutcome {
        switch phase {
        case .bypassed:
            return .bypassedDisabled
        case .engaged:
            processor.processPlanarFloat32(channels, frameCount: frameCount)
            return .processedEngaged
        case .engaging(let warmupFramesRemaining):
            return runTransitionPlanar(
                channels: channels,
                frameCount: frameCount,
                processor: processor,
                warmupFramesRemaining: warmupFramesRemaining,
                isEngaging: true
            )
        case .disengaging:
            return runTransitionPlanar(
                channels: channels,
                frameCount: frameCount,
                processor: processor,
                warmupFramesRemaining: 0,
                isEngaging: false
            )
        }
    }

    /// Planar variant of `runTransition` — same weight trajectory and phase
    /// bookkeeping, channel-major dry copies and blend indexing. Scalar per
    /// frame by design; it only runs for ~one lookahead per toggle.
    private mutating func runTransitionPlanar(
        channels: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>,
        frameCount: Int,
        processor: VoiceBoostProcessor,
        warmupFramesRemaining: Int,
        isEngaging: Bool
    ) -> VoiceBoostTapProcessOutcome {
        let sampleCount = frameCount * channelCount
        guard sampleCount <= dryScratch.count else {
            // Unreachable under the prepare contract (maximumFrames bounds
            // every callback); degrade to unblended processing rather than
            // wedge the transition.
            processor.processPlanarFloat32(channels, frameCount: frameCount)
            return .processedTransition
        }

        let channelCount = self.channelCount
        let spliceStep = self.spliceStep
        dryScratch.withUnsafeMutableBufferPointer { dry in
            for channel in 0..<channelCount {
                (dry.baseAddress! + channel * frameCount)
                    .update(from: channels[channel]!, count: frameCount)
            }
        }
        let drainReachedDry = isEngaging ? false : processor.currentWetMix == 0
        processor.processPlanarFloat32(channels, frameCount: frameCount)

        var warmupRemaining = warmupFramesRemaining
        var weight = liveMixWeight
        dryScratch.withUnsafeBufferPointer { dry in
            for frame in 0..<frameCount {
                if isEngaging {
                    if warmupRemaining > 0 {
                        warmupRemaining -= 1
                    } else if weight > 0 {
                        weight = max(0, weight - spliceStep)
                    }
                } else if drainReachedDry, weight < 1 {
                    weight = min(1, weight + spliceStep)
                }
                if weight > 0 {
                    let liveWeight = Float(weight)
                    let processedWeight = 1 - liveWeight
                    for channel in 0..<channelCount {
                        let data = channels[channel]!
                        data[frame] = dry[channel * frameCount + frame] * liveWeight
                            + data[frame] * processedWeight
                    }
                }
            }
        }
        liveMixWeight = weight

        if isEngaging {
            if weight == 0 {
                phase = .engaged
                return .processedEngaged
            }
            phase = .engaging(warmupFramesRemaining: warmupRemaining)
        } else if weight == 1 {
            phase = .bypassed
        }
        return .processedTransition
    }

    private mutating func runEngine(
        on buffer: UnsafeMutableBufferPointer<Float>,
        frameCount: Int,
        processor: VoiceBoostProcessor
    ) -> VoiceBoostTapProcessOutcome {
        switch phase {
        case .bypassed:
            return .bypassedDisabled
        case .engaged:
            processor.processInterleavedFloat32(buffer, frameCount: frameCount)
            return .processedEngaged
        case .engaging(let warmupFramesRemaining):
            return runTransition(
                on: buffer,
                frameCount: frameCount,
                processor: processor,
                warmupFramesRemaining: warmupFramesRemaining,
                isEngaging: true
            )
        case .disengaging:
            return runTransition(
                on: buffer,
                frameCount: frameCount,
                processor: processor,
                warmupFramesRemaining: 0,
                isEngaging: false
            )
        }
    }

    /// Runs the processor and blends its (delayed) output against the live
    /// input per the phase: engaging holds pure live through the warmup then
    /// ramps toward processor output; disengaging waits for the in-processor
    /// drain to reach exactly dry, then ramps toward live and parks in
    /// bypass. Both splice legs carry the same programme ~5 ms apart, so the
    /// blend is click-free by construction.
    private mutating func runTransition(
        on buffer: UnsafeMutableBufferPointer<Float>,
        frameCount: Int,
        processor: VoiceBoostProcessor,
        warmupFramesRemaining: Int,
        isEngaging: Bool
    ) -> VoiceBoostTapProcessOutcome {
        let sampleCount = frameCount * channelCount
        guard sampleCount <= dryScratch.count else {
            // Unreachable under the prepare contract (maximumFrames bounds
            // every callback); degrade to unblended processing rather than
            // wedge the transition.
            processor.processInterleavedFloat32(buffer, frameCount: frameCount)
            return .processedTransition
        }

        dryScratch.withUnsafeMutableBufferPointer { dry in
            dry.baseAddress!.update(from: buffer.baseAddress!, count: sampleCount)
        }
        let drainReachedDry = isEngaging ? false : processor.currentWetMix == 0
        processor.processInterleavedFloat32(buffer, frameCount: frameCount)

        var warmupRemaining = warmupFramesRemaining
        var weight = liveMixWeight
        let channelCount = self.channelCount
        let spliceStep = self.spliceStep
        dryScratch.withUnsafeBufferPointer { dry in
            for frame in 0..<frameCount {
                if isEngaging {
                    if warmupRemaining > 0 {
                        warmupRemaining -= 1
                    } else if weight > 0 {
                        weight = max(0, weight - spliceStep)
                    }
                } else if drainReachedDry, weight < 1 {
                    weight = min(1, weight + spliceStep)
                }
                if weight > 0 {
                    let liveWeight = Float(weight)
                    let processedWeight = 1 - liveWeight
                    for channel in 0..<channelCount {
                        let index = frame * channelCount + channel
                        buffer[index] = dry[index] * liveWeight + buffer[index] * processedWeight
                    }
                }
            }
        }
        liveMixWeight = weight

        if isEngaging {
            if weight == 0 {
                phase = .engaged
                return .processedEngaged
            }
            phase = .engaging(warmupFramesRemaining: warmupRemaining)
        } else if weight == 1 {
            phase = .bypassed
        }
        return .processedTransition
    }
}
