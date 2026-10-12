import Foundation

// Shared by floating, notch, and conversation bulbs. Values are relative to
// the user's brightness, so breathing never raises their configured maximum.
enum LightBreathingProfile {
    static let minimumOpacity = 0.32
    static let minimumScale = 0.90
    static let minimumGlow = 0.30
    static let halfCycleSeconds = 1.40
}

struct LightIllumination: Equatable {
    let opacity: Double
    let scale: Double
    let glow: Double

    static func sample(at time: TimeInterval, breathing: Bool, alerting: Bool,
                       completionFlash: Bool) -> LightIllumination {
        if alerting {
            let dim = Int(floor(time / 0.42)).isMultiple(of: 2)
            return LightIllumination(opacity: dim ? 0.22 : 1, scale: 0.94, glow: 1)
        }
        if breathing {
            let phase = time.truncatingRemainder(dividingBy: LightBreathingProfile.halfCycleSeconds * 2)
            let level = (1 + cos(phase * .pi / LightBreathingProfile.halfCycleSeconds)) / 2
            func interpolate(_ minimum: Double) -> Double { minimum + (1 - minimum) * level }
            return LightIllumination(opacity: interpolate(LightBreathingProfile.minimumOpacity),
                scale: interpolate(LightBreathingProfile.minimumScale),
                glow: interpolate(LightBreathingProfile.minimumGlow))
        }
        // Green has no time-dependent values, even immediately after red.
        return LightIllumination(opacity: completionFlash ? 0.22 : 1,
                                 scale: completionFlash ? 0.94 : 1, glow: 1)
    }
}
