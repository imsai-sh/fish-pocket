# 远程控制

在手机上管电脑或服务器里的智能体：Codex、Claude Code、DeepSeek Harness。Fish Pocket 是控制端，智能体仍然跑在那台机器上。

这个功能通过开源项目 [Agents Anywhere](https://github.com/anywhere-labs/Agents-Anywhere) 实现。那台机器上要跑它的 Connector，手机和 Connector 都连到同一个 Agents Anywhere 服务器，由服务器在中间转发。服务器可以用官方的云服务，也可以自己部署。Fish Pocket 的开发者不运营任何服务器。

不登录远程控制，App 里什么都不会发生；本机会话始终留在手机上，不经过任何服务器。

## 个人电脑（没有公网 IP 也可以）

1. 在电脑上安装 [Agents Anywhere 桌面应用](https://www.agents-anywhere.com/download)并登录。它自带 Connector，会主动连到服务器，所以电脑不需要公网 IP，也不用开端口。
2. 在桌面应用的「设置 → 连接手机」里点「开始连接」，电脑上会出现一个登录二维码。
3. 在 Fish Pocket 侧边栏点「远程控制 → 扫码登录」，扫这个二维码，再到电脑上确认。

连上以后，这台电脑上的会话会出现在侧边栏里，和本机会话放在一起，可以按时间、按项目、按设备分组。

## 云服务器（没有图形界面的 Linux）

服务器上不装桌面应用，直接跑 Connector。Agents Anywhere 提供了带 Connector 的 Ubuntu 镜像，可以顺带装上 Codex 和 Claude Code。下面的命令在 Agents Anywhere 仓库的根目录执行。

构建镜像：

```bash
docker build -f docker/Dockerfile.connector-agents-ubuntu -t agents-anywhere-connector:agents-ubuntu2404 .
```

启动并配对（把地址换成你用的 Agents Anywhere 服务器，官方云服务是 `https://web.agents-anywhere.com`）：

```bash
docker run --rm -it \
  -v agents-anywhere-connector-data:/data \
  -v "$PWD:/workspace" \
  -e AGENT_CONNECTOR_MODE=pair \
  -e AGENT_SERVER_URL=https://web.agents-anywhere.com \
  -e INSTALL_CLAUDE=true \
  agents-anywhere-connector:agents-ubuntu2404
```

接下来三步：

1. 容器会打印一个配对码（`Pairing code: …`）。在 Agents Anywhere 的网页或桌面应用里添加设备、填入这个配对码，这台服务器就挂到你的账号下了。配对结果存在 `/data` 卷里，之后重启容器不用再配对。
2. 在 Agents Anywhere 里给这台服务器添加智能体，比如 Claude Code。服务器上装了哪些，它会自己列出来。
3. 打开 Fish Pocket，侧边栏的「新会话」里就能选这台服务器，填上服务器上的项目路径（比如 `/workspace/项目名`）开始。

智能体自己的账号和密钥要在服务器上配好，和在电脑上用它们时一样：比如给 Claude Code 设置它的 API 地址和密钥的环境变量，用 `-e` 传进容器。

构建镜像时如果报 `useradd: UID 1000 is not unique`，是因为新版 Ubuntu 24.04 基础镜像自带一个占用这个编号的 `ubuntu` 用户。在 Dockerfile 里 `useradd` 那一行前面加一行 `&& (userdel -r ubuntu 2>/dev/null || true) \` 再构建。

不用 Docker 也可以：在服务器上直接运行 Connector 的命令行，见 Agents Anywhere 的 [Connector 说明](https://github.com/anywhere-labs/Agents-Anywhere/blob/main/connector/README.md)。

手机这边不用区分电脑和服务器：登录同一个账号，服务器就作为一台设备出现在列表里。

这条路实测过：用上面的镜像起一台没有图形界面的 Linux 容器，装 Claude Code，从 Fish Pocket 新建会话、让它跑测试并修一个 bug，审批在手机锁屏上逐条批准，全程走通。

DeepSeek Harness 目前要在它自己的界面里登录 Agents Anywhere，更适合有桌面的电脑；没有图形界面的服务器上建议用 Codex 或 Claude Code。

## 自己部署服务器

不想让会话内容经过官方云服务，可以自己部署 Agents Anywhere 的服务器，见它的[部署说明](https://github.com/anywhere-labs/Agents-Anywhere/blob/main/docker/README.md)。在 Fish Pocket 里选「用邮箱和密码登录」，填你自己的服务器地址。

这种登录没有续期，过期后要重新登录；扫码登录可以保持更久。

## 在手机上能做什么

- 看消息流和执行过程，发消息（可以带图片和文件），随时打断。
- 回应审批、提问、表单和计划确认。
- 切换模型和权限，使用智能体自己的斜杠指令。
- 看这一轮改动了哪些文件，浏览项目里的文件。
- 在某台机器上新建会话；给机器改名，或把它从账号里移除。

在智能体自己的窗口里开始的会话（比如在电脑终端里起的 Codex），手机上默认只读。点「接管」后才能从手机发消息；用完可以「交还」。

添加机器和智能体、配置模型、终端这些，在 Agents Anywhere 自己的 App 里完成，Fish Pocket 里给了跳转。

## 和本机会话一样的地方

由手机负责的远程会话，也就是从手机新建的，或者接管过来的，和本机会话享有同样的待遇：

- **锁屏和灵动岛**：显示它在进行、等你允许、等你回答还是已完成。能一键答复的审批，可以直接在锁屏上点允许或拒绝。
- **小组件**：会话列表里有它们。
- **后台**：App 退到后台后，只要还有这样的会话在跑或在等你，就继续跟进。
- **提醒**：你在看别的会话时，它有请求等着，App 里会出现提示条，点一下直达。
- **回到上次的位置**：重新打开 App，回到上次所在的远程会话。

没有接管的会话是别人（你自己在电脑前）在操作的，只在侧边栏里显示状态，不上锁屏。

## 限制

- **没有推送服务。** 锁屏和灵动岛上的更新靠 App 自己在后台保持连接，和本机会话一样。「设置 → 后台运行 → 静音音频」开着时可以长时间保持；关掉后，App 退到后台大约半分钟就会被系统挂起，之后的进展要等回到 App 才看得到。App 被系统结束后也收不到。
- **那台机器要开着。** 机器离线时只能看已经同步过的历史。
- **会话内容经过服务器。** 远程会话的消息由 Agents Anywhere 的服务器转发，官方云服务或你自己部署的那台。见[隐私政策](../PRIVACY.md)。
- 远程会话没有工作台里的终端、内置浏览器和 Git 面板。
