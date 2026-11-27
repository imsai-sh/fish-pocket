# 官方 Web 功能对齐清单（iOS 移植取舍）

> 原则：dsh-ios 只是引擎的原生界面，**移植的是能力，不是网页的样子**：只移植适合手机的功能，交互按 iOS 习惯重新设计；只在桌面上有价值的功能不移植；官方产品运营用的东西（反馈、公告、数据收集）也不移植，我们不是官方。
>
> 功能 ID 引用自同目录三份清单：`C-` → [conversation.md](conversation.md)，`S-` → [shell.md](shell.md)，`G-/A-/M-/I-/AP-/O-/P-/PC-/F-/MK-/MS-` → [settings-plugins.md](settings-plugins.md)（其中设置外壳的 `S-01…S-07` 写作 `设置 S-0x`，与 shell.md 的 `S-xx` 区分）。那三份清单里的 ☐/☑ 状态已过时，**以本文为准**。
>
> 更新于 2026-11-18（引擎从 `0.2.2-rc.3` 升到 `0.2.2-rc.4`，网页端没有新功能，见 §3.3 末尾；`0.2.2-rc.3` 的对齐情况见 §3.3）。状态变化时同步更新本文。

## 1. 现状

第一批到第三批已全部实现（2026-11-04 合入），下表「部分」的缺口见第 3 节。

| 区域 | 已对齐 |
|---|---|
| 消息流 | 图片与大图、回到底部、输出上限「继续」、加载更早、跳转轮次、工具专属卡片（C-56…C-71、C-79）、时间戳、本轮用量、重试条、命令与压缩卡、定时触发通知、计划卡、交付物卡、密钥遮罩、推理摘要、运行计时 |
| 提问 | 经 `$events` 的 `user-questions/request` 作答、倒计时与「慢慢回答」、分页与跳过、计划审阅、迟到回复 |
| 输入框 | 草稿持久化、发送中气泡与失败放回、Todo / 目标 / 上下文 Dock、计划模式、队列编辑、`/` 排名与分组、`@` 引用、消息引用（上游 `dsh-message-quotes`）、相机与文件附件、`fileUploads` 上传、模型搜索、权限目录刷新、`busyEnter` |
| 壳层 | 统一 Toast、归档撤销、分叉命名、首启引导、子智能体目录与子会话、后台任务、Agent 预设、Session 日志、目录浏览加工作区、Cordis 面板、断线横幅、指数退避重连 |
| 工作台 | 文件预览（Markdown / 图片 / PDF）、自动刷新、内置浏览器、终端协议重写（背压、序号、重连、重命名、接管输入）、改动页跳转 |
| 自动化 | `schedule/catalog`、筛选与搜索、时区格式化、编辑（含 Cron、时区、未保存确认）、运行记录、按会话筛选 |
| 设置与插件 | SettingsMirror、Schema 表单补全、官方配置页、第三方与自定义提供商、`discoverModels`、插件完整安装流程与后台安装、组件开关、更新、插件市场、内置插件清单、Agent 预设页、`cordis.patch.yml` 编辑（保存后校验，失败回滚）、版本号 |

## 2. 验证情况

2026-11-04 用真实 DeepSeek Key 在模拟器上跑了完整回合（XCUITest 走 SwiftUI 界面，脚本未提交）：

- **真实回合跑通**：首次引导与填 Key、发送与流式输出、工具调用、排队（下一轮自动发出）、插话、提问作答、计划审阅（同意执行到轮尾计划卡）、真实审批（越权写入）、`@` 文件与会话引用（智能体读到了被引用的会话）、子智能体目录与进入子会话、后台任务查看与停止、定时任务创建与详情、分叉、归档与撤销、长按回复菜单、选择文本、工具详情 sheet、草稿重启后保留。
- **看过页面**：设置与高级页、插件列表、抽屉、标题菜单、工作台五个页签。
- **编译**：模拟器与真机目标都通过；引擎单测 43 过 5 跳过。
- **没有验证**：
  - 真实回合之外的页面：插件安装、更新与市场（`pluginMarket/*` 只核对过参数名）、添加第三方提供商、自动化编辑保存、Agent 预设页、配置文件编辑、日志导出的 ZIP、目录浏览加工作区、内置浏览器打开页面、相机。
  - 提问倒计时（没有遇到带时限的提问）、`session/page` 翻页、自动加载更早消息。
  - 真机：这一版只安装启动过；真机上的文件路径、`fs.watch`、后台任务等行为都没有单独测。
  - iOS 17：回到底部依赖 iOS 18 的滚动几何。

实测的已知限制：**bash 的输出要等命令结束才出现**，后台任务运行中显示「等待输出…」，这是执行层（just-bash）的限制，不是界面问题。

## 3. 未完成

**部分实现**

| ID | 缺口 |
|---|---|
| C-12 / C-13 | 依赖 iOS 18 的滚动几何，iOS 17 没有按钮也不跟随；不记阅读位置 |
| C-61 | 未识别 spill 提示，被 spill 的命令可能丢退出码而显示成功 |
| C-72…C-76 | 只改善标题与摘要，没有专属卡片（这些工具本身没有 meta） |
| C-41 | 有重试或失败尝试的轮次不显示用量，比官方保守；不读 `performanceUsage` |
| C-83 / C-87 | 没有「不可用」「父会话离线」两档；执行命令时只禁发送 |
| C-97 | iOS 17 拿不到光标，按光标在末尾处理 |
| C-117 | 提问草稿只存内存 |
| C-150 | 并发上传固定为 2 |
| S-08 / C-01…C-03 | 没有审批按钮：Client 半部跑不了，`cordis/request-run` 立即回 `client-half-failed` 并提示 |
| S-45 | 从 App 文稿目录起步，没有路径编辑 |
| S-57 | 改动数据仍来自工具调用，没接 `api/changes.*`（要先取 `workspace/changes` 的 seq；git 支持已合入 main，可以再评估） |
| S-79 | Markdown 里的本地图片不显示，没有代码高亮 |
| M-03 | 编辑改为 push 页，没有首启时直接展开的设置卡 |

**没做**

C-49 `/goal` 气泡 · C-90 原子 chip · C-16 鲸鱼动画与流光 · C-30 组体内层滚动 · S-15 / S-22 手动排序 · S-19 工作区树 · S-40 启动恢复（有意保持「打开即新对话」）· S-65 View 标签 · S-114 / G-02 多语言 · C-138 思维链翻译 · C-139 语音输入 · P-16 版本兼容豁免（官方 Web 也没有界面）· F-35 折叠（用独立页面代替）

**有意与官方不同**

- C-46：官方没有「继续」按钮，这里加了，发送「继续」。
- C-32：运行中的工作步骤组允许手动折叠。
- P-15：关闭安装弹窗继续在后台安装，要取消得点「取消安装」（手机上下滑关 sheet 容易误触）。
- S-78：文件变更时只显示横幅，不自动重载，保住滚动位置。
- 首启引导：没有可用模型时不在启动时自动弹登录框，先进正常界面；发出第一条消息发现没有凭据时才弹（同一个登录 / API Key sheet）。
- 同时开着网页版时，提问和审批都由 iOS 持有，不再转给网页。
- **本机能力（官方 Web 没有）**：`device_info`、`notify`、`calendar` 等工具，走 `dsh_ios_native` addon（`native/ios-native`）。官方 Web 跑在桌面浏览器里，没有这些框架，所以这是本项目自有扩展而非对齐项。设计与后续分期见 [`../native-services.md`](../native-services.md)。

**已知风险**

- `cordis.patch.yml` 的保护只在 App 内编辑器里；文件已损坏，或在写入与校验之间 App 被杀，引擎会循环重启，App 内无法恢复。
- 引擎重启后，已打开的安装 sheet 还持有旧 `AppModel`，「立即启用」可能失败。

## 3.1 iOS 化改造

对照 Apple HIG 把网页式交互改成手机习惯（2026-11-04）：工具行 44pt、详情进 sheet；回复操作收进长按菜单；统一的「+」托盘（相机 / 照片 / 文件、引用、指令、模型、计划、思考、访问模式）；运行中有字时也能停止；多层 dock 合成一条状态条；顶栏显示会话名；抽屉默认按工作区分组（可切到按时间）、防左滑误归档；Toast 短文案放到拇指区；工作台不自动弹键盘；保存放工具栏；设置首页精简，开发者项收进「高级」；添加提供商分两步；`@` 引用在输入框和气泡里只显示 `@标题`。消息引用（2026-11-16）：网页版在选中文字旁浮出按钮、引用块嵌在输入框文字中间；手机上改为长按消息「引用」整条，或在「选择文本」页选中一段后从编辑菜单「引用」，引用块排在输入框上方、各带 ✕，发送时排在正文前。发出去的仍是普通 Markdown blockquote，草稿里的 `quotes` 字段与网页版同形，气泡和排队预览按 `>` 行识别显示，与上游一致。规格文档 `docs/webui/` 只用来确定协议和能力，界面以 `docs/design/README.md` 为准。

## 3.2 上游 `0.2.2-rc.1` 新增（尚未移植）

引擎 2026-11-06 从 `0.2.1-rc.4` 升到 `0.2.2-rc.1`。协议层的删除、改形和新增方法见 [protocol.md](protocol.md) §0.1，原生客户端已经跟上的只有那几处**必须**跟的形状变化（`schedule/edit`、`session/attachment`、任务记录的 `target` / `status` / `updatedAt`）。下面是上游新增、原生还没有的能力。

| 上游新增 | 原生现状 |
|---|---|
| 整段历史会话复制为 Markdown（含可用的原始日志路径） | 没有 |
| 工作步骤收起后保留全部助手文字回复，可切换为仅最终回答 | 收起就是收起，没有这个切换 |
| 插件管理的富文本详情（`pluginMarket/readEntryDetail`、`pluginManager/readBundleDetail`） | 插件页只有现有字段 |
| 第三方插件包更新（`pluginManager/listVersions`、`updateBundle`；热更新失败回滚旧版） | 只能装和卸，不能更新 |
| 自动化任务：一键清除全部已结束（`schedule/deleteInactive`）、立即投递一次（`schedule/run`）、`paused` 状态的暂停 / 恢复、`rrule` 规则 | 都没有；`rrule` 任务在详情页按只读处理（这个编辑器表达不了它） |
| 会话快照与订阅拆成独立接口（`session/state`、`session/events`、`session/wait`、`session/observeState`、`session/observeProjections`、`session/observeEvent`） | 仍走 `session/follow` + `session/control`，上游也还在，不急 |
| 工具返回值的原始 JSON 查看（`toolResults/watch`） | 没有（Trajectory 本来就不移植，见 §4） |
| 回答下方的操作卡（`actionCards/act`） | 没有 |
| 日语、西班牙语、法语、德语、俄语、巴西葡萄牙语界面 | 只有中文和英文 |
| 图片进入输入框就上传，发送时复用；默认单图上限提到 50 MiB | 仍在发送时把图片内联成 base64 放进 `submittedAttachments` |
| 默认关闭的 `apply_patch` 工具（一次完成多文件增删改移） | 没有专属卡片，按通用工具卡渲染 |
| 统一的右键 / 键盘菜单，文件预览常驻目录树与文件定位 | 桌面交互为主，见 §4；目录树待评估 |
| 实验插件：`subagent_oar`、个性化推荐（`pluginRecommendations/*`）、开发者工具统计、变更请求与工作树（`forgePanel/*` 20 个方法）、共享会话（`liveshareShares/*` 12 个方法） | 不移植；「变更请求与工作树」如果以后要做，是一整块新功能 |

引擎侧的变化不需要原生改动：最低 Node 提到 24.9（内嵌 nodejs-mobile 是 24.20.0，满足）、Cordis 升到 4.1.0、pi-ai 升到 1.3.0、Search 给模型更长的摘要、远程连接默认开启 WebSocket 压缩（客户端协商，不开就不压）、Web 静态资源支持 ETag。「Git 工作树」插件已并入「变更请求与工作树」，本项目没有在 `dsh.profile.bundles` 里启用过它，不受影响。

## 3.3 上游 `0.2.2-rc.3` 新增

引擎 2026-11-17 从 `0.2.2-rc.1` 升到 `0.2.2-rc.3`。协议层的删除、改形和新增方法见 [protocol.md](protocol.md) §0.2。接口形状跟着变的有：`account/watch`（结果改成 `{type, state}` 信封）、`subagents/prompt`（去掉 `parentSessionId` 和 `mode`）、`subagents/interruptByUser`（取代 `interruptByParent`）、`pluginManager/updateBundle`（git 安装的包要带 `spec`）、网页搜索设置（`web-deepseek-api` 的 `baseURL`、`apiKeyEnv` 拆成 `searchBaseURL`、`fetchBaseURL`、`searchApiKeyEnv`、`fetchApiKeyEnv`）。Office 渲染（`office-kit`）和 Office 技能在 iOS 上关闭，见 `engine/ios.patch.yml`。

官方网页版这一版新暴露给用户的功能，同一天逐项对齐。对照的办法：比两版 `dsh-web-app/cordis.patch.yml` 默认启用的 `client-ui` 包和各包界面文案的增删，再拿旧版的包核对哪些是真的新增。

| 上游新增 | 原生现状 |
|---|---|
| 智能体团队改成内置，输入区有开关（`agentTeams/setEnabled`），共享任务板（C-140） | 已对齐。「+」托盘里的「智能体团队协作」开关，会话用过模型后停用要确认；子智能体面板多一节「共享任务」（进度、状态、描述、负责人），没有子智能体只有任务时顶栏入口是「任务板」。没做：`/team on`、`/team off` 的回执仍按普通命令卡显示 |
| 失败的一轮可以「继续生成」（投影 `conversationContinuation`，发空内容的 `session/prompt`） | 已对齐。按钮在这一轮的失败提示下面，只在引擎说可以接着这一轮、输入框和队列都空时出现；时间线上记一行「已请求继续生成」 |
| 模型的重试策略（`retryPolicy`：模式、最大重试次数、错误码、退避） | 已对齐。提供商 → 高级 → 重试策略，DeepSeek 和其他提供商都有；选回「默认」清掉覆盖 |
| 自定义提供商的 Gemini 协议（`google-generative-ai`） | 已对齐。协议里多一项「Gemini API」，要先填 Key，推理档位只给 minimal、low、medium、high |
| 网页搜索和网页获取各选提供方（`web/listProviders`），Search API、Fetch API 各有计费方式（`searchBilling`、`fetchBilling`） | 已对齐。插件 → 网页搜索与获取。iOS 上默认的搜索提供方是内置 Bot 插件注册的 `auto`，页面里叫「自动」；默认的获取提供方是 `http`「本机直接获取」。Search API、Fetch API 各自的地址和 Key 引用只读不改，设了就锁住计费方式并说明 |
| 整个工作区的文件搜索（`workspaceFiles/search`） | 已对齐（原 S-77）。工作台 → 文件，路径右边的放大镜；可选显示隐藏项、跳过 `.gitignore` 忽略的文件。文件列表默认不显示点开头的条目，旁边的眼睛切换。没做：排除清单不能编辑，用的是官方默认那一份；这两个偏好全 App 共用，官方按工作区记 |
| 账户通知卡片（`account/getNotifications`、`account/reportNotificationEvent`，取代赠金卡片），按 `nextPollAfterSeconds` 轮询 | 已对齐。登录期间按引擎给的间隔轮询，展示、点击、关闭各上报一次。没做：切换界面语言后重取文案（`account/getNotificationContent`），要到下一次轮询才换 |
| 子智能体有名字（`subagentCatalog[].name`），结束通知带结束原因 | 已对齐。面板、详情和子会话切换里显示名字；通知标题按完成、中止、出错等区分 |
| Agent 打开的终端在终端面板里可见、可接管（`terminal/watch`） | 已对齐。终端列表跟着引擎变，Agent 开的终端带「Agent」标记，连上后提示「你一输入就由你接管」。要先在插件页启用实验性的终端插件包 |
| 新工具 `apply_patch`、`subagent_fork`、`wait_agent` | 卡片标题已对齐（编辑、派生子智能体、等待消息），内容仍是通用卡片 |
| 插件清单：团队协作不再是实验插件包；新增 Computer Use 包 | 已对齐。实验性插件里去掉团队协作那一项；Computer Use 是桌面专属，不列出，`cuaAccess/*` 的 9 个方法不接 |
| DeepSeek 会话导入（`deepseekChatImport/limits`） | 已对齐。新会话输入框上方的「导入 DeepSeek 会话」：选导出的 ZIP 和工作区，显示上传和写入进度；插件默认关闭，第一次导入时自动开启 |
| MCP 管理（`mcpManager/probe`、`mcpManager/restart`、`mcpManager/watch`） | 官方网页版这一版没有对应界面，不做 |
| 变更请求与工作树新增的 12 个方法（`forgePanel/*`，见 [protocol.md](protocol.md) §0.2） | 不移植；整块「变更请求与工作树」没做（§3.2） |
| 共享会话的多会话与按插件授权（`liveshareShares/addSessions`，结果里的 `sessionIds` / `viewerPluginAccess` / `viewerPlugins`） | 不移植（§3.2） |

和官方不同的一处：子智能体的父会话没在运行时，子会话的输入框仍然只读并说明原因。引擎这时确实拒收（`subagent/delivery-unavailable`），所以提示保留。

**验证**（2026-11-17，iOS 27 模拟器，真实 DeepSeek Key）：团队开关和停用确认、一次真实的团队协作（建共享任务、起子智能体认领）、任务板、「继续生成」（把 API 地址指到连不上的端口造出失败，恢复后点按钮续上）、重试策略的保存与清除（「所有错误」模式下断开服务会一直重试到恢复）、Gemini 协议（本机起一个模拟的 Gemini 服务，读模型列表和对话都走通）、搜索提供方切换并用 Search API 真搜一次、文件搜索、Agent 终端的标记和接管提示，都走过一遍。`scripts/smoke-matrix.sh` 的全部页面另在 iOS 18 的 iPhone、iOS 26 和 iOS 27 的 iPad、iPhone Duo 上截图看过，其中文件搜索页是这次加进去的（`-dshOpen filesearch`）。没有验证：账户通知卡片，要真实的 DeepSeek 账号并且服务端正好有通知；团队开关、任务板、重试策略和搜索设置这几页只在 iOS 27 的 iPhone 上点过。

### 上游 `0.2.2-rc.4`

引擎 2026-11-18 从 `0.2.2-rc.3` 升到 `0.2.2-rc.4`。这一版只改了三个包的源码，网页界面、Remote 方法表（39 个包逐个比对）和发给模型的工具清单（54 个，名字和定义都没变）都和 rc.3 一样，没有需要对齐的新功能。

| 上游变化 | 原生现状 |
|---|---|
| DeepSeek 内容拒答（`stop_reason: "refusal"`）的错误码从 `MALFORMED_RESPONSE` 改成 `CONTENT_REFUSED`，消息里带上 DeepSeek 给的原因；拒答前用掉的 token 照样记入用量。不在默认的重试列表里 | 已对齐。会话和 Bot 私聊里这一轮的失败提示是「内容没有通过 DeepSeek 的安全审核，模型拒绝回答」，有原因时接在冒号后面；群聊成员停下时说「内容没有通过 DeepSeek 的安全审核」。只影响 DeepSeek 账号和 DeepSeek API Key 两条线路，Fish Pocket 线路走 pi-ai，不经过这个适配器 |
| 共享会话在桌面版 Electron 里启动隧道进程的修复 | 桌面专属，和 iOS 无关 |

**验证**（2026-11-18，自建模拟器）：iOS 27 iPhone 上先装 rc.3 的包，建带工具调用的会话、起过子智能体的会话、两个 Bot、一个群并各说几句，再覆盖安装 rc.4：老会话读得出来、能接着聊，子智能体在父会话运行时能追问、能中断（结束原因 `aborted / user`），Bot 记得之前的话，群里新发一条后两位成员的回复都显示出来。新建会话跑 bash 用例，工具卡片、回复、自动标题正常。拒答提示用一个本机假 DeepSeek 服务（`DEEPSEEK_BASE_URL` 指过去，返回 `refusal`）在会话、Bot 私聊和群聊里各看了一遍。`SMOKE_SCREENS=full scripts/smoke-matrix.sh` 在 iOS 27 的 iPhone、iPad、iPhone Duo，iOS 18 和 iOS 26 的 iPhone 上全部通过，截图逐张看过。

## 3.4 本项目自有扩展（官方 Web 没有）

**本机能力**（`docs/native-services.md`）：把 iOS 的系统框架以工具的形式交给智能体——设备状态、本地通知、朗读、日历、提醒事项、地图、图像识别、剪贴板、位置、文本分析。官方 Web 没有对应物，因为浏览器够不到这些东西。

三件和官方不同、会影响界面的事：

- 设置里多一页「本机能力」，列出这个构建实现了哪些能力、各自的系统授权状态，以及一页「使用记录」。
- 插件安装确认的 `installTrust` 多一句本机能力（见 `settings-plugins.md`）。
- 日历和提醒的写操作会弹系统事件编辑器或原生确认框。这是有意为之：系统给的权限是读写一起给的，写的那道门只能由我们自己把。

## 4. 暂不移植（桌面专属）

| ID | 功能 | 理由 |
|---|---|---|
| S-03 | 左栏宽度拖拽 | iPhone 用抽屉，iPad 由系统分栏控制（折叠已做：顶栏按钮、⌘B） |
| S-04 | 品牌区 | 无动作，手机不需要 |
| S-26 / S-49 | 会话、工作区悬停卡片 | 悬停交互；信息已在长按菜单里 |
| S-29 | 双击改名 | 用长按菜单「重命名」代替 |
| S-36 / S-52 | 会话、工作区拖拽排序 | 拖拽交互，手机上需求低 |
| S-115 / G-07 / C-88 / C-89 / C-149 | 快捷键编辑、发送键位设置、双 Esc 停止 | 硬件键盘专属。常用键位已做成固定快捷键，见 feasibility.md「iPad」 |
| S-67 / S-69 / S-70 / S-72 | 右栏布局持久化、多 tab 停靠规则、分栏、拖拽、浮窗、开始页 | 手机用固定页签的工作台 sheet 代替，iPad 是右侧一栏 |
| S-63 / S-88 | 在应用中打开（外部编辑器） | 依赖 Host 桌面上的编辑器；本机分享已由 ShareLink 覆盖 |
| S-113 | 自定义字体族 | iOS 可用字体少，意义不大 |
| S-116 | 在 Host 上打开配置文件 | 需要 Host 桌面打开文件；手机上改成 App 内编辑（设置 S-05，已实现） |
| S-127 / A-16 | Desktop 安装引导、欢迎和充值引导 | 桌面安装流程 |
| 设置 S-04 / S-07 / S-11 | 服务版本变化对话框、桌面端更新指示 | 内嵌引擎与 App 一起发版，通过 App Store 更新 |
| C-07 / C-133…C-137 / C-146 | Trajectory 开发者视图及其开关 | 调试视图，重度依赖拖拽、滚轮、右键 |
| C-08 | 内容宽度拖拽 | 手机屏宽固定 |
| C-53 | 未知事件兜底显示 | 调试用途 |
| C-57 中的「查看」（Inspect） | 工具调用检查器 | 开发者功能 |
| C-104 中的「添加文件夹」 | 拖入 Host 路径 | 依赖桌面 `__DSH_HOST_PATHS__` 桥 |
| — | Tooltip、滚动条 linger、marquee 标题、右键菜单 | 桌面交互原语，手机用长按、contextMenu 代替（见 shell.md §5.3） |

## 5. 官方专属（不移植）

这些是官方产品运营用的，不是用户要用的能力。下表的引擎插件在 `engine/ios.patch.yml` 里关掉，`网页版` 里也不会有。

| ID | 功能 | 处理 |
|---|---|---|
| G-11 | 上传 Session Log | 官方默认开启，随官方 API 请求上传会话日志。关掉 `session-log-deepseek`、`ui-settings-session-log` |
| C-37 / C-129 | 消息反馈 👍/👎 | 关掉 `message-feedback`、`ui-message-feedback` |
| A-14 / S-117 | 意见反馈问卷 | 不做 |
| — | `/feedback` 命令 | 关掉 `command-feedback` |
| — | 使用统计 | 关掉 `product-analytics` |
| O-01 / S-125 | 预览版说明 | 不做 |

本地导出 Session 日志（S-62）保留：那是用户自己的数据，不经过官方。

## 6. iOS 做不到（BLOCKED）

| ID | 功能 | 原因 / 替代 |
|---|---|---|
| S-46 | Host 原生目录选择 | `directoryPicker/pick` 要在 Host 本机弹系统对话框；`fileImporter` 拿到的是沙盒外的安全作用域 URL，引擎读不到。替代方案是 S-45 目录浏览（已实现） |
| S-91 / A2 | 选择 Shell | iOS 上只有 just-bash 一个 shell |
| C-127 部分 | 交付文件「用默认应用打开 / 在文件管理器中显示」 | 要在 Host 上 spawn `open`；手机上改用 QuickLook 或分享 |
| M-14 / P-06 / C-04 Client 半部 | 第三方 React 扩展槽、插件自带 UI | 浏览器 JS，原生跑不了，只能走「网页版」WebView 兜底 |
| C-139 host-local provider | 本地语音识别 | 如果需要本地二进制或子进程，真机不行；cloud provider 可行 |
