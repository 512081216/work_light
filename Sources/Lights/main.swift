import SwiftUI
import AppKit

extension Notification.Name {
    static let lightsResize = Notification.Name("LightsResize")
    static let lightsLayoutChanged = Notification.Name("LightsLayoutChanged")
    static let lightsRetentionChanged = Notification.Name("LightsRetentionChanged")
}

enum LightsDisplayMode: String, CaseIterable, Identifiable {
    case floating
    case notchLeading
    case conversations

    var id: String { rawValue }
    var label: String {
        switch self {
        case .floating: return "Floating corner"
        case .notchLeading: return "Left of notch"
        case .conversations: return "Conversation lights"
        }
    }
    var detail: String {
        switch self {
        case .floating: return "A movable light in the upper-right corner."
        case .notchLeading: return "A compact light attached to the left side of the MacBook notch."
        case .conversations: return "One light per conversation, in sidebar order. Completed tasks stay green until the idle timeout."
        }
    }
}

enum LightsSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }

    var bulb: CGFloat   { switch self { case .small: 16; case .medium: 22; case .large: 28 } }
    var spacing: CGFloat { switch self { case .small: 6;  case .medium: 8;  case .large: 10 } }
    var padding: CGFloat { switch self { case .small: 7;  case .medium: 9;  case .large: 11 } }
    var corner: CGFloat  { switch self { case .small: 12; case .medium: 15; case .large: 18 } }
    var socket: CGFloat { bulb + 8 }
    var glowOuter: CGFloat { bulb * 0.5 }
    var glowFar:   CGFloat { bulb * 1.0 }
    var highlightInset: CGFloat { bulb / 18 + 1 }
    var label: String { switch self { case .small: "Small"; case .medium: "Medium"; case .large: "Large" } }

    var windowSize: NSSize {
        NSSize(width: socket + 2 * padding,
               height: socket + 2 * padding)
    }
}

// MARK: - Entry

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
setupMainMenu(app: app)
app.run()

func setupMainMenu(app: NSApplication) {
    let main = NSMenu()
    let appItem = NSMenuItem()
    main.addItem(appItem)

    let appMenu = NSMenu()
    appMenu.addItem(NSMenuItem(
        title: "About Lights",
        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
        keyEquivalent: ""
    ))
    appMenu.addItem(.separator())
    appMenu.addItem(NSMenuItem(
        title: "Hide Lights",
        action: #selector(NSApplication.hide(_:)),
        keyEquivalent: "h"
    ))
    appMenu.addItem(.separator())
    appMenu.addItem(NSMenuItem(
        title: "Quit Lights",
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"
    ))
    appItem.submenu = appMenu

    app.mainMenu = main
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: FloatingWindow!
    var setupWindow: NSPanel?
    let statusServer = StatusServer()
    let menuBar = MenuBarController()
    private var conversationCount = 1

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement=true in Info.plist already hides Dock.
        // Belt-and-suspenders for builds run without the bundle:
        NSApp.setActivationPolicy(.accessory)
        // Start in multi-conversation mode even if another mode was used in
        // the previous run. The user can still switch modes while running.
        UserDefaults.standard.set(LightsDisplayMode.conversations.rawValue, forKey: "lightsDisplayMode")
        statusServer.start()
        menuBar.install()

        let mode = storedDisplayMode
        let size = windowSize(for: mode)
        let placement = windowPlacement(for: mode, size: size)
        NSLog("[Lights] Placing window at \(placement.origin) size \(size) in \(mode.rawValue) mode")

        let win = FloatingWindow(
            contentRect: NSRect(origin: placement.origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.backgroundColor = .clear
        win.isOpaque = false
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        win.contentView = NSHostingView(rootView: ContentView())
        configureWindow(win, for: mode)
        win.makeKeyAndOrderFront(nil)

        self.window = win
        NSApp.activate(ignoringOtherApps: true)

        NotificationCenter.default.addObserver(
            forName: .lightsResize, object: nil, queue: .main
        ) { [weak self] note in
            self?.applyResize(note)
        }
        NotificationCenter.default.addObserver(
            forName: .lightsToggleWindow, object: nil, queue: .main
        ) { [weak self] _ in
            self?.toggleWindowVisibility()
        }
        NotificationCenter.default.addObserver(
            forName: .lightsShowSetup, object: nil, queue: .main
        ) { [weak self] _ in
            self?.showSetupPanel()
        }
        NotificationCenter.default.addObserver(
            forName: .lightsLayoutChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyDisplayMode(animated: true)
        }
        NotificationCenter.default.addObserver(
            forName: .lightsRetentionChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.statusServer.reloadConversationRetention()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyDisplayMode(animated: false)
        }
        NotificationCenter.default.addObserver(
            forName: .lightsSessionsChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let sessions = note.userInfo?["sessions"] as? [ConversationLight] else { return }
            let count = max(1, sessions.count)
            guard count != self.conversationCount else { return }
            self.conversationCount = count
            if self.storedDisplayMode == .conversations { self.applyDisplayMode(animated: true) }
        }

        // First-launch: auto-open Setup
        if !SetupManager.hasSeenSetup {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showSetupPanel()
            }
        }
    }

    private func toggleWindowVisibility() {
        guard let win = window else { return }
        if win.isVisible {
            win.orderOut(nil)
        } else {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func showSetupPanel() {
        // Temporarily switch to regular activation so the window can take focus
        // and receive button clicks. Restored to .accessory on window close.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let panel = setupWindow {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let view = SetupView(onDone: { [weak self] in
            self?.setupWindow?.close()
        })
        let hosting = NSHostingView(rootView: view)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Lights Settings"
        panel.titleVisibility = .hidden     // hide title text (we have header inside)
        panel.titlebarAppearsTransparent = true
        panel.contentView = hosting
        panel.center()
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false     // don't auto-hide when user clicks elsewhere
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
        setupWindow = panel
    }

    private func applyResize(_ note: Notification) {
        guard let win = window,
              storedDisplayMode == .floating,
              let width  = note.userInfo?["width"]  as? CGFloat,
              let height = note.userInfo?["height"] as? CGFloat else { return }
        var frame = win.frame
        let oldTop = frame.maxY
        let oldRight = frame.maxX
        frame.size = NSSize(width: width, height: height)
        frame.origin.y = oldTop - height
        frame.origin.x = oldRight - width
        win.setFrame(frame, display: true, animate: true)
    }

    private var storedDisplayMode: LightsDisplayMode {
        let raw = UserDefaults.standard.string(forKey: "lightsDisplayMode")
        return LightsDisplayMode(rawValue: raw ?? "") ?? .conversations
    }

    private var storedSize: LightsSize {
        let raw = UserDefaults.standard.string(forKey: "lightsSize")
        return LightsSize(rawValue: raw ?? "") ?? .large
    }

    private func windowSize(for mode: LightsDisplayMode) -> NSSize {
        if mode == .floating { return storedSize.windowSize }
        let count = mode == .conversations ? conversationCount : 1
        return NSSize(width: 44 + CGFloat(count - 1) * 24, height: 32)
    }

    private func preferredScreen(for mode: LightsDisplayMode) -> NSScreen? {
        if mode != .floating {
            return NSScreen.screens.first {
                $0.safeAreaInsets.top > 0
                    || ($0.auxiliaryTopLeftArea != nil && $0.auxiliaryTopRightArea != nil)
            } ?? NSScreen.main ?? NSScreen.screens.first
        }
        return window?.screen ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func windowPlacement(for mode: LightsDisplayMode, size: NSSize) -> NSRect {
        guard let screen = preferredScreen(for: mode) else {
            return NSRect(origin: NSPoint(x: 1350, y: 810), size: size)
        }

        if mode != .floating {
            let notchLeft = screen.auxiliaryTopLeftArea?.maxX
                ?? (screen.frame.midX - 90)
            // Extend the housing underneath the notch's curved left edge.
            // Abutting its bounding box alone leaves a visible curved seam.
            let overlap: CGFloat = screen.safeAreaInsets.top > 0 ? 12 : 0
            let x = max(screen.frame.minX + 8, notchLeft - size.width + overlap)
            return NSRect(
                x: x,
                y: screen.frame.maxY - size.height,
                width: size.width,
                height: size.height
            )
        }

        let visible = screen.visibleFrame
        return NSRect(
            x: visible.maxX - size.width - 24,
            y: visible.maxY - size.height - 24,
            width: size.width,
            height: size.height
        )
    }

    private func configureWindow(_ win: FloatingWindow, for mode: LightsDisplayMode) {
        let notchMode = mode != .floating
        win.allowsFocus = !notchMode
        win.level = notchMode
            ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
            : .floating
        win.isMovableByWindowBackground = !notchMode
        win.hasShadow = !notchMode
    }

    private func applyDisplayMode(animated: Bool) {
        guard let win = window else { return }
        let mode = storedDisplayMode
        let size = windowSize(for: mode)
        configureWindow(win, for: mode)
        win.setFrame(windowPlacement(for: mode, size: size), display: true, animate: animated)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Menu bar agent stays alive even when no windows are open.
        false
    }

    // NSWindowDelegate
    func windowWillClose(_ notification: Notification) {
        if let panel = notification.object as? NSPanel, panel === setupWindow {
            SetupManager.markSetupSeen()
            setupWindow = nil
            // Return to accessory mode (no Dock icon) once setup window closes.
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

final class FloatingWindow: NSWindow {
    var allowsFocus = true
    override var canBecomeKey: Bool { allowsFocus }
    override var canBecomeMain: Bool { allowsFocus }

    // AppKit normally pushes windows below the menu bar. Notch mode needs its
    // top edge flush with the physical screen edge, just like a native island.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        allowsFocus ? super.constrainFrameRect(frameRect, to: screen) : frameRect
    }
}

// MARK: - Content

enum Light: Hashable { case red, yellow, green }

struct ContentView: View {
    @State private var conversations: [ConversationLight] = []
    @State private var active: Light? = .green
    @State private var yellowStickyUntil: Date = .distantPast
    @State private var greenCompletionFlashID = 0
    @AppStorage("lightsSize") private var size: LightsSize = .large
    @AppStorage("lightsDisplayMode") private var displayMode: LightsDisplayMode = .conversations

    var body: some View {
        Group {
        if displayMode == .conversations && !conversations.isEmpty {
            HStack(spacing: 0) {
                ForEach(conversations) { conversation in
                    ConversationBulb(conversation: conversation)
                        .frame(width: 24, height: 24)
                }
            }
        } else {
        LightView(
            palette: activePalette,
            isOn: active != nil,
            isAlerting: active == .yellow,
            isBreathing: active == .red,
            completionFlashID: greenCompletionFlashID,
            size: renderedSize,
            onTap: toggleManualOverride
        )
        .scaleEffect(displayMode != .floating ? 0.82 : 1.0)
        }
        }
        .frame(
            width: displayMode != .floating
                ? 36 + CGFloat(displayMode == .conversations ? max(0, conversations.count - 1) : 0) * 24 : nil,
            height: displayMode != .floating ? 24 : nil,
            alignment: .leading
        )
        .accessibilityLabel("Lights status")
        .accessibilityValue(accessibilityStatus)
        .padding(displayMode != .floating ? 4 : size.padding)
        .background(housing)
        .contextMenu {
            Menu("Display") {
                ForEach(LightsDisplayMode.allCases) { opt in
                    Button {
                        displayMode = opt
                    } label: {
                        HStack {
                            Text(opt.label)
                            if displayMode == opt { Spacer(); Image(systemName: "checkmark") }
                        }
                    }
                }
            }
            Menu("Size") {
                ForEach(LightsSize.allCases) { opt in
                    Button {
                        size = opt
                    } label: {
                        HStack {
                            Text(opt.label)
                            if size == opt { Spacer(); Image(systemName: "checkmark") }
                        }
                    }
                }
            }
            Divider()
            Button("Settings & Hooks…") {
                NotificationCenter.default.post(name: .lightsShowSetup, object: nil)
            }
            Divider()
            Button("Off") { setActive(nil) }
            Divider()
            Button("Quit Lights") { NSApp.terminate(nil) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lightsStateChange)) { note in
            guard let raw = note.userInfo?["state"] as? String else { return }
            handleSignal(raw)
        }
        .onReceive(NotificationCenter.default.publisher(for: .lightsSessionsChange)) { note in
            guard let sessions = note.userInfo?["sessions"] as? [ConversationLight] else { return }
            conversations = sessions
        }
        .onReceive(NotificationCenter.default.publisher(for: .lightsRequestOff)) { _ in
            setActive(nil)
        }
        .onChange(of: size) { _, newSize in
            guard displayMode == .floating else { return }
            let dim = newSize.windowSize
            NotificationCenter.default.post(
                name: .lightsResize, object: nil,
                userInfo: ["width": dim.width, "height": dim.height]
            )
        }
        .onChange(of: displayMode) { _, _ in
            NotificationCenter.default.post(name: .lightsLayoutChanged, object: nil)
        }
    }

    private var renderedSize: LightsSize {
        displayMode != .floating ? .small : size
    }

    private func handleSignal(_ raw: String) {
        let target: Light?
        switch raw {
        case "executing":  target = .red
        case "permission": target = .yellow
        case "idle":       target = .green
        case "off":        target = nil
        default: return
        }

        // Yellow is sticky briefly — guards against true ms-scale races
        // where /executing arrives right after /permission. Short enough
        // that intentional transitions (e.g. PostToolUse after the user
        // answers an AskUserQuestion) still take effect.
        if active == .yellow, target == .red, Date() < yellowStickyUntil {
            return
        }
        if target == .yellow {
            yellowStickyUntil = Date().addingTimeInterval(0.2)
        }
        if active == .red, target == .green {
            greenCompletionFlashID += 1
        }
        setActive(target)
    }

    private var housing: some View {
        let corner = displayMode != .floating ? 10 : size.corner
        return ZStack {
            housingShape(corner: corner)
                .fill(
                    LinearGradient(
                        colors: displayMode != .floating
                            ? [Color.black, Color.black]
                            : [Color(red: 0.18, green: 0.18, blue: 0.20),
                               Color(red: 0.07, green: 0.07, blue: 0.09)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            if displayMode == .floating {
            housingShape(corner: corner)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(displayMode == .notchLeading ? 0.10 : 0.20),
                            Color.white.opacity(0.03)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            }
        }
    }

    private func housingShape(corner: CGFloat) -> UnevenRoundedRectangle {
        if displayMode != .floating {
            return UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: corner,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0,
                style: .continuous
            )
        }
        return UnevenRoundedRectangle(
            topLeadingRadius: corner,
            bottomLeadingRadius: corner,
            bottomTrailingRadius: corner,
            topTrailingRadius: corner,
            style: .continuous
        )
    }

    private var activePalette: LightPalette {
        switch active {
        case .red:    return .red
        case .yellow: return .yellow
        case .green, nil: return .green
        }
    }

    private var accessibilityStatus: String {
        switch active {
        case .red:    return "Executing"
        case .yellow: return "Permission required"
        case .green:  return "Idle"
        case nil:     return "Off"
        }
    }

    private func toggleManualOverride() {
        setActive(active == nil ? .green : nil)
    }

    private func setActive(_ light: Light?) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) {
            active = light
        }
    }
}

// MARK: - Single Light

struct ConversationBulb: View {
    let conversation: ConversationLight
    @State private var completionID = 0

    private var palette: LightPalette {
        switch conversation.state {
        case .executing: return .red
        case .permission: return .yellow
        case .idle, .off: return .green
        }
    }

    var body: some View {
        LightView(
            palette: palette,
            isOn: conversation.state != .off,
            isAlerting: conversation.state == .permission,
            isBreathing: conversation.state == .executing,
            completionFlashID: completionID,
            size: .small,
            onTap: {}
        )
        .scaleEffect(0.82)
        .help(conversation.title + " — " + conversation.state.rawValue)
        .accessibilityLabel(conversation.title)
        .accessibilityValue(conversation.state.rawValue)
        .onChange(of: conversation.state) { old, new in
            if old == .executing && new == .idle { completionID += 1 }
        }
    }
}

struct LightPalette {
    let bright: Color
    let base: Color
    let dark: Color
    let glow: Color
    let dimBright: Color
    let dimBase: Color
    let dimDark: Color

    static let red = LightPalette(
        bright:    Color(red: 1.00, green: 0.66, blue: 0.66),
        base:      Color(red: 1.00, green: 0.18, blue: 0.22),
        dark:      Color(red: 0.94, green: 0.08, blue: 0.12),
        glow:      Color(red: 1.00, green: 0.06, blue: 0.10),
        dimBright: Color(red: 0.46, green: 0.20, blue: 0.20),
        dimBase:   Color(red: 0.28, green: 0.12, blue: 0.12),
        dimDark:   Color(red: 0.16, green: 0.07, blue: 0.07)
    )

    static let yellow = LightPalette(
        bright:    Color(red: 1.00, green: 0.98, blue: 0.62),
        base:      Color(red: 1.00, green: 0.72, blue: 0.04),
        dark:      Color(red: 0.96, green: 0.58, blue: 0.02),
        glow:      Color(red: 1.00, green: 0.64, blue: 0.00),
        dimBright: Color(red: 0.46, green: 0.40, blue: 0.18),
        dimBase:   Color(red: 0.28, green: 0.24, blue: 0.10),
        dimDark:   Color(red: 0.16, green: 0.14, blue: 0.06)
    )

    static let green = LightPalette(
        bright:    Color(red: 0.58, green: 1.00, blue: 0.64),
        base:      Color(red: 0.03, green: 0.96, blue: 0.30),
        dark:      Color(red: 0.02, green: 0.80, blue: 0.20),
        glow:      Color(red: 0.00, green: 1.00, blue: 0.24),
        dimBright: Color(red: 0.18, green: 0.40, blue: 0.22),
        dimBase:   Color(red: 0.09, green: 0.24, blue: 0.13),
        dimDark:   Color(red: 0.05, green: 0.14, blue: 0.08)
    )
}

struct LightView: View {
    @AppStorage(LightPreferences.brightnessKey) private var brightness = LightPreferences.defaultBrightness
    let palette: LightPalette
    let isOn: Bool
    let isAlerting: Bool
    let isBreathing: Bool
    let completionFlashID: Int
    let size: LightsSize
    let onTap: () -> Void

    @State private var pulse: CGFloat = 1.0
    @State private var alertPulse = false
    @State private var breathPulse = false
    @State private var completionFlash = false
    @State private var completionFlashGeneration = 0

    var body: some View {
        ZStack {
            // Socket (the dark well the bulb sits in)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.black.opacity(0.85),
                            Color.black.opacity(0.40)
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: size.socket / 2 + 2
                    )
                )
                .frame(width: size.socket, height: size.socket)
                .overlay(
                    Circle().strokeBorder(Color.black.opacity(0.6), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.6), radius: 1.5, x: 0, y: 1)

            // The bulb itself
            Circle()
                .fill(
                    RadialGradient(
                        colors: isOn
                            ? [palette.bright, palette.base, palette.dark]
                            : [palette.dimBright, palette.dimBase, palette.dimDark],
                        center: UnitPoint(x: 0.35, y: 0.30),
                        startRadius: 0.5,
                        endRadius: size.bulb * 0.65
                    )
                )
                .frame(width: size.bulb, height: size.bulb)
                .overlay(
                    // Specular glassy highlight
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(isOn ? 0.68 : 0.15),
                                    Color.white.opacity(0)
                                ],
                                startPoint: .topLeading,
                                endPoint: UnitPoint(x: 0.65, y: 0.55)
                            )
                        )
                        .padding(size.highlightInset)
                        .blur(radius: 0.4)
                )
                .brightness(isOn ? 0.06 : 0)
                .shadow(color: isOn ? palette.glow : .clear, radius: size.glowOuter)
                .shadow(color: isOn ? palette.glow.opacity(0.85) : .clear, radius: size.glowFar)
                .opacity(illuminationOpacity * (isOn ? LightPreferences.brightnessFactor(brightness) : 1))
                .scaleEffect(pulse * illuminationScale)
        }
        .contentShape(Circle())
        .onTapGesture {
            pulseAndTap()
        }
        .onAppear(perform: updateAlertAnimation)
        .onChange(of: isAlerting) { _, _ in
            updateAlertAnimation()
        }
        .onAppear(perform: updateBreathingAnimation)
        .onChange(of: isBreathing) { _, _ in
            updateBreathingAnimation()
        }
        .onChange(of: completionFlashID) { _, _ in
            startCompletionFlash()
        }
    }

    private var illuminationOpacity: Double {
        if isAlerting { return alertPulse ? 0.22 : 1.0 }
        if isBreathing { return breathPulse ? 0.78 : 1.0 }
        if completionFlash { return 0.22 }
        return 1.0
    }

    private var illuminationScale: CGFloat {
        if isAlerting { return 0.94 }
        if isBreathing { return breathPulse ? 0.96 : 1.0 }
        if completionFlash { return 0.94 }
        return 1.0
    }

    private func updateAlertAnimation() {
        guard isAlerting else {
            withAnimation(.easeOut(duration: 0.16)) {
                alertPulse = false
            }
            return
        }

        alertPulse = false
        withAnimation(.easeInOut(duration: 0.42).repeatForever(autoreverses: true)) {
            alertPulse = true
        }
    }

    private func updateBreathingAnimation() {
        guard isBreathing else {
            withAnimation(.easeOut(duration: 0.20)) {
                breathPulse = false
            }
            return
        }

        breathPulse = false
        withAnimation(.easeInOut(duration: 1.20).repeatForever(autoreverses: true)) {
            breathPulse = true
        }
    }

    private func startCompletionFlash() {
        guard completionFlashID > 0 else { return }
        completionFlashGeneration += 1
        let generation = completionFlashGeneration
        completionFlash = false
        withAnimation(.easeInOut(duration: 0.28).repeatForever(autoreverses: true)) {
            completionFlash = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            guard completionFlashGeneration == generation else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                completionFlash = false
            }
        }
    }

    private func pulseAndTap() {
        withAnimation(.spring(response: 0.18, dampingFraction: 0.55)) {
            pulse = 0.85
        }
        onTap()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            withAnimation(.spring(response: 0.40, dampingFraction: 0.55)) {
                pulse = 1.0
            }
        }
    }
}
