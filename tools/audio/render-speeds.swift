import AVFoundation
import Foundation

// Renders a speech sample through AVFoundation's time-pitch algorithms at several rates using a
// scaled AVMutableComposition + AVAssetExportSession — the same AVAudioTimePitchAlgorithm
// implementations AVPlayer uses for AVPlayerItem.audioTimePitchAlgorithm.
let args = CommandLine.arguments
let input = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])

struct Variant { let name: String; let rate: Double; let algo: AVAudioTimePitchAlgorithm }
let variants: [Variant] = [
    .init(name: "00_1x_reference", rate: 1, algo: .timeDomain),
    .init(name: "01_2x_timeDomain_CURRENT", rate: 2, algo: .timeDomain),
    .init(name: "02_2x_spectral", rate: 2, algo: .spectral),
    .init(name: "03_3x_timeDomain_CURRENT", rate: 3, algo: .timeDomain),
    .init(name: "04_3x_spectral", rate: 3, algo: .spectral),
    .init(name: "05_3x_varispeed_nopitchcorrection", rate: 3, algo: .varispeed),
    .init(name: "06_8x_timeDomain_silenceSkipRate_at_2x", rate: 8, algo: .timeDomain),
    .init(name: "07_12x_timeDomain_silenceSkipRate_at_3x", rate: 12, algo: .timeDomain),
    .init(name: "08_12x_spectral", rate: 12, algo: .spectral),
]

func render(_ v: Variant) async throws {
    let asset = AVURLAsset(url: input)
    guard let srcTrack = try await asset.loadTracks(withMediaType: .audio).first else { fatalError("no audio track") }
    let duration = try await asset.load(.duration)
    let comp = AVMutableComposition()
    let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
    let range = CMTimeRange(start: .zero, duration: duration)
    try track.insertTimeRange(range, of: srcTrack, at: .zero)
    comp.scaleTimeRange(range, toDuration: CMTimeMultiplyByFloat64(duration, multiplier: 1.0 / v.rate))
    guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A) else {
        fatalError("no export session")
    }
    export.audioTimePitchAlgorithm = v.algo
    let out = outDir.appendingPathComponent("\(v.name).m4a")
    try? FileManager.default.removeItem(at: out)
    try await export.export(to: out, as: .m4a)
    let outAsset = AVURLAsset(url: out)
    let outDuration = try await outAsset.load(.duration).seconds
    print(String(format: "%@  rate=%.0fx  %@  -> %.2fs", v.name, v.rate, v.algo.rawValue, outDuration))
}

for v in variants {
    try await render(v)
}
