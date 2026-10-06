import SwiftUI
import AppKit

struct SetupView: View {
    @ObservedObject var mgr: SetupManager = .shared
    @AppStorage("lightsDisplayMode") private var displayMode: LightsDisplayMode = .conversations
    @AppStorage(LightPreferences.idleMinutesKey) private var idleMinutes = LightPreferences.defaultIdleMinutes
    @AppStorage(LightPreferences.brightnessKey) private var brightness = LightPreferences.defaultBrightness
    var onDone: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            intro
            displaySettings
            toolList
            Spacer(minLength: 0)
            footer
        }
        .frame(width: 500, height: 620)
        .onAppear { mgr.refreshAll() }
    }

    private var displaySettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Display mode")
                .font(.headline)
            Picker("Display mode", selection: $displayMode) {
                ForEach(LightsDisplayMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(displayMode.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Text("灯的亮度")
                Slider(value: brightnessBinding, in: LightPreferences.brightnessRange)
                    .accessibilityLabel("灯的亮度")
                Text("\(Int(LightPreferences.clampedBrightness(brightness)))%")
                    .monospacedDigit()
                    .frame(width: 42, alignment: .trailing)
            }
            Text("适用于所有显示模式，调整后立即生效并自动保存。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            HStack {
                Text("空闲多久后移除灯")
                Spacer()
                TextField("分钟", value: idleMinutesBinding, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 68)
                Text("分钟")
                Stepper("空闲保留时间", value: idleMinutesBinding,
                        in: LightPreferences.idleMinutesRange)
                    .labelsHidden()
            }
            Text("完成后保留绿灯；连续空闲达到设定时间才移除。执行或等待审批不计时（1–1440 分钟）。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.55))
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .onChange(of: displayMode) { _, _ in
            NotificationCenter.default.post(name: .lightsLayoutChanged, object: nil)
        }
        .onChange(of: idleMinutes) { _, _ in
            NotificationCenter.default.post(name: .lightsRetentionChanged, object: nil)
        }
    }

    private var idleMinutesBinding: Binding<Int> {
        Binding(get: { LightPreferences.clampedIdleMinutes(idleMinutes) },
                set: { idleMinutes = LightPreferences.clampedIdleMinutes($0) })
    }

    private var brightnessBinding: Binding<Double> {
        Binding(get: { LightPreferences.clampedBrightness(brightness) },
                set: { brightness = LightPreferences.clampedBrightness($0.rounded()) })
    }

    private var header: some View {
        HStack {
            Text("Lights Settings")
                .font(.title2.bold())
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private var intro: some View {
        Text("Connect Lights to your AI coding tools. Lights must be running for hooks to reach it.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 12)
    }

    private var toolList: some View {
        VStack(spacing: 6) {
            ForEach(mgr.tools) { state in
                ToolRow(state: state, mgr: mgr)
            }
        }
        .padding(.horizontal, 20)
    }

    private var footer: some View {
        HStack {
            Text("Backups saved beside the config files.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Refresh") { mgr.refreshAll() }
            Button("Done") {
                SetupManager.markSetupSeen()
                onDone()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }
}

private struct ToolRow: View {
    @ObservedObject var state: ToolIntegrationState
    let mgr: SetupManager

    var body: some View {
        HStack(spacing: 12) {
            badge.frame(width: 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(state.tool.displayName).font(.body.weight(.medium))
                Text(state.tool.statusBlurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let err = state.lastError {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer()
            actionButton
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.4))
        )
    }

    @ViewBuilder
    private var badge: some View {
        switch state.status {
        case .configured:             dot(.green)
        case .toolPresentHookMissing: dot(.orange)
        case .toolNotInstalled:       dot(.gray)
        case .unknown:                dot(.red)
        }
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 10, height: 10)
    }

    @ViewBuilder
    private var actionButton: some View {
        switch (state.tool.supportLevel, state.status) {
        case (.notSupported, _):
            Text("N/A").font(.caption).foregroundStyle(.tertiary)
        case (.comingSoon, _):
            Text("v2").font(.caption).foregroundStyle(.tertiary)
        case (.events, .toolNotInstalled):
            Text("—").font(.caption).foregroundStyle(.tertiary)
        case (.events, .toolPresentHookMissing):
            Button("Install") { mgr.install(state) }
                .buttonStyle(.borderedProminent)
        case (.events, .configured):
            Button("Uninstall") { mgr.uninstall(state) }
        case (.events, .unknown):
            Button("Retry") { state.refresh() }
        }
    }
}
