# Audio engine bench tools

Two throwaway-grade macOS scripts used for
[docs/audio-engine-research.md](../../docs/audio-engine-research.md). They run against
the same AVFoundation code paths the iOS app uses, so what you hear from them is what
`AVPlayer` produces on device.

```sh
# A spoken-word sample with explicit pauses (macOS TTS; any speech file works too).
say -v Samantha -f sample-script.txt -o speech.aiff

# Render the sample through every AVAudioTimePitchAlgorithm at 1x/2x/3x plus the
# silence-skip rates, one .m4a per variant, so the algorithms can be A/B'd by ear.
swiftc -O render-speeds.swift -o render && ./render speech.aiff out/

# Find silent runs with SmartSpeedProcessor's own threshold and report how much listening
# time the current rate-multiplier trim removes vs. a real splice.
swiftc -O measure-pauses.swift -o pauses && ./pauses speech.aiff
```
