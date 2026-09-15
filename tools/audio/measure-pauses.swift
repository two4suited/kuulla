import AVFoundation
import Foundation

// Finds silent runs in a file using the app's own threshold (RMS < 0.008 over ~20ms windows) and
// reports how much wall-clock time the current rate-multiplier design removes vs. a real splice.
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let file = try AVAudioFile(forReading: url)
let format = file.processingFormat
let frameCount = AVAudioFrameCount(file.length)
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
try file.read(into: buffer)
let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
let sr = format.sampleRate
let window = Int(sr * 0.02)
let threshold: Float = 0.008
var runs: [Double] = []
var runStart: Int? = nil
var i = 0
while i + window <= samples.count {
    var ss: Float = 0
    for j in i..<(i + window) { ss += samples[j] * samples[j] }
    let rms = (ss / Float(window)).squareRoot()
    if rms < threshold {
        if runStart == nil { runStart = i }
    } else if let s = runStart {
        runs.append(Double(i - s) / sr); runStart = nil
    }
    i += window
}
if let s = runStart { runs.append(Double(samples.count - s) / sr) }
let total = Double(samples.count) / sr
print(String(format: "file %.1fs, %d silent runs, silence total %.2fs", total, runs.count, runs.reduce(0, +)))
print("run lengths: " + runs.map { String(format: "%.2f", $0) }.joined(separator: " "))

let minSilence = 0.8, multiplier = 4.0, spliceFloor = 0.25
for speed in [1.0, 2.0, 3.0] {
    var currentSaved = 0.0, spliceSaved = 0.0, eligible = 0
    for r in runs {
        if r >= minSilence {
            eligible += 1
            let tail = r - minSilence
            currentSaved += (tail / speed) * (1 - 1 / multiplier)
        }
        if r > spliceFloor { spliceSaved += (r - spliceFloor) / speed }
    }
    print(String(format: "at %.0fx: runs >= 0.8s: %d | current design saves %.2fs (%.1f%% of listen time) | splice-to-%.2fs saves %.2fs (%.1f%%)",
                 speed, eligible, currentSaved, 100 * currentSaved / (total / speed), spliceFloor, spliceSaved, 100 * spliceSaved / (total / speed)))
}
