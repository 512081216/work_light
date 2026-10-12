import Foundation

assert(LightBreathingProfile.minimumOpacity > 0)
assert(LightBreathingProfile.minimumOpacity <= 0.4)
assert(1 / LightBreathingProfile.minimumOpacity >= 3)
assert(LightBreathingProfile.minimumScale >= 0.85)
assert(LightBreathingProfile.minimumScale <= 0.95)
assert(LightBreathingProfile.minimumGlow > 0)
assert(LightBreathingProfile.minimumGlow <= 0.4)
assert(LightBreathingProfile.halfCycleSeconds * 2 == 2.8)
for brightness in [20.0, 50.0, 100.0] {
    let peak = LightPreferences.brightnessFactor(brightness)
    let trough = peak * LightBreathingProfile.minimumOpacity
    assert(trough > 0 && trough < peak)
    assert(peak <= 1)
    assert(abs(peak / trough - 3.125) < 0.0001)
}
print("PASS: breathing contrast, visible trough, smooth cycle, user brightness ceiling")
assert(CompletionFlashProfile.phases.count == 12)
assert(CompletionFlashProfile.phases.filter { $0 }.count == 6)
assert(CompletionFlashProfile.phases.last == false)
assert(UInt64(CompletionFlashProfile.phases.count) * CompletionFlashProfile.phaseNanoseconds == 3_000_000_000)
print("PASS: green flash is finite, six flashes, three seconds, ends steady")
let steady = LightIllumination(opacity: 1, scale: 1, glow: 1)
for tick in 0..<3000 {
    let time = Double(tick) / 30
    // Sample a red frame immediately before every green frame to detect leakage.
    _ = LightIllumination.sample(at: time, breathing: true, alerting: false, completionFlash: false)
    assert(LightIllumination.sample(at: time, breathing: false, alerting: false, completionFlash: false) == steady)
}
let redPeak = LightIllumination.sample(at: 0, breathing: true, alerting: false, completionFlash: false)
let redTrough = LightIllumination.sample(at: 1.4, breathing: true, alerting: false, completionFlash: false)
assert(redPeak == steady)
assert(abs(redTrough.opacity - 0.32) < 0.000001)
assert(abs(redTrough.scale - 0.90) < 0.000001)
assert(abs(redTrough.glow - 0.30) < 0.000001)
assert(LightIllumination.sample(at: 0, breathing: false, alerting: true, completionFlash: false).opacity == 0.22)
assert(LightIllumination.sample(at: 0.43, breathing: false, alerting: true, completionFlash: false).opacity == 1)
print("PASS: 3000 red-to-green samples stay constant, red peak/trough, yellow flash")
