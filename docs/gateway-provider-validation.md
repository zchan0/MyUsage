# LiteLLM 网关实现与验证记录

2026-09-22，LiteLLM 实现与试用记录；纳入 v0.18.0。

## 实现范围

- Settings → Providers → Add Gateway…；Vendor 固定 LiteLLM。同供应商多实例，各自启停、排序、编辑和删除，和内建 provider 同级。
- `GatewayAdapter` 的 usage check / summary / history 三个操作，LiteLLM 自己实现端点、认证、身份和数据映射。检查只读，不调用模型推理。
- 额度概要与历史独立维护；支持账户/key 预算与消费、账户本月费用/模型/token/请求记录。key 级历史未启用。
- API key 存 Keychain；连接配置本机保存。地址/凭据/scope 变化取消在途工作、清空旧数据；名称变更保留身份和排序。
- UTC 月初至今天的历史按需读取，五分钟内存缓存。缺字段不补零、缺页不称完整、不同范围不拼接、成本不加入本地设备账本。
- 330pt 原生 popover、当前系统字号及额度条/页脚。Overview 固定，provider 横向滚动，选中项自动滚入视野；实际溢出时有全部 provider 菜单；过高主体滚动，导航和页脚保持可达。

## 修改文件

| 部分 | 文件 |
| --- | --- |
| 身份与数据 | `MyUsage/Models/ProviderID.swift`、`GatewayUsage.swift` |
| 协议与运行态 | `MyUsage/Providers/UsageProvider.swift`、`GatewayAdapter.swift`、`LiteLLMAdapter.swift`、`GatewayProvider.swift` |
| 内建协议适配 | `MyUsage/Providers/ClaudeProvider.swift`、`CodexProvider.swift`、`CursorProvider.swift`、`AntigravityProvider.swift`；仅变更协议声明 |
| 存储、调度、通知 | `MyUsage/Services/GatewayConnectionStore.swift`、`UsageManager.swift`、`LimitNotifier.swift` |
| 新 UI | `MyUsage/Views/GatewayConnectionEditor.swift`、`GatewayProviderDeck.swift`、`ProviderInstanceView.swift` |
| 现有 UI 接入 | `MyUsage/Views/SettingsView.swift`、`FocusOverview.swift`、`ProviderDeck.swift`、`ProviderPopover.swift`、`ProviderTabBar.swift`、`UsagePopover.swift`、`MenuBarIcon.swift` |
| 菜单栏 | `MyUsage/MenuBar/MenuBarCoordinator.swift`、`StatusItemController.swift`、`PopoverPanel.swift` |
| 隔离预览 | `MyUsage/Views/GatewayPreviewFixtures.swift`、`PreviewFixtures.swift`、`MyUsage/MyUsageApp.swift` |
| 测试 | `MyUsageTests/GatewayAdapterTests.swift`、`GatewayStateTests.swift`、`GatewayPresentationTests.swift`、`UsageManagerTests.swift` |
| 文档 | `README.md`、`README.zh-CN.md`、`docs/architecture.md`、`docs/gateway-provider-design.md`、本文；已有 `gateway-provider-preview.html` 草图保留，本轮开发没有改其样式或行为 |

## 已执行

- `swift test`：153 项 XCTest + 287 项 Swift Testing，合计 440 项通过，其中 26 项新增网关测试。覆盖请求顺序/显式用户过滤、401/403/429、HTML/错误 JSON、缺省/null/0、Decimal、分页和部分模型分解、token 汇总、身份迁移、多实例隔离、凭据写失败、删除失败、取消后的旧响应和通知隔离。测试无真实网关凭据/网络依赖。
- `xcodebuild build -scheme MyUsage -destination 'platform=macOS' -skipPackagePluginValidation`：构建通过。
- `git diff --check`：通过。
- 通过现有 DEBUG 原生截图入口，以隔离配置和虚构数据渲染了浅色完整用量、深色仅 token 历史的网关详情；窗口实测宽 330pt，额度、消费、图表、模型、token 和页脚可见。发现的溢出导航文字样式和图表日期标签问题已修正。
- 增加 SwiftUI previews：完整数据、仅 token 历史、历史无权限、空历史、旧数据失败状态、创建表单。Preview 编译通过不等于所有交互均已人工验证。

原生 fixture 不连接用户服务、不读取用户 API key，也不启动真实设备同步、价格更新或通知授权流程。临时截图及构建日志位于本次任务的 `/tmp/myusage-*` 输出；不作为发布资源提交。UI 自动化工具未能定位 SwiftPM 裸进程，因此没有把创建 sheet 的操作流程记为通过。

## 仍需手动确认

1. 在真实 Settings 中新增两条 LiteLLM，确认独立启停、排序、改名、编辑 key、删除；取消编辑不保存。检查长名称、列表滚动和 540×460 设置窗口的 sheet。
2. 验收合并/分离菜单栏、多屏/小屏、长模型列表滚动、浅色/深色以及当前内建 provider 的视觉回归；真实通知授权和阈值通知尚未验收。
3. 使用用户自己的 host/key，在相同账户或 key 范围下对照 LiteLLM 管理页：预算周期消费、UTC 月累计、模型/token 分开核对。服务版本/权限会影响 `/key/info`、`/user/info` 和 `/user/daily/activity`。
4. 实际 Keychain 系统行为、跨进程重启恢复、网关重定向/证书/超时需要真实部署验收；单元测试使用内存凭据存储和 mock transport。

暂不包含其他供应商、余额/积分、多重团队限制、key 过滤历史、跨实例总费用或磁盘统计缓存。LiteLLM 图标按官方高速列车标志重绘简化 SVG，并非上游提供的原始矢量素材；来源和许可说明随 Icons 资源打包。

## 2026-09-22 试用包补充

本轮将顶部切换栏改为横向滚动，Overview 固定；实际内容超出空间时显示全部 provider 菜单，长名称保持单行且可通过 tooltip/菜单查看。菜单选择、Overview 行点击、排序变化都会使当前选择滚入视野。增加 2/6/30 个实例的原生 Preview 和最多 50 个虚构网关的 DEBUG 配置。搜索和分组仍为更多实例时的后续选项。

打包使用 `MYUSAGE_BUILD=41 ./Scripts/package_app.sh`，版本 0.17.1 (41)，源码版本文件不变。只生成本地试用产物，不覆盖 /Applications 中已安装版本，不创建发布或提交。

本轮复验：440 项测试、macOS xcodebuild 与 release 打包通过；ad-hoc 签名和 ZIP 完整性校验通过。原生 fixture 截图检查了 2 个 provider 时不出现溢出菜单、30 个 provider 时末尾选中项自动滚入视野。手动触控板滑动和全部菜单操作仍由试用验证。

产物：`MyUsage-0.17.1-gateway-preview-20260922-161810.zip`，Apple Silicon / arm64；附 `.sha256` 校验文件。

## 2026-09-22 试用反馈修正

- Updated 只在页脚展示一次；取当前展示数据中最早的成功获取时间。额度或历史刷新失败不会把旧数据标成刚更新，悬停可分别查看成功时间。
- 模型汇总后过滤明确为零的费用，保留费用未知的 token 记录，原始日数据和 token 总量不变；非零且不足一美分显示 `<$0.01`。
- Token 只保留四列，移除缓存写入、请求次数、历史 Updated 三行辅助文字。
- 预算消费保留在额度区，删除重复的 Current budget period 金额行；历史改为 This month。预算周期来自服务端，历史固定 UTC 自然月，两者不保证一致。
- LiteLLM 使用官方高速列车意象的简化单色 SVG，18pt 菜单栏自适应明暗；面板共用现有 provider tile 的圆角、渐变和描边。原始标志参考、重绘说明和上游 MIT 许可见 `MyUsage/Resources/Icons/LiteLLM-NOTICE.txt`。
- 本轮修改：`GatewayUsage.swift`、`GatewayProviderDeck.swift`、`ProviderPopover.swift`、`UsagePopover.swift`、`GatewayPresentationTests.swift`；图标涉及 `ProviderInstanceView.swift`、`ProviderIcon.swift`、`MenuBarIcon.swift`、`Resources/Icons/ProviderIcon-litellm.svg` 与 `LiteLLM-NOTICE.txt`；fixture 和设计/验证文档同步更新。
- 验证：30 项网关测试通过；完整测试 157 项 XCTest + 287 项 Swift Testing，共 444 项通过；macOS xcodebuild 通过。
- 原生 fixture 浅色完整用量和深色仅 token 截图通过检查：零费用模型消失，微额模型保留，token 辅助行移除，页脚只有一处更新时间。菜单栏同尺寸单色图标完成明暗渲染检查；真实菜单栏壁纸/选中态仍需试用确认。
- 新试用包：`MyUsage-0.17.1-gateway-preview-20260922-173938.zip`，版本 0.17.1 (42)，arm64；`MYUSAGE_BUILD=42 ./Scripts/package_app.sh` 构建，ad-hoc 签名、图标/许可资源和 ZIP 完整性校验通过。附 `.sha256`。未覆盖 /Applications 安装、未提交或发布。

## v0.17.2 首次发布记录

用户于 2026-09-22 确认试用无明显问题，并授权提交、发布新版本。功能提交为 `be612d87`。首次打包版本为 0.17.2，build 43，接续本地试用 build 42；CI 显式采用 tag 源码的 build 号，避免打包时再次自增。上面的手动检查清单仍用于更广泛的部署/系统组合，不把单次用户试用扩展为全部场景已验收。

发布前复验：444 项测试、macOS xcodebuild、0.17.2 (43) release 打包、ad-hoc 签名、ZIP 完整性和 SHA-256 校验通过。发布说明为中英双语，GitHub Release 按既有流程提取英文部分。

## v0.18.0 版本号更正

本次新增网关 provider，按次版本升级发布 0.18.0 (44)。更正时 v0.17.2 已完成 GitHub 发布，因此保留其 tag 和发布历史，新增 v0.18.0 作为最新版本；v0.17.2 的发布说明将引导至 v0.18.0。应用功能与已验收的版本一致，本次仅调整版本元数据及发布文档。

0.18.0 (44) 本地 release 打包、ad-hoc 签名、ZIP 完整性和 SHA-256 校验通过；功能代码未变，原 444 项测试与 macOS CI 均已通过，新 tag 继续执行发布测试。
