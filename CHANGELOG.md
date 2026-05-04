# Changelog

All notable changes are listed here. Each release section is bilingual
(English first, 中文 second). Format loosely follows [Keep a Changelog](https://keepachangelog.com).

The English half of each section is what GitHub's Release page shows;
the 中文 half lives here only.

## v0.9.0 — 2026-05-04

### Changed
- **LimitBar redesigned around the projection signal.** The 4 pt sage
  rail grows to a 12 pt bar that hosts the percent text inside it
  (right-anchored, mono). The burn-rate signal is now a **dashed
  vertical marker** that *only* appears when current pace would push
  the limit past 100% before reset — the marker overflows past the
  bar's right edge in warn-amber and the footer picks up a
  `projected 118%` note. Healthy projections (≤ 100%) stay silent:
  the bar fill alone communicates "you have headroom," and a marker
  that sits right next to the fill (e.g. current 29% / projected 31%)
  is pure noise. Replaces the v0.8 ghost-extension + ↗ arrow combo,
  which proved hard to read at 4 pt and over-relied on chromatic
  severity.
- The 20% elapsed-window gate from v0.8 stays — projection math
  doesn't even run until at least 20% of the window has elapsed,
  so a single early prompt can't false-trigger the alarm.

### Docs
- README + README.zh-CN updated to describe the alarm-only signal.

### 中文

- **LimitBar 围绕「预测信号」整体重做**：4 pt 的 sage 细条变成 12 pt
  的 bar，百分数直接放进 bar 里（右对齐 mono）。burn-rate 信号换成
  **虚线竖向 marker**，*只*在「按当前速度到 reset 时会冲破 100%」
  时才出现——marker 在 bar 右边缘溢出，染 warn-amber，footer 补一行
  `projected 118%`。projected ≤ 100% 全部静默：bar 留白本身就告诉
  你「还有空间」，多画一根挨着 fill 的小竖线（比如 29% / 31% 那种）
  纯属噪音。替换 v0.8 的「幽灵延伸 + ↗ 箭头」，那套在 4 pt 高度上
  太难辨认，且过度依赖颜色分级。
- v0.8 引入的「窗口走完 20% 才开始算预测」门继续保留——单次大请求
  没法把信号炸出来。
- README + README.zh-CN 更新了 burn-rate 那段，对齐新的"只报警"行为。

---

## v0.8.0 — 2026-04-30

### Added
- **Burn-rate projection on rolling-window bars.** Each 5h / weekly bar
  now draws a faint ghost extension showing where you'll land at reset
  if usage continues at the current rate. An ↗ arrow appears next to
  the percent text when the projection clearly overshoots 100% (5pt
  grace) — so you spot "I'm going to run out before Sunday" while
  there's still time to slow down. Linear extrapolation, ignored in
  the first 60s of a window where burn rate is too noisy. Applies to
  Claude Code and Codex.
- **Per-model breakdown under Claude weekly bar.** Anthropic's
  `/api/oauth/usage` ships separate utilization buckets per model
  family — Sonnet, Opus, Haiku. We now surface them as indented mono
  rows directly under the weekly bar, sorted by share descending.
  Models with 0% are dropped (no "Haiku 0%" noise). Tells you which
  model is actually eating the budget.

### Docs
- README rewritten for the v0.8 launch: new tagline, "Why MyUsage"
  opener, Highlights re-ordered to lead with the multi-device +
  multi-provider moat (the only true differentiator vs CodexBar /
  ccusage / the long tail), provider table updated to reflect v0.7.x
  reality, Roadmap pruned of items already shipped.
- `docs/competitive-analysis.md` added — survey of ~12 competitors,
  per-tool notes, and ranked distribution channels with drafted
  Show HN / Reddit / Product Hunt posts.
- `docs/release.md` (new) carries the internal release-flow notes
  (CHANGELOG extraction pipeline, tag-failure recovery procedure)
  that used to clutter the user-facing README.
- GitHub repository metadata set: description, homepage, 12 topics
  for discoverability.

### 中文

- **滚动窗口 bar 增加 burn-rate 预测**：每条 5 小时 / 每周 bar 上叠一层
  幽灵延伸，按当前消耗速度预测 reset 时会落在哪里。如果预测会突破
  100%（>105% 以避免 "101%" 误报），百分数旁边出现红色 ↗ 箭头——
  让你在还有时间放慢之前看到"周日要爆了"。线性外推；窗口刚开始
  60 秒内不预测（数据太抖）。Claude Code 和 Codex 都生效。
- **Claude weekly 卡内多出 per-model 拆分**：Anthropic 的
  `/api/oauth/usage` 本来就返回 Sonnet / Opus / Haiku 的分别用量，
  我们之前没用上。现在在 weekly 主条下面以缩进 mono 列出，按消耗
  排序，0% 的不显示。一眼看到是哪个模型在吃额度。
- README 为 v0.8 上线重写：新 tagline、"Why MyUsage" 开篇、
  Highlights 按 moat-first 重排（multi-device + multi-provider 的
  组合是唯一真护城河），Provider 表格更新到 v0.7.x 现实，Roadmap
  砍掉已经 ship 的项。
- 新增 `docs/competitive-analysis.md` — 调研了约 12 个竞品，每个
  写了简评，给出了 Hacker News / Reddit / Product Hunt 三个渠道的
  发帖草稿。
- 新增 `docs/release.md` 把发版流程（CHANGELOG 抽取 pipeline、tag
  失败回滚操作）从 user-facing README 挪进 internal docs。
- GitHub 仓库元数据设了：description / homepage / 12 个 topics
  方便被搜到。

---

## v0.7.2 — 2026-04-30

### Changed
- **Update banner now downloads the .zip and reveals the new
  `MyUsage.app` in Finder.** No more "open release page in browser →
  hunt for the .zip in the assets list → download → double-click to
  extract" — Settings → About's update banner does all of that and
  drops you in Finder one drag away from `/Applications`. Subtitle
  rotates with state ("Downloading… 47%", "Drag MyUsage.app into
  /Applications, then relaunch."), action button rotates with state
  (Download → spinner + progress → Show in Finder → Retry on error).
  Falls back to the old "Open Release" link when a release ships
  without a .zip asset.

### 中文

- **更新横幅现在自动下载 .zip 并在 Finder 里高亮新的 MyUsage.app。**
  之前要"在浏览器打开 release 页 → 在 assets 列表里找 .zip → 下载
  → 双击解压"，现在 设置 → 关于 那个 banner 一键搞定，最后在
  Finder 里直接看到新的 .app，只剩"拖到 /Applications + 重启"两步
  手动。下载中显示百分比，状态机走到底了 banner 上的副标题和按钮
  都会跟着变（Download → 转圈 + 进度条 → Show in Finder → 出错则
  Retry）。如果某个 release 没传 .zip，会自动回退到原来的"Open
  Release"链接。

---

## v0.7.1 — 2026-04-30

> Originally tagged as v0.7.0, but the v0.7.0 release workflow never
> produced an artifact (Sendable conformance bug on the Xcode 16
> toolchain — local Xcode 26 builds were fine, CI failed). v0.7.1 is
> the first 0.7-line release that actually shipped. The feature set
> below is what's in the build.

### Added
- **Limit-pressure notifications.** Get a macOS notification the moment
  any tracked limit (Claude/Codex 5h or weekly, Cursor included or
  on-demand, each Antigravity model) crosses an upgrade threshold.
  Defaults: warn 80%, crit 95%. Both are user-tunable in Settings →
  General → Notifications. Idempotent — same percent across two
  refreshes never double-fires; tier resets once usage retreats so
  the next climb fires fresh.
- **Update-available check.** On launch, MyUsage polls GitHub Releases
  (debounced to once per 24h) and surfaces a newer tag in two places:
  a small accent dot on the popover refresh icon, and a tinted banner
  at the top of Settings → About with an "Open Release" button. No
  auto-download; click through to GitHub for the .app.
- **Provider reordering** in Settings → Providers, restored after the
  v0.6.0 visual refactor stripped `.onMove`. Up/down arrows on each
  row, disabled at the ends.

### Fixed
- ClaudeProvider profile-fetch errors are now logged instead of
  silently swallowed — falling back to the credentials.planName
  field, but visible in `log stream --category Claude`.
- CI / release pipelines now build on the macos-15 + Xcode 16
  toolchain. Required `extension UNUserNotificationCenter:
  @retroactive @unchecked Sendable {}` because that SDK doesn't yet
  carry Apple's Sendable annotation; without it the protocol-driven
  notification dispatcher couldn't be sent across `await`.

### Changed
- Release notes on GitHub Releases now embed the matching CHANGELOG
  section instead of the same hardcoded install body for every tag.
  Install instructions appended below.
- Documentation: `DevicesTab.swift` docstring points at the actual
  `specs/12a-sync-folder.md` (the unpublished `spec 12` reference
  was a dead link).

### Operations
- New `.github/workflows/ci.yml`: every PR + push to main now runs
  `swift test` and `xcodebuild build` against macOS 15 / Xcode 16.

### 中文

> 这一版原本打成 v0.7.0，但 release workflow 在 Xcode 16 上构建失败
> （Sendable conformance bug — 本地 Xcode 26 编译没问题，CI 跑炸），
> 没有产出 .app artifact。v0.7.1 才是 0.7 系列里第一个真正发出去的
> 版本。下面列的是这次构建里实际带的功能。

- **新增 limit 压力通知**：任意一条受跟踪的 limit（Claude / Codex
  的 5 小时或每周窗口、Cursor 的 Included / On-demand、Antigravity
  的每个模型）跨过提醒阈值时，macOS 系统通知会立即弹出。默认 80%
  告警 / 95% 严重，可在 设置 → 通用 → 通知 里调。带幂等：同一个
  百分比连续两次刷新不会重复弹；用量回落后状态自动复位，下次再升
  会重新触发。
- **新增升级提示**：启动时（每 24 小时最多一次）会去 GitHub Releases
  查最新版本，发现更新时菜单栏 popover 的刷新图标右上角会有蓝点，
  设置 → 关于 顶上会出现"Update available"横幅 + 一键打开 release
  页的按钮。不会自动下载，需要手动到 GitHub 取 .app。
- **恢复 provider 排序**：v0.6.0 视觉重构时把 `.onMove` 拆掉了；
  现在 设置 → Providers 每行加了上下箭头按钮，到顶/底自动禁用。

### 修复

- Claude 的 profile API 拉取失败现在会记到 log（之前是 `try?`
  静默吞掉），通过 `log stream --category Claude` 可见。
- 修复 CI / Release 在 macos-15 + Xcode 16 toolchain 上的构建：
  必须显式声明 `extension UNUserNotificationCenter: @retroactive
  @unchecked Sendable {}`，因为该 SDK 还没带 Apple 的 Sendable
  注解；没这一行的话基于 protocol 的通知 dispatcher 跨 `await`
  传递时编译报错。

### 变更

- GitHub Releases 页的发布说明现在自动从 CHANGELOG.md 抽对应版本
  的段落，而不是每次都一样的硬编码安装说明（安装说明仍附在下面）。
- DevicesTab.swift 的注释指向真实存在的 `specs/12a-sync-folder.md`
  （之前 `spec 12` 是死链）。

### 工程

- 新增 `.github/workflows/ci.yml`：每个 PR 和 push 到 main 现在都
  会跑 `swift test` + `xcodebuild build`（macOS 15 / Xcode 16）。

---

## v0.6.1 — 2026-04-29

### Fixed
- **Claude plan label was missing or stale** for users on the latest
  Claude CLI. Recent CLI builds stopped writing `subscriptionType` /
  `rateLimitTier` into `~/.claude/.credentials.json`, so the popover
  card showed nothing on a fresh refresh, and a stale "Pro" pill on
  any device that hadn't refreshed since the upgrade. The plan label
  is now derived from `/api/oauth/profile` (Max / Pro / Team /
  Enterprise), with the credentials field kept as a fallback for
  older CLIs.

### Docs
- README & README.zh-CN: lift the app icon above the title and refresh
  the screenshot to the v0.6.0 popover.

### 中文

- **修复 Claude 计划标签丢失或过期的问题**：新版 Claude CLI 不再把
  `subscriptionType` / `rateLimitTier` 写进 `~/.claude/.credentials.json`，
  导致 popover 卡上要么不显示，要么停留在升级前缓存的旧 "Pro"。
  现在改成从 `/api/oauth/profile` 拉取（Max / Pro / Team / Enterprise），
  老版 CLI 的 credentials 字段作为兜底。
- README 和 README.zh-CN：把 app 图标提到标题上方居中展示，截图换成
  v0.6.0 的新 popover。

---

## v0.6.0 — 2026-04-29

### Changed
- **Popover redesign.** Provider cards are now glass surfaces with a
  brand-color icon tile; progress bars use a shared safety palette
  (healthy / warn ≥ 75% / crit ≥ 90%) instead of brand color, so
  pressure reads consistently across providers. Each row carries the
  percent + reset countdown in fixed-width monospaced columns so
  multiple limits in one card line up vertically. Plan label is now a
  small monospaced pill (matches the ⊕ devices pill).
- **Header reflow.** App name on the left; updated-time + refresh
  button grouped on the right. Inner dividers between cards removed.
- **Footer simplified.** Quit button removed from the popover footer
  (Cmd-Q from the Settings window still terminates).
- **Settings restyled.** General / Providers / Devices / About tabs
  rebuilt with a new SettingsCard / SettingsRow primitive that mirrors
  the popover's glass card. Sync status indicator uses the same
  safety palette as the popover. Provider rows in the Providers tab
  use the same brand-tile icon as the popover.
- **Devices tab restyled.** Column-aligned device list inside a glass
  card with hairline separators, "THIS MAC" tint pill on the self
  row, monospaced cost columns. Empty state offers a "Sync now"
  button.

### Added
- Settings → About → Help & Feedback. Two buttons: "Report an Issue"
  opens a GitHub issue with version + macOS info pre-filled. "Copy
  Latest Crash Log" scans `~/Library/Logs/DiagnosticReports` for the
  newest MyUsage crash and copies it to the clipboard.

### Fixed
- Doc-comment references to the unpublished `specs/12-usage-ledger.md`
  now point at the existing `specs/12a-sync-folder.md`.

### 中文

- **Popover 视觉大改**：每个 provider 卡变玻璃面板 + 品牌色图标方块；
  进度条改用统一的安全色（< 75% 中性 / 75–89% 琥珀 / ≥ 90% 红），
  品牌色不再出现在条上，多 provider 之间的"压力"信号更一致。每行的
  百分比 + 重置倒计时改成等宽 mono 列对齐，同卡内多条 limit 之间
  上下对齐。Plan 标签变成 mono 小胶囊，跟 ⊕ devices pill 同形系。
- **头部重排**：App 名在左，更新时间 + 刷新按钮放在右侧成对。卡片
  之间的分割线去掉了，每张卡自带边框。
- **底部精简**：popover 底部的 Quit 按钮已移除（Settings 窗口的
  Cmd-Q 仍可退出）。
- **Settings 全套重构**：四个 tab (General / Providers / Devices /
  About) 用新的 SettingsCard 玻璃卡 + SettingsRow（label + 副文 + 控件）
  重写，跟 popover 视觉系统一致。Sync 状态指示灯用同一套安全色。
  Providers 列表里每个 provider 用跟 popover 一致的品牌色图标方块。
- **Devices tab 重写**：列对齐的设备列表放在玻璃卡里，行间用 hairline
  分隔，本机用蓝色 "THIS MAC" 小标识，cost 列用 mono 数字。空状态
  增加 "Sync now" 按钮。
- 新增 设置 → 关于 → 帮助与反馈：「Report an Issue」按钮一键打开 GitHub
  Issue 模板，自动带上版本号和 macOS 版本；「Copy Latest Crash Log」
  扫描 `~/Library/Logs/DiagnosticReports` 找到最新的 MyUsage 崩溃日志
  并复制到剪贴板，方便贴进 Issue。
- 修复源码注释里指向未发布 spec `12-usage-ledger.md` 的死链，统一指向
  实际存在的 `12a-sync-folder.md`。

---

## v0.5.0 — 2026-04-25

### Fixed
- Reinstalling MyUsage no longer creates a duplicate device folder under
  `<sync>/devices/`. The device ID is now derived from the hardware
  `IOPlatformUUID` (salted SHA-256 → UUIDv4), with `UserDefaults`
  acting as a cache. Same Mac → same ID across reinstalls. Raw
  `IOPlatformUUID` never leaves the process. See `specs/14-stable-device-id.md`.

### Added
- Snapshot republish on launch, wake, and folder change. The Sync folder
  is now refreshed from the local SQLite source of truth without waiting
  for a provider sweep, healing missing or stale JSONL files.
- `LedgerStore.entries(forDevice:)`, `LedgerWriter.publishSnapshot`,
  `LedgerSync.syncNow()`.
- Multi-device sync integration test suite (`LedgerSyncIntegrationTests`),
  including a regression test for the spec-14 reinstall bug.
- Tolerance for a final JSONL line without a trailing LF, so a half-flushed
  peer file no longer blocks its last entry forever.
- Legacy snake_case decoder for `LedgerEntry` so older sync files written
  by earlier builds keep parsing.

### Changed
- Settings → Devices → **Forget** is now destructive in the user-facing
  sense: it deletes the local rows *and* removes the peer's folder under
  `<sync>/devices/<id>/`. A confirmation dialog explains the consequences.
  If the peer is still active and publishes again, a fresh folder is
  created — this is expected, not a regression.
- Build number bumped to 3.

### 中文

- **修复重装后多出"幽灵设备"文件夹的问题**。设备 ID 现在由硬件
  `IOPlatformUUID` 派生（加盐 SHA-256 → UUIDv4），`UserDefaults` 仅作
  缓存：同一台 Mac 跨重装永远是同一个 ID。原始硬件 ID 不会被写入磁盘。
  详情见 `specs/14-stable-device-id.md`。
- **新增启动 / 唤醒 / 选目录后主动 publish 同步快照**：从本地 SQLite
  重新写一遍 Sync 文件夹的 JSONL/manifest，自动修复缺失或过期的同步文件。
- 新增多设备同步**端到端集成测试**，覆盖跨设备聚合、Latest-wins、
  Reader 不写自己文件夹、reinstall 不产生重复目录等核心契约。
- 新增对**末尾缺少换行的 JSONL 行**的容错（避免半刷新文件丢最后一条）。
- 新增对**老版本 snake_case JSONL** 的兼容解码。
- **Forget 设备**改为名副其实的"删除"：本地数据 + Sync 文件夹里这个
  设备的子目录一并删掉，弹确认对话框说明后果。如果对端设备仍在运行并
  下次 publish，会重新出现一个新文件夹——这是预期行为，不是 bug。
- Build 号 → 3。

---

## v0.4.0 — 2026-04-24

### Added
- Configurable Sync folder for multi-device ledger (any transport: iCloud
  Drive, Syncthing, Dropbox, NAS, …). See `specs/12a-sync-folder.md`.
- Menu bar icon now follows the currently tracked provider.
- Aligned app versioning between `Info.plist`, About panel, and release
  packaging so distributed bundles always self-report the right version.

### 中文

- 新增可自定义的 Sync 文件夹，支持任意同步通道（iCloud Drive、Syncthing、
  Dropbox、NAS 等）。详见 `specs/12a-sync-folder.md`。
- 菜单栏图标会跟随当前追踪的 provider 变化。
- 统一了 `Info.plist` / 关于页 / 打包脚本的版本来源，发布包始终自报正确版本。

---

## Earlier releases

For v0.3.0 and earlier, see the GitHub Releases page —
https://github.com/zchan0/MyUsage/releases.
