import Accelerate
import AVFoundation
import Foundation

actor AutoMixEngine {
    static let shared = AutoMixEngine()

    struct TrackMixProfile: Sendable {
        let bpm: Double
        let firstBeat: TimeInterval      // First strong downbeat in intro
        let outroStartOffset: TimeInterval // Seconds before track end where energy drops (ideal mix-out)
    }

    private var profileCache: [String: TrackMixProfile] = [:]

    func computeTransition(
        outgoingURL: URL?,
        outgoingId: String,
        incomingURL: URL?,
        incomingId: String,
        baseSpeed: Float
    ) async -> (startRate: Float, targetRate: Float, seekOffset: Double, beatSynced: Bool) {
        async let outProfileTask = analyze(url: outgoingURL, id: outgoingId, tail: true)
        async let inProfileTask = analyze(url: incomingURL, id: incomingId, tail: false)

        let outProfile = await outProfileTask
        let inProfile = await inProfileTask

        guard let outP = outProfile, let inP = inProfile, outP.bpm > 55, inP.bpm > 55 else {
            return (baseSpeed, baseSpeed, inProfile?.firstBeat ?? 0, false)
        }

        // Normalize half/double tempo (e.g., 72 BPM R&B vs 144 BPM Trap/Pop)
        var targetInBPM = inP.bpm
        if targetInBPM < outP.bpm * 0.72 { targetInBPM *= 2.0 }
        if targetInBPM > outP.bpm * 1.38 { targetInBPM /= 2.0 }

        let ratio = Float(outP.bpm / targetInBPM)
        // Allow up to ±14% seamless tempo lock
        let clampedRatio = min(max(ratio, 0.86), 1.14)

        // Snap seekOffset to the first strong downbeat so intro silence is skipped cleanly
        let beatPeriod = 60.0 / targetInBPM
        var alignedOffset = inP.firstBeat
        if alignedOffset > 8.0 {
            // Keep within reasonable intro range while staying locked to a 4-beat bar boundary
            let barLength = beatPeriod * 4.0
            alignedOffset = alignedOffset.truncatingRemainder(dividingBy: barLength)
        }

        return (baseSpeed * clampedRatio, baseSpeed, max(0, alignedOffset), true)
    }

    /// Returns optimal mix window duration (seconds) tailored to the outgoing track's outro energy.
    func optimalMixDuration(for url: URL?, id: String, fallback: Double) async -> Double {
        if let profile = await analyze(url: url, id: id, tail: true), profile.outroStartOffset >= 4.0 {
            return min(max(profile.outroStartOffset, 5.0), 14.0)
        }
        return fallback
    }

    private func analyze(url: URL?, id: String, tail: Bool) async -> TrackMixProfile? {
        if !id.isEmpty, let cached = profileCache[id] { return cached }

        let resolvedURL: URL? = await MainActor.run {
            if let own = LocalMusic.shared.localAudioURL(for: id) { return own }
            if let dl = Downloads.shared.localAudioURL(for: id) { return dl }
            if let cache = AudioCache.shared.cachedURL(for: id) { return cache }
            return url
        }

        guard let targetURL = resolvedURL else { return nil }

        do {
            let asset = AVURLAsset(url: targetURL, options: [
                AVURLAssetHTTPUserAgentKey: YouTube.visionUA
            ])
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let audioTrack = tracks.first else { return nil }

            let durationCM = try await asset.load(.duration)
            let totalSec = durationCM.seconds
            guard totalSec.isFinite, totalSec > 8.0 else { return nil }

            let reader = try AVAssetReader(asset: asset)
            let windowSec = min(totalSec, 24.0)
            let startSec = tail ? max(0, totalSec - windowSec) : 0
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: startSec, preferredTimescale: 600),
                duration: CMTime(seconds: windowSec, preferredTimescale: 600)
            )

            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: 22050.0,
                AVNumberOfChannelsKey: 1
            ]

            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return nil }
            reader.add(output)
            guard reader.startReading() else { return nil }

            var samples: [Float] = []
            samples.reserveCapacity(Int(22050.0 * windowSec))

            while reader.status == .reading {
                guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
                guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
                var length = 0
                var dataPointer: UnsafeMutablePointer<Int8>?
                let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
                if status == kCMBlockBufferNoErr, let dataPointer, length > 0 {
                    let floatCount = length / MemoryLayout<Float>.size
                    dataPointer.withMemoryRebound(to: Float.self, capacity: floatCount) { ptr in
                        samples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: floatCount))
                    }
                }
            }

            guard samples.count > 44100 else { return nil }

            // 20ms hop (50 Hz envelope)
            let hop = Int(22050.0 * 0.02)
            let envCount = samples.count / hop
            guard envCount > 150 else { return nil }

            var env = [Float](repeating: 0, count: envCount)
            samples.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                for i in 0..<envCount {
                    var rms: Float = 0
                    vDSP_rmsqv(base.advanced(by: i * hop), 1, &rms, vDSP_Length(hop))
                    env[i] = rms
                }
            }

            var peak: Float = 0
            vDSP_maxv(env, 1, &peak, vDSP_Length(envCount))
            guard peak > 0.001 else { return nil }

            // 1. Detect first strong beat onset in intro
            var onset = [Float](repeating: 0, count: envCount)
            var firstBeatIdx = 0
            for i in 1..<envCount {
                let diff = max(0, env[i] - env[i - 1])
                onset[i] = diff
                if firstBeatIdx == 0 && env[i] > peak * 0.34 && diff > peak * 0.08 {
                    firstBeatIdx = i
                }
            }

            // 2. Detect outro energy drop point (where song transitions into instrumental tail)
            var outroDropSec: TimeInterval = 8.0
            if tail {
                let threshold = peak * 0.42
                for i in stride(from: envCount - 1, through: envCount / 3, by: -1) {
                    if env[i] > threshold {
                        let tailFrames = envCount - 1 - i
                        let detected = Double(tailFrames) * 0.02
                        if detected >= 3.5 && detected <= 15.0 {
                            outroDropSec = detected
                        }
                        break
                    }
                }
            }

            // 3. Weighted Autocorrelation across 70..175 BPM
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
            let profile = TrackMixProfile(
                bpm: bpm,
                firstBeat: Double(firstBeatIdx) * 0.02,
                outroStartOffset: outroDropSec
            )
            if !id.isEmpty, bpm > 0 {
                profileCache[id] = profile
            }
            return profile
        } catch {
            return nil
        }
    }
}
