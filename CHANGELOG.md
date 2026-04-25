# Changelog

All notable changes are listed here. Each release section is bilingual
(English first, 中文 second). Format loosely follows [Keep a Changelog](https://keepachangelog.com).

## Unreleased

### Added
- Settings → About → Help & Feedback. Two buttons: "Report an Issue" opens
  a GitHub issue with version + macOS info pre-filled. "Copy Latest Crash
  Log" scans `~/Library/Logs/DiagnosticReports` for the newest MyUsage
  crash and copies it to the clipboard.

### Changed
- Doc-comment references to the unpublished `specs/12-usage-ledger.md`
  now point at the existing `specs/12a-sync-folder.md`.

### 中文

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
