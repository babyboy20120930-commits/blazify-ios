import Accelerate
import AVFoundation
import Foundation

actor AutoMixEngine {
    static let shared = AutoMixEngine()

    private var bpmCache: [String: (bpm: Double, firstBeat: TimeInterval)] = [:]

    func computeTransition(
        outgoingURL: URL?,
        outgoingId: String,
        incomingURL: URL?,
        incomingId: String,
        baseSpeed: Float
    ) async -> (startRate: Float, targetRate: Float, seekOffset: Double, beatSynced: Bool) {
        async let outInfo = analyze(url: outgoingURL, id: outgoingId, tail: true)
        async let inInfo = analyze(url: incomingURL, id: incomingId, tail: false)

        let (outBPM, _) = await outInfo
        let (inBPM, inFirstBeat) = await inInfo

        guard outBPM > 55, inBPM > 55 else {
            return (baseSpeed, baseSpeed, 0, false)
        }

        // Normalize half/double tempo (e.g. 75 BPM vs 150 BPM)
        var targetInBPM = inBPM
        if targetInBPM < outBPM * 0.72 { targetInBPM *= 2.0 }
        if targetInBPM > outBPM * 1.38 { targetInBPM /= 2.0 }

        let ratio = Float(outBPM / targetInBPM)
        // Allow up to ±12% smooth tempo matching so beats lock together clearly
        let clampedRatio = min(max(ratio, 0.88), 1.12)

        return (baseSpeed * clampedRatio, baseSpeed, min(inFirstBeat, 6.0), true)
    }

    private func analyze(url: URL?, id: String, tail: Bool) async -> (Double, TimeInterval) {
        if !id.isEmpty, let cached = bpmCache[id] { return cached }

        // Resolve local file first, otherwise fall back to streaming URL via AVAssetReader
        let resolvedURL: URL? = await MainActor.run {
            if let own = LocalMusic.shared.localAudioURL(for: id) { return own }
            if let dl = Downloads.shared.localAudioURL(for: id) { return dl }
            if let cache = AudioCache.shared.cachedURL(for: id) { return cache }
            return url
        }

        guard let targetURL = resolvedURL else { return (0, 0) }

        do {
            let asset = AVURLAsset(url: targetURL, options: [
                AVURLAssetHTTPUserAgentKey: YouTube.visionUA
            ])
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let audioTrack = tracks.first else { return (0, 0) }

            let durationCM = try await asset.load(.duration)
            let totalSec = durationCM.seconds
            guard totalSec.isFinite, totalSec > 6.0 else { return (0, 0) }

            let reader = try AVAssetReader(asset: asset)
            let windowSec = min(totalSec, 20.0)
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
            guard reader.canAdd(output) else { return (0, 0) }
            reader.add(output)
            guard reader.startReading() else { return (0, 0) }

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

            guard samples.count > 44100 else { return (0, 0) }

            // Compute RMS energy envelope in 20ms hops (50 Hz envelope rate)
            let hop = Int(22050.0 * 0.02)
            let envCount = samples.count / hop
            guard envCount > 120 else { return (0, 0) }

            var env = [Float](repeating: 0, count: envCount)
            samples.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                for i in 0..<envCount {
                    var rms: Float = 0
                    vDSP_rmsqv(base.advanced(by: i * hop), 1, &rms, vDSP_Length(hop))
                    env[i] = rms
                }
            }

            // Onset strength (positive half-wave rectified difference)
            var onset = [Float](repeating: 0, count: envCount)
            var firstBeatIdx = 0
            var peak: Float = 0
            vDSP_maxv(env, 1, &peak, vDSP_Length(envCount))
            for i in 1..<envCount {
                onset[i] = max(0, env[i] - env[i - 1])
                if firstBeatIdx == 0 && env[i] > peak * 0.30 {
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
            if !id.isEmpty, bpm > 0 {
                bpmCache[id] = result
            }
            return result
        } catch {
            return (0, 0)
        }
    }
}
