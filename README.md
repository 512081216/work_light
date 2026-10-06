# Work Light · AI 工作状态灯

一个 macOS 菜单栏应用，用灯光显示 AI 编程助手的执行、等待审批和空闲状态。应用名称仍为 **Lights**。

本仓库基于 [fengyiqicoder/Lights](https://github.com/fengyiqicoder/Lights) 开发，重点增强 Codex 桌面版的会话监控、多对话显示与刘海贴合效果，保留原项目 MIT 许可证和署名。

## 灯光状态

| 灯光 | 状态 | 效果 |
|---|---|---|
| 🔴 红灯 | 正在执行任务 | 呼吸灯 |
| 🟡 黄灯 | 检测到审批或输入等待 | 持续闪烁，直到对应等待解除 |
| 🟢 绿灯 | 空闲或任务完成 | 从红灯切换时闪烁约 3 秒，再常亮 |

单灯显示所有已跟踪 Codex 对话的汇总状态，优先级为：等待审批 > 正在执行 > 空闲。多灯模式分别显示每个对话的状态。

## 显示模式与设置

右键状态灯，选择 **Settings & Hooks…**；也可从菜单栏图标进入设置。

| 设置 | 说明 |
|---|---|
| `Floating corner` | 可移动的单灯浮窗，初始位于屏幕右上角；支持 Small / Medium / Large 尺寸 |
| `Left of notch` | 单灯贴合刘海左侧，黑色外壳与刘海衔接，右下角不设圆角 |
| `Conversation lights` | 每个活跃本地 Codex 对话一盏灯，按侧栏顺序从左到右排列；悬停显示标题和状态 |
| 灯的亮度 | 20%–100%，默认 100%；所有模式立即生效，自动保存 |
| 空闲多久后移除灯 | 1–1440 分钟，默认 30 分钟；修改后立即生效，自动保存 |

**每次启动默认进入多灯模式**，即使上次退出前使用其他模式。启动后仍可手动切换。

多灯模式的“活跃”包括正在执行、等待审批，以及完成任务后尚未达到空闲期限的对话：

- 任务完成不会立即隐藏灯：绿灯提示后继续常亮。
- 空闲达到设置的时间、期间没有新任务，才移除对话的灯；不需要等归档。
- 新任务复用同一对话的灯，并在任务完成后重新计算空闲时间。
- 执行或等待审批期间不会因空闲期限到达而移除。
- 没有活跃对话时显示一盏待机灯；重启 Lights 后重新收集对话，亮度和保留时间设置不变。

桌面监视器参考置顶、项目、聊天排序设置，并排除子代理对话。刘海模式使用固定紧凑尺寸；没有刘海时回退到屏幕顶部中间偏左的位置。

## 系统要求

- macOS 14 或更高版本。
- Swift 5.9 或更高版本，以及与当前 macOS SDK 匹配的 Xcode 或 Command Line Tools。
- 当前构建脚本指定 `arm64`，面向 Apple Silicon；Intel Mac 未经本项目验证。
- Node.js：用于 Codex hook、桌面监视器和测试。测试脚本使用内置 `fetch`，需要 Node.js 18 或更高版本。
- 桌面监视器调用 `/usr/bin/sqlite3` 和 `/usr/bin/curl`。

## 从源码安装

```bash
git clone https://github.com/512081216/work_light.git
cd work_light
./build-app.sh
open Lights.app
```

构建脚本会编译发布版、生成应用图标、打包 Codex hook，并对 `Lights.app` 进行本地 ad-hoc 签名。可将生成的应用拖入“应用程序”目录，再从那里启动。

**本增强版没有声明 Developer ID 签名或 Apple 公证。** 上游下载包不包含这里的新增功能，其签名和公证信息也不代表本仓库。

### 配置 Codex hooks

首次启动会打开设置。找到 **Codex CLI**，点击 **Install**。安装逻辑会：

1. 将 `Resources/lights-codex-hook.js` 安装到 `~/.codex/lights-codex-hook.js`。
2. 合并 `~/.codex/hooks.json` 中的 Lights 生命周期 hooks，替换旧的全局通知。
3. 在 `~/.codex/config.toml` 中尝试启用 `features.hooks = true`。

hook 传递会话、任务和可用的工具调用标识，避免不同对话、旧任务与并行工具相互覆盖状态。JSON hook 配置写入前生成带时间戳的备份，并保留其他 hooks。

实际事件是否发出取决于 Codex 版本。**Hooks configured ✓** 只表示检测到配置，不代表所有桌面审批类型都已实测。更新应用内的 hook 脚本后，可重新安装以更新稳定路径下的运行脚本。

### 启动 Codex 桌面监视器

桌面版可能没有完整发出 hooks。建议使用桌面版时同时运行监视器：

```bash
node lights-codex-desktop-watcher.js
```

保持终端运行；按 `Ctrl+C` 停止。监视器约每秒读取本机会话数据库和增量 JSONL 日志，向已运行的 Lights 发送会话状态及快照。

数据目录优先级为 `LIGHTS_CODEX_HOME` > `CODEX_HOME` > `~/.codex`：

```bash
LIGHTS_CODEX_HOME="/path/to/codex-data" node lights-codex-desktop-watcher.js
```

当前实现使用 `state_5.sqlite`、`.codex-global-state.json` 获取会话、标题和侧栏顺序，最多扫描最近更新的 256 个未归档、非子代理对话。

仓库不会自动安装开机启动服务。如需常驻运行，可自行配置 LaunchAgent，使用 Node 和脚本的**绝对路径**。更新监视器源码后必须重启进程，旧进程不会自动加载新文件。

### 其他编程助手

| 工具 | 当前实现 |
|---|---|
| Codex | 会话级 hooks + 本机桌面 JSONL 监视器；多对话灯主要针对 Codex |
| Claude Code | 可配置 `~/.claude/settings.json` 的全局状态 hooks；不会生成逐对话灯 |
| Goose / OpenCode | 占位实现，尚未接入状态监控 |

## 监控逻辑与限制

Lights 根据事件判断状态，不用“文件最近被修改”推断任务仍在执行。任务完成、中止记录用于结束红灯；会话快照用于校正遗漏或过期状态。

审批跟踪包括显式权限申请、用户输入工具及可识别的提权调用。执行单元返回 `Script running with cell ID …` 时，监视器继续跟踪后续 `wait`，不会把临时返回当作审批结束。官方 hook 提供调用标识时，只由匹配结果解除对应审批，不由无关并行输出清除。

已知限制：

- **不能承诺识别所有审批弹窗。** 若 Codex 或插件没有对应 hook，且 JSONL 也没有可识别的等待信息，Lights 无法仅凭弹窗存在判断状态。
- 一个执行单元可能先审批、再做其他工作。JSONL 只记录整个调用返回时，黄灯可能保持到执行单元真正结束。
- 侧栏排序依赖 Codex 本地存储格式；自定义分组、未识别的排序设置或超出扫描上限的对话可能无法完整还原。
- 空闲期限在状态刷新时判定。监视器正常轮询会持续刷新；仅用 hooks、长时间没有新事件时，灯的移除可能延后。
- 重启 Lights 不恢复此前所有已完成对话的内存状态；监视器重新发现的活跃任务会再次显示。
- 菜单栏空间不足时图标可能被刘海遮住，可右键状态灯打开设置。菜单栏图标不是实时彩色状态灯。
- 无刘海屏幕、多显示器、全屏空间和 Intel Mac 的行为不保证与已验证本机效果完全一致。

## 本机 HTTP 接口

服务只绑定 `127.0.0.1:9876`，不要转发到公网。全局手动状态可能被自动事件覆盖；多灯优先显示会话状态，不应使用全局接口测试某个对话。

| 路径 | 用途 |
|---|---|
| `/status` | 查询汇总状态：`executing` / `permission` / `idle` / `off` |
| `/sessions` | 返回当前可显示对话的 `id`、`title`、`state`，按灯的顺序排列 |
| `/executing`、`/permission`、`/idle`、`/off` | 全局状态控制，主要用于单灯调试 |
| `/codex-event` | 接收 hook 的会话/任务事件，使用 JSON 请求体 |
| `/codex-snapshot` | 接收桌面监视器的活动任务快照，使用 JSON 请求体 |
| `/snapshot` | 将 Lights 自身窗口保存为本机 `/tmp` 下的 PNG，返回路径 |

```bash
curl -s http://127.0.0.1:9876/status
curl -s http://127.0.0.1:9876/sessions
```

## 开发与测试

```bash
# 编译应用
swift build --disable-sandbox -c release --arch arm64

# 检查 JavaScript 并验证审批跟踪
node --check Resources/lights-codex-hook.js
node --check lights-codex-desktop-watcher.js
node tests/approval-watcher.js

# 编译隔离的状态服务测试入口
swiftc -module-cache-path .build/test-module-cache \
  Sources/Lights/LightPreferences.swift \
  Sources/Lights/StatusServer.swift \
  tests/retention-server/main.swift \
  -o .build/retention-test-server

# 验证会话保留、超时、审批关联与快照合并
node tests/conversation-retention.js .build/retention-test-server
```

隔离测试使用 `127.0.0.1:19876` 和加速的 6 秒空闲期限，不写入正常 Lights 会话。确保该端口空闲，不要并行运行两份测试。测试通过不代表所有 Codex 版本、插件审批和设备均已实测。

## 常见问题

**Swift SDK 或工具链不匹配**

检查 `xcode-select -p`、`xcrun --show-sdk-path`、`swift --version`，确认开发工具、SDK 和 macOS 相容。完整 Xcode 需完成首次启动及许可确认；Command Line Tools 也需匹配 SDK。不要混用不同安装目录的编译器和 SDK。

**任务开始后灯没有变化**

查询 `/status`、`/sessions` 确认服务正常，再检查 hooks 是否实际发出、监视器是否运行、数据目录是否正确。首次监控需要读取日志，可能稍后才显示全部当前任务。

**审批时没有黄灯，或审批结束仍是黄灯**

确认后台已重启到新代码，记录当时的工具名称、审批类型和 `/sessions` 结果。显式权限申请、插件授权、异步输入不是相同事件，排查时需区分；不要用全局 `/permission` 替代真实事件链验证。

**完成后绿灯一直保留**

默认保留 30 分钟，可修改「空闲多久后移除灯」。监视器持续轮询才能及时刷新超时结果。

## 源码结构

```text
Sources/Lights/
  main.swift                    应用启动、显示模式、灯光与动画
  StatusServer.swift            HTTP 服务、会话状态、审批合并和空闲保留
  LightPreferences.swift        亮度和保留时间的默认值及范围
  SetupView.swift               设置界面
  SetupManager.swift            工具配置状态管理
  MenuBarController.swift       菜单栏入口
  CodexIntegration.swift        Codex hook 安装与移除
  ClaudeCodeIntegration.swift   Claude Code hook 配置
  JSONHookMerger.swift          JSON hook 合并、备份及命令构造
Resources/lights-codex-hook.js   官方 hook 的 stdin 接收与状态转发
lights-codex-desktop-watcher.js  本机 JSONL 监视器与侧栏排序
tests/                         审批跟踪和状态服务回归测试
build-app.sh                   应用打包及本地签名
tools/                         图标和上游演示辅助脚本
```

构建产物、缓存和本机日志不属于源码发布内容。监视器只向本机回环接口发送状态；编程助手自身的网络行为不由 Lights 管理。

## 许可证

[MIT License](LICENSE)。保留上游版权声明及许可条款；`docs` 中旧演示素材不表示增强版的最新界面。
