import AppKit
import Foundation

// Snapshot rendering is irrelevant to this isolated lifecycle server test.
class FloatingWindow: NSWindow {}
let preferences = UserDefaults(suiteName: "LightsRetentionTests-\(UUID().uuidString)")!
assert(LightPreferences.idleRetention(defaults: preferences) == 1800)
preferences.setVolatileDomain([LightPreferences.idleMinutesKey: 5], forName: UserDefaults.argumentDomain)
assert(LightPreferences.idleRetention(defaults: preferences) == 300)
preferences.setVolatileDomain([LightPreferences.idleMinutesKey: 60], forName: UserDefaults.argumentDomain)
assert(LightPreferences.idleRetention(defaults: preferences) == 3600)
assert(LightPreferences.clampedIdleMinutes(0) == 1)
assert(LightPreferences.clampedIdleMinutes(2000) == 1440)
assert(LightPreferences.defaultBrightness == 100)
assert(LightPreferences.brightnessFactor(100) == 1)
assert(LightPreferences.brightnessFactor(20) == 0.2)
assert(LightPreferences.clampedBrightness(-1) == 20)
assert(LightPreferences.clampedBrightness(200) == 100)
assert(LightPreferences.clampedBrightness(.nan) == 100)
// Accelerated timeout; production defaults to 30 * 60 seconds.
let server = StatusServer(port: 19876, conversationIdleRetention: 6)
server.start()
RunLoop.main.run()
