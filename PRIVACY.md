# 隐私政策 / Privacy Policy

生效日期 / Effective: 2026-11-07

[中文](#中文) · [English](#english)

## 中文

Fish Pocket 是独立的开源社区项目，与深度求索（DeepSeek）不存在隶属、合作、授权或背书关系。

**不登录 Fish Pocket 账号时，我们不收集你的数据。** 这时开发者收不到你的对话、文件、账号或使用情况。只有你选择登录 Fish Pocket 账号、使用 Fish Pocket 额度时，才会用到开发者运营的服务器，见下方「Fish Pocket 账号与额度」。App 里没有广告、分析或第三方追踪 SDK，官方客户端的会话日志上传、消息评价、反馈和使用分析在这个版本里都已关闭。

### 保存在你设备上的内容

会话、工作区文件、设置和模型服务商的凭证都只保存在你的设备上。删除 App 会删除这些内容。

### 会发送到第三方的内容

以下连接都是你使用相应功能时才发生，数据直接发给对方，不经过我们：

- **模型服务商：** 你发送的消息、附件，以及智能体为回答你而读取的文件内容和命令输出，都会发给你选择的模型服务商（默认是 DeepSeek，也可以配置其他服务商）。使用 DeepSeek 官方服务时，请求还带有 App 在本机生成的匿名 ID 和会话 ID。这些数据如何处理，由服务商的隐私政策决定。
- **DeepSeek 账号：** 选择账号登录时，登录在 DeepSeek 的官方页面完成，App 读不到你的账号和密码，只保存授权令牌用于调用模型和查询余额。
- **插件：** 打开插件市场时，App 会访问索引源里列出的地址，默认是 `api.dshfind.com`，并从索引指定的地址加载插件图标，目前是 GitHub。查看插件说明时会访问 npm 文件 CDN 或插件的代码仓库，安装插件时会访问 npm 仓库。这些请求不含你的对话或文件，但对方能看到你的 IP 地址。已安装的插件和智能体运行的命令可以按你的操作访问网络。
- **内置浏览器：** 你访问的网站会收到常规的网络请求。
- **更新检查：** App 会向 Apple 和 GitHub 查询最新版本，请求里不含你的个人信息。

### Fish Pocket 账号与额度（可选）

Fish Pocket 账号是可选功能，登录后可以用 App 内购买的额度调用 DeepSeek 模型。只有登录并使用这个功能时，以下数据才会发给开发者运营的 Fish Pocket 服务器：

- **账号信息：** 用 Apple 登录时，Apple 提供的用户标识，以及你同意分享的姓名和邮箱；用手机号登录时，你的手机号和验证码。
- **额度与购买：** 积分余额、App Store 的购买凭证，以及每次调用的模型名称、token 用量和扣除的积分。
- **对话内容：** 选择「Fish Pocket 额度」里的模型时，你发送的内容经 Fish Pocket 服务器转发给 DeepSeek，并按 DeepSeek 的隐私政策处理。服务器只读取用量用于计费，不保存对话内容。

登录凭证保存在本机的钥匙串里。你可以随时在「设置 → Fish Pocket 额度」退出登录，或注销账号；注销后账号无法恢复，剩余积分作废。

### 儿童

本 App 不面向 13 岁以下的儿童。

### 政策变更与联系方式

政策变更会更新在这个页面。如有问题，请在 [GitHub](https://github.com/imsai-sh/fish-pocket/issues) 上提问。

## English

Fish Pocket is an independent open-source community project. It is not affiliated with, authorized by or endorsed by DeepSeek.

**Unless you sign in to a Fish Pocket account, we do not collect your data.** Without one, the developer receives none of your conversations, files, account details or usage information. Only if you choose to sign in to Fish Pocket and use Fish Pocket credits does the app use servers the developer runs; see "Fish Pocket account and credits" below. The app contains no advertising, analytics or third-party tracking SDKs, and the official client's session log upload, message ratings, feedback and usage analytics are turned off in this build.

### What stays on your device

Sessions, workspace files, settings and model provider credentials are stored only on your device. Deleting the app deletes this data.

### What is sent to third parties

These connections happen only when you use the related feature, and the data goes directly to that party, not through us:

- **Model providers:** Your messages and attachments, along with file contents and command output the agent reads to answer you, are sent to the model provider you choose (DeepSeek by default, and other providers can be configured). Requests to DeepSeek's official service also carry an anonymous ID generated on your device and a session ID. How this data is handled is governed by the provider's privacy policy.
- **DeepSeek account:** If you sign in with an account, sign-in happens on DeepSeek's own page. The app cannot read your credentials and stores only an authorization token used to call models and check your balance.
- **Plugins:** Opening the plugin market contacts the addresses in your index sources, `api.dshfind.com` by default, and loads plugin icons from the addresses the index gives, currently GitHub. Viewing a plugin's documentation contacts npm file CDNs or the plugin's repository, and installing a plugin contacts the npm registry. These requests do not contain your conversations or files, but those services can see your IP address. Installed plugins and commands run by the agent can access the network as you direct them.
- **Built-in browser:** Websites you visit receive ordinary network requests.
- **Update check:** The app asks Apple and GitHub for the latest version. These requests contain no personal information.

### Fish Pocket account and credits (optional)

A Fish Pocket account is optional. Once signed in, you can use credits bought in the app to call DeepSeek models. Only when you sign in and use this feature is the following sent to the Fish Pocket servers the developer runs:

- **Account details:** with Sign in with Apple, the user identifier Apple provides and the name and email you choose to share; with a phone number, your number and the verification code.
- **Credits and purchases:** your credit balance, App Store purchase receipts, and for each request the model name, token usage and credits deducted.
- **Conversations:** when you pick a model under "Fish Pocket credits", what you send is forwarded through the Fish Pocket servers to DeepSeek and handled under DeepSeek's privacy policy. The servers read usage for billing only and do not store conversation content.

Sign-in tokens are kept in this device's Keychain. You can sign out or delete your account at any time in Settings → Fish Pocket credits; a deleted account cannot be restored and its remaining credits are forfeited.

### Children

This app is not directed at children under 13.

### Changes and contact

Changes to this policy are posted on this page. For questions, open an issue on [GitHub](https://github.com/imsai-sh/fish-pocket/issues).
