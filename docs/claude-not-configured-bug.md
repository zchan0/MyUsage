# Bug Postmortem — Claude 卡片显示 "Not configured"

> 日期：2026-04-22  
> 涉及代码：`MyUsage/Providers/ClaudeProvider.swift`, `MyUsage/Services/KeychainHelper.swift`  
> 相关 commit：`fix: detect Claude availability from Keychain`  
> 相关规格：[`specs/02-claude-provider.md`](../specs/02-claude-provider.md)
> （提供器原始设计）、[`specs/10-fix-claude-429.md`](../specs/10-fix-claude-429.md)
> （发现本 bug 的回归测试上下文）

## 1. 问题现象

打开 MyUsage 菜单栏面板，Claude 卡片停留在 "Not configured" 状态。
但用户的 Claude Code CLI 是能正常使用的：`~/.claude/history.jsonl` 最近仍在写入。

## 2. 从 UI 看 "Not configured" 的触发条件

`ProviderCard.swift` 的分支逻辑：

```swift
if provider.isLoading && provider.snapshot == nil { loadingView }
else if let error = provider.error, provider.snapshot == nil { errorView(error) }
else if let snapshot = provider.snapshot { snapshotContent(snapshot) }
else { notConfiguredView }
```

换句话说，"Not configured" = `isLoading == false && error == nil && snapshot == nil`。

这是一条**静默 fallback**：只要 `ClaudeProvider` 从未成功也从未显式报错，UI 就会停在这里。

## 3. Claude 原有的用量获取链路

`ClaudeProvider` 每轮 `refresh()` 的完整路径：

```
init → detectAvailability()
        │
        └──▶ isAvailable = (file ~/.claude/.credentials.json 是否存在)

timer → refresh()
        │
        ├──▶ guard isAvailable else { return }        ← 静默返回（不设 error）
        │
        ├──▶ loadCredentials()
        │     ├─ 读 ~/.claude/.credentials.json，能解码就返回
        │     └─ 兜底读 Keychain `Claude Code-credentials`
        │
        ├──▶ 如果 credentials.isExpired → refreshToken() (HTTP POST)
        │
        ├──▶ fetchUsage() (HTTP GET /api/oauth/usage)
        │
        └──▶ snapshot = mapToSnapshot(usage)
              monthlyEstimatedCost = 从 ~/.claude/projects/**/*.jsonl 本地扫
```

关键：**`detectAvailability()` 和 `loadCredentials()` 不是同一套判据**。前者只看文件，后者文件 + Keychain 双源。

## 4. 链路中可能"坏"的每一处

按阶段逐层列，对应到 UI 能看到什么：

| 阶段 | 失败条件 | UI 结果 |
|---|---|---|
| 检测 | `~/.claude/.credentials.json` 不存在 → `isAvailable = false` | **"Not configured"（静默）** |
| 加载凭据 | 文件存在但解码失败，Keychain 兜底也失败 | `"No credentials found"` 错误 |
| Token 刷新 | `refreshToken` POST 失败 | 网络错误信息 |
| 查用量 | `fetchUsage` GET 非 200 | `"API error (XXX)"` 或 429 / 退避信息 |
| Cost 计算 | 本地日志扫描异常（实现上已吞错） | 不影响卡片显示 |

看表就能看出：**只有第一阶段失败会让 UI 停在 "Not configured"**。其它每一步失败都会被写进 `provider.error`，UI 会走到 `errorView` 分支。

## 5. 本次 bug 真正的原因

### 5.1 环境事实

| 位置 | 状态 |
|---|---|
| `~/.claude/.credentials.json` | ❌ 不存在 |
| `~/.claude/`（`projects/`, `history.jsonl` 等） | ✅ 存在且近期活跃 |
| Keychain item `Claude Code-credentials` | ✅ 存在，最近修改 2026-04-21 |
| Keychain payload JSON | 结构与 `ClaudeCredentials` 解码器一致 |

### 5.2 真正的问题

**Claude Code CLI 的新版在 macOS 上只把 OAuth 凭据写入 Keychain，不再落盘到 `~/.claude/.credentials.json`。**

而 MyUsage 的 `detectAvailability()` 只查文件、不查 Keychain：

```swift
private func detectAvailability() {
    isAvailable = FileManager.default.fileExists(atPath: Self.credentialFilePath)
}
```

对"只 Keychain"的用户，这条判据永远是 `false`，`refresh()` 开头的 `guard` 直接返回，
`snapshot` / `error` 都不会被写 → UI 停在 "Not configured"。

讽刺的地方在于，**同一个文件里的 `loadCredentials()` 本来就做了双源读取**，只是
`detectAvailability()` 没复用它。这是典型的"两处判据不对称"的 bug。

### 5.3 为什么会这样被设计

翻历史 spec（[`specs/02-claude-provider.md`](../specs/02-claude-provider.md)）：早期 Claude Code CLI 是把凭据写在
`~/.claude/.credentials.json` 的，Keychain 只是"某些版本"的备选。`detectAvailability`
按当时的主流形态只检测了文件，`loadCredentials` 比较保守地加了 Keychain 兜底。

后来 Claude Code CLI 逐步迁移到 Keychain-only，但 MyUsage 没同步更新 detect 逻辑。

## 6. 修复

动三处：

### 6.1 `detectAvailability()` 改为显式两级检测，并区分 "没装 Claude" 与 "读不到 Keychain"

```swift
private func detectAvailability() {
    // 1) 文件优先
    if let data = FileManager.default.contents(atPath: Self.credentialFilePath),
       let creds = try? JSONDecoder().decode(ClaudeCredentials.self, from: data),
       creds.claudeAiOauth != nil {
        isAvailable = true; error = nil; return
    }

    // 2) Keychain（附带 OSStatus，便于诊断）
    let result = KeychainHelper.readGenericPasswordResult(service: Self.keychainService)
    if let data = result.data,
       let creds = try? JSONDecoder().decode(ClaudeCredentials.self, from: data),
       creds.claudeAiOauth != nil {
        isAvailable = true; error = nil
        Logger.claude.info("Claude credentials loaded from Keychain")
        return
    }

    // 3) 两种 "拿不到凭据" 的子情况
    isAvailable = false
    if !FileManager.default.fileExists(atPath: Self.claudeDirectory) {
        // 真的没装 Claude，保持 "Not configured"
        return
    }
    // 装了 Claude 但凭据读不到 → 写一个可操作的错误，不再掉进 "Not configured"
    Logger.claude.error("Claude credentials unreadable (keychain status=\(result.status, privacy: .public))")
    error = Self.credentialAccessErrorMessage(status: result.status)
}
```

### 6.2 `refresh()` 开头再探测一次

```swift
func refresh() async {
    if !isAvailable { detectAvailability() }
    guard isAvailable else { return }
    ...
}
```

用户如果是 app 启动后才跑的 `claude login`，不用退出 app，下一轮自动恢复。

### 6.3 `KeychainHelper` 暴露 `OSStatus`，把失败分流成可操作文案

新增非破坏性 API：

```swift
static func readGenericPasswordResult(service: String, account: String? = nil)
    -> (data: Data?, status: OSStatus)
```

对应 UI 文案：

| OSStatus | 提示 |
|---|---|
| `errSecItemNotFound` | "Claude Code is installed but no credentials were found. Run `claude login` in a terminal." |
| 其他（如 `errSecAuthFailed`） | "Cannot read Claude credentials from Keychain (status N). Open Keychain Access, find "Claude Code-credentials", and allow MyUsage to access it." |

### 6.4 核心改动的语义对比

| 情形 | 修复前 | 修复后 |
|---|---|---|
| 用户只有 Keychain 凭据 | "Not configured"（静默） | 正常显示用量 |
| 用户从没登录过 Claude | "Not configured" | "Not configured"（保持） |
| 用户装了 Claude 但 Keychain 拒读 | "Not configured"（静默） | 显示带操作指引的错误 |
| 用户 app 启动后才 `claude login` | 需要重启 app | 下一轮 refresh 自动恢复 |

## 7. 次要发现与兜底

修复过程中顺带确认 / 兜底的两点，不是本次 bug 的根因，但值得记录：

- **JSON 结构一致**：Keychain payload 与 `ClaudeCredentials` 解码器的字段完全吻合，
  排除"解码静默失败"假设。
- **Keychain ACL 拦截（潜在风险）**：Claude Code CLI 写入 Keychain 时会把自身加入
  ACL 的 trusted apps 列表；ad-hoc 签名的 MyUsage 理论上可能被拦。本次实测没触发
  （macOS 对解锁的登录钥匙串里的 generic password 并没有硬性拦截），但 6.3 的 OSStatus
  分流就是在兜这条路径——将来换机器 / 企业管控 Keychain 撞到时，UI 会给出明确提示
  而不是静默。

## 8. 走过的弯路

按时间顺序：

1. 假设 Claude 凭据已迁 Keychain，把 `detectAvailability()` 改为 `loadCredentials() != nil`。改完跑单测通过、打包完成，就交给用户验。
2. 用户反馈"没改成功"。当时没抓运行证据，直接去怀疑"是不是 JSON 结构不匹配"、"是不是 Keychain ACL 拦了"。
3. 翻 Keychain payload → 结构对得上，排除解码问题。
4. 写诊断代码：让 `KeychainHelper` 返回 `OSStatus`，让 `ClaudeProvider` 在失败时打 `Logger.claude` 并写 `error`。
5. 显式 `pkill -x MyUsage` + `open MyUsage.app`，同时 `/usr/bin/log stream --predicate 'subsystem == "com.zchan0.MyUsage"'` 抓 category=Claude 的日志。
6. 日志里拿到 `Claude credentials loaded from Keychain`，确认第 1 步的改动其实是对的——之前用户看到"没改成功"应是点菜单栏时跑的还是旧进程。

**这一步的教训是**：方案判断对不对，不能只靠"测试通过 + 打包成功"就下结论，要在真实 app 里抓一条运行证据（log / snapshot 状态）闭环。

## 9. 预防复发

- **Provider 的检测路径必须与凭据加载路径对称**。今后 `loadCredentials()` 新增数据源
  （比如 `~/.config/claude/`），`detectAvailability()` 必须同步覆盖，否则整条 provider
  会静默消失。
- **"Not configured" 只对应"用户确实没装"这一种情况**。任何"装了但拿不到凭据"的分支
  都要升级为带引导文案的 error 态。
- **Keychain 访问失败要带 `OSStatus` 日志**。以后用户再报类似问题，让他们跑
  `log show --predicate 'subsystem == "com.zchan0.MyUsage"' --last 5m` 能一眼看到状态码。
- **长期考虑**：ad-hoc 签名读其它 app 写入的 Keychain item 始终有被 ACL 拦截的风险，
  未来要么走 Developer ID 签名 + 稳定身份、要么做"只读本地 JSONL、不调 Anthropic
  usage API" 的降级模式。这两条都不在本次修复范围。

## 10. 相关测试

`MyUsageTests/ClaudeProviderTests.swift` 新增：

- `errSecItemNotFound yields "run claude login" guidance`
- `Other OSStatus yields Keychain ACL guidance with status code`

全量 109 条测试通过（107 + 本次新增 2）。
