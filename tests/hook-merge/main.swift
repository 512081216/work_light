import Foundation

let command = JSONHookMerger.codexHookCommand
var settings: [String: Any] = ["hooks": Dictionary(uniqueKeysWithValues:
    JSONHookMerger.codexHookSpecs.map { spec in
        (spec.event, [["hooks": [
            ["type": "command", "command": "other-first", "timeout": 600],
            ["type": "command", "command": command, "timeout": 30000],
            ["type": "command", "command": "other-last"]
        ]]] as [[String: Any]])
    })]
let before = settings as NSDictionary
JSONHookMerger.mergeCodexPreservingPositions(into: &settings)
precondition(before.isEqual(to: settings), "Reinstall must preserve all existing trust positions/definitions")
JSONHookMerger.mergeCodexPreservingPositions(into: &settings)
precondition(before.isEqual(to: settings), "Repeated reinstall must be a no-op")
var missing: [String: Any] = ["hooks": ["PermissionRequest": [["hooks": [["command": "other"]]]]]]
JSONHookMerger.mergeCodexPreservingPositions(into: &missing)
let groups = (missing["hooks"] as! [String: Any])["PermissionRequest"] as! [[String: Any]]
precondition(groups.count == 2)
precondition((groups[0]["hooks"] as! [[String: Any]])[0]["command"] as! String == "other")
let once = missing as NSDictionary
JSONHookMerger.mergeCodexPreservingPositions(into: &missing)
precondition(once.isEqual(to: missing))
print("PASS: reinstall preserves hook definitions/indices; missing hooks append idempotently")
