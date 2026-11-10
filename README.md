<p align="center">
  <img src="docs/assets/mascot.png" width="220" alt="Fish Pocket 吉祥物：眨眼笑的鲸鱼娘大肥鱼">
</p>

<h3 align="center">Fish Pocket</h3>

<h1 align="center">在 iPhone 和 iPad 上本机运行 DSH（DeepSeek Harness），界面完全原生</h1>

<p align="center">
  <b>不连电脑，不连服务器，不是网页套壳。引擎就跑在 App 里，每个页面都用 SwiftUI 重写，iPhone 和 iPad 都是原生体验。</b>
</p>

<p align="center">
  <b>功能对齐 DSH 官方 Web UI，官方有的这里都有。智能体还能直接用 iPhone 自带的日历、提醒事项、健康、照片和地图。</b>
</p>

<p align="center">如果你也想把大肥鱼装进口袋，<a href="https://testflight.apple.com/join/2SCftb2M"><b>加入 TestFlight 公测</b></a>（推荐，全球可用）或<a href="https://apps.apple.com/app/id6830703602">从 App Store 下载</a>（非中国大陆），再点个 ⭐ 支持一下吧。</p>

<p align="center"><a href="https://fish.deepseek1024.com">官网</a> · <a href="README.en.md">English</a></p>

https://github.com/user-attachments/assets/d149b48d-ef15-4ba7-9fc3-2c627ea66ec0

## 看它干活

<table>
<tr>
<td align="center" width="33%"><img src="docs/assets/demo-market.gif" width="250" alt="在插件市场里找到 cc-safety-net，安装并启用；回到对话后，智能体要执行 git reset --hard，被这个插件拦下"><br/><b>插件市场</b><br/><sub>在手机上装一个安全网插件，危险命令当场被拦下</sub></td>
<td align="center" width="33%"><img src="docs/assets/demo-native.gif" width="250" alt="一句话让智能体把评审会加进系统日历，再建一条提醒，随后在日历 App 里看到这条日程"><br/><b>本机能力</b><br/><sub>说一句话，日程就进了系统日历，提醒也建好了</sub></td>
<td align="center" width="33%"><img src="docs/assets/demo-widget.gif" width="250" alt="任务运行时回到主屏幕，小组件和灵动岛显示这个会话正在进行，点小组件回到会话"><br/><b>小组件和灵动岛</b><br/><sub>切到后台任务照样跑，进度在主屏幕上看</sub></td>
</tr>
</table>

<p align="center">
  <img src="docs/assets/demo-ipad.gif" width="840" alt="iPad 上两个 Fish Pocket 窗口并排，各自运行一个会话：左边给贪吃蛇加排行榜，右边初始化 Git 仓库并提交">
  <br/>
  <b>iPad 多窗口</b>
  <br/>
  <sub>两个窗口并排，各跑各的会话：左边改游戏，右边提交代码</sub>
</p>

<p align="center"><sub>以上都是实际运行的录屏，等待的部分剪掉或加了速。</sub></p>

## 能做什么

- **能用 iPhone 自带的能力：** 智能体直接查日历、建提醒、读健康数据、找联系人、搜地图，每一项都由你自己开启。见[本机能力](#本机能力)。
- **功能对齐官方 Web UI：** 对话、工具调用、文件编辑、搜索、计划模式、审批、子智能体、定时任务和插件，DSH 官方 Web UI 能做的这里都能做。
- **完全原生的界面：** 对话、审批、工作台、插件和设置都用 SwiftUI 重写，交互按 iOS 习惯设计，不是把网页塞进 WebView。支持深色模式，可以跟随系统，也可以在设置里手动切换。官方 Web UI 也保留着，需要时可以在设置里打开。
- **真能用的终端：** 内置 bash、`node`、`pnpm`、`python3`、`pip`、`git`，还有 `rg`、`jq`、`curl`、`sed`、`awk` 等常用命令。
- **内置 Python：** Python 3.15 直接嵌在 App 里，标准库齐全，`pip install` 能装纯 Python 的包，`venv` 也能用。带编译扩展的包（numpy、pandas 等）暂时装不了。
- **内置 Git：** 基于静态链接的 libgit2，不靠子进程。`clone`、`commit`、`branch`、`merge`、`stash`、`pull`、`push` 等日常操作都能用，输出和真 git 一致，Agent 照常读懂。私有仓库用 HTTPS 加 Token 认证。
- **内置 DSH 插件商店：** 预置 DSH 生态插件市场，在手机上浏览、搜索，一键安装，装完就能用，不用回到电脑前。也可以在「索引源」里添加自己信任的商店源，或者直接从 npm 安装纯 JavaScript 插件。
- **工作台：** 终端、文件预览、内置浏览器和改动查看都放在一个面板里。
- **iOS 专属体验：** 灵动岛和锁屏 Live Activity，主屏幕和锁屏小组件，控制中心按钮，Siri 和快捷指令，切到后台任务也能继续。
- **iPad 适配：** 常驻侧栏、右侧工作台、多窗口、拖放文件，外接键盘支持常用快捷键。
- **更私密：** 会话和工作区留在设备上。
- **即将推出：Bot 模式。** 把口袋里的 Agent 变成一直在线的 Bot：在聊天里交代任务，它在手机上跑完，再把结果发回给你。

模型调用仍然需要联网，用 DeepSeek 账号或 API Key 都可以。

## 本机能力

引擎就跑在手机里，所以智能体能直接用 iPhone 自带的能力。说一句「明天下午 3 点约了牙医，记进日历，提前一小时提醒我」，日程和提醒就出现在系统自带的 App 里。

**日历 · 提醒事项 · 闹钟 · 通讯录 · 健康 · 照片 · 文件 · 音乐 · 位置 · 地图 · 智能家居 · 邮件和短信**，还有图像识别、语音转写等本机识别。

每一项都要你自己在侧边栏的「本机能力」里开启，没开的智能体用不了。开启后你装的插件也能用，用过哪些有记录可查。

## 和 DSH 官方 Web UI 的对比

功能和 DSH 官方 Web UI 对齐，官方能做的这里都能做，界面则用 SwiftUI 完全重写，iPhone 和 iPad 各按自己的习惯适配。在这之上还有官方没有的：本机能力、灵动岛和锁屏 Live Activity、小组件、Siri 和快捷指令、切到后台继续跑、iPad 多窗口。

## 和其他方案的区别

远程客户端要电脑一直开着，Fish Pocket 不用：引擎就在手机里，掏出来随时随地都能用。在手机上直接运行的方案里，它也是目前最快的：Node、Git 和 Python 都是原生代码，不经过模拟器。

|  | Fish Pocket | 远程客户端 | 手机里跑网页版 | iOS 上的 Linux 模拟器（iSH、UTM SE） |
|---|---|---|---|---|
| 引擎在哪里 | 手机 | 电脑或服务器 | 手机 | 手机 |
| 界面 | 完全原生 SwiftUI | 看具体项目 | 官方 Web UI | 终端或官方 Web UI |
| 电脑要开着吗 | 不用，有手机就行，随时随地 | 要，电脑得一直开着联网 | 不用 | 不用 |
| 灵动岛和锁屏状态 | 有 | 看具体项目 | 看具体项目 | 没有 |
| 调用日历、提醒事项、健康等本机能力 | 能，逐项由你开启 | 看具体项目 | 看具体项目 | 不能 |
| 完整的 Linux 工具 | 没有，只有内置命令、Node 和 Python | 有 | 看具体项目 | 有 |
| 运行速度 | 手机上直接运行的方案里最快：Node、Git、Python 都是原生代码 | 取决于那台电脑 | 看具体项目 | 特别慢，CPU 指令要逐条解释执行 |

## 快速开始

直接安装，需要 iOS 17 或更高版本：

- **TestFlight（推荐，全球可用）**：在 iPhone 或 iPad 上打开 [TestFlight 公测链接](https://testflight.apple.com/join/2SCftb2M)。新版本最先发到这里，和开源仓库保持同步。
- **App Store（非中国大陆）**：[在 App Store 下载](https://apps.apple.com/app/id6830703602)。目前只在中国大陆以外的地区上架。App Store 每个版本都要等审核，所以会比 TestFlight 和开源仓库晚一些。

自己编译：你需要 macOS、Xcode 26 或更高版本、Node 24 和 `xcodegen`，构建 libgit2 还需要 `cmake` 或 `uv`。要在 iPhone Duo 上铺满屏幕，需要用 Xcode 27.1 或更高版本编译，更早的版本编出来的包在 Duo 上只按普通 iPhone 的大小显示。

```bash
git clone https://github.com/imsai-sh/fish-pocket.git
```

```bash
cd fish-pocket && scripts/run-sim.sh
```

脚本会自动下载 nodejs-mobile 和 Python、构建 libgit2、组装引擎，然后装到模拟器上运行。默认设备是 `iPhone 17 Pro`，可以用 `SIM_DEVICE` 指定。

想装到真机上，先把 `app/project.yml` 和 `scripts/run-device.sh` 里的 `com.wsw.dsh-ios` 换成你自己的 Bundle ID，再运行：

```bash
DEVELOPMENT_TEAM=<你的团队 ID> scripts/run-device.sh
```

## 怎么做到的

iOS 不允许 App 创建子进程，也不允许运行下载的二进制。所以这里不模拟 Linux 虚拟机，而是把 Node 和 Python 嵌进 App，再用 DSH 自己的服务接缝换掉“执行世界”。引擎文件一行都没改。

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/architecture-zh-dark.svg">
    <img src="docs/assets/architecture-zh.svg" width="100%" alt="Fish Pocket 架构：SwiftUI 界面通过本地 HTTP 连接 App 内的 DSH 引擎，引擎再把 bash、node、git 和原生 addon 分别交给 just-bash、Worker 线程、libgit2 和纯 JS 替身">
  </picture>
</p>

## 插件兼容性

我们按下载量从 DSH 社区抽取了前 50 个第三方插件作为样本，在 iOS 引擎上逐个走完安装、启用、冷启动和卸载。**这只是抽样，不代表只支持这 50 个，其他插件同样可以安装。**

| 结果 | 数量 |
|---|---:|
| 直接可用 | 42 |
| 允许或跳过安装脚本、指定版本或重启 App 后可用 | 6 |
| 暂不可用 | 2 |

这里的“可用”指插件能被引擎加载，功能没有逐个试用。逐个插件的结果见 [#18](https://github.com/imsai-sh/fish-pocket/issues/18)。

## 常见问题

### Fish Pocket 是什么？

Fish Pocket 是一款开源的 iOS App，把 DeepSeek Harness（简称 DSH）的整个 Agent 引擎装进 iPhone 和 iPad，在本机运行。不用连电脑，也不用连服务器，界面用 SwiftUI 原生重写。

### Fish Pocket 和 DSH 官方 Web UI 有什么区别？

功能对齐，官方 Web UI 能做的 Fish Pocket 都能做。区别是引擎跑在手机和平板本机，不用开电脑；界面用 SwiftUI 重写，是 iPhone 和 iPad 的原生体验；还多了本机能力、灵动岛、小组件、Siri 和 iPad 多窗口这些官方没有的功能。

### 用 Fish Pocket 要开着电脑吗？

不用。远程客户端需要一台一直开着联网的电脑，Fish Pocket 的引擎就在 App 里，有手机就能用。只有调用模型时需要联网。

### Fish Pocket 收费吗？

App 免费，代码以 MIT 协议开源，商用需要先取得授权，见[许可证](#许可证)。模型调用用你自己的 DeepSeek 账号或 API Key，费用由模型服务商收取，不经过 Fish Pocket。

### 中国大陆能用吗？

能。用 TestFlight 公测安装，全球可用，包括中国大陆。App Store 版目前只在中国大陆以外的地区上架。

### 我的对话和代码会被上传吗？

不会传给我们：我们不运营任何服务器。会话和工作区留在你的设备上，模型请求直接发给你选择的服务商，详见[隐私政策](PRIVACY.md)。

### 智能体能看到我的日历、健康数据和照片吗？

只有你在「本机能力」里开启对应的那一项之后才能，没开的它用不了。用到时，读到的内容会随对话发给你选择的模型服务商。健康、通讯录和照片只读不写。

### 只能用 DeepSeek 的模型吗？

默认使用 DeepSeek，用账号登录或者填 API Key 都可以，也可以配置其他模型服务商。

### Fish Pocket 是 DeepSeek 官方出的吗？

不是。这是独立的开源社区项目，与深度求索（DeepSeek）不存在隶属、合作、授权或背书关系。

更多问答见[官网](https://fish.deepseek1024.com/#faq)。

## 路线图

- [x] 抽样测试社区热门插件的兼容性
- [x] 原生界面支持英文，搭好多语言框架
- [x] 界面支持西班牙语（[#24](https://github.com/imsai-sh/fish-pocket/issues/24)），设置里可以直接切换界面语言
- [ ] 确定插件兼容分级和适配规范（[#4](https://github.com/imsai-sh/fish-pocket/issues/4)）
- [x] 预置第三方插件商店（[#5](https://github.com/imsai-sh/fish-pocket/issues/5)）
- [x] 智能体可以使用 iPhone 的本机能力：日历、提醒事项、健康、照片、地图等
- [x] 内置 Python 3.15，支持 pip 和 venv
- [ ] bash 解释器移出引擎线程
- [ ] Bot 模式：在聊天里给口袋里的 Agent 派任务

## 交流群

<p align="center">
  <img src="docs/assets/wechat-group.png" width="260" alt="Fish Pocket 微信交流群二维码">
</p>

<p align="center">微信扫码加入 Fish Pocket 交流群。二维码过期了的话，欢迎<a href="https://github.com/imsai-sh/fish-pocket/issues">提 issue</a> 提醒我们更新。</p>

## 参与贡献

欢迎提 issue 和 PR，让你的 Agent 看 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 致谢

**特别感谢 [DSH Go](https://github.com/ccch1mneyyy/dsh-go)**，是它启发我们做了这个 iOS 版本，但他只支持Android版本。

Fish Pocket 还站在这些优秀项目的肩膀上。

**直接使用：**

- [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)：引擎本身，一切的基础
- [nodejs-mobile](https://github.com/nodejs-mobile/nodejs-mobile) 及其 [digidem 分支](https://github.com/digidem/nodejs-mobile)：让 Node 24 跑在 iOS 上
- [CPython](https://github.com/python/cpython)：python.org 官方的 iOS 构建，App 内的 Python
- [just-bash](https://github.com/vercel-labs/just-bash)：TypeScript 写的 bash 解释器
- [libgit2](https://github.com/libgit2/libgit2)：App 内的 git 能力
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)：终端界面

**参考过的思路：**

- [dsh-mobile](https://github.com/saya-ch/dsh-mobile)：DSH 的远程访问方案
- [a-Shell](https://github.com/holzschu/a-shell)：证明了 iOS 上可以有真正好用的本地终端
- [OpenMinis](https://github.com/OpenMinis/OpenMinis)：跑在手机上的 AI Agent，本机能力的分类和权限档位参考了它的设计

也感谢 DSH 社区的朋友们，“大肥鱼”这个外号来自大家的二创。吉祥物鲸鱼娘的原始角色来自[上善无形](https://space.bilibili.com/4456176)，女仆版二次设计来自 [ZipZipPipe](https://www.pixiv.net/artworks/148186519)。第三方许可证见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 作者

由 [sai](https://imsai.cc) 开发，更多内容见[个人主页](https://imsai.cc)。

我的其他开源项目：

- [awesome-deepseek-harness-plugins](https://github.com/imsai-sh/awesome-deepseek-harness-plugins)：DSH 插件商店与导航，收录 11000+ 插件（[deepseek1024.com](https://deepseek1024.com/)）
- [竹知了](https://github.com/imsai-sh/zhuzhiliao)：一转就哇哇叫的传统玩具，Web 模拟版

## 许可证

**欢迎自用，没有任何限制。** 下载、编译、阅读、修改，自己怎么用都行，不用打招呼，给本仓库提 PR 也一样。

代码使用 [MIT](LICENSE) 许可证。只有拿去商用或者公开发布改造版时，才有三条附加限制：

1. **商用先拿授权。** 把 Fish Pocket 或它的改造版拿去卖、收费分发、加内购或广告、打包进收费的产品或服务之前，要先取得作者的书面授权，请[提 issue](https://github.com/imsai-sh/fish-pocket/issues) 联系。自己用它干活不算商用。
2. **改造先提 issue。** 公开发布改造版之前，先[提 issue](https://github.com/imsai-sh/fish-pocket/issues) 说明改了什么、做什么用、打算怎么发。
3. **写明出处，换掉名字。** 改造版要写明基于 Fish Pocket 并附上本仓库链接，同时换成自己的名称和图标，不能当作官方版本发布。

条款原文在 [LICENSE](LICENSE) 末尾。

吉祥物图片（App 图标、启动图和 README 头图）不适用 MIT，它们基于他人作品，按 [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/) 使用，**不可商用**。拿到商用授权后也要先换掉这些图片，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

---

> 这是独立的社区项目，与深度求索（DeepSeek）不存在隶属、合作、授权或背书关系。“大肥鱼”是社区对 DeepSeek 的昵称。吉祥物基于社区二创的鲸鱼娘形象，用 AI 重新生成了表情，原形象版权归上善无形和 ZipZipPipe，没有使用 DeepSeek 的 Logo。
