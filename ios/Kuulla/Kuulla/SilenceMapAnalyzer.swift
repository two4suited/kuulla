import AVFoundation
import SwiftData

// Produces a downloaded episode's silence map ahead of time (#777) by decoding the whole file
// with AVAssetReader — many times faster than real time — instead of relying on
// SmartSpeedProcessor's real-time tap, which can only react after a pause has already started
// and never knows how long it's about to continue. Runs once per download, triggered by
// DownloadManager right after a file finishes downloading; the result is cached on
// DownloadedEpisodeRecord so SpliceCompositionBuilder never has to re-decode the file.
enum SilenceMapAnalyzer {
    enum AnalysisError: Error {
        case noAudioTrack
        case readerFailed
    }

    // Decodes `fileURL` and writes the resulting silence map (or failure) onto the
    // DownloadedEpisodeRecord matching `episodeId` in a fresh ModelContext — a fresh context
    // (rather than one handed in) mirrors DownloadManager's own pattern for background work that
    // outlives the call that triggered it, since the record fetched by an earlier context could
    // already be stale by the time decoding finishes.
    //
    // `expectedLocalFilePath` guards against writing a stale analysis onto a record that has
    // since moved on to a different file: a delete-then-redownload (or a failed download retried)
    // reuses the same episodeId, so an earlier analysis task for the old file — still decoding
    // when the new download completes and starts its own analysis — must not overwrite the new
    // file's (possibly already-finished) silence map with results computed against bytes that no
    // longer exist on disk.
    static func analyzeAndStore(episodeId: String, fileURL: URL, expectedLocalFilePath: String, modelContainer: ModelContainer) async {
        let ranges: [SilenceRange]
        do {
            ranges = try await silenceRanges(of: fileURL)
        } catch {
            await MainActor.run {
                let context = ModelContext(modelContainer)
                guard let record = Self.fetchRecord(episodeId: episodeId, context: context),
                      record.localFilePath == expectedLocalFilePath
                else { return }
                record.silenceMapFailed = true
                try? context.save()
            }
            return
        }

        await MainActor.run {
            let context = ModelContext(modelContainer)
            guard let record = Self.fetchRecord(episodeId: episodeId, context: context),
                  record.localFilePath == expectedLocalFilePath
            else { return }
            record.silenceMapData = try? JSONEncoder().encode(ranges)
            record.silenceMapComputedAt = Date()
            record.silenceMapFailed = false
            try? context.save()
        }
    }

    private static func fetchRecord(episodeId: String, context: ModelContext) -> DownloadedEpisodeRecord? {
        let descriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { $0.id == episodeId })
        return try? context.fetch(descriptor).first
    }

    // Decodes the file's audio track to mono 32-bit float PCM and replays the resulting per-chunk
    // RMS levels through the same SilenceRunDetector state machine the real-time tap uses, so a
    // silence run only ever counts here if it also would have triggered the tap — same
    // threshold, same confirmation window, just computed ahead of time instead of live.
    static func silenceRanges(of fileURL: URL) async throws -> [SilenceRange] {
        let asset = AVURLAsset(url: fileURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AnalysisError.noAudioTrack
        }
        guard let reader = try? AVAssetReader(asset: asset) else { throw AnalysisError.readerFailed }

        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsNonInterleaved: true,
                AVNumberOfChannelsKey: 1,
            ])
        guard reader.canAdd(output) else { throw AnalysisError.readerFailed }
        reader.add(output)
        guard reader.startReading() else { throw AnalysisError.readerFailed }

        var levels: [(itemTime: TimeInterval, level: Float)] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let level = Self.rmsLevel(of: sampleBuffer) else { continue }
            let itemTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            guard itemTime.isFinite else { continue }
            levels.append((itemTime, level))
        }
        guard reader.status == .completed else { throw AnalysisError.readerFailed }

        return Self.silenceRanges(levels: levels)
    }

    // RMS of a mono-float sample buffer's data, mirroring SmartSpeedProcessor.process's own
    // sum-of-squares computation over an AudioBufferList — pulled apart here only because the
    // source is a CMSampleBuffer (from AVAssetReader) rather than a tap's AudioBufferList.
    private static func rmsLevel(of sampleBuffer: CMSampleBuffer) -> Float? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        let sampleCount = length / MemoryLayout<Float>.size
        guard sampleCount > 0 else { return nil }

        var sumOfSquares: Float = 0
        var status = noErr
        withUnsafeTemporaryAllocation(of: Float.self, capacity: sampleCount) { buffer in
            status = CMBlockBufferCopyDataBytes(
                blockBuffer, atOffset: 0, dataLength: length, destination: buffer.baseAddress!)
            guard status == noErr else { return }
            for sample in buffer {
                sumOfSquares += sample * sample
            }
        }
        guard status == noErr else { return nil }
        return (sumOfSquares / Float(sampleCount)).squareRoot()
    }

    // Pure: replays a sequence of (itemTime, level) readings through SilenceRunDetector's exact
    // state machine and collects each confirmed run as a SilenceRange. Split out from the
    // AVAssetReader I/O above so this state-machine-to-ranges logic is unit-testable against
    // synthetic level sequences, without decoding a real audio file.
    static func silenceRanges(levels: [(itemTime: TimeInterval, level: Float)]) -> [SilenceRange] {
        var detector = SilenceRunDetector()
        var ranges: [SilenceRange] = []
        var confirmedStart: TimeInterval?
        for (itemTime, level) in levels {
            guard let isSilent = detector.observe(level: level, itemTime: itemTime) else { continue }
            if isSilent {
                confirmedStart = itemTime - SmartSpeedProcessor.minimumSilenceDuration
            } else if let start = confirmedStart {
                ranges.append(SilenceRange(start: max(0, start), end: itemTime))
                confirmedStart = nil
            }
        }
        return ranges
    }
}
