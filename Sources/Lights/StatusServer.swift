import Foundation
import Network
import AppKit

extension Notification.Name {
    static let lightsStateChange = Notification.Name("LightsStateChange")
    static let lightsSessionsChange = Notification.Name("LightsSessionsChange")
}

struct ConversationLight: Identifiable, Equatable {
    let id: String
    let title: String
    let state: LightsState
}

enum LightsState: String {
    case executing
    case permission
    case idle
    case off
}

final class StatusServer {
    private let port: NWEndpoint.Port
    private var listener: NWListener?
    private(set) var currentState: LightsState = .idle
    private let stateLock = NSLock()
    private var pendingIdleWork: DispatchWorkItem?
    private var stateGeneration = 0
    private let idleGracePeriod: TimeInterval = 8

    // Codex emits lifecycle events for a session, not for a global light.
    // Keep the identity and a small per-turn fence so a late Stop from an
    // older turn cannot turn an active session green.
    private struct CodexSession {
        var currentTurnID: String?
        var terminalTurnID: String?
        var closedTurnIDs: [String]
        var state: LightsState
        var hadToolUse: Bool
        var hasJSONLActivity: Bool
        var jsonlActiveTurnID: String?
        var generation: Int
        var lastEventAt: Date
        var awaitingOfficialApproval = false
    }

    private var codexSessions: [String: CodexSession] = [:]
    private var sidebarOrder: [String] = []
    private var sessionTitles: [String: String] = [:]
    private var codexIdleWork: [String: DispatchWorkItem] = [:]
    private let codexStopGracePeriod: TimeInterval = 5
    private let codexPermissionGracePeriod: TimeInterval = 30
    private let conversationIdleRetentionOverride: TimeInterval?
    private var conversationIdleRetention: TimeInterval {
        conversationIdleRetentionOverride ?? LightPreferences.idleRetention()
    }

    init(port: UInt16 = 9876, conversationIdleRetention: TimeInterval? = nil) {
        self.port = NWEndpoint.Port(rawValue: port)!
        self.conversationIdleRetentionOverride = conversationIdleRetention
    }

    func reloadConversationRetention() {
        stateLock.lock()
        let state = currentState
        stateLock.unlock()
        publishState(state)
    }

    func start() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(.loopback),
                port: port
            )
            let listener = try NWListener(using: params)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            listener.start(queue: .global(qos: .utility))
            NSLog("[Lights] StatusServer listening on 127.0.0.1:\(port.rawValue)")
        } catch {
            NSLog("[Lights] StatusServer failed to start: \(error)")
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .utility))
        receiveRequest(conn, accumulated: Data())
    }

    private func receiveRequest(_ conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, let data else {
                conn.cancel()
                return
            }
            var buffer = accumulated
            buffer.append(data)
            guard buffer.count <= 1024 * 1024 else { conn.cancel(); return }
            let separator = Data("\r\n\r\n".utf8)
            if let range = buffer.range(of: separator) {
                let header = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
                let length = header.components(separatedBy: "\r\n").first {
                    $0.lowercased().hasPrefix("content-length:")
                }.flatMap { Int($0.split(separator: ":", maxSplits: 1).last?
                    .trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
                if buffer.count - range.upperBound < length {
                    if complete || error != nil { conn.cancel(); return }
                    self.receiveRequest(conn, accumulated: buffer)
                    return
                }
            } else {
                if complete || error != nil { conn.cancel(); return }
                self.receiveRequest(conn, accumulated: buffer)
                return
            }
            guard let req = String(data: buffer, encoding: .utf8) else { conn.cancel(); return }
            let request = self.parseRequest(req)
            let response = self.route(path: request.path, body: request.body)
            let body = response.body
            let http = """
            HTTP/1.1 \(response.status)\r
            Content-Type: text/plain; charset=utf-8\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r
            \(body)
            """
            conn.send(content: Data(http.utf8), completion: .contentProcessed { _ in
                conn.cancel()
            })
        }
    }

    private struct ParsedRequest {
        let path: String
        let body: String
    }

    private func parseRequest(_ request: String) -> ParsedRequest {
        let firstLine = request.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return ParsedRequest(path: "/", body: "") }
        let body = request.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
        return ParsedRequest(path: String(parts[1]), body: body)
    }

    private struct Response {
        let status: String
        let body: String
    }

    private func route(path: String, body: String = "") -> Response {
        let cleaned = path.split(separator: "?").first.map(String.init) ?? path
        switch cleaned {
        case "/executing":
            return setState(.executing)
        case "/permission":
            return setState(.permission)
        case "/idle":
            return setState(.idle)
        case "/off":
            return setState(.off)
        case "/codex-event":
            return handleCodexEvent(body)
        case "/codex-snapshot":
            return handleCodexSnapshot(body)
        case "/status":
            return Response(status: "200 OK", body: currentStateSnapshot().rawValue)
        case "/sessions":
            stateLock.lock()
            let sessions = conversationLightsLocked()
            stateLock.unlock()
            let json = sessions.map { ["id": $0.id, "title": $0.title, "state": $0.state.rawValue] }
            let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("[]".utf8)
            return Response(status: "200 OK", body: String(decoding: data, as: UTF8.self))
        case "/snapshot":
            return Response(status: "200 OK", body: snapshotPNG() ?? "error")
        case "/", "/health":
            return Response(status: "200 OK", body: "lights ok")
        default:
            return Response(status: "404 Not Found", body: "unknown route")
        }
    }

    /// Render the floating window's content view to a PNG and write to /tmp.
    /// Returns the file path on success. Used for demo / marketing capture
    /// without requiring system Screen Recording permission.
    private func snapshotPNG() -> String? {
        var resultPath: String?
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.main.async {
            defer { group.leave() }
            guard let view = NSApp.windows
                    .first(where: { $0 is FloatingWindow })?.contentView else { return }
            let bounds = view.bounds
            guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
            view.cacheDisplay(in: bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { return }
            let path = "/tmp/lights-snapshot-\(Int(Date().timeIntervalSince1970 * 1000)).png"
            do {
                try data.write(to: URL(fileURLWithPath: path))
                resultPath = path
            } catch {
                NSLog("[Lights] snapshot write failed: \(error)")
            }
        }
        _ = group.wait(timeout: .now() + 1.0)
        return resultPath
    }

    private func setState(_ state: LightsState) -> Response {
        stateLock.lock()
        if state == .off {
            codexIdleWork.values.forEach { $0.cancel() }
            codexIdleWork.removeAll()
            codexSessions.removeAll()
        }
        stateGeneration += 1
        let generation = stateGeneration
        pendingIdleWork?.cancel()
        pendingIdleWork = nil

        // Codex can emit a transient Stop/idle event between tool calls while
        // the same task is still running. Keep the last busy state until idle
        // remains stable long enough to be considered a real completion.
        if state == .idle {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.stateLock.lock()
                guard generation == self.stateGeneration else {
                    self.stateLock.unlock()
                    return
                }
                let codexState = self.codexAggregateLocked()
                self.currentState = codexState == .idle ? .idle : codexState
                self.pendingIdleWork = nil
                let published = self.currentState
                self.stateLock.unlock()
                self.publishState(published)
            }
            pendingIdleWork = work
            stateLock.unlock()
            DispatchQueue.main.asyncAfter(
                deadline: .now() + idleGracePeriod,
                execute: work
            )
            return Response(status: "200 OK", body: state.rawValue)
        }

        currentState = state
        stateLock.unlock()
        publishState(state)
        return Response(status: "200 OK", body: state.rawValue)
    }

    private func currentStateSnapshot() -> LightsState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return currentState
    }

    // MARK: - Codex structured lifecycle

    private func handleCodexEvent(_ body: String) -> Response {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = json["event"] as? String,
              !event.isEmpty else {
            return Response(status: "400 Bad Request", body: "invalid codex event")
        }

        let sessionID = normalizedIdentifier(json["session_id"])
            ?? normalizedIdentifier(json["sessionId"])
            ?? "default"
        let turnID = normalizedIdentifier(json["turn_id"])
            ?? normalizedIdentifier(json["turnId"])
        let incomingState = LightsState(rawValue: (json["state"] as? String) ?? "")
        let source = normalizedIdentifier(json["source"]) ?? "codex-official"
        let stopHookActive = json["stop_hook_active"] as? Bool == true

        stateLock.lock()
        if stopHookActive {
            stateLock.unlock()
            return Response(status: "200 OK", body: "ignored")
        }

        var session = codexSessions[sessionID] ?? CodexSession(
            currentTurnID: nil,
            terminalTurnID: nil,
            closedTurnIDs: [],
            state: .idle,
            hadToolUse: false,
            hasJSONLActivity: false,
            jsonlActiveTurnID: nil,
            generation: 0,
            lastEventAt: Date()
        )
        let now = Date()
        session.lastEventAt = now

        let isStart = event == "UserPromptSubmit" || event == "event_msg:task_started"
        let isWork = event == "PreToolUse" || event == "PostToolUse"
            || incomingState == .executing
        let isPermission = event == "PermissionRequest" || incomingState == .permission
        let isTerminal = event == "Stop" || event == "event_msg:task_complete"
            || event == "event_msg:turn_aborted" || event == "SessionEnd"

        if source == "codex-jsonl" {
            session.hasJSONLActivity = true
        }

        // JSONL is a fallback and often has no turn_id. Its old final record
        // must never terminate a turn that the official hook has just opened.
        // A turn-aware JSONL terminal is still accepted below.
        if source == "codex-jsonl",
           isTerminal,
           turnID == nil {
            stateLock.unlock()
            return Response(status: "200 OK", body: "ambiguous")
        }

        // A terminal event from a different turn is stale. This is the
        // important distinction missing from the old global curl hooks.
        if isTerminal,
           let turnID,
           let currentTurnID = session.currentTurnID,
           currentTurnID != turnID {
            stateLock.unlock()
            return Response(status: "200 OK", body: "stale")
        }
        if isWork,
           let turnID,
           let terminalTurnID = session.terminalTurnID,
           terminalTurnID != turnID,
           session.currentTurnID != nil {
            stateLock.unlock()
            return Response(status: "200 OK", body: "stale")
        }

        if isStart {
            session.awaitingOfficialApproval = false
            cancelCodexIdleLocked(sessionID)
            session.currentTurnID = turnID ?? UUID().uuidString
            if source == "codex-jsonl", event == "event_msg:task_started" {
                session.jsonlActiveTurnID = session.currentTurnID
            }
            session.terminalTurnID = nil
            session.hadToolUse = false
            session.generation += 1
            session.state = event == "event_msg:task_started" || incomingState != .idle
                ? .executing : .idle
        } else if isPermission {
            if source == "codex-official" { session.awaitingOfficialApproval = true }
            cancelCodexIdleLocked(sessionID)
            if let turnID { session.currentTurnID = turnID }
            session.terminalTurnID = nil
            session.generation += 1
            session.state = .permission
        } else if isWork {
            if source == "codex-official", event == "PostToolUse" {
                session.awaitingOfficialApproval = false
            }
            cancelCodexIdleLocked(sessionID)
            if session.currentTurnID == nil { session.currentTurnID = turnID }
            session.terminalTurnID = nil
            session.hadToolUse = true
            session.generation += 1
            session.state = session.awaitingOfficialApproval ? .permission : .executing
        } else if isTerminal {
            if event != "Stop" { session.awaitingOfficialApproval = false }
            let terminalTurnID = turnID ?? session.currentTurnID
            session.terminalTurnID = terminalTurnID
            session.generation += 1

            if event == "Stop" {
                // The official Stop hook can fire between model/tool phases.
                // While JSONL still has an active turn it is only provisional,
                // so keep the busy state. If JSONL already completed the turn,
                // Stop is a late duplicate and must not resurrect a red light.
                if session.jsonlActiveTurnID != nil {
                    if session.state != .permission { session.state = .executing }
                    cancelCodexIdleLocked(sessionID)
                } else if session.hasJSONLActivity {
                    cancelCodexIdleLocked(sessionID)
                    session.currentTurnID = nil
                    session.state = .idle
                } else {
                    if session.state != .permission { session.state = .executing }
                    scheduleCodexIdleLocked(
                        sessionID,
                        generation: session.generation,
                        delay: session.state == .permission
                            ? codexPermissionGracePeriod : codexStopGracePeriod
                    )
                }
            } else {
                cancelCodexIdleLocked(sessionID)
                if let terminalTurnID, !session.closedTurnIDs.contains(terminalTurnID) {
                    session.closedTurnIDs.append(terminalTurnID)
                    if session.closedTurnIDs.count > 128 { session.closedTurnIDs.removeFirst() }
                }
                session.jsonlActiveTurnID = nil
                session.currentTurnID = nil
                session.state = .idle
            }
        } else if let incomingState {
            session.state = incomingState
        }

        codexSessions[sessionID] = session
        let aggregate = codexAggregateLocked()
        currentState = aggregate
        stateLock.unlock()
        publishState(aggregate)
        return Response(status: "200 OK", body: aggregate.rawValue)
    }

    /// Reconcile JSONL-backed sessions against the complete set of open Codex
    /// turns observed in the current poll. Event delivery can be missed while
    /// Lights is restarting; this snapshot is what removes those ghost turns.
    private func handleCodexSnapshot(_ body: String) -> Response {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              normalizedIdentifier(json["source"]) == "codex-jsonl",
              let entries = json["active"] as? [[String: Any]] else {
            return Response(status: "400 Bad Request", body: "invalid codex snapshot")
        }

        var activeBySession: [String: (turnID: String, state: LightsState)] = [:]
        for entry in entries {
            guard let sessionID = normalizedIdentifier(entry["session_id"]),
                  let turnID = normalizedIdentifier(entry["turn_id"]) else { continue }
            let state: LightsState = entry["state"] as? String == LightsState.permission.rawValue
                ? .permission : .executing
            if activeBySession[sessionID]?.state != .permission {
                activeBySession[sessionID] = (turnID, state)
            }
        }

        stateLock.lock()
        let now = Date()
        if let order = json["sidebar_order"] as? [String] { sidebarOrder = order }
        if let titles = json["titles"] as? [String: String] { sessionTitles = titles }
        for sessionID in Array(codexSessions.keys) {
            guard var session = codexSessions[sessionID],
                  session.hasJSONLActivity || activeBySession[sessionID] != nil else { continue }
            session.hasJSONLActivity = true
            cancelCodexIdleLocked(sessionID)
            session.generation += 1
            if activeBySession[sessionID] != nil || session.state != .idle {
                session.lastEventAt = now
            }
            if let active = activeBySession.removeValue(forKey: sessionID) {
                if session.currentTurnID != active.turnID {
                    session.awaitingOfficialApproval = false
                }
                session.currentTurnID = active.turnID
                session.terminalTurnID = nil
                session.jsonlActiveTurnID = active.turnID
                session.state = session.awaitingOfficialApproval ? .permission : active.state
            } else {
                session.awaitingOfficialApproval = false
                if let turnID = session.currentTurnID { session.terminalTurnID = turnID }
                session.currentTurnID = nil
                session.jsonlActiveTurnID = nil
                session.state = .idle
            }
            codexSessions[sessionID] = session
        }

        for (sessionID, active) in activeBySession {
            codexSessions[sessionID] = CodexSession(
                currentTurnID: active.turnID,
                terminalTurnID: nil,
                closedTurnIDs: [],
                state: active.state,
                hadToolUse: false,
                hasJSONLActivity: true,
                jsonlActiveTurnID: active.turnID,
                generation: 1,
                lastEventAt: now
            )
        }

        let aggregate = codexAggregateLocked()
        currentState = aggregate
        stateLock.unlock()
        publishState(aggregate)
        return Response(status: "200 OK", body: aggregate.rawValue)
    }

    private func normalizedIdentifier(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(256))
    }

    private func codexAggregateLocked() -> LightsState {
        if codexSessions.values.contains(where: { $0.state == .permission }) { return .permission }
        if codexSessions.values.contains(where: { $0.state == .executing }) { return .executing }
        return .idle
    }

    private func cancelCodexIdleLocked(_ sessionID: String) {
        codexIdleWork.removeValue(forKey: sessionID)?.cancel()
    }

    private func scheduleCodexIdleLocked(
        _ sessionID: String,
        generation: Int,
        delay: TimeInterval
    ) {
        cancelCodexIdleLocked(sessionID)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            guard var session = self.codexSessions[sessionID],
                  session.generation == generation else {
                self.stateLock.unlock()
                return
            }
            session.currentTurnID = nil
            session.terminalTurnID = nil
            session.state = .idle
            self.codexSessions[sessionID] = session
            self.codexIdleWork.removeValue(forKey: sessionID)
            let aggregate = self.codexAggregateLocked()
            self.currentState = aggregate
            self.stateLock.unlock()
            self.publishState(aggregate)
        }
        codexIdleWork[sessionID] = work
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + delay,
            execute: work
        )
    }

    private func publishState(_ state: LightsState) {
        stateLock.lock()
        let sessions = conversationLightsLocked()
        stateLock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .lightsStateChange,
                object: nil,
                userInfo: ["state": state.rawValue]
            )
            NotificationCenter.default.post(
                name: .lightsSessionsChange, object: nil,
                userInfo: ["sessions": sessions]
            )
        }
    }

    private func conversationLightsLocked() -> [ConversationLight] {
        let now = Date()
        let rank = Dictionary(sidebarOrder.enumerated().map { ($0.element, $0.offset) },
                              uniquingKeysWith: { first, _ in first })
        return codexSessions.compactMap { id, session -> ConversationLight? in
            // Execution/approval never expires. Idle snapshots must not reset
            // lastEventAt: only a new task or its completion renews retention.
            guard session.state == .executing || session.state == .permission
                    || (session.state == .idle
                        && now.timeIntervalSince(session.lastEventAt) < conversationIdleRetention)
                else { return nil }
            return ConversationLight(id: id, title: sessionTitles[id] ?? id, state: session.state)
        }.sorted {
            let a = rank[$0.id] ?? Int.max, b = rank[$1.id] ?? Int.max
            return a == b ? $0.id < $1.id : a < b
        }
    }
}
