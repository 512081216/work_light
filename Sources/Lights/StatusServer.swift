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
        var taskActivityAt: Date? = nil
        var awaitingOfficialApproval = false
        var pendingOfficialApprovalKeys: Set<String> = []
    }

    private var codexSessions: [String: CodexSession] = [:]
    private struct RuntimeState {
        let state: LightsState
        let revision: Int
        let observedAt: Date
    }
    private struct RuntimeStream {
        let heartbeat: Date
        let entries: [String: RuntimeState]
    }
    private var runtimeStreams: [String: RuntimeStream] = [:]
    private var runtimeTimer: DispatchSourceTimer?
    private var sidebarOrder: [String] = []
    // The desktop watcher supplies the complete visible top-level roster.
    // Runtime notifications also include internal/guardian/subagent threads;
    // they must never create additional user conversation lamps.
    private var visibleConversationIDs: Set<String>?
    private var pendingQuestionIDs: Set<String> = []
    private var sessionTitles: [String: String] = [:]
    private var codexIdleWork: [String: DispatchWorkItem] = [:]
    private let codexStopGracePeriod: TimeInterval = 5
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
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.stateLock.lock()
                let hadRuntime = !self.runtimeStreams.isEmpty
                self.runtimeStreams = self.runtimeStreams.filter {
                    Date().timeIntervalSince($0.value.heartbeat) < 5
                }
                // Expire idle conversation views even without any new events.
                // Preserve legacy/global state when no runtime owns it.
                let state = hadRuntime ? self.codexAggregateLocked() : self.currentState
                self.currentState = state
                self.stateLock.unlock()
                self.publishState(state)
            }
            runtimeTimer = timer
            timer.resume()
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
        case "/codex-runtime-snapshot":
            return handleRuntimeSnapshot(body)
        case "/status":
            return Response(status: "200 OK", body: currentStateSnapshot().rawValue)
        case "/sessions":
            stateLock.lock()
            let sessions = conversationLightsLocked()
            stateLock.unlock()
            let json = sessions.map { ["id": $0.id, "title": $0.title, "state": $0.state.rawValue] }
            let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("[]".utf8)
            return Response(status: "200 OK", body: String(decoding: data, as: UTF8.self))
        case "/diagnostics":
            stateLock.lock()
            let diagnostics: [[String: Any]] = codexSessions.compactMap { id, session in
                guard isVisibleConversationLocked(id, session: session) else { return nil }
                let runtime = runtimeStateLocked(id)
                return ["id": id, "fallback": session.state.rawValue,
                        "effective": effectiveStateLocked(id, fallback: session.state).rawValue,
                        "runtime": runtime?.state.rawValue ?? "none",
                        "runtime_revision": runtime?.revision ?? 0,
                        "runtime_streams": runtimeStreams.compactMap { streamID, stream -> [String: Any]? in
                            guard let entry = stream.entries[id] else { return nil }
                            return ["stream": streamID, "state": entry.state.rawValue,
                                    "revision": entry.revision,
                                    "heartbeat_age": Date().timeIntervalSince(stream.heartbeat),
                                    "state_age": Date().timeIntervalSince(entry.observedAt)]
                        },
                        "pending_question": pendingQuestionIDs.contains(id),
                        "official_approval_count": session.pendingOfficialApprovalKeys.count,
                        "jsonl_active": session.jsonlActiveTurnID != nil]
            }
            stateLock.unlock()
            let data = (try? JSONSerialization.data(withJSONObject: diagnostics)) ?? Data("[]".utf8)
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
        let approvalKey = normalizedIdentifier(json["call_id"]).map { "call:\($0)" }
            ?? normalizedIdentifier(json["tool_name"]).map { "tool:\($0)" }
            ?? "unknown"

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

        if !isStart, let turnID, session.closedTurnIDs.contains(turnID) {
            stateLock.unlock()
            return Response(status: "200 OK", body: "stale")
        }
        if source != "codex-jsonl", isStart, session.currentTurnID != turnID || session.state == .idle {
            session.taskActivityAt = now
        }

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
            if turnID == nil || session.currentTurnID != turnID {
                session.awaitingOfficialApproval = false
                session.pendingOfficialApprovalKeys.removeAll()
            }
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
            if session.awaitingOfficialApproval { session.state = .permission }
        } else if isPermission {
            // PreToolUse is only a prediction: escalation may be accepted
            // automatically without any human decision. Latch only an actual
            // PermissionRequest, not every permission-coloured tool start.
            if source == "codex-official", event == "PermissionRequest" {
                session.pendingOfficialApprovalKeys.insert(approvalKey)
                session.awaitingOfficialApproval = true
            }
            cancelCodexIdleLocked(sessionID)
            if let turnID { session.currentTurnID = turnID }
            session.terminalTurnID = nil
            session.generation += 1
            session.state = .permission
        } else if isWork {
            if source == "codex-official", event == "PostToolUse" {
                session.pendingOfficialApprovalKeys.remove(approvalKey)
                session.awaitingOfficialApproval = !session.pendingOfficialApprovalKeys.isEmpty
            }
            cancelCodexIdleLocked(sessionID)
            if session.currentTurnID == nil { session.currentTurnID = turnID }
            session.terminalTurnID = nil
            session.hadToolUse = true
            session.generation += 1
            session.state = session.awaitingOfficialApproval ? .permission : .executing
        } else if isTerminal {
            if event != "Stop" {
                session.awaitingOfficialApproval = false
                session.pendingOfficialApprovalKeys.removeAll()
            }
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
                    if session.state == .permission {
                        // A provisional Stop is not an approval response.
                        // Never time out a still-pending human decision.
                        cancelCodexIdleLocked(sessionID)
                    } else {
                        scheduleCodexIdleLocked(sessionID, generation: session.generation,
                                                delay: codexStopGracePeriod)
                    }
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
        if let questions = json["pending_questions"] as? [String] {
            pendingQuestionIDs = Set(questions)
            for id in pendingQuestionIDs where codexSessions[id] == nil {
                codexSessions[id] = CodexSession(currentTurnID: nil, terminalTurnID: nil,
                    closedTurnIDs: [], state: .idle, hadToolUse: false,
                    hasJSONLActivity: true, jsonlActiveTurnID: nil,
                    generation: 1, lastEventAt: now)
            }
        }
        if let titles = json["titles"] as? [String: String] {
            visibleConversationIDs = Set(titles.keys)
        } else if let order = json["sidebar_order"] as? [String] {
            visibleConversationIDs = Set(order)
        }
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
                    session.pendingOfficialApprovalKeys.removeAll()
                }
                session.currentTurnID = active.turnID
                session.terminalTurnID = nil
                session.jsonlActiveTurnID = active.turnID
                // An observed result proves this exact call is no longer
                // awaiting approval, even if its official PostToolUse was
                // dropped. Never clear unrelated or anonymous approvals.
                if let completed = (json["completed_calls"] as? [String: [String]])?[sessionID] {
                    for callID in completed.prefix(512) {
                        session.pendingOfficialApprovalKeys.remove("call:\(callID)")
                    }
                    session.awaitingOfficialApproval = !session.pendingOfficialApprovalKeys.isEmpty
                }
                session.state = session.awaitingOfficialApproval ? .permission : active.state
            } else {
                session.awaitingOfficialApproval = false
                session.pendingOfficialApprovalKeys.removeAll()
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

        // Recover real task timestamps after Lights/watcher restarts. Merely
        // observing an old idle thread must not start a fresh retention period.
        if let activity = json["activity_at"] as? [String: NSNumber] {
            for (id, value) in activity {
                let date = Date(timeIntervalSince1970: value.doubleValue / 1000)
                guard value.doubleValue.isFinite, date.timeIntervalSince1970 > 0,
                      date <= now.addingTimeInterval(60), var session = codexSessions[id] else { continue }
                if session.taskActivityAt == nil || date > session.taskActivityAt! {
                    session.taskActivityAt = date
                }
                codexSessions[id] = session
            }
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

    // Live app-server state overrides heuristics only while its bridge is alive.
    // Heartbeats do not renew completed conversation retention.
    private func handleRuntimeSnapshot(_ body: String) -> Response {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streamID = normalizedIdentifier(json["stream_id"]),
              let entries = json["sessions"] as? [[String: Any]], entries.count <= 1024 else {
            return Response(status: "400 Bad Request", body: "invalid runtime snapshot")
        }
        stateLock.lock()
        let now = Date()
        let previous = runtimeStreams[streamID]?.entries ?? [:]
        var states: [String: RuntimeState] = [:]
        for entry in entries {
            guard let id = normalizedIdentifier(entry["session_id"]),
                  let raw = entry["state"] as? String,
                  let state = LightsState(rawValue: raw), state != .off,
                  let revision = entry["revision"] as? Int else { continue }
            let old = previous[id]
            states[id] = RuntimeState(state: state, revision: revision,
                                      observedAt: old?.revision == revision ? old!.observedAt : now)
            if var session = codexSessions[id] {
                if state == .idle, old != nil, old?.state != .idle {
                    session.taskActivityAt = now
                }
                if old?.revision != revision { session.lastEventAt = now }
                codexSessions[id] = session
            } else {
                codexSessions[id] = CodexSession(currentTurnID: nil, terminalTurnID: nil,
                    closedTurnIDs: [], state: .idle, hadToolUse: false,
                    hasJSONLActivity: false, jsonlActiveTurnID: nil,
                    generation: 0, lastEventAt: now)
            }
        }
        if states.isEmpty { runtimeStreams.removeValue(forKey: streamID) }
        else { runtimeStreams[streamID] = RuntimeStream(heartbeat: now, entries: states) }
        let aggregate = codexAggregateLocked()
        currentState = aggregate
        stateLock.unlock()
        publishState(aggregate)
        return Response(status: "200 OK", body: aggregate.rawValue)
    }

    private func effectiveStateLocked(_ id: String, fallback: LightsState) -> LightsState {
        if pendingQuestionIDs.contains(id) { return .permission }
        return runtimeStateLocked(id)?.state ?? fallback
    }

    private func runtimeStateLocked(_ id: String) -> RuntimeState? {
        runtimeStreams.values.filter { Date().timeIntervalSince($0.heartbeat) < 5 }
            .compactMap { $0.entries[id] }.max { $0.observedAt < $1.observedAt }
    }

    private func codexAggregateLocked() -> LightsState {
        let states = codexSessions.filter { isVisibleConversationLocked($0.key, session: $0.value) }
            .map { effectiveStateLocked($0.key, fallback: $0.value.state) }
        if states.contains(.permission) { return .permission }
        if states.contains(.executing) { return .executing }
        return .idle
    }

    private func isVisibleConversationLocked(_ id: String, session: CodexSession) -> Bool {
        if let visibleConversationIDs { return visibleConversationIDs.contains(id) }
        // Before the first roster arrives, runtime-only identities are not
        // evidence of a user-visible conversation. Hooks/JSONL retain fallback.
        return session.generation > 0
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
            guard isVisibleConversationLocked(id, session: session) else { return nil }
            let runtime = runtimeStateLocked(id)
            let state = effectiveStateLocked(id, fallback: session.state)
            // Execution/approval never expires. Idle snapshots must not reset
            // lastEventAt: only a new task or its completion renews retention.
            guard state == .executing || state == .permission
                    || (state == .idle
                        && now.timeIntervalSince(session.taskActivityAt ?? runtime?.observedAt ?? session.lastEventAt) < conversationIdleRetention)
                else { return nil }
            return ConversationLight(id: id, title: sessionTitles[id] ?? id, state: state)
        }.sorted {
            let a = rank[$0.id] ?? Int.max, b = rank[$1.id] ?? Int.max
            return a == b ? $0.id < $1.id : a < b
        }
    }
}
