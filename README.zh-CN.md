# MyUsage（中文说明）

MyUsage 是一个 macOS 菜单栏应用，用来统一查看 Claude Code、Codex、Cursor、Antigravity 的使用情况。

英文主文档：[`README.md`](README.md)

## 特色能力

- 在一个弹层里集中展示多个 AI 编码工具的用量。
- 可选择一个 provider 显示在菜单栏图标旁。
- 可配置刷新频率（1m / 2m / 5m / 15m / 手动）。
- 支持 provider 启用/禁用与拖拽排序。
- 支持 Claude Code + Codex 的预计月费显示。
- 支持通过共享同步目录聚合多台 Mac 的月度成本（`Devices` 标签页）。

## 安装

1. 从 [Releases](https://github.com/zchan0/MyUsage/releases) 下载 `MyUsage-<version>.zip`
2. 解压后将 `MyUsage.app` 拖到 `/Applications`
3. 首次启动若出现 Gatekeeper 提示，可右键 `Open` 一次，或执行：

```bash
xattr -cr /Applications/MyUsage.app && open /Applications/MyUsage.app
```

每个 release 都会附带 `.sha256` 文件用于校验包完整性。

## 使用入口

- 点击菜单栏图标查看总览。
- 点刷新按钮手动拉取最新数据。
- 在 Settings 中配置：
  - `General`：刷新频率、菜单栏追踪、预计月费开关、同步目录、开机启动
  - `Providers`：provider 顺序与启用状态
  - `Devices`：查看设备聚合成本、忘记旧设备
  - `About`：版本与项目链接

## 本地构建与打包

```bash
# 打包 .app
./Scripts/package_app.sh

# 或仅构建 release 二进制
swift build -c release
```

## 发版脚本

```bash
./Scripts/prepare_release.sh --version 0.4.0 --build 2
```

该脚本会更新并校验版本字段，然后输出：

- `MyUsage-<version>.zip`
- `MyUsage-<version>.zip.sha256`

## 数据与隐私

- 应用会读取本地凭据/状态文件与 Keychain 中必要信息来拉取各 provider 用量。
- 网络请求仅用于访问对应 provider 的接口。
- 多设备聚合依赖你手动选择的本地/共享同步目录，不依赖 MyUsage 自建云服务。

## 后续方向

不是承诺，只是可能性。如果哪一项对你特别重要，欢迎在 GitHub 开 issue：

- **Token 级别用量统计** — 按模型、按 prompt 缓存命中率展开月度费用。
- **UI 重设计** — 更紧凑、更 macOS 原生的视觉。
- **签名 + 公证打包** — 在新 Mac 上首次打开不再被 Gatekeeper 拦截。
- **应用内更新提醒** — Sparkle 或简单地与 GitHub Releases 比对版本号。
