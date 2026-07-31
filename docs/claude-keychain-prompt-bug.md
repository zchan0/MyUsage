# Bug Postmortem — Claude Keychain 每天都要重输一次密码

> 日期：2026-07-31
> 涉及代码：`MyUsage/Services/SecurityToolKeychain.swift`,
> `MyUsage/Services/ClaudeCredentialStore.swift`
> 相关文档：[`docs/claude-token-rotation-bug.md`](./claude-token-rotation-bug.md)

## 1. 问题现象

用户反馈：**每天至少一次**，MyUsage 会弹 macOS 钥匙串密码框
（"MyUsage wants to use your confidential information stored in
'Claude Code-credentials'"）。点了「始终允许」当时有效，第二天照弹。

此前的判断是「ad-hoc 签名 → 每次重编译换 cdhash → 授权失效，根治要 Developer ID
签名」。这个判断**是错的**，见下。

## 2. 实测取证

写了个 `SecKeychainItemCopyAccess` + `SecAccessCopyACLList` 的小工具 dump
`Claude Code-credentials` 的 ACL，两个关键发现：

**(a) 受信任 App 列表里有 ~120 条重复的 MyUsage。**

```
[1] auths=[ACLAuthorizationDecrypt, ...]
    app: /Applications/MyUsage.app
    app: /Users/zhengcc/Developer/MyUsage/MyUsage-debug.app
    app: /Applications/MyUsage.app
    ...  (共约 120 条，绝大多数是同一个 app 的重复)
```

item 的 `cdat` 是 2026-04-29 且从未变过（没有 delete+recreate），到 7-31 约 93 天
——**约 120 次「始终允许」/ 93 天 ≈ 1.3 次每天**，和用户描述完全吻合。也就是说
授权确实每次都写进去了，但下次照样不生效。

**(b) 真正的闸门是 ACL partition list。**

```
[3] auths=[ACLAuthorizationPartitionID]
    <plist><dict><key>Partitions</key><array>
      <string>apple-tool:</string>
      <string>cdhash:c05c9491ac18543741185b1129fe88d9d41a179a</string>
    </array></dict></plist>
```

macOS Sierra 起，legacy 钥匙串条目除了「受信任 App 列表」还有一份 **partition
list**（允许免弹窗使用该条目的代码身份集合）。**两道闸门都要过**：App 在受信任列表
里、但 partition ID 不在 partition list 里，照样弹框。

## 3. 根因

Claude CLI 用 `security add-generic-password -U …` 写 OAuth token
（在 CLI 二进制里 grep 得到），而**这条命令会把 partition list 重写成只剩
`apple-tool:`**。

用一个一次性条目实测确认（先用自己的工具 `SecItemAdd` 建，partition 是
`cdhash:5e5eb949…`；再跑一次 `security add-generic-password -U`）：

```
before:  Partitions = [ cdhash:5e5eb949b58c93988e1e0edf666f924ee6f866f0 ]
after:   Partitions = [ apple-tool: ]              ← 被清掉了
```

受信任 App 列表**不受影响**（所以那 120 条会一直累积），只有 partition 被清空。

于是完整链条是：

1. CLI 每次轮转 access token（TTL 8h）就 `-U` 写一次钥匙串。
2. 该写入把 partition list 重置为 `apple-tool:`，上次「始终允许」种下的
   `cdhash:<MyUsage>` 被删除。
3. MyUsage 的 no-UI 读取因此再次被 ACL 拦截。
4. `ClaudeCredentialStore` 的第 4 步（当时）判定「自有缓存已过期 + CLI item
   ACL-blocked」→ 弹交互式读取 → 用户又输一次密码。

**重要纠正：Developer ID 签名解决不了这个问题。** partition 重置是把
*所有* partition 都清掉，不只是 ad-hoc 的 `cdhash:`；换成 `teamid:XXXX` 一样会被
清掉。签名只影响「重编译后授权是否延续」，不影响这条每日轮转的路径。

## 4. 解决方案

**读取改走 `/usr/bin/security`。**

`security` 自己就是 apple-tool，partition ID 正是 `apple-tool:` ——CLI 每次写入
唯一会保留的那一个；而且 CLI 建条目时就把 `/usr/bin/security` 放进了受信任 App
列表。两道闸门都天然满足，**永不弹窗**，不需要改 ACL、不需要改签名。这也正是 CLI
自己读回 token 用的路径。

实测（轮转后、in-process 读被拦的状态下）：

```
$ security find-generic-password -w -s "Claude Code-credentials" -a $USER
→ exit 0，505 bytes，无弹窗
```

落地为 `SecurityToolKeychain`，插进 `ClaudeCredentialStore` 源链的第 3 步：

```
1. ~/.claude/.credentials.json          文件，免费
2. SecItemCopyMatching no-UI            便宜，轮转后会失败
3. /usr/bin/security find-generic-password   ← 新增，轮转后仍然静默成功
4. 自有钥匙串缓存副本
5. 交互式读取（几乎不会再走到）
```

第 3 步成功时会把 `lastCLIStatus` 归一成 `errSecSuccess`——第 2 步的
ACL-blocked 状态不能外泄，否则仍会驱动交互式引导和 "needs Keychain access" 文案。

子进程有 3s 硬超时 + kill，任何意料之外的状态都不会把刷新卡在模态框后面。

## 5. 验证

dev 裸二进制 + `MYUSAGE_NO_PROMPT=1`（交互式弹窗被完全禁用）现在能直接读到实时
Claude 数据并渲染面板。改动前这种组合只能显示 "No credentials found"，必须
`MYUSAGE_FORCE_PROMPT=1` 手动点一次「始终允许」才行（见
[`memory: codexbar-lite-direction`] 里的逃生开关说明）。

## 6. 安全说明

这不是绕过任何用户不想要的限制：条目的 ACL 本来就授权了 `apple-tool:`——**是
Claude CLI 自己写进去的**。也就是说，以该用户身份运行的任何进程，一条
`security find-generic-password` 命令本来就能读到这个 token；MyUsage 只是换用了
同一条被授权的路径。凭据全程不落日志。

## 7. 预防复发

- **判断钥匙串弹窗原因时，先 dump ACL 再下结论。** 「ad-hoc 签名 →
  cdhash 变了」这个假设很自然，但和证据（120 条累积授权 + 未变的 cdat）矛盾。
- **legacy 钥匙串有两道闸门**，受信任 App 列表和 partition list 要分开看。
  `security dump-keychain -a` 会为每个条目弹密码框，用
  `SecAccessCopyACLList` 的小工具更实用。
- **别人写的条目，读取路径优先考虑对方自己用的那条**。写入方授权了什么身份，
  读取方就用什么身份，比反过来要求写入方改 ACL 稳得多。
