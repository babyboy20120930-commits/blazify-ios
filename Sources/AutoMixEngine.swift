import Accelerate
import AVFoundation
import Foundation

struct BeatTransitionPlan {
    let duration: TimeInterval
    let outgoingRate: Float
    let incomingRate: Float
    let incomingStartOffset: TimeInterval
    let outgoingBPM: Double
    let incomingBPM: Double
}

actor AutoMixEngine {
    static let shared = AutoMixEngine()

    private var bpmCache: [String: (bpm: Double, firstBeat: TimeInterval)] = [:]

    func computeTransition(
        outgoingURL: URL?,
        outgoingId: String,
        incomingURL: URL?,
        incomingId: String,
        baseDuration: TimeInterval
    ) async -> BeatTransitionPlan {
        async let outInfo = analyze(url: outgoingURL, id: outgoingId, tail: true)
        async let inInfo = analyze(url: incomingURL, id: incomingId, tail: false)

        let (outBPM, _) = await outInfo
        let (inBPM, inFirstBeat) = await inInfo

        guard outBPM > 55, inBPM > 55 else {
            return BeatTransitionPlan(
                duration: baseDuration,
                outgoingRate: 1.0,
                incomingRate: 1.0,
                incomingStartOffset: 0,
                outgoingBPM: outBPM,
                incomingBPM: inBPM
            )
        }

        // Normalize half/double tempo
        var targetInBPM = inBPM
        if targetInBPM < outBPM * 0.72 { targetInBPM *= 2.0 }
        if targetInBPM > outBPM * 1.38 { targetInBPM /= 2.0 }

        let ratio = outBPM / targetInBPM
        let clampedRatio = min(max(ratio, 0.92), 1.08)

        // Snap transition duration to a musical bar multiple (4 beats = 1 bar)
        let beatSec = 60.0 / outBPM
        let barSec = beatSec * 4.0
        let bars = max(1, round(baseDuration / barSec))
        let snappedDuration = min(max(bars * barSec, 2.0), 15.0)

        return BeatTransitionPlan(
            duration: snappedDuration,
            outgoingRate: 1.0,
            incomingRate: Float(clampedRatio),
            incomingStartOffset: min(inFirstBeat, 8.0),
            outgoingBPM: outBPM,
            incomingBPM: targetInBPM
        )
    }

    private func analyze(url: URL?, id: String, tail: Bool) async -> (Double, TimeInterval) {
        if let cached = bpmCache[id] { return cached }
        guard let url, url.isFileURL else { return (0, 0) }

        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let sr = format.sampleRate
            let totalFrames = file.length
            guard sr > 0, totalFrames > AVAudioFramePosition(sr * 6) else { return (0, 0) }

            let windowFrames = AVAudioFrameCount(min(Double(totalFrames), sr * 24.0))
            if tail {
                file.framePosition = max(0, totalFrames - AVAudioFramePosition(windowFrames))
            } else {
                file.framePosition = 0
            }

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: windowFrames) else {
                return (0, 0)
            }
            try file.read(into: buffer)
            guard let channelData = buffer.floatChannelData?[0] else { return (0, 0) }
            let count = Int(buffer.frameLength)
            guard count > 4096 else { return (0, 0) }

            // Compute RMS energy envelope in 20ms hops (50 Hz envelope rate)
            let hop = max(1, Int(sr * 0.02))
            let envCount = count / hop
            guard envCount > 120 else { return (0, 0) }

            var env = [Float](repeating: 0, count: envCount)
            for i in 0..<envCount {
                var rms: Float = 0
                vDSP_rmsqv(channelData.advanced(by: i * hop), 1, &rms, vDSP_Length(hop))
                env[i] = rms
            }

            // Onset strength (positive half-wave rectified difference)
            var onset = [Float](repeating: 0, count: envCount)
            var firstBeatIdx = 0
            var peak: Float = 0
            vDSP_maxv(env, 1, &peak, vDSP_Length(envCount))
            for i in 1..<envCount {
                onset[i] = max(0, env[i] - env[i - 1])
                if firstBeatIdx == 0 && env[i] > peak * 0.35 {
                    firstBeatIdx = i
                }
            }

            // Autocorrelation across 70..175 BPM (lags at 50 Hz)
            let minLag = Int(50.0 * 60.0 / 175.0)
            let maxLag = min(envCount / 2, Int(50.0 * 60.0 / 70.0))
            var bestLag = 0
            var bestScore: Float = -1

            if maxLag > minLag {
                for lag in minLag...maxLag {
                    var dot: Float = 0
                    let len = envCount - lag
                    vDSP_dotpr(onset, 1, Array(onset[lag..<envCount]), 1, &dot, vDSP_Length(len))
                    let score = dot / Float(len)
                    if score > bestScore {
                        bestScore = score
                        bestLag = lag
                    }
                }
            }

            let bpm = bestLag > 0 ? (50.0 * 60.0) / Double(bestLag) : 0
            let firstBeatSec = Double(firstBeatIdx) * 0.02
            let result = (bpm, firstBeatSec)
            bpmCache[id] = result
            return result
        } catch {
            return (0, 0)
        }
    }
}
