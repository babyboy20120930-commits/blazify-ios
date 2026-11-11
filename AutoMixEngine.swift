import AVFoundation
import Accelerate
import Foundation

/// BitChord-inspired real-time Beat-Matching & Tempo-Stretching AutoMix Engine.
/// Analyzes audio onset energy peaks via AVAssetReader + Accelerate (vDSP) to
/// calculate BPM, align downbeats, and smoothly stretch tempo without pitch shift.
actor AutoMixEngine {
    static let shared = AutoMixEngine()

    struct BeatProfile: Sendable {
        let bpm: Double
        let firstBeatOffset: Double
        let confidence: Double
    }

    private var cache: [String: BeatProfile] = [:]

    /// Analyzes the beat grid (BPM and beat phase) of an audio URL.
    /// Scans a 20-second window (tail for outgoing track, head for incoming track).
    func analyze(url: URL, videoId: String, scanTail: Bool) async -> BeatProfile? {
        let key = "\(videoId)_\(scanTail ? "tail" : "head")"
        if let cached = cache[key] { return cached }

        let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPUserAgentKey: YouTube.visionUA])
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let durationCM = try? await asset.load(.duration) else {
            return nil
        }

        let totalSeconds = CMTimeGetSeconds(durationCM)
        guard totalSeconds.isFinite, totalSeconds > 10 else { return nil }

        let windowDuration: Double = min(22.0, totalSeconds * 0.4)
        let startTime = scanTail ? max(0, totalSeconds - windowDuration - 2.0) : 0.0
        let timeRange = CMTimeRange(
            start: CMTime(seconds: startTime, preferredTimescale: 600),
            duration: CMTime(seconds: windowDuration, preferredTimescale: 600)
        )

        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        reader.timeRange = timeRange

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 22050,
            AVNumberOfChannelsKey: 1
        ]

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        let frameSize = 220
        var energies: [Float] = []
        var sampleBufferAccum: [Float] = []
        sampleBufferAccum.reserveCapacity(frameSize * 4)

        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer(),
                  let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                break
            }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            let floatCount = length / MemoryLayout<Float>.size
            if floatCount > 0 {
                var chunk = [Float](repeating: 0, count: floatCount)
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: &chunk)
                sampleBufferAccum.append(contentsOf: chunk)

                while sampleBufferAccum.count >= frameSize {
                    var rms: Float = 0
                    vDSP_rmsqv(sampleBufferAccum, 1, &rms, vDSP_Length(frameSize))
                    energies.append(rms)
                    sampleBufferAccum.removeFirst(frameSize)
                }
            }
            CMSampleBufferInvalidate(sampleBuffer)
        }

        guard energies.count > 400 else { return nil }

        var onsets = [Float](repeating: 0, count: energies.count)
        for i in 1..<energies.count {
            let diff = energies[i] - energies[i - 1]
            onsets[i] = diff > 0 ? diff : 0
        }

        let minLag = 34
        let maxLag = 86
        var bestLag = 50
        var maxScore: Float = 0
        var totalScore: Float = 0

        for lag in minLag...maxLag {
            var corr: Float = 0
            let count = onsets.count - lag
            guard count > 0 else { continue }
            onsets.withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return }
                vDSP_dotpr(base, 1, base.advanced(by: lag), 1, &corr, vDSP_Length(count))
            }
            let bpmCandidate = 6000.0 / Double(lag)
            let weight: Float = (bpmCandidate >= 95 && bpmCandidate <= 138) ? 1.12 : 1.0
            let weightedCorr = corr * weight
            totalScore += weightedCorr
            if weightedCorr > maxScore {
                maxScore = weightedCorr
                bestLag = lag
            }
        }

        let avgScore = totalScore / Float(maxLag - minLag + 1)
        let confidence = avgScore > 0 ? min(Double(maxScore / avgScore) / 3.0, 1.0) : 0.0
        var bpm = 6000.0 / Double(bestLag)

        while bpm < 80 { bpm *= 2 }
        while bpm > 160 { bpm /= 2 }

        let beatFrames = Int(round(6000.0 / bpm))
        var bestPhase = 0
        var bestPhaseEnergy: Float = -1
        for phase in 0..<min(beatFrames, onsets.count) {
            var phaseSum: Float = 0
            var idx = phase
            while idx < onsets.count {
                phaseSum += onsets[idx]
                idx += beatFrames
            }
            if phaseSum > bestPhaseEnergy {
                bestPhaseEnergy = phaseSum
                bestPhase = phase
            }
        }

        let profile = BeatProfile(
            bpm: bpm,
            firstBeatOffset: Double(bestPhase) * 0.01,
            confidence: confidence
        )
        cache[key] = profile
        return profile
    }

    /// Computes a safe DJ tempo-stretch ratio (within ±8%) and beat-aligned entry point.
    func computeTransition(
        outgoingURL: URL?,
        outgoingId: String,
        incomingURL: URL,
        incomingId: String,
        baseSpeed: Float
    ) async -> (startRate: Float, targetRate: Float, seekOffset: Double, beatSynced: Bool) {
        guard let outgoingURL else {
            return (baseSpeed, baseSpeed, 0, false)
        }

        async let outProfileTask = analyze(url: outgoingURL, videoId: outgoingId, scanTail: true)
        async let inProfileTask = analyze(url: incomingURL, videoId: incomingId, scanTail: false)
        let (outProfile, inProfile) = await (outProfileTask, inProfileTask)

        guard let outP = outProfile, let inP = inProfile,
              outP.confidence > 0.35, inP.confidence > 0.35 else {
            return (baseSpeed, baseSpeed, 0, false)
        }

        var targetInBPM = inP.bpm
        if abs(outP.bpm - targetInBPM * 2) < abs(outP.bpm - targetInBPM) {
            targetInBPM *= 2
        } else if abs(outP.bpm - targetInBPM / 2) < abs(outP.bpm - targetInBPM) {
            targetInBPM /= 2
        }

        let ratio = Float(outP.bpm / targetInBPM)
        guard ratio >= 0.92 && ratio <= 1.08 else {
            return (baseSpeed, baseSpeed, inP.firstBeatOffset, false)
        }

        let matchedRate = baseSpeed * ratio
        return (matchedRate, baseSpeed, inP.firstBeatOffset, true)
    }
}
