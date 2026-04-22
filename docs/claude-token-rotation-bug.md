# Bug Postmortem — Claude 卡在 "Retrying in 1800s" / "Resetting…"

> 日期：2026-04-22  
> 涉及代码：`MyUsage/Providers/ClaudeProvider.swift`, `MyUsageTests/ClaudeProviderTests.swift`  
> 相关 commit：`fix(claude): stop self-refreshing OAuth tokens`  
> 相关规格：[`specs/02-claude-provider.md`](../specs/02-claude-provider.md) / [`specs/10-fix-claude-429.md`](../specs/10-fix-claude-429.md)

## 1. 问题现象

MyUsage 打开后 Claude 卡片先显示一次 `Token refresh failed. Retrying in 1800s`，
之后一直停在 `Resetting…`，用量数据不再更新。重启 app、切换网络都没用。

## 2. UI 分支与现象还原

- `Token refresh failed. Retrying in 1800s` ← `ClaudeProvider` 的 Phase 2 退避分支，`consecutiveFailures` 已经堆到 ≥ 7，退避到 30 分钟上限。
- `Resetting…` ← `UsageSnapshot.resetCountdown` 在 `resetsAt` 已过期时的 fallback 文案。留在卡片上的是 token 死掉之前最后一次成功拿到的 snapshot，它那会儿的 reset 时间如今已经过去了，所以显示 `Resetting…`。

两句话说的是同一件事：**token refresh 一直失败 → 拿不到新 snapshot → 旧 snapshot 的 reset 时间过期 → UI 永远在 "Resetting…"**。

## 3. 真正的原因

直接 curl 验证：

```
POST https://platform.claude.com/v1/oauth/token
→ HTTP 400 {"error":"invalid_grant","error_description":"Refresh token not found or invalid"}
```

Anthropic 的 OAuth 启用了 **refresh-token rotation**：每次成功刷新会发新 RT 并作废旧的。而 MyUsage 当时的 `ClaudeProvider.refreshToken()` 实现只在内存里用新 RT/AT 跑一次 `fetchUsage`，**没有把新 token 对写回 Keychain**。结果：

1. MyUsage 首次触发 refresh → 消费 Keychain 里的 RT → Anthropic 发 RT'/AT'、作废 RT。
2. MyUsage 扔掉 RT'/AT'，下次又从 Keychain 读 —— 还是已经作废的 RT。
3. 之后所有 refresh 都是 `invalid_grant` → 退避堆到 1800s 上限，卡住不动。

换句话说：**MyUsage 自己把自己的 refresh token 烧掉了**。CLI 那边如果还没用那条 RT，它手里也是旧的，迟早也会撞 `invalid_grant`，但 CLI 撞到会引导用户重登；MyUsage 不会，只会一直 retry。

## 4. 解决方向

三个候选：

- **A. 写回 Keychain**：refresh 后把新 token 对 `SecItemUpdate` 回去。要求 ad-hoc 签名的 MyUsage 能通过 CLI 写的 ACL，能不能过要实际试；就算能写，仍然和 CLI 有竞争。
- **B. 不再 refresh**（选中）：MyUsage 彻底不调 `/v1/oauth/token`。access_token 过期就显示 "Run `claude` to refresh it"，等 CLI 自己轮转 Keychain。
- **C. 先 B 后 A**：先上 B 止血，后续单独 spec 评估 A 的可行性。

选 B。理由：

- MyUsage 定位是**被动观察型 companion app**，refresh 本来就不该由我们做。
- 代价是 access_token（约 8 小时有效期）到期后卡片会暂时停更，直到用户跑一次 `claude`。Claude Code 用户一般每天都会用 CLI，实际影响小。
- 完全避开了"写 Keychain"这条 ad-hoc 签名不可靠的路径。

## 5. 修复改动

`MyUsage/Providers/ClaudeProvider.swift`：

- **删**：`refreshToken()`、`updateCredentials()`、`ClaudeTokenRefreshResponse`、`refreshURL`、`clientID`、`forceTokenRefreshOnNextCall` 状态。
- **改** `refresh()`：遇到 `creds.isExpired` 不再调 refresh 端点，直接写 `error = tokenExpiredErrorMessage()` 并 return，snapshot 保留原样。
- **加** `tokenExpiredErrorMessage()`：统一文案 — "Claude access token expired. Run \`claude\` once in Terminal so the CLI refreshes the Keychain entry."
- **改** 429 catch：不再设 `forceTokenRefreshOnNextCall`（该状态已删）。

`MyUsageTests/ClaudeProviderTests.swift`：补一条 `tokenExpiredErrorMessage` 文案断言。

## 6. 用户侧紧急恢复步骤

MyUsage 自身修了之后，Keychain 里那条 RT 在 Anthropic 端仍然是死的。用户需要让 CLI 重新拿一对 token：

```bash
claude            # 能走正常重登流程就够了；
claude logout && claude login   # 如果 claude 启动时没引导重登，手动重登
```

确认 `security find-generic-password -s "Claude Code-credentials" -w` 输出里的 `refreshToken` 换了新前缀之后，重启 MyUsage 即可恢复。

## 7. 与前几条变更的关系

- 本 bug 是 [`specs/10-fix-claude-429.md`](../specs/10-fix-claude-429.md) Phase 1 埋下的坑。Phase 1 的 `forceTokenRefreshOnNextCall` 想"在 429 后主动刷新以换掉被 rate-limit 的 bucket"，这其实基于一个错误假设：**我们拥有 refresh 循环**。一旦启用 rotation，主动刷新只会帮我们更快烧掉 RT。本次修复把 Phase 1 的 `forceTokenRefreshOnNextCall` 彻底拿掉。
- [`docs/claude-not-configured-bug.md`](./claude-not-configured-bug.md) 的 §9 "长期考虑" 里其实已经预告过这条路：
  > ad-hoc 签名读其它 app 写入的 Keychain item 始终有被 ACL 拦截的风险，未来要么走 Developer ID 签名 + 稳定身份、要么做"只读本地 JSONL、不调 Anthropic usage API"的降级模式。
  
  这次选的 B 就是那条降级模式的一个子集 — 还继续调 usage API，但不再 touch OAuth 侧。

## 8. 预防复发

- **companion app 不应持有任何会被消费/轮转的凭据。** 只读，不写，不 refresh。未来新增 provider 默认遵循这条；如果某个 provider 必须要刷新（比如 API 不接受 CLI 的 token），单独立 spec 论证写回策略。
- **UI 错误文案必须可操作。** 之前的 `Retrying in 1800s` 给不出动作，用户干瞪眼；现在的 `Run 'claude' once in Terminal` 至少指向了下一步。
- **"重试 + 退避" 永远不是 `invalid_grant` 这类 hard failure 的正确动作。** 未来如果新增 transient-vs-permanent 的判定，要把 `400 invalid_grant` / `401 invalid_token` 这类特例从退避路径里摘出来，一次就放弃并明确报错。本次没为此专门加分支，是因为删掉 refresh 逻辑之后，这条路径就不存在了。

## 9. 相关测试

- `Token-expired message points user at \`claude\` CLI`（新加）
- 全量 110 条测试通过（109 + 本次新增 1）。
