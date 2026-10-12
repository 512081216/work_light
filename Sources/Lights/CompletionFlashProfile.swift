enum CompletionFlashProfile {
    // Six discrete flashes over three seconds, ending at steady brightness.
    // No repeating animation: green must never inherit a breathing effect.
    static let phases = (0..<12).map { $0.isMultiple(of: 2) }
    static let phaseNanoseconds: UInt64 = 250_000_000
}
