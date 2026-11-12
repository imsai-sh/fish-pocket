# 第三方声明

本项目的代码以 [MIT](LICENSE) 协议发布，另有几条附加限制（商用需要授权，发布改造版前要先提 issue），见 LICENSE 末尾。下面的组件不属于本项目，保留各自的许可证和版权声明。**吉祥物图片不适用 MIT**，见[吉祥物](#吉祥物不适用-mit)一节。

本仓库不包含这些组件的源码。它们在构建时下载或安装，版本钉死在 `engine/package-lock.json`、`app/project.yml` 和 `scripts/` 里。编译出的 App 会包含它们，分发 App 时要一并遵守这些许可证。

## 主要组件

| 组件 | 版本 | 许可证 | 版权方 | 用途 |
|---|---|---|---|---|
| [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（`@deepseek-ai/dsh` 及其插件包） | 0.2.2-rc.1 | MIT | Copyright (c) 2026 DeepSeek | 引擎 |
| [nodejs-mobile](https://github.com/digidem/nodejs-mobile)（digidem 分支，上游为 [nodejs-mobile/nodejs-mobile](https://github.com/nodejs-mobile/nodejs-mobile)） | 24.20.0-0 | Node.js 许可证（MIT 及其捆绑组件的各自许可证） | Node.js 贡献者等 | 内嵌 Node 运行时，以预编译的 `NodeMobile.xcframework` 下载 |
| [just-bash](https://github.com/vercel-labs/just-bash) | 3.6.0 | Apache-2.0 | Copyright 2025 Vercel Inc. | bash 解释器和内置命令 |
| [CPython](https://github.com/python/cpython)（python.org 的 iOS 构建） | 3.15.2 | PSF 许可证第 2 版（及其捆绑组件的各自许可证） | Copyright (c) 2001 Python Software Foundation 等 | 内嵌 Python 运行时，以预编译的 `Python.xcframework` 下载，含标准库和 `ensurepip` 自带的 pip |
| [FFmpeg](https://ffmpeg.org) | 9.0.2 | LGPL 2.1 或更高版本（只开 LGPL 组件） | FFmpeg 贡献者 | `ffmpeg`、`ffprobe` 命令，从官方源码编译成动态框架 `FFmpeg.framework`，有少量改动，见下文 |
| [libgit2](https://github.com/libgit2/libgit2) | 1.9.7 | GPLv2 + 链接例外 | libgit2 贡献者 | git 能力，未修改源码，静态链接 |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | 1.10.0 | MIT | Copyright (c) 2019-2022 Miguel de Icaza 等 | 终端界面 |
| [SwiftMath](https://github.com/mgriebling/SwiftMath) | 1.7.3 | MIT；随包的数学字体各有许可证（GUST 字体许可证、SIL OFL 等），见其 README 的 Fonts 一节 | Copyright (c) 2023 Computer Inspirations | 回复里的公式排版 |
| [pnpm](https://github.com/pnpm/pnpm) | 11.28.5 | MIT | Rico Sta. Cruz、Zoltan Kochan 及贡献者 | 插件安装 |
| [DS Bot](https://github.com/Fei2411/DS-Bot)（`ds-bot`） | 0.3.1 | Apache-2.0 | Copyright 2026 Fei2411 and the DS Bot contributors | Bot 功能的后台，内置在引擎里 |
| [Simple Icons](https://github.com/simple-icons/simple-icons) | 16.37.0 | CC0-1.0 | Simple Icons 贡献者 | Bot 连接器页面的品牌图标 |

Simple Icons 是上面这句话的例外：用到的 28 个图标以 SVG 文件直接放在仓库里（`app/DshIOS/Assets.xcassets/Connectors`）。CC0 只覆盖图标文件本身，各图标仍是其品牌方的商标，App 里只用来标明连接的是哪家服务。

CPython 的完整许可证及其捆绑组件（OpenSSL、SQLite、libffi、zlib、bzip2、xz、zstd、expat、mpdecimal 等）的许可证见 [Python 文档的许可证页](https://docs.python.org/3.15/license.html)；标准库里的 `LICENSE.txt` 随 App 一起分发。

FFmpeg 按 LGPL 2.1 或更高版本使用，构建方式见 `scripts/build-ffmpeg.sh`：

- **只开 LGPL 组件。** 不加 `--enable-gpl` 和 `--enable-nonfree`，不链接 x264、x265、LAME 等外部库，构建时检查 configure 报告的许可证。H.264、HEVC 编码走系统的 VideoToolbox。
- **动态链接。** FFmpeg 的库和 ffmpeg、ffprobe 两个程序编成一个独立的动态框架 `FFmpeg.framework`，App 的其余部分只通过它导出的两个函数调用它。框架里附带 LGPL 2.1 全文（`LICENSE`）。
- **改动公开。** 为了让两个程序在 App 内作为函数运行，对 FFmpeg 源码做了少量修改：改名入口函数、不安装信号处理、不读终端、`pipe:` 协议改用当次命令的管道，以及每次运行前复位程序的全局变量。改动全部在本仓库的 `native/ffmpeg/`（`ffmpeg.patch`、`fftools-prefix.h`、`tool.c`），任何人都可以用原版或自己修改过的 FFmpeg 源码重新编译出这个框架并替换进 App。
- **源码。** 官方源码包 <https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz>，构建脚本里钉死了 sha256。许可证全文见源码里的 `COPYING.LGPLv2.1` 和 [FFmpeg 的许可证说明](https://ffmpeg.org/legal.html)。
- **预编译包。** 为了省去每次构建都编译一遍，本仓库的 GitHub Release（tag 以 `ffmpeg-` 开头）里放着用上面的脚本和改动编好的同一个框架，`scripts/fetch-ffmpeg.sh` 下载它并校验 sha256。它和从源码编出来的框架内容相同，上面几条同样适用。

libgit2 的完整许可证见其仓库的 [COPYING](https://github.com/libgit2/libgit2/blob/main/COPYING)。其中的链接例外允许把未修改的库链接进其他程序并分发，只有修改库本身时才受 GPLv2 约束。

## 打进 App 的 npm 包

`scripts/build-engine.sh` 组装出的引擎目录约有 680 个 npm 包，分布如下：

| 许可证 | 包数量 |
|---|---|
| MIT | 568 |
| Apache-2.0 | 59 |
| ISC | 23 |
| BSD-3-Clause | 19 |
| BlueOak-1.0.0 | 6 |
| BSD-2-Clause | 2 |
| 其他（0BSD、Unlicense、Python-2.0、MPL-2.0 各 1 个，双重许可 3 个） | 7 |

上游自带的许可证文件会随包一起打进 App。准确清单以 `engine/package-lock.json` 为准，个别包不带单独的许可证文件，以其 `package.json` 的声明为准。

需要单独留意的两项：

- **`@deepseek-ai/libreoffice-kit`（MPL-2.0）：** 只保留了很小的 JS 外壳，平台二进制和 wasm 在打包时已删除，`office-to-pdf` 也已禁用。
- **`ds-bot`（Apache-2.0）：** 它的 npm 包只带 LICENSE，不带上游仓库的 NOTICE。按 Apache-2.0 第 4 条，`engine/notices/ds-bot.NOTICE`（取自上游 v0.3.1）在打包时放到 `ds-bot/NOTICE`，随 App 一起分发。原生界面只调用它的接口，没有使用它的界面代码。
- **`just-bash` 自带的 CPython（Python 许可证）：** 位于 `just-bash/vendor/cpython-emscripten`，随 just-bash 一起打包，但 iOS 上没有启用 `python` 命令。

## 吉祥物（不适用 MIT）

吉祥物图片不是本项目的原创，**不按 MIT 授权**。它们基于社区二创形象“鲸鱼娘·大肥鱼”，版权归原作者，按 [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/)（署名、非商业使用、相同方式共享）使用，完整协议见 [docs/design/brand/LICENSE](docs/design/brand/LICENSE)。

| 贡献 | 作者 | 来源 |
|---|---|---|
| 鲸鱼娘原始角色形象（原创角色“溟月”） | 上善无形 | [Bilibili](https://space.bilibili.com/4456176) |
| 加入 DeepSeek 元素的女仆二次设计 | ZipZipPipe | [Pixiv《AI娘化》](https://www.pixiv.net/artworks/148186519) |
| 以原始鲸鱼娘形象为基础，用 AI 重新生成表情 | sai | 本项目 |

这个协议覆盖下面的文件：

- `docs/design/brand/mascot-icon.png`
- `app/DshIOS/Assets.xcassets/AppIcon.appiconset/`、`LaunchMark.imageset/` 和 `ShareMascot.imageset/` 里的 PNG
- `docs/assets/icon.png`、`docs/assets/mascot.png`
- `docs/assets/demo-widget.gif`、`docs/assets/demo-ipad.gif`（画面含 App 图标）
- `docs/promo/` 里的宣传片（画面含吉祥物）

本项目的修改：`mascot-icon.png` 以原始鲸鱼娘形象为基础，用 AI 重新生成了表情。其余文件由 `docs/design/brand/make-icons.py` 从它生成，只做了缩放、圆角和灰度处理；`ShareMascot.imageset/` 里的分享海报用图另外去掉了背景。这些修改同样按 CC BY-NC-SA 4.0 发布。

**如果你要商用这份代码：** 先按 [LICENSE](LICENSE) 的附加条款取得作者的授权。授权只覆盖代码，不覆盖这些图片，请换掉上面的文件，或者自行取得原作者的许可。

本项目没有使用 DeepSeek 的 Logo，也和上述作者没有隶属或背书关系。

## 参考但未包含的内容

- **官方 Web UI：** `docs/webui/` 的功能清单和协议说明，以及原生界面的部分文案和行为，整理或移植自 `@deepseek-ai/*`（MIT，Copyright (c) 2026 DeepSeek）。
- **DSH Go：** AGPL-3.0。本项目参考过它的方案和协议，没有使用它的代码。
- **Agents Anywhere：** Apache-2.0，Copyright 2026 Agents Anywhere Contributors。远程控制（`app/DshIOS/Remote/`）对接它的服务器接口，事件合并、斜杠指令和交互表单的处理规则参照它公开的 iOS 客户端重新实现。App 不捆绑它的任何组件，电脑端和服务器由用户自己安装或部署。
