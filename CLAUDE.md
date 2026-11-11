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
2. 给新词条补上 `en`、`es` 翻译。
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

## Xcode Cloud 构建

推送到 `main` 且改到 `app`、`engine`、`native`、`scripts` 任一目录时，Xcode Cloud 会自动归档一次；只改文档不触发。影响打包的东西都放在这四个目录里，新增的也照此放。

- 工程文件不进仓库。Xcode Cloud 克隆后跑 `app/ci_scripts/ci_post_clone.sh`：装工具、下载 nodejs-mobile 和 Python、编译 libgit2、组装引擎、生成工程。这个脚本在 Mac 上也能直接跑，改完先本地跑一遍。
- build 号由 Xcode Cloud 分配，每次构建加 1，失败的也占号。脚本把它写进生成的工程，`app/project.yml` 里的 `CURRENT_PROJECT_VERSION` 只对本地构建有效。
- 改了 `app/project.yml` 里 SwiftPM 依赖的版本后，本地构建一次，把 `app/DshIOS.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` 拷到 `app/ci_scripts/Package.resolved`。Xcode Cloud 不自己解析版本，两边对不上会构建失败。

### 注意

- **升级 nodejs-mobile、Python、libgit2 的版本后**（`scripts/fetch-nodejs-mobile.sh`、`scripts/fetch-python.sh`、`scripts/build-libgit2.sh`），本地从零跑一遍 `app/ci_scripts/ci_post_clone.sh`。云端每次都重新下载和编译，下载地址或 sha256 写错会直接失败。
- **改构建脚本或 `app/project.yml` 的工程结构时**，合并前先在分支上手动触发一次云端构建。本地能验证脚本和编译，验证不了云端的签名和上传。
- **触发规则按提交看，不按净差异看。** 只改文档的 PR，如果分支在合并前同步过 `main`，那个同步提交带着别人的代码改动，照样会触发构建。不想触发，就从最新的 `main` 开分支，合并前不再同步。
- **连续推送只跑最新一次**，前一次会被自动取消。但被取消的那次如果已经导出完，包照样会上传并占一个 build 号，所以 build 列表里的号不一定连续，也可能多出包。
- **归档成功就自动上传**，不用另外操作。构建要等上传的包处理完才算结束，全程二三十分钟，其中真正在构建的只有几分钟；处理完之前包不会出现在 build 列表里，不是没传上去。
- **云端构建失败不影响本地**：`scripts/run-sim.sh`、`scripts/run-device.sh` 和 GitHub 上的编译检查走的是各自的流程。

## 内置 skill：iOS 环境说明

`engine/skills/ios-environment/SKILL.md` 随 App 打包，App 里的 Agent 靠它判断这台「iOS 沙盒」里能做什么、不能做什么。它写错了，Agent 就会去试不存在的命令，或者放弃本来能做的事。

**只要改动影响 Agent 在 App 里的执行环境，就在同一个提交里更新这份 skill。** 包括但不限于：

- Shell 命令增减或行为变化：升级 `just-bash`，改 `engine/runtime/shell.mjs`（自定义命令、`/dev`、挂载）。
- git：`engine/runtime/git` 里增减子命令或改了限制（同时对齐 `MISSING` 里的替代建议）。
- Python：`engine/runtime/python`、`scripts/fetch-python.sh`（版本、pip/venv、subprocess 的能力）。
- Node 和包管理：`scripts/fetch-nodejs-mobile.sh` 的 Node 版本、pnpm 版本、`engine/runtime/node-worker.mjs`、`engine/shims`（比如 `sharp` 替身支持的方法）。
- 文件系统布局：`native/root`、`app/DshIOS/EnginePaths.swift`、`engine/main.mjs` 里的 `HOME`、`TMPDIR`、工作区位置。
- 插件在原生界面和网页版里的可见范围，以及设置里相关入口的名字。

改完跑 `cd engine && node --test test/ios-environment.test.mjs`：它检查 frontmatter、description 不超过 500 字，以及「Commands that exist」里列的每个命令都真实存在。在没有 git 原生插件的机器上（比如 Linux），`git` 会被报成不存在，这一项可以忽略；macOS 上先跑 `scripts/build-git-addon.sh`。

写法上保持现在的风格：英文、短句、先说能不能用再说替代办法；「Commands that exist」之外的命令都会被当成不存在，所以新增命令一定要列进去。

## Bot：只用 DS Bot 的后端

Bot 功能的后台是内置的 ds-bot 插件，版本锁定在 `engine/plugins/ios-host/pins.json`。

- 只调用它的接口（`/api/bot`、`/api/bot/feed`），不使用、不移植它的前端代码（`client.js` 和它的界面组件）。
- 它网页版的设计只作参考借鉴。原生界面要自己设计，交互做得比它更好，不照搬它的布局和流程。
- ds-bot 网页版能做的事，都要用原生界面做。网页版入口可以保留，但只作为次要的备用入口，不能让用户依赖它完成主要操作。

## Bot 的内置形象

Bot 没有照片时显示的角色是 App 自己画的，形状和动作都写在 `app/DshIOS/Views/BotCharacter.swift` 里，不取自 ds-bot 的网页版。

- **形状名沿用后端的**：`BotCharacter.all` 里每个角色的 `id` 是 ds-bot 存在 Bot 上的形状名（`avatar.shape`，如 `star`、`kitty`）。后端新增了形状名，就在这里补画一个同名的；没画的名字会按 Bot 的 id 从 `friendly` 里挑一个顶上。同一个形状名在 App 和网页版里画法不同，这是有意的。
- **加一个形状**：用 `Draw` 里的积木（圆、圆角矩形、圆角多边形、平滑曲线，`join` 合并、`subtracting` 挖洞）在 100×100 的格子里拼出轮廓，再给出两眼的位置和大小。眼睛要整个落在轮廓里。
- **动作**：`Pose.make` 按状态（思考、搜索、干活、交接、等待、有事找用户）算出当下的姿态。改动作只改这里。
- 只有传了 `live: true` 的头像会动（列表、标题栏、详情页、聊天尾部的状态行）；聊天记录里的头像保持静止，免得长对话同时跑几十个动画。系统开了「减弱动态效果」时全部静止。

## Bot 连接器的图标和说明

连接器页面（`app/DshIOS/Views/BotConnectors.swift`）里每个服务的图标、品牌色和一句中文说明，都在 `ConnectorBrand.looks` 这张表里，按 ds-bot 接口返回的连接器 id 查。接口本身不带图标，说明也只有英文。

- **图标取自 [Simple Icons](https://github.com/simple-icons/simple-icons)（CC0）**，不取自 ds-bot 的网页版。SVG 放在 `app/DshIOS/Assets.xcassets/Connectors/<id>.imageset`，模板渲染，由代码按品牌色上底色。Simple Icons 里没有的品牌（有些是品牌方要求下架的），表里不填图标，显示成品牌色加名字首字母。
- **ds-bot 新增了连接器时**，在表里补一行，否则它显示成通用的拼图块、说明是英文。新的中文说明要照「文案翻译」的步骤补 `en`、`es`。
- **导入一个新图标**：从 Simple Icons 的 npm 包里取 `icons/<名字>.svg` 的那一条路径，写成 24×24 的单路径 SVG，配一个模板渲染的 `Contents.json`（照现有的抄）；品牌色在它的 `data/simple-icons.json` 里。只读这两处的数据，不要运行包里的脚本。换了 Simple Icons 的版本，记得改 `THIRD_PARTY_NOTICES.md` 里的版本号。
- 近乎纯黑的品牌色（GitHub、Notion、Vercel）在深色模式下会自动反成白底黑标，不用单独处理。

## 微信交流群二维码

群二维码只放在 README 和官网，App 里不放，设置页底部只有一个「官网」链接。二维码 7 天过期，有两份，换图时一起换：

- 主仓库的 `docs/assets/wechat-group.png`：README 的「交流群」一节引用它。
- 官网 `fish-pocket-site` 的 `web/public/wechat-group.png`：中文页页脚显示它，合进官网的 `main` 就自动部署。
