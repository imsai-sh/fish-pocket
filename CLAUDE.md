# Fish Pocket 开发说明

## 「新功能」弹窗：每次发版怎么更新内容

用户升级后第一次打开 App，会弹出一个「新功能」页面；设置 → 关于 → 新功能 也能再看。内容全部写在 `app/DshIOS/Core/WhatsNew.swift` 的 `releases` 里，弹出逻辑不用改。

### 加内容

`releases` 按从新到旧排列，新条目加在最前面。

- **新版本**：加一条 `Release(version: "1.2.0", features: [...])`。`version` 要和 `app/project.yml` 里的 `MARKETING_VERSION` 一致。App 还没到这个版本时条目不会显示，所以可以提前写。
- **同一版本的后续 build 又加了功能**（比如 TestFlight）：再加一条 `Release(version: "1.1.0", build: 20, features: [...])`。`build` 写第一个带这些内容的 build 号，`features` 里只写这次新增的。build 号由 Xcode Cloud 分配，提交时还不知道确切是几，写「目前最大的 build 号 + 1」就行：App 的 build 号大于等于它时条目就会显示。
- **只修 bug 的版本**：不加条目，也就不会弹。

每条 `Feature` 由三部分组成：一个 SF Symbol、一句标题、一行说明。只写用户能感知到的亮点，一次 3～5 条，不要写成修复列表。

### 文案翻译

标题和说明先写中文，然后：

1. 跑 `scripts/sync-strings.sh`，把新文案同步进 `app/Shared/Localizable.xcstrings`。
2. 给新词条补上 `en`、`es`、`ja`、`ko`、`zh-Hant` 翻译，照下面「界面翻译」一节的规则直接翻。
3. 跑 `node scripts/strings-coverage.mjs`，确认各语言都是全覆盖。

同步脚本有时会顺带改动其他旧词条，提交前看一下 diff，只保留这次自己加的部分。

### 弹出规则（已经实现，了解即可）

- 新装用户不弹。从 1.0.x 升级的老用户靠本地已有的设置识别，会弹。
- 同一个版本、同一个 build 只弹一次。决定弹出的那一刻就记为已看过，用户点「继续」、点 ✕、下滑关掉或直接杀掉 App，都不会再弹。
- 升级到某个版本时，这个版本下所有没看过的条目会合并成一次显示。
- 只有看过这个版本之后，后续 build 又加了条目，才会再弹，而且只弹新增的部分。这时版本胶囊里带上 build 号，比如「版本 1.1 (20)」，表明是新 build 的内容，不会让人以为是重复提醒。

### 注意

- 已经发出去的条目，不要改它的 `version` 或 `build`，否则看过的人可能会再弹一次，或者有人会漏看。
- 本地自测用 Debug 版的启动参数：`-dshVersion 1.1.0 -dshBuild 20` 让 App 当成这个版本和 build 运行；`-dshOpen whatsnew` 直接打开弹窗。这些参数只在 Debug 版里生效。

## 界面翻译

所有语言的译文，包括繁体中文，都由做这次改动的 Agent 自己逐条直接翻译。不用 OpenCC 这类简繁转换工具，也不用机器翻译服务或脚本批量生成初稿，再拿来校对也不行：大模型直接翻最准，转换工具只会逐字逐词替换，一词多义时常选错（比如把「权限」转成「許可權」、「连接」分不清連線和連結）。

- 文案多的时候可以分批交给子 Agent 翻，但每一批都要由 Agent 读原文直接翻出来。
- 繁体中文按台湾用词写，系统 App 和 iOS 功能用 Apple 台湾版的名字，产品名词跟已有译法保持一致，术语见 `CONTRIBUTING.md` 的「界面语言」。
- 脚本只用来做机械检查：覆盖率、格式占位符是否和原文一致、有没有残留简体字。

## Xcode Cloud 构建

推送到 `release` 分支且改到 `app`、`engine`、`native`、`scripts` 任一目录时，Xcode Cloud 会自动归档一次，发到 TestFlight；只改文档不触发。合进 `main` 不出包。影响打包的东西都放在这四个目录里，新增的也照此放。

- 工程文件不进仓库。Xcode Cloud 克隆后跑 `app/ci_scripts/ci_post_clone.sh`：装工具、下载 nodejs-mobile 和 Python、编译 libgit2、组装引擎、生成工程。这个脚本在 Mac 上也能直接跑，改完先本地跑一遍。
- build 号由 Xcode Cloud 分配，每次构建加 1，失败的也占号。脚本把它写进生成的工程，`app/project.yml` 里的 `CURRENT_PROJECT_VERSION` 只对本地构建有效。
- Fish Pocket 账号要构建时带上服务地址才会出现（`FISH_POCKET_API_URL`，`app/project.yml` 里默认为空）。云端构建从工作流的环境变量读它，脚本写进生成的工程；本地构建从 `.env.local` 读它（不进 git，照 `.env.local.example` 写；Claude Code 新建 worktree 时按 `.worktreeinclude` 拷过去），`scripts/run-sim.sh`、`scripts/run-device.sh` 自动带上，打包时会打印账号功能是开还是关（不设是正常的，账号不是必需的）；自己手写 `xcodebuild` 时要在命令行上传。没带地址的构建里看不到这个功能，「新功能」里也不提它。
- 改了 `app/project.yml` 里 SwiftPM 依赖的版本后，本地构建一次，把 `app/DshIOS.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` 拷到 `app/ci_scripts/Package.resolved`。Xcode Cloud 不自己解析版本，两边对不上会构建失败。

### 分支

- **`main`**：默认分支，日常开发都在这里。PR 都合进 `main`，合多少次都不会出包。
- **`release`**：出包用，只从 `main` 往前走。攒够一批要发的改动，确认 `main` 上的 GitHub 编译检查是绿的，再把 `main` 推过去：
  ```bash
  git push origin main:release
  ```
  这是快进推送，不用开 PR。推上去就开始云端构建，过审后会发给公开测试用户，所以只推真打算发出去的东西。
- **紧急修复**：从 `release` 开分支修，PR 合进 `release` 出包，然后把 `release` 合回 `main`。这样 `main` 包含了这次修复，下次推 `main:release` 仍然是快进。
- 不要强推 `release`，也不要直接在 `release` 上提交而不合回 `main`，否则下次推 `main:release` 会因为不是快进被拒。

### 注意

- **升级 nodejs-mobile、Python、libgit2、FFmpeg 的版本后**（`scripts/fetch-nodejs-mobile.sh`、`scripts/fetch-python.sh`、`scripts/build-libgit2.sh`、`scripts/build-ffmpeg.sh`），本地从零跑一遍 `app/ci_scripts/ci_post_clone.sh`。升级 FFmpeg 还要确认 `native/ffmpeg/ffmpeg.patch` 能打上，并在模拟器里实测一遍 `ffmpeg`、`ffprobe`。云端每次都重新下载和编译，下载地址或 sha256 写错会直接失败。
- **FFmpeg 用本仓库 GitHub Release 里预编译好的包。** `scripts/fetch-ffmpeg.sh` 下载 `FFmpeg.xcframework.zip` 并校验 sha256，不再每次从源码编译。Release 的 tag 形如 `ffmpeg-9.0.2-c79aea98`，末尾是构建输入的指纹，构建输入指 `scripts/build-ffmpeg.sh` 和 `native/ffmpeg` 里除 `binding.c` 以外的文件。改了这些文件或升级 FFmpeg 后，指纹对不上，下载脚本会自动改为从源码编译，构建不会坏，只是慢一两分钟。这时补发一个新包：
  1. 跑 `scripts/fetch-ffmpeg.sh --package`，它从源码编译、打包，并打印 tag、zip 路径和 sha256。
  2. 照常扫一遍隐私，`strings` 查二进制里有没有家目录等本机路径。
  3. `gh release create <tag> <zip> --target <包含这些改动的提交> --prerelease --latest=false`。
  4. 把 tag 末尾的指纹和 sha256 填进 `fetch-ffmpeg.sh` 开头的 `inputs`、`sha256`，和改动一起提交。

  旧的 Release 不要删，旧提交构建时还要下载它。
- **云端构建只在推 `release` 时跑**，不在分支上手动触发。改构建脚本或 `app/project.yml` 的工程结构时，本地跑通 `ci_post_clone.sh` 并编译一遍就可以合并；云端的签名和上传等下次推 `release` 时再验证。
- **触发规则按提交看，不按净差异看。** 推到 `release` 的这一批提交里，只要有一个改到上面四个目录就会出包，哪怕后面的提交又把它改回去了。
- **连续推送 `release` 只跑最新一次**，前一次会被自动取消。但被取消的那次如果已经导出完，包照样会上传并占一个 build 号，所以 build 列表里的号不一定连续，也可能多出包。
- **归档成功就自动上传**，不用另外操作。构建要等上传的包处理完才算结束，全程二三十分钟，其中真正在构建的只有几分钟；处理完之前包不会出现在 build 列表里，不是没传上去。
- **某个版本在 App Store 上架后，这个版本号不再接收新包。** 之后的云端构建归档、导出都成功，上传时才失败，报 `90186` 和 `90062`。版本一上架，就把 `app/project.yml` 的 `MARKETING_VERSION` 升到下一个版本，并把「新功能」里还挂在旧版本下、商店用户没看过的 build 条目并进新版本的那一条。
- **云端构建失败不影响本地**：`scripts/run-sim.sh`、`scripts/run-device.sh` 和 GitHub 上的编译检查走的是各自的流程。
- **GitHub 的编译检查**在合进 `main` 或 `release` 的 PR 上跑，合进 `main` 后再跑一次；推到 `release` 不跑，因为推上去的都是检查过的提交。
- **GitHub 的编译检查用 Xcode 27.2**（`.github/workflows/ios-build.yml`，运行器是 `xcode-27`），和本机、Xcode Cloud 是同一代。它停在旧版本时出过一次事：本机和 Xcode Cloud 都能编的代码，旧编译器报「无法在合理时间内完成类型检查」。本机升级 Xcode 后，把工作流里的版本一起改；README「快速开始」里写的最低 Xcode 版本也跟着它走，因为没有别的地方验证更老的版本。

## 引擎或插件升级后的回归

**只要动了 `@deepseek-ai/dsh` 或 ds-bot 的版本，就必须在模拟器上把主体流程走一遍**，不能只跑单测和编译。它们的改动会从引擎接口、客户端槽位、插件装配一路影响到原生页面，单测和编译都看不出来：升到 0.2.2-rc.3 和 ds-bot 0.3.8 那次，单测全绿、编译通过，群聊里成员的回复却整轮不显示。

动手前先读上游自己写的变更：

- DSH 随包带升级指南，`engine/node_modules/@deepseek-ai/dsh/docs/upgrade-guide/`，每个版本一个目录。从旧版本到新版本之间的每一条都对一遍：配置行改名的对 `engine/ios.patch.yml`，设置字段改名的对原生设置页，接口改形的对 Swift 调用点。
- **官方网页版这段版本之间新暴露给用户的功能，原生要逐项对齐，这是升级的一部分，不是事后的遗留。**对比两版 `dsh-web-app/cordis.patch.yml` 默认启用的 `client-ui` 包、各包界面文案（`locale/` 或 `src/client/locales.ts`）的增删，列出新增和改动的功能，再对着 `docs/webui/parity.md` 逐项做。指南的分节不能直接当作这次的变更范围，有些条目旧版本里已经有了，要拿旧版的包核对。项目已定不移植的整块（变更请求与工作树、共享会话、桌面专属）除外。
- ds-bot 没有指南，只能对两版源码：原生调用的每个接口（`BotModel.call` 的调用点）返回的形状，以及它新增的默认开启的行为（`config.<名字> !== false` 这类开关）。新行为要不要在 iOS 上开，在 `ios.patch.yml` 的 `bot` 配置里定。Bot 和群聊做不做某个功能以它的网页版为准：它有的原生做，它拿掉或挪走的原生跟着拿掉或挪走，不按旧版行为补回去（它的网页端打包在 `client.js`，按 `// src/client/<文件>` 的注释定位，只读来确认有没有、在哪）。

然后按顺序：

1. `scripts/build-engine.sh` 收紧，`cd engine && node --test test/*.test.mjs` 全绿（macOS 上先跑 `scripts/build-git-addon.sh`，否则 git 那项会报不存在）。`test/ios-patch.test.mjs` 会查 `ios.patch.yml` 里的每个 id 在新版本里还在不在：补丁对不上的条目运行时只是被跳过，不报错。`ios.patch.yml` 整个关掉的官方插件（如 `harness-dev-context`，它告诉模型用户在网页版里），官方往里新加的东西也会一起被关掉，所以 `test/harness-dev-context.test.mjs` 记下了它现在注册的全部内容，一变就报错：先看新加了什么，再决定继续关着还是只去掉误导的那段，最后更新测试里的清单。
2. **先装旧版，造数据，再覆盖安装新版。**一台自己新建的模拟器装上升级前的包，建一条带工具调用的会话、一条起过子智能体的会话、两个 Bot、一个群并各说几句，然后覆盖安装新包：老会话读得出来、能接着聊，子智能体能追问和中断，Bot 记得之前的话，群里新发一条消息后成员的回复显示出来。老用户都是这么升上来的，只测全新安装测不到这条路。
3. `scripts/smoke-sim.sh` 把 `-dshOpen` 能到的每个页面截图，并断言包里的 DSH / ds-bot 版本和仓库里钉的一致、所有插件行无错、`/api/bot` 有响应、会话列表可读。`scripts/smoke-matrix.sh <UDID…>` 在几台模拟器上并行跑同一份。要覆盖的是：最新 iOS 的 iPhone 和 iPad、iPhone Duo、iOS 18 和 iOS 26 各一台（分栏和 Tab 布局三代不一样）。旧 runtime 的模拟器启动后截不了图时，`simctl shutdown` 再 `boot` 一次；还不行就新建一台。
4. **截图要自己逐张看**，脚本只保证页面起得来、数据没报错，看不出一页是不是它该是的那一页。重点看：会话首页、插件页（实验性插件列表里新版本带来的条目）、插件商店、设置、计划任务、连接器、本机能力、Mini Apps，以及 iPad / Duo 上的分栏和 Tab 布局。
5. 真跑一条会话链路：新建会话发一句「用 bash 运行 node -e "console.log(6*7)"，然后一句话告诉我结果」，确认工具卡片、流式回复、自动标题都正常。再看一眼发给模型的工具和技能有没有多出 iOS 上用不了的（会话事件里的 `request/header`）。
6. 打开 Bot 聊天和群聊各发一条消息，看回复在原生界面里显示出来，而不只是接口有响应。

发消息、读会话、调 Bot 接口都可以不点界面，直接走引擎的 HTTP 接口（信封格式见 `EngineClient.swift`，地址和令牌在 App 数据目录的 `.ios/web-url`）；界面上的结果用截图确认。脚本覆盖不到、要人工点的：输入框打字与发送、分享扩展、手表。

## 内置 skill：iOS 环境说明

`engine/skills/ios-environment/` 随 App 打包，App 里的 Agent 靠它判断这台「iOS 沙盒」里能做什么、不能做什么。它写错了，Agent 就会去试不存在的命令，或者放弃本来能做的事。

它按标准的 skill 格式分成两层，免得每次加载都把三万字全塞给模型：

- `SKILL.md`：每次加载都会读到的主文件。放随时要查的东西：有哪些命令、缺的命令用什么代替、shell 的行为、文件布局、Node、Python、包管理、git。
- `references/`：篇幅大、只在特定任务里才用得上的专题，Agent 按主文件的指引再去读。现在有 `plugins.md`（写或改 DSH 插件之前读）和 `device-capabilities.md`（用本机能力之前读）。

拆出去的专题，主文件里要留一段：一句话说清是什么、什么时候去读哪个文件（写成 `references/<名字>.md`），再加上不读也必须知道的硬规则。Agent 没读子文档时，只知道主文件里的内容。App 里技能目录映射在只读的 `/opt/dsh/` 下，Agent 读得到。

**只要改动影响 Agent 在 App 里的执行环境，就在同一个提交里更新这份 skill。** 包括但不限于：

- Shell 命令增减或行为变化：升级 `just-bash`，改 `engine/runtime/shell.mjs`（自定义命令、`/dev`、挂载）。
- git：`engine/runtime/git` 里增减子命令或改了限制（同时对齐 `MISSING` 里的替代建议）。
- Python：`engine/runtime/python`、`scripts/fetch-python.sh`（版本、pip/venv、subprocess 的能力）。
- FFmpeg：`engine/runtime/ffmpeg`、`native/ffmpeg`、`scripts/build-ffmpeg.sh`（版本、开了哪些编码器和封装格式、同一时间只跑一个）。
- Node 和包管理：`scripts/fetch-nodejs-mobile.sh` 的 Node 版本、pnpm 版本、`engine/runtime/node-worker.mjs`、`engine/shims`（比如 `sharp` 替身支持的方法）。
- 文件系统布局：`native/root`、`app/DshIOS/EnginePaths.swift`、`engine/main.mjs` 里的 `HOME`、`TMPDIR`、工作区位置。
- 插件在原生界面和网页版里的可见范围，以及设置里相关入口的名字（`references/plugins.md`，主文件里的摘要也要对得上）。
- 本机能力增减、改名或行为变化（`references/device-capabilities.md`，主文件里列的工具名也要跟着改）。

改完跑 `cd engine && node --test test/ios-environment.test.mjs`：它检查 frontmatter、description 不超过 500 字、「Commands that exist」里列的每个命令都真实存在，以及主文件里提到的子文档和 `references/` 下的文件一一对应。在没有 git 原生插件的机器上（比如 Linux），`git` 会被报成不存在，这一项可以忽略；macOS 上先跑 `scripts/build-git-addon.sh`。

写法上保持现在的风格：英文、短句、先说能不能用再说替代办法；「Commands that exist」之外的命令都会被当成不存在，所以新增命令一定要列进去。

## 回复里的公式

公式先用 SwiftMath 排（同步，`Views/MathFormula.swift`），它排不了的交给 KaTeX（`Views/MathKaTeX.swift`）：带中文的、`\xrightarrow`、公式中间的 `\boxed`、`\overset`、`\underbrace` 等等。网页版所有公式都用 KaTeX，所以原生用同一个版本，排出来和网页版一样。

- KaTeX 在一个不显示的网页里跑（`Math/MathPage.html`），每条公式由 WebKit 画成 PDF 再转成图，按源码和字号缓存。第一次出现时要等一下，这期间显示源码。
- 行内公式按 KaTeX 允许断行的位置（关系符、运算符之后）切成几段图，段间插零宽空格，长公式才能像网页版一样折行。
- 公式图平时按文字颜色染色显示。带自己颜色的（`\color`、`\colorbox`，以及 KaTeX 标红的不支持命令）一律交给 KaTeX，按原色显示，深色模式另画一份；彩色底框里没指定颜色的字，按底色深浅选深色或浅色墨水。
- KaTeX 的文件在 `Math/KaTeX`，由 `scripts/build-katex.sh` 生成并提交。**升级 `@deepseek-ai/dsh` 后看一眼网页版用的 KaTeX 版本**（`dsh-web-frontend/dist/assets/vendor-*.js` 里的 `"0.x.y"`），变了就改脚本里的版本重跑，更新 `THIRD_PARTY_NOTICES.md`，再用 `-dshOpen timeline` 看一遍样例里的公式，iOS 17 也看（字体没加载完时 iOS 17 会漏画字符）。

## 浏览器能力

会话通过 `browser-cli` Skill 和内置 `browser` 命令操作工作台浏览器，其他本机能力通过 `device` 命令调用。原 `browser` 工具有哪些动作、各要什么参数、给模型看的说明，全写在 `app/DshIOS/Browser/BrowserCatalog.swift` 一处：引擎按它生成工具（`describe`），原生层按它放行动作，参数也按它检查。

- 加一个浏览器能力：在 `BrowserCatalog` 里登记动作和参数，在 `BrowserAgent.perform` 里接上实现（多数写在 `BrowserAbilities.swift`）。引擎的 `tools.mjs` 和 `caps_browser.m` 都不用改。
- 返回值里带 `image: {data, mediaType}` 的，引擎会自动存成附件给模型看；会出图的动作在清单里标 `image`，引擎先确认模型能看图再执行。
- 注入网页的脚本（`scripts/page-controller/entry.js`）改了要跑 `scripts/build-page-controller.sh` 重新打包，产物 `PageController.js` 一起提交。
- 新动作在聊天里的显示文字在 `ToolCards.swift` 的 `browserLine`，没写的会直接显示动作名。
- 改完照「内置 skill」一节更新 ios-environment skill。 本机工具的注册和发现流程见 [动作目录](docs/action-catalog.md)。

## Mini Apps（小应用）

用户在对话里让 Agent 做的小工具、小游戏。每个应用是 `~/apps/<id>/` 下的一个文件夹（引擎路径，磁盘上在 `EnginePaths.real("/home/dsh/apps")`），`app.json` 写名字、emoji 图标和颜色，入口是 `App.jsx`（React 组件）或 `index.html`。打开应用不需要引擎。

- **开发版和发布版**：Agent 写的文件是开发版；用户打开的是发布版，即应用文件夹里的 `.build`：所有文件的完整快照，JSX、TS 已经编译好，打开时不编译、不依赖系统会清理的缓存。发布在 Agent 一轮结束（会话列表里不再有运行中的会话）、读应用列表、第一次打开时进行（`MiniAppPublisher.swift`），按文件的路径、大小、修改时间判断是否过期；有 Agent 在跑时，打开的是上一次发布的版本，不会打开改到一半的应用。上一版留在 `.build-previous`。
- **加载**：`app/DshIOS/MiniApps/MiniAppServer.swift` 用自定义协议 `fishapp://<id>/` 提供文件，只给本应用文件夹里的东西；用户那边提供发布版，Agent 浏览器那边提供开发版、返回时用 Sucrase（JavaScriptCore 里跑，没有 JIT，所以只在创作时编译）编译；页面开头注入 import map（`react` 等指向内置的 React）和错误上报脚本。
- **隔离**：每个应用一个独立的 `WKWebsiteDataStore`（按 id 派生），删应用时一起删；能联网，但用内容规则拦掉 localhost、127.x 等本机地址；不开放相机、麦克风等本机能力。
- **入口**：「探索」页「创作」一组的「Mini Apps」（iOS 17 的 iPad 侧边栏是「Mini Apps」一行，点开是弹出页）、聊天里单独一行的 `[名字](fishapp://<id>)` 链接会显示成卡片、`fishpocket://app/<id>` 链接（旧的 `dsh://app/<id>` 也认）、「Mini Apps」小组件（`app/LiveActivity/MiniAppsWidget.swift`）、快捷指令里的「打开 Mini App」（见「快捷指令和 Siri」）。
- **放到主屏幕**：Mini App 和网页版的「添加到主屏幕」只给两种方式（`AddToHomeScreenSheet`）：小组件（「Mini Apps」「网页版」）、快捷指令（「打开 Mini App」「打开网页版」）。两种都直接进 App，不经过网页，但 App 没法替用户建好，只能写明步骤。以后加别的可放到主屏幕的东西，这两种都要有。原来的第三种 Safari 图标（`HomeScreenShortcut`，每次点开都要先加载官网的 `/add-to-home/` 页面）已经从界面上隐藏，代码留着；用户以前加到桌面的这种图标要一直能用，所以官网的 `/add-to-home/` 页面、它跳回 App 的链接（含 `scheme=dsh`）都不能动。
- **叫法**：界面上叫 Mini App。探索页的那一行、页面标题、小组件这类指一整组的地方用复数 Mini Apps，指其中一个时用单数 Mini App（「删除 Mini App」「3 个 Mini App」）。简体、繁体中文都直接写英文，不译成「小工具」「應用」：繁体里「小工具」是系统对小组件的叫法，「应用」又会让人以为是我们提供的 App；其他语言用各自的写法（Miniapps、ミニアプリ、미니 앱）。替用户写好、发给 Agent 的话（「帮我做一个记账小工具」）照口语写，不受这条限制。
- **图标**：默认是 `app.json` 里的 emoji 配底色；文件夹里有 `icon.png`（方形、铺满、不带圆角）时用它。小组件读不到应用文件夹，主 App 写 `mini-apps.json` 时把图标一起拷进 App Group 的 `mini-app-icons/`。示例的图标是 `icon.svg` 画的，改了要重新导出同目录的 `icon.png`（360 像素）。
- **全屏页的顶栏**：iOS 26 起网页一直铺到系统的透明顶栏下面，滚上去的内容由系统虚化（`MiniAppScreen.swift` 的 `PageWebView`）；页面仍从顶栏下方开始排，`100dvh` 是顶栏以下的高度，顶栏后面是页面自己的底色。更早的系统顶栏是实底的，网页不铺上去。
- **示例**：自带的几个示例（`MiniAppExamples`）在页面上单独放在「示例」一节，和用户自己做的分开；哪些是示例记在 UserDefaults 里，不写进应用文件夹。示例只在第一次拷进 `~/apps`，之后改了示例，老用户手里还是旧的：所以重做一个示例时，把它上一版三个源文件的指纹加进 `MiniAppExamples.shipped`，`revision` 加 1，没被改过的旧拷贝会换成新版，用户或 Agent 改过的不动。示例存的数据不会清，新版要读得了旧版存下的格式。小组件和快捷指令读 App Group 里的 `mini-apps.json`，主 App 每次读应用列表时写它。
- **Agent 的浏览器**也能打开 `fishapp://<id>/`，看到的是开发版（现编译、结果放缓存），Agent 用它截图自查；那里的存储是浏览器的，不是用户那份。
- **运行时**：`app/DshIOS/MiniApps/Runtime` 是 `scripts/build-mini-app-runtime.sh` 打出来的 React 18 和 Sucrase，提交进仓库，平时不用跑。升级版本时改脚本里的版本号重跑，并更新 `THIRD_PARTY_NOTICES.md`。
- **skill**：`engine/skills/mini-apps/SKILL.md` 告诉 Agent 格式和限制，`scripts/check.mjs` 是给 Agent 自查用的检查脚本（`engine/test/mini-apps.test.mjs` 测它）。改了内置的库、能用的能力、文件格式或入口，同一个提交里更新这份 skill。

## 手表 App

手表 App 内嵌在 iPhone App 里一起安装，引擎不在手表上。手机通过 WatchConnectivity 把会话状态发给手表，手表只负责显示、震动提醒，以及把「允许 / 拒绝」发回手机。

- `app/WatchShared`：手机和手表共用的数据（`WatchSnapshot`、`WatchCommand`），两个 target 都编译它。改这里等于改两端的协议。
- `app/DshIOS/WatchLink.swift`：手机端。状态变了就发给手表，并执行手表发回的指令。
- `app/Watch`：手表端的界面、素材和文案。

### 文案

手表的文案在 `app/Watch/Localizable.xcstrings`，`scripts/sync-strings.sh` 不管它，要手动加词条并补上 `en`、`es`、`ja`、`ko`、`zh-Hant`。每个词条的 `zh-Hans` 也要写出来并标成 `translated`，否则中文用户会看到英文。加完跑 `node scripts/strings-coverage.mjs` 确认全覆盖。

### 本地看效果

- 只看界面：单独编译 `DshWatch` scheme，用 Debug 版的启动参数 `-dshWatchDemo waiting`（还有 `question`、`running`、`done`、`many`、`idle`、`unknown`、`offline`）显示一份固定的演示数据，不需要手机。
- 手表模拟器如果和某台 iPhone 模拟器配了对，而那台 iPhone 上没装主 App，系统会把手表 App 卸掉。所以要么装到没配对的手表模拟器上，要么先把主 App 装到配对的 iPhone 模拟器上。
- 联调：两台配对的模拟器都开着，`scripts/run-sim.sh` 把主 App 装到 iPhone 上，手表 App 会跟着装过去。

### 注意

- 构建主 App 时不要给 `xcodebuild` 传 `-sdk iphonesimulator`：它会让内嵌的手表 App 也按 iOS 的 SDK 编译，直接失败。用 `-destination` 选平台就够了。
- 手表 App 的 bundle ID 必须以主 App 的 bundle ID 开头，`WKCompanionAppBundleIdentifier` 要和主 App 的一致，改主 App 的 bundle ID 时一起改。

## 快捷指令和 Siri

App 给系统提供五个操作：新对话、打开 Bot、打开 Mini App、打开网页版、查看余额。用户装好 App 就能在「快捷指令」里看到，也能对 Siri 说，不用设置。

- 操作在 `app/DshIOS/ShortcutIntents.swift`，「新对话」「打开 Mini App」「打开网页版」在 `app/Shared`（小组件和控制中心也用）。「打开 Mini App」「打开网页版」也是把它们放到主屏幕、点开不经过网页的办法之一（见 Mini Apps 一节的「放到主屏幕」）。Siri 说法和「快捷指令」首页的格子在 `app/DshIOS/AppShortcuts.swift`，说法的译文在 `app/DshIOS/AppShortcuts.xcstrings`，`scripts/sync-strings.sh` 不管它，要手动补齐各语言；每句说法都必须带上 App 名。
- Bot 和 Mini App 的列表来自 App Group 里 App 写好的文件（`Share/targets.json`、`mini-apps.json`），系统读它们不需要引擎。列表变了要调 `DshShortcuts.updateAppShortcutParameters()`，Siri 才认得新名字。
- 「打开 Bot」「打开 Mini App」的参数必须是必填。改成选填后，系统在「快捷指令」首页就不再按 Bot、按 Mini App 展开格子。
- iOS 26 及以前，新建自动化时那排 App 格子只列基础操作，选不了具体是哪个 Bot，所以要走「新建空白自动化」（iOS 26 叫「创建新快捷指令」）再搜「Bot」：iOS 18 起搜索结果直接列出每个 Bot，iOS 17 只有「打开 Bot」，加上后再点参数选。iOS 27 起自动化并进了普通快捷指令：先点「自动化」设触发条件，再搜「Bot」点选，返回即保存。这些步骤写在探索页的「快捷指令」教程里（`ShortcutsGuidePage`），按系统版本各一套。系统改了这套界面，或者新增、改名了操作，就去 iOS 17、18、26、27 的模拟器上照着走一遍，再改教程。
- 模拟器上定时自动化不会真的触发，「到点打开」只能在真机上验证。

## 系统分享（分享扩展）

别的 App 点「分享」选 Fish Pocket，内容进新对话、某个 Bot 或群聊的输入框，不自动发送。扩展是 `app/ShareExtension`（target `DshShare`），引擎不在扩展里，扩展什么都不发。

- 扩展一打开就把文字、链接、图片、文件拷进 App Group 的 `Share/inbox/<id>/`；用户选好去处后写下 `delivery.json`，再打开 `fishpocket://share/<id>`。App 收到后把文件挪进自己的临时目录，交给对应会话的输入框（`Shared/ShareInbox.swift`、`MainView.receive`）。
- 系统没让扩展拉起 App 时，内容留在收件箱里，App 下次回到前台会自己取走；超过半小时没取的直接清掉。
- 扩展里列的 Bot 和群聊来自 App 写的 `Share/targets.json` 和 `Share/avatars/`（`ShareTargetsWriter`）：和 Bot 页一样混在一个列表里、顺序相同（`order`），隐藏的不列，头像是 App 按自己的画法渲染好的图，群头像深浅色各一张。扩展不编译 `BotCharacter`，改了头像画法不用动扩展。
- 扩展的文案在 `app/Shared/Localizable.xcstrings`，`scripts/sync-strings.sh` 会一起收进来。扩展不认 `NSAccentColorName`，主色在 `ShareView` 里显式指定。
- 发行签名多了一个 bundle ID：`com.wsw.dsh-ios.Share`，要有 App Group。
- 拉起 App 的链接前缀是工程变量 `DSH_URL_SCHEME`（正式版 `fishpocket`），App 生成的链接都用它。用别的 Bundle ID 并排装测试包时，`DSH_APP_GROUP` 和它都要换成测试包自己的，不然链接可能打开正式包，正式包读不到测试包的 App Group。

## 链接前缀：`fishpocket`，`dsh` 只作兼容

App 的链接前缀是 `fishpocket://`（`DSH_URL_SCHEME`）。早先用的 `dsh://` 太通用，可能和别的 App（比如 DeepSeek 官方的 DSH App）撞上，几个 App 注册同一个前缀时 iOS 打开哪一个是不确定的，所以换成了独占的前缀。路由都在 `app/Shared/DshLink.swift`：`session`、`new`、`share`、`app`、`web`、`bot`、`balance`。

- **`dsh` 永久保留，只用来兼容。**它写在 `DSH_LEGACY_URL_SCHEME`，主 App 同时注册两个前缀，`DshLink(url:)` 两个都认，`handlesExternalEvents` 两个都交给已开的窗口。用户桌面上已有的网页版和 Mini App 图标网址里写死了 `scheme=dsh`，快捷指令、NFC 自动化、旧聊天记录里也可能有 `dsh://`，所以不能删。
- **新生成的链接一律用 `fishpocket`**（`DshLink.scheme`）：小组件、灵动岛、分享扩展、主屏幕图标（官网 `/add-to-home/` 的 `scheme=`）、iCTRL 回调、引擎拿到的 `FISH_POCKET_URL_SCHEME`。不要在代码、skill 或文案里新写 `dsh://`。
- **并排装的测试包把 `DSH_LEGACY_URL_SCHEME` 设成空**，否则它也注册 `dsh`，会抢走正式包的旧链接。空值时 `CFBundleURLSchemes` 里留下一个空字符串，系统不当成前缀，`DshLink` 也会跳过它。
- 官网 `/add-to-home/` 页面按 `scheme=` 跳回 App，它对前缀的校验要同时认 `fishpocket`、`dsh` 和测试包的前缀。

## Bot：只用 DS Bot 的后端

Bot 功能的后台是内置的 ds-bot 插件，版本锁定在 `engine/plugins/ios-host/pins.json`。

- 只调用它的接口（`/api/bot`、`/api/bot/feed`），不使用、不移植它的前端代码（`client.js` 和它的界面组件）。
- 它网页版的设计只作参考借鉴。原生界面要自己设计，交互做得比它更好，不照搬它的布局和流程。
- ds-bot 网页版能做的事，都要用原生界面做。网页版入口可以保留，但只作为次要的备用入口，不能让用户依赖它完成主要操作。
- 群聊每一轮的回复不在 `group_relay` 的工具结果里：0.3.8 起结果只给出这一轮在群聊账本里的位置（`{from, anchor}`），回复用 `group-rows` 读（`BotModel.loadRows`），群自己的会话这一轮随即结束，成员是否还在干活看 `group-rows` 返回的 `active`。升级前的轮次结果里仍带着 `replies`，两种都要认。
- 它的 peer 依赖全是 `*`，而 npm 上 `@deepseek-ai/dsh-llm`、`dsh-scope`、`dsh-tools`、`dsh-web`、`dsh-typert-protocol` 的 `latest` 标签还停在 `0.0.1-rc.x` 占位版。所以 `engine/package.json` 用 `overrides` 把它们钉成引擎自己的 DSH 版本；升级 `@deepseek-ai/dsh` 时这几行要一起改，否则会装出一棵顶层是占位版的树。

## 生图：内置 dsh-image-gen

生图功能的后台是内置的第三方插件 dsh-image-gen，和 ds-bot 一样锁在 `engine/plugins/ios-host/pins.json`（`builtin`）、首次启动自动开启。打包时它的 README 截图和文档被裁掉，网页版的画布、图库、Studio 用的是它自己的界面。

- **只用它的后端。**设置读写 `image-gen` 命名空间，Key 走凭据；测试连接、拉取模型、订阅登录走它的 `/plugins/dsh-image-gen/` 路由（`ImageGenModel`）。原生设置页（`ImageGenSettings.swift`）逐项对应它网页版设置卡片里的字段，升级插件时对照它 `src/client/index.tsx` 的 `ImageGenerationSettingsCard` 增删字段；保存前的几项校验（尺寸表、附加 JSON、OpenAI 尺寸、ComfyUI 工作流、官方接口的自动编辑格式）是照它的前端写的，也要一起对。
- **订阅登录**用它在本机固定端口起的回调（ChatGPT 1455、Grok 56121、Google 51121），授权页在 App 内的 Safari 里打开，引擎一直在跑才接得到跳回，和连接器的登录是同一套。
- **给模型的说明只放模型不可能知道的事**（`image-gen-notes.mjs`）：画布没打开时去掉插件那句「让用户去开工作台」，并在插件的生图说明后补一句 App 里生图设置的位置。不要往里加「该用哪张图」之类的指令，选图交给插件自己的规则和模型。`test/image-gen-notes.test.mjs` 会检查插件的上下文名和措辞，升级后它报错就先看插件现在说了什么。
- **用 Fish Pocket 积分生图**（`Models/FishPocketImageGen.swift`）：只卖火山方舟的 Seedream 一个模型。插件自带的 Seedream 服务商把 Key 存在 `ARK_API_KEY`，和用户自己的方舟 Key 共用，所以 Fish Pocket 是插件的一个 OpenAI 兼容渠道（id `fishpocket`，Key 存在它自己的 `DSH_IMAGE_GEN_OPENAI_COMPAT_KEY_FISHPOCKET`），地址是 Fish Pocket 服务的 `/v1`，改图用 `jsonImageUrlArray` 格式，尺寸表按 Seedream 的像素范围填好，生成和改图都要 JPEG（`output_format`）：Seedream 默认出 PNG，存进 App 时会被重新编码成 JPEG，火山写在文件里的隐式标识（C2PA）就丢了；直接要 JPEG 才原样保存，也小得多。渠道和 Key 都由 App 写、由 App 同步（运行时密钥换了、退出登录、引擎连上时），设置页的渠道列表里不显示它，在生图设置的「默认使用」和单独的「Fish Pocket 账号」页里选。只有用户选了才建，选了也不替用户切回别家。服务端强制加「AI生成」水印、只出单张图，换模型、改价格都在服务端，不用发版。
- **对话里的图**：生图结果由 `ImageGenCard` 显示，一轮折叠后图片仍留在外面；对话里任何一张图点开都有「标注」（`MarkupCanvas`），画完只把标注版放进输入框。
- 升级插件后照「引擎或插件升级后的回归」走一遍，另外在设置页把每家服务商点开看一眼，再用一个真实或本机假的 OpenAI 兼容服务各生一张、改一张。

## Bot 的内置形象

Bot 没有照片时显示的角色是 App 自己画的，形状和动作都写在 `app/DshIOS/Views/BotCharacter.swift` 里，不取自 ds-bot 的网页版。

- **形状名沿用后端的**：`BotCharacter.all` 里每个角色的 `id` 是 ds-bot 存在 Bot 上的形状名（`avatar.shape`，如 `star`、`kitty`）。后端新增了形状名，就在这里补画一个同名的；没画的名字会按 Bot 的 id 从 `friendly` 里挑一个顶上。同一个形状名在 App 和网页版里画法不同，这是有意的。
- **加一个形状**：用 `Draw` 里的积木（圆、圆角矩形、圆角多边形、平滑曲线，`join` 合并、`subtracting` 挖洞）在 100×100 的格子里拼出轮廓，再给出两眼的位置和大小。眼睛要整个落在轮廓里。
- **动作**：`Pose.make` 按状态（思考、搜索、干活、交接、等待、有事找用户）算出当下的姿态。改动作只改这里。
- 只有传了 `live: true` 的头像会动（列表、标题栏、详情页、聊天尾部的状态行）；聊天记录里的头像保持静止，免得长对话同时跑几十个动画。系统开了「减弱动态效果」时全部静止。

## 语音通话

会话和 Bot 一对一聊天里，输入框空着时右边的波形按钮发起通话（群聊、子智能体没有）。识别用火山流式识别 2.0，回答的声音用火山双向流式合成 2.0，和按住说话、语音消息共用同一种火山接入方式；声音不经过引擎。代码在 `app/DshIOS/Call`。

- **两种接入方式，用户自己选，不自动切换**（设置里的「接入方式」，`VolcSpeech.route`）：自己的火山 API Key，声音直接在手机和火山之间走；或者 Fish Pocket 账号，连 Fish Pocket 服务器的语音中转（`/v1/speech/recognition`、`/v1/speech/synthesis`，带运行时密钥），由服务器换上自己的火山 Key 转发，按用量扣积分。火山只有长期有效的 API Key，没有给客户端用的临时凭证，所以只能中转。中转原样转发火山的帧，握手之后两种方式的协议完全一样，差别都在 `VolcCredential`（`Models/VolcSpeech.swift`）：握手地址和头、握手被拒（中转的 401、402、429、503）和中途关闭码（4402 余额用完）怎么说给用户。不要按登录状态或有没有 Key 替用户选，一条失败了也不换另一条重试。
- **音频走 Ogg Opus**（`Models/OggOpus.swift`，系统的 Opus 编解码，Ogg 封装自己写）：识别上行 16 kHz、约 24 kbps，首包 `"format": "ogg"`；合成下行要 `ogg_opus`（只有 48 kHz，码率 64 kbps），App 解码成 24 kHz PCM 再交给播放和回声消除，对外的 `.audio` 事件仍是 PCM。字节数只有 PCM 的十分之一到四分之一，中转服务器的带宽靠这个撑。每条连接一个编码器（重连后先发头页），合成的每个会话一个解码器。

- **判断交给火山，不加规则**：一句话说没说完是火山识别的分句（`definite`），附和、打断也只看火山认出了什么字（单独一个「嗯」它不出字）。不加附和词表、打断词表，也不在 App 里跑判停模型；火山以后升级了直接受益。火山的判停只看静音时长，不懂语义，半句停久了会被切开，这是已知限制。
- **一轮怎么走**（`VoiceCall`）：火山认定一句说完，就像输入框发消息一样发进对话；回答的文字一边流出来一边喂给合成（`SessionModel.callListener`），火山自己切句、边合成边返回；用户开口（火山认出了字）就停掉播放、取消合成和这一轮，新的话作为下一条消息。只念回答正文，工具调用和思考不念。
- **告诉模型这是通话**：引擎插件 `engine/plugins/ios-call` 给通话中的会话每轮第一步加一条隐藏的提示（简短口语、不出 Markdown、别调 `speak`），和时间上下文一样是单独来源的消息，时间线不显示。App 每 30 秒续一次，90 秒没续就失效，App 崩了也不会让以后的回合以为还在通话。
- **声音**（`CallAudio`）：一个音频引擎同时收音和放音，她说话时麦克风一直开着，回声由 App 自己的回声消除去掉（见下一条）。通话期间后台照常（`audio` 后台模式），`BackgroundKeeper` 的静音音频让开；朗读和按住说话在通话中不可用。
- **开始时像打电话，之后和别的 App 混放**（`CallAudio.configureSession`）：先用不混放的会话激活，正在放的音乐、视频随之停下（不然它们进麦克风，回声消除只认得她自己的声音，会被识别成用户在说话），激活后再把会话改成 `.mixWithOthers`，这样通话中用户自己去别的 App 放视频、音乐，两边一起出声，不会把通话打断（#317）。挂断时 `notifyOthersOnDeactivation`，开头停下的音乐会接着放。通话中外放别的 App 的声音仍会进麦克风、可能打断她，这是用户自己选的，戴耳机就没事。电话、FaceTime、Siri、闹钟这类仍会打断：通话先暂停，提示「通话被系统暂停，结束后自动继续」；打断结束时系统给了 `shouldResume` 才重新接上音频，没给（用户转去放别的了）或接不上就照旧挂断。暂停期间「没人说话自动挂断」照常计时，暂停太久（比如接了个长电话）照样会挂。
- **界面**：跟 App 的设计语言走（单色加一种朱红 `Palette.spot`，跟随 App 的浅色 / 深色）。中间偏上是大头像（Bot 是它自己的形象，普通会话是 App 的形象），两个人的声音和「在想」都由它周围一圈短刻度表现（`CallDial`）：安静时是一圈淡淡的细点，她说话时刻度变朱红、按声音长短不一地伸出去，用户说话时是墨色、幅度小一些，在想时刻度不动、一束亮光绕圈扫过，接通中刻度从顶端一格格亮起。以前的朱红模糊光晕用户嫌丑，换掉了，别再用模糊光晕。头像本身只有 Bot 选了内置画的形象时才会呼吸、跟着她说话起伏；照片（用户上传的图、内置的大肥鱼）一动不动，用户嫌照片弹来弹去难看；下面是名字和状态，底部三个圆按钮，有事要用户处理时按钮上方出一张卡片。没有声线和字幕：这两样都试过，用户嫌丑、嫌乱，去掉了，以后别加回来。通话页是独立的窗口，盖在所有弹窗之上；最小化后是可拖动的悬浮小头像（`CallBubbleWindow`），不挤占页面布局。
- **没人说话自动挂断**：火山识别按上传的音频时长计费（流式识别 2.0 后付费 1 元/小时），通话开着就一直在计费，忘了挂会计一整晚。所以「在听」（她不在想、不在说）的状态下，火山连续 3 分钟没认出用户说的字，她就念一句固定的「还在吗？没声音的话我先挂了」（直接走合成，不发给模型），按钮上方出现「没听到声音，30 秒后挂断 · 继续通话」；这 30 秒里用户一开口、点「继续通话」或点静音、扬声器，就接着聊，否则挂断，结束页和提示条写明原因（`VoiceCall` 的 `checkIdle`）。她在想或在说时不计时，长任务不会被挂断。Debug 版用 `-dshCallIdle 10` 把 3 分钟改成 10 秒来试。
- **灵动岛和锁屏**：通话期间有自己的实时活动（`Shared/CallActivity.swift`、`LiveActivity/CallLiveActivity.swift`），显示状态和时长，带静音、结束按钮（`LiveActivityIntent`，在 App 进程里执行）。会话运行的实时活动在通话期间让开。
- **回声**：用 WebRTC 的回声消除 AEC3（`CallEchoCanceller`，源码在 `native/aec3`，由 `scripts/vendor-aec3.sh` 从官方发布包挑出，App 自己编译），不用系统的通话音频处理：会话模式是 `.default`，不开 voice processing，拿原始麦克风。处理后的声音才送火山识别，用户音量也按它算。不按文字比对丢回声，不在她说话时静音或停麦（这些是工程补丁，用户明确不要）。
  - **参照和对齐照作者的小程序做法**：回答不交给系统播放器，由 `CallSpeaker` 按自己的时钟（已渲染的样本数）放：每 20 ms 把下一段（最多半秒）放到时钟上，最多提前半秒，同一段样本连同位置登记给消除器作参照；还没放上去的留在 `CallAudio` 里，打断时直接丢，已放的从当前位置截掉。麦克风每到一批就读一次时钟，最后一帧对齐读数，往前每帧早 10 ms，处理每帧前把参照喂到它那一刻。两路声音都不裁不补，延迟由 AEC3 自己找。消除器内核 48 kHz，参照 24 kHz、麦克风 16 kHz 在里面重采样。每通电话建一个，跨轮保留学到的回声路径。
  - **不要按每块音频的时间戳去拼参照或麦克风**：时间戳有十几毫秒的抖动，按它补零、裁剪会让两路内容前后错位，AEC3 每次重新估延迟都会清掉学到的回声路径，几乎消不掉（实测只消 4～9 dB）。从引擎总混音取参照也不行，iPhone 上拿到的是静音。
  - **为什么不用系统的**：外放时系统的回声消除（`.voiceChat`、`.videoChat`）每通电话开头 1～3 秒没适应，回声被认成用户的话、把她打断；放音渐强、垫舒适噪声都试过，挡不住或沙沙声明显，已撤掉。作者的另一个同样链路（火山连续识别 + 双向合成）的项目在 iPhone 上试了 8 种系统配置都漏，最后关掉系统处理、自己跑 AEC3 才解决，这里照它做。自动增益也是系统处理的一部分，会把残留回声放大到能认出字。
  - **回声路径一变就漏，靠两项配置压住**：手机被拿起、放下，或者手挡住扬声器，回声路径就变了，滤波器要一两秒才跟上。这期间对不上的回声在 AEC3 看来和有人说话一样，默认配置会判成用户在说话、放开低频，她的话漏给识别，把自己打断。`native/aec3/dsh_aec3.cc` 改了两项：判断「用户更响」时按有把握的残余回声算（`use_unbounded_echo_spectrum = false`），判成用户在说话后也不放宽低频门限（`nearend_tuning = normal_tuning`）。代价在用户压着她说话的时候：真机上比回声小 9 dB 以上的插话仍然打断得了她，但认出来的字可能有出入，音量开得越大越明显。更保守的两种（完全不信线性滤波器 `erle.max_l = 1`，或只用抑制器 `use_linear_filter = false`）漏得更少，但比回声小声的插话会被认错或吞掉，没有采用。
  - **离线验证**：按上面的时序模拟（播放 20 ms 一拍、麦克风 100 ms 一批、送达抖动 30～60 ms、回声比参照响），AEC3 学会回声路径后能压 50 dB 以上，跨停顿保留；每通电话的第一段里，它第一次修正延迟估计时会清掉一次滤波器，那 200～300 ms 压得少。真机效果以用户自己打电话为准。
  - Debug 版把每通电话前 90 秒喂给消除器的东西存在文档目录的 `call-echo/`：参照（`-speaker.pcm`，24 kHz）、原始麦克风（`-microphone.pcm`，16 kHz）、每个麦克风帧之前喂了几帧参照（`-steps.bin`），可以在 Mac 上原样重放。改消除器的配置前先这样比：把 `native/aec3` 按 macOS 编译，照 `-steps.bin` 的顺序喂参照和麦克风，看她说话时输出里和参照相干的部分还剩多少，再把输出送火山识别，确认没有她的字、用户的插话还认得出。
  - Debug 版把每一步写进 App 文档目录的 `call-diagnostics.log`（`CallDiagnostics`）：音频模式、麦克风格式、输出延迟、她说话期间每秒麦克风在消除前后的音量（`echo canceller: …`）、她每段放音时（处理后）麦克风的音量、每次认出字时离她开口多久。用 `devicectl device copy from --domain-type appDataContainer` 取，不用启动 App。真机上不注入测试消息：回声在用户自己通话时测，测完取这份日志看。
- **Fish Pocket 线路在模拟器里测**：App 用 `FISH_POCKET_API_URL=https://localhost:<端口>` 构建，连本机起的 Fish Pocket 服务，模拟器要信任它的测试证书（`simctl keychain <UDID> add-root-cert`）；语音由 App 自己连，不经过引擎，所以只看语音时不用给引擎配证书。
- **在模拟器里测**（Debug 版）：`SIMCTL_CHILD_DSH_CALL_AUDIO=<16 kHz 单声道 WAV>` 让通话听这个文件而不是麦克风；`-dshOpen call` 在打开的会话上直接接通（配合 `-dsh.lastPlace bot:<Bot id>` 打开 Bot），`-dshOpen callscreen` 只看通话页。测试语音用 `say -v Tingting` 加 `afconvert -f WAVE -d LEI16@16000 -c 1` 生成，日志里 `[call]` 开头的行是每一步。真机才能测回声消除和真人说话。模拟器的音频服务有时会卡在第一次取麦克风节点（`engine.inputNode`），几秒后报 `Cleanup: RPC timeout. Apparently deadlocked` 退出，和代码无关；重启模拟器不一定好，这时换一台或直接上真机。

## 语音消息

AI 可以像微信那样回一条语音：对话里是一个语音气泡，点了才念。引擎不出声音，插件 `engine/plugins/ios-voice-message` 只提供 `send_voice_message` 工具（参数是要念的文字，发完这一轮就结束）；App 把这个工具调用画成气泡（`VoiceMessageBubble`），点的时候合成、播放（`Models/VoiceMessages.swift`）。

- **在哪能发由用户定，什么时候发由 AI 定**：设置 → 语音消息，会话和 Bot 聊天各一个开关，Bot 默认开、会话默认关（会话里多是干活）。下面那段「什么时候发」是给 AI 的规则，用户可以改，默认写的是闲聊时偶尔发、干活不发、用户要就发。App 连上引擎、开关或规则变了、Bot 列表变了、合成服务变了时，把这些发给插件，插件存在 `$DSH_IOS_DATA/voice-message.json`，引擎重启后照旧。不允许的地方工具根本不出现，模型看不到。
- **永远不发的地方**：群聊（成员的话从 ds-bot 的群聊账本读，工具调用不在里面）、子智能体、语音通话中、IM 渠道（微信、Telegram 等）发来的消息开的那一轮（ds-bot 只往回转文字），以及没有可用合成服务时。
- **合成只用一家**：火山接好了（自己的 Key，或选了用 Fish Pocket 账号接入并已登录）就用火山（和语音通话同一个声音），没有才用 DeepSeek（和朗读同一个声音）。一家失败就报错，不换另一家重念：同一个对话里声音突然变了很割裂。
- **声音跟着 Bot 和会话走**：用的是这个 Bot 或会话在「声音」页里单独选的通话声音（火山）或朗读声音（DeepSeek），没选才用全局的（`VoiceChoices`）。缓存按声音区分，改了声音会重新合成。
- **边合成边播**：第一次点时一边合成一边播放，播完存成缓存里的 WAV，再点立刻播；秒数在合成完之前按字数估。试过「语音到达时先合成好再出气泡」，等得太久，用户不要。
- **未读**：没播过的气泡旁边有红点。播过的记录存在 Application Support 的 `voice-messages-played.json`，不写 UserDefaults（写它会让整个界面重算）。
- **朗读工具已删掉**：原来本机能力里有 `speak`（让 Agent 直接念一段话），和语音消息重叠，用户说「发条语音」时模型常选错，所以拿掉了。不要再加回来。
- 本地看效果：`-dshOpen timeline` 的样例里有两条语音消息。

## 朗读

回复下面的「朗读」（会话、Bot、群聊里的每条发言，以及 Bot 的自动朗读）由 `ReadAloud`（`Models/DeepSeekSpeech.swift`）按顺序念，换到别的对话就停。

- **用哪家由用户在「设置 → 朗读」里选**（`VoicePreferences.readingSource`），默认 DeepSeek，不按有没有火山的 Key 或登没登录替用户切换，一家失败也不换另一家重念。
- **DeepSeek**：自己的两个声音，走引擎的 `/api/ios-speech/tts`，长回复按段切成几次请求。
- **火山引擎**：豆包语音合成模型 2.0（`CallSynthesizer`，和通话、语音消息同一套），接入方式（自己的 Key 或 Fish Pocket 账号）和语音通话共用 `VolcSpeech.route`。声音就是通话的声音：设置页里列的是通话的音色，改了通话、语音消息跟着变；Bot 和会话单独选的声音也用「通话」那一栏（`SynthesisVoice.reading`），这时「声音」页把两栏合成「通话和朗读」。整段回复在一个合成会话里，一句一句喂进去。
- 选了火山但接入方式没设置好时，点朗读直接提示去「设置 → 朗读」，不偷偷改用 DeepSeek。

## 首页布局：系统的自适应 Tab

iOS 18 起，iPhone、iPhone Duo、iPad 共用一套系统 `TabView`，样式是 `sidebarAdaptable`（`MainView.tabLayout`）：「会话 · Bot · 探索」三个 Tab，设置和 Mini Apps 都是探索页的一页，从页面最上面的「通用」「创作」两组进入（`SettingsView(pushed: true)`、`MiniAppsPage`），窄屏在底部，宽屏由系统放到顶部或换成侧边栏，Duo 展开时是右侧的竖条。宽窄切换（Duo 开合、iPad 拖窗口）不换布局，Tab 保持不变。iOS 17 的 iPhone 用同样三个 Tab，只是换成旧写法（`TabView` 加 `.tabItem`，`MainView.phoneTabLayout`），Tab 栏始终在底部，页面和行为与 iOS 18 起的一致。iOS 17 的 iPad 仍是旧布局：常驻侧边栏，窄窗口是抽屉（`DrawerView` 的 `sidebar` 样式，`MainView.split` / `drawerLayout`）；旧写法的 Tab 栏在 iPad 上也只能放底部，所以没改。iPhone Duo 只有 iOS 27，不涉及旧版本。

- **iPhone 只支持竖屏**（`app/project.yml` 的 `UISupportedInterfaceOrientations`，iPad 四个方向照旧）。大屏 iPhone 横屏时会话 Tab 是分栏，会话页旁边的工作台在 iOS 26 起用的是系统的 inspector；切到别的 Tab 再转回竖屏，后台那个 inspector 在系统的转屏动画里被重排，App 闪退（`UISplitViewController internal inconsistency: unexpected column dimension for resizing`，栈里没有我们的代码）。横屏用得少，所以直接不支持。Duo 展开时系统不理会方向锁，照样会转，走长一点的路径（开过工作台、切过 Bot Tab、回过主屏）再转屏同样闪退，所以 Duo 上完全不用 inspector，工作台在会话旁边自己占一栏（`WorkbenchBeside` 的 `inspector`，和 iOS 26 以前的 iPad 同一套）。iPad 转屏、拖窄窗口按同样的长路径实测不会触发。不要再把 iPhone 横屏打开，要开先解决这个闪退。
- **会话 Tab**：窄屏是列表，点开会话推入新页面；宽屏是列表和会话并排的分栏（`sessionsSplit`），没有选中时自动开一个空白会话，和旧分栏一样。这层分栏照旧分栏的规矩：列宽固定、从 27.1 起保留系统侧栏按钮（`systemSidebarButton`，否则 Duo 会卡死）、Duo 半开时避开折痕（`PastTheFold`）。
- **新增一个全局入口**（像插件、连接器、操控手机、远程控制、网页版这类），要同时加到 `ExploreTabView` 和 `DrawerView` 侧边栏的那几行里：后者是 iOS 17 上 iPad 的入口，漏了 iOS 17 的 iPad 用户就找不到。
- **文案和给模型的说明里写入口位置时**，写成「探索 → …（iOS 17 的 iPad 上在侧边栏）」。原生拒绝消息（`native/ios-native`）和 ios-environment skill 里用的是英文 "the app's Explore tab (in the sidebar on an iPad before iOS 18)"。
- **iPhone Duo 开合时 Tab 界面按尺寸重建**（`tabLayout` 上的 `.id(ThisDevice.isDuo ? sizeClass : nil)`）。Duo 展开后，右侧那一列同时放 Tab 栏和导航栏按钮，系统只在 Tab 界面创建时安排这一列：合着启动、再展开，会话一侧的新会话和工作台按钮会丢。重建不丢状态，因为 Tab、各 Tab 的导航路径和当前会话都存在外层。
- **iPadOS 18 的顶部 Tab 栏会盖住分栏的导航栏**：全宽页面系统会自己把标题挪到第二行，分栏（会话 Tab 的列表和对话）不会，标题、模型选择器、左上角按钮都被挡住。所以 iOS 18–25 的 iPad 上，Tab 栏浮在顶部时会话和 Bot 的分栏整体下移一行（`MainView` 的 `BelowFloatingTabBar`，改的是 UIKit 分栏控制器的安全区，SwiftUI 的 inset、padding 挪不动这层导航栏），切成侧边栏时再收回。iOS 26 起系统自己处理。以后在 Tab 里再放分栏，也要套上它。
- **iPadOS 27 给分栏让出顶部 Tab 栏有两种摆法，要固定成一种。**某个 Tab 第一次显示时，系统把整个分栏放在 Tab 栏下面；切走再切回来，改成分栏顶到 Tab 栏底下、两栏的导航栏各自下移。前一种会零碎地变成后一种：收起左侧列表、弹出带键盘的表单之后，两栏的标题行先各自下移一行，分栏却还停在 Tab 栏下面，于是标题行整体低一行，要切一次 Tab 才恢复。`BelowFloatingTabBar` 在 iOS 27 上发现页面处在前一种时，让它重算一次安全区，直接进入后一种（`SplitBelowTabBar.settle`）。iPadOS 26.4 上没有这个现象，所以只在 iOS 27 起这样做。
- **iPadOS 26 起，竖屏把 Tab 栏展开成侧边栏再收回后，分栏两栏的导航栏会留在 Tab 栏下面。**竖屏时侧边栏是盖在页面上的浮层，收回后系统没有再把两栏的导航栏往下挪：标题、模型选择器、左上角按钮被 Tab 栏盖住，切 Tab 不恢复，要把左侧列表收起再展开才好（iPadOS 26.4 和 27.2 都有）。在这个侧边栏里点选一个还没显示过的 Tab，它一出来也是这样。横屏时侧边栏是并排的第三栏，没有这个问题。`BelowFloatingTabBar` 发现自己所在的那一栏处在这种状态时（Tab 栏浮在顶部，它的高度既不在页面的安全区里，也不在这一栏的安全区里），让页面重算一次安全区（`SplitBelowTabBar` 的 `uncover`）。侧边栏还在收回的途中重算不起作用，所以隔一小会儿再试，连续无效到一定次数就停。
- **会话页交给整个窗口的东西，不能每次重算都是新的。**iPadOS 18 和 26 上，分栏右侧的会话页只要重设一次这类东西，从左侧列表弹出的表单（新建 Bot、团队设置等）就会被整个重建：填的内容清空、键盘收回。键盘弹出本身就会让会话页重算一次，所以表单里的输入框根本点不进去；回复流式输出时也一样。已知两类：`focusedSceneValue` 发布的菜单命令（`WindowCommands`、`WorkbenchCommands`，闭包放进固定的盒子，只在真正影响菜单的值变化时才算变）；并排工作台用的 `.inspector`（`WorkbenchBeside` 只接收稳定的状态，自己构建页面，不接收会话页每次新建的闭包）。`@AppStorage` 的绑定不算稳定的状态：会话页每重算一次它就是新的，`UserDefaults` 里随便哪个键一写，用到它的页面也跟着重算。工作台的标签原先就是这样传进 `.inspector` 的，于是任意一轮回复结束时（那一刻会往 `UserDefaults` 记一次轮数），不在前台的会话 Tab 里那个会话页重设了工作台，Bot Tab 上新开的表单被重建；现在它是会话页自己的 `@State`，手动读写 `UserDefaults`（`WorkbenchTab.last`）。以后给会话页加 `focusedSceneValue`、`.inspector` 这类修饰时照此处理，并在 iPadOS 18 和 26 上验证：先到会话 Tab 打开一个会话，再到 Bot Tab 选中一个聊天，打开「新建 Bot」，在名字框里打字，然后让任意会话回复完一轮，字还在。
- **iOS 18 的 iPhone 上，深浅色切换后 Tab 栏的按钮和背景不跟着变。**Tab 栏自己换成了新外观，它的子视图却还是旧的（调试器里看到的，没人给它们设覆盖）：从深色切回浅色，没选中的图标是深色模式的灰、几乎看不见，角标是深色模式的红，有列表滚到下面时（探索页）整条 Tab 栏是深色底；切 Tab 不恢复，只有重启 App 才好。`TabBarAppearanceFollower` 在每次深浅色变化后检查，子视图和 Tab 栏不一致就把 Tab 栏的外观设成另一种再改回来，逼 UIKit 重新下发，中间不绘制。iOS 26 起和 iPad 上没有这个问题，iOS 17 不用 `Tab`。改 Tab 栏时在 iOS 18 的 iPhone 上切一次深→浅确认。
- **导航栈外面的环境值不要跟着它的路径变。**探索页原来按路径给整个栈设设置页的样式（`systemLists`），推入设置的同一次更新里样式也变了：iOS 17、18 上从别的 Tab 刚切回探索页时，点齿轮会把设置页推两次。现在先换样式、下一轮再推入，回到根页后再换回（`ExploreTabView.settingsLook`）。下级页的样式只能从栈上拿，挂在目的页上传不到它推出的页面。
- **iPadOS 18 上 Tab 栏展开成侧边栏时会盖住分栏左侧的列表**（系统不给分栏让位置；iPadOS 26 起是三栏并排）。这时会话页左上角的列表按钮改为把侧边栏收回 Tab 栏（`TabSidebar.foldOffList`），列表就露出来了。
- **分栏左侧的列表不用系统的选中（`List(selection:)`）。**列表拿到焦点后（切走 Tab 再切回来），系统用主色画选中行，而主色是写名字用的墨色：深色模式下整行变白、名字看不见。Bot 列表在并排时每行是一个按钮，自己设置选中的路由，选中行的底色用 `listRowBackground` 画（`BotHomeView.row`、`pickedFill`），和会话列表的做法一样。并排时每一行从一开始就给底色，没选中的给透明，不给 nil：行建好以后才第一次出现的底色，列表只画一次就不再更新，切换深浅色后选中行会停在原来的外观。不要用给列表改主色的办法去盖系统的选中色，主色会漏到同一栏的工具栏按钮上（iOS 18 上「⋯」会看不见）。
- 窄屏时会话、Bot 聊天、群聊推入后 Tab 栏照样显示，输入框在它上面，所以聊天页底部不要再放别的东西（「内容由 AI 生成」放在标题下面，Bot 和群聊接在标题第二行后面，见 `AILabelledSubtitle`）。iPhone 上 Tab 栏只显示图标，文字只给读屏用；iPad 保留文字，因为 iPadOS 顶部的 Tab 栏只显示文字。
- **分栏左侧的列表栏里不要放会推入页面的链接，也不要给这一栏套 `NavigationStack`。**左栏没有自己的栈时，`NavigationLink(value:)` 推出的页面会被系统放进右侧会话栏，那里没有返回按钮，点左侧会话也换不回来（#284，「已归档」原来就是这样）。给左栏套一层栈也不行：在 iPadOS 18 上，从推入的页面返回后，左栏会多出系统侧栏按钮，`toolbar(removing:)` 去不掉；用它把列表收起再展开，标题、视图菜单、新会话按钮会一直消失到重启。原地换内容也有坑：二级页还在时分栏被重建（窗口变窄、切走 Tab），列表随后才出现，iPadOS 18 会把列表的搜索框收进导航栏。所以「已归档」挪进了设置（「设置 → 已归档会话」，`DrawerView.archive()`），左栏只放会话列表。以后需要二级页面，放到设置或探索页这类有自己导航栈的地方；真要放进左栏，在 iPadOS 18 上验证：进出几次、收起展开列表、横竖来回转、切 Tab 再切回来，看标题行和搜索框是否都在。
- **并排在会话旁边的面板（工作台）不要自带 `NavigationStack`。**它已经在会话所在的导航栈里，再套一层会被 SwiftUI 并进外层的栈，连路径一起接管：外层是 Bot 页那种定类型路径时，路径下次变化就闪退（`AnyNavigationPath.Error.comparisonTypeMismatch`，TestFlight 上 iPad 的闪退就是它）；不闪退的布局里，之后推入的页面不显示。面板里的下级页面用 `NavigationLink { 页面 }` 直接推到会话的栈上，不用按值跳转（`NavigationLink(value:)`），值的类型和外层路径对不上。弹出层里的面板是另一棵视图树，可以有自己的栈（`WorkbenchView.beside`）。
- **iOS 17 的 iPad 分栏详情栏里轮流出现的几个栈，路径要是同一种。**详情栏按状态放插件、Bot、会话三个栈之一，系统把它们当成同一个栈，换栈时会比较前后两个路径：Bot 栈带 `[BotRoute]` 路径、另两个不带路径时类型对不上，App 闪退（`AnyNavigationPath.Error.comparisonTypeMismatch`；在 Bot 页点侧边栏里另一条会话必现）。所以 Bot 栈在这里把路径包成 `NavigationPath` 交给系统（`MainView.botStackInSplit`）。路径同类之后，系统换栈时会把上一个栈里用链接推入的页面留下来（插件下级页盖在 Bot 列表上），所以换栈时先把详情栏退回根页（`SplitDetail.popToRoot`）。以后往详情栏里再加一个栈，也照这两条做，并在 iPadOS 17 上验证：Bot 页点另一条会话；插件下级页开着时点「Bot」。

## 连接器对谁生效

连接器的入口在「探索」页（iOS 17 的 iPad 上在侧边栏「插件」下面那一行），是全 App 的通用入口，Bot 团队设置里也留了同一个页面。原因是 ds-bot 把连上的服务挂成引擎级的 MCP 插件：普通会话和 Bot 都能用它的工具（`mcp__<id>__*`），「哪些 Bot 可以用」的开关只限制 Bot，管不到普通会话。连接服务、登录都走 ds-bot 的接口，Bot 插件没就绪时只有「本机能力」那一类能用。本机能力是连接器页里的一类，在那里直接开关；只选这一类时显示完整的本机能力页（隐私说明、使用记录、系统设置）。

**以后增加连接器，或者增加类似的共享能力时，务必先判断它是否对 DS Bot 和普通会话同时生效：**

- 同时生效的，入口放在「探索」页（iOS 17 的 iPad 上是侧边栏）这类通用位置，页面文案要说清两边都能用，不能只藏在 Bot 的页面里。
- 只对 Bot 生效的，才只放在 Bot 的页面里。
- 判断依据是它在引擎里怎么挂载：挂在引擎上的（像连接器）对所有会话生效；只注入 Bot 会话的（像给某个 Bot 的能力）只对 Bot 生效。拿不准就实测：在普通会话和 Bot 聊天里各让 Agent 列一次可用工具。

## Bot 连接器的图标和说明

连接器页面（`app/DshIOS/Views/BotConnectors.swift`）里每个服务的图标、品牌色和一句中文说明，都在 `ConnectorBrand.looks` 这张表里，按 ds-bot 接口返回的连接器 id 查。接口本身不带图标，说明也只有英文。

- **图标取自 [Simple Icons](https://github.com/simple-icons/simple-icons)（CC0）**，不取自 ds-bot 的网页版。SVG 放在 `app/DshIOS/Assets.xcassets/Connectors/<id>.imageset`，模板渲染，由代码按品牌色上底色。Simple Icons 里没有的品牌（有些是品牌方要求下架的），表里不填图标，显示成品牌色加名字首字母。
- **ds-bot 新增了连接器时**，在表里补一行，否则它显示成通用的拼图块、说明是英文。新的中文说明要照「文案翻译」的步骤补齐各语言。
- **导入一个新图标**：从 Simple Icons 的 npm 包里取 `icons/<名字>.svg` 的那一条路径，写成 24×24 的单路径 SVG，配一个模板渲染的 `Contents.json`（照现有的抄）；品牌色在它的 `data/simple-icons.json` 里。只读这两处的数据，不要运行包里的脚本。换了 Simple Icons 的版本，记得改 `THIRD_PARTY_NOTICES.md` 里的版本号。
- 近乎纯黑的品牌色（GitHub、Notion、Vercel）在深色模式下会自动反成白底黑标，不用单独处理。

## 微信交流群二维码

群二维码在 README 和官网上，App 设置页里是一个打开官网图片的链接。它是企业微信的客户群活码，长期有效，群满了自动建新群，平时不用换。图有两份，真要换时一起换：

- 主仓库的 `docs/assets/wechat-group.png`：README 的「交流群」一节引用它。
- 官网 `fish-pocket-site` 的 `web/public/wechat-group.png`：中文页顶部「微信群」按钮弹出的大图和页脚都用它，合进官网的 `main` 就自动部署。

App 不内置图片，设置页里「微信交流群」一行是个链接，在浏览器里打开官网的 `https://fish.deepseek1024.com/wechat-group.png`（`AppLinks.wechatGroupCode`）。所以换二维码只要更新官网，不用发版；反过来，官网上这个文件的名字和路径不能改，否则已经装好的 App 都会打开一个不存在的页面。
