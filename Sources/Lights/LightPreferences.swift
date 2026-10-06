import Foundation

enum LightPreferences {
    static let brightnessKey = "lightsBrightnessPercent"
    static let defaultBrightness = 100.0
    static let brightnessRange = 20.0...100.0

    static func clampedBrightness(_ value: Double) -> Double {
        guard value.isFinite else { return defaultBrightness }
        return min(brightnessRange.upperBound, max(brightnessRange.lowerBound, value))
    }

    static func brightnessFactor(_ value: Double) -> Double {
        clampedBrightness(value) / 100
    }

    static let idleMinutesKey = "lightsConversationIdleMinutes"
    static let defaultIdleMinutes = 30
    static let idleMinutesRange = 1...1440

    static func clampedIdleMinutes(_ value: Int) -> Int {
        min(idleMinutesRange.upperBound, max(idleMinutesRange.lowerBound, value))
    }

    static func idleRetention(defaults: UserDefaults = .standard) -> TimeInterval {
        let minutes = (defaults.object(forKey: idleMinutesKey) as? NSNumber)?.intValue
            ?? defaultIdleMinutes
        return TimeInterval(clampedIdleMinutes(minutes) * 60)
    }
}
