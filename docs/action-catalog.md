# Fish Pocket 本机命令

模型通过已有的 `bash` 使用工作台浏览器和 iOS 设备能力。新会话从 Skill 目录看到 `browser-cli`、`ios-environment` 的简短说明。调用设备、切换能力和恢复会话都沿用同一张模型工具表。

| 命令 | 作用 |
| --- | --- |
| `device --help` | 列出当前调用者可用的设备能力 |
| `device calendar --help`、`device calendar list` | 查看参数、查询日程 |
| `device notify schedule --after-seconds 1200 --body '喝水'` | 安排 20 分钟后的系统本地通知 |
| `browser --help`、`browser help upload` | 从已安装的浏览器目录读取动作和参数 |
| `browser screenshot`、`browser pdf --path page.pdf` | 返回图片、保存工作区 PDF |

引擎为每次命令临时解析当前调用者的原生定义，经 DSH 的 `tools.resolve` 和 `tools.execute` 执行，结束后释放。原生处理器负责系统授权、写入确认、取消反馈及活动记录。新增的设备定义由同一注册入口提供给 CLI，浏览器动作以 Swift 的 `BrowserCatalog` 为准。
