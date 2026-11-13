# DSH plugins in the iOS app

The app has two interfaces onto the same engine and profile. The user normally works in the **native interface**, built in SwiftUI. The **web interface** is the official DSH Web UI, opened from Settings → 网页版. A plugin does not reach both in the same way:

| Part of a plugin | Native interface | Web interface |
|---|---|---|
| Host half: what runs in the engine, such as tools and settings | Works | Works |
| Browser half: `dsh.client` in `package.json`, the `./client` export, slots such as `sidebar.panellist` and `main`, React pages and panels | **Never runs** | Works |

- **A plugin that only adds interface is invisible in the native interface.** No sidebar entry, panel, or custom page appears there. Its card still shows under DSH 插件 in the sidebar as installed and running, because the engine did load it.
- **The built-in DS Bot plugin (`ds-bot`) is the exception.** The app ships it pinned to one version and draws its Bots, group chats, schedules and forms in native pages (the Bot card in the sidebar). Its own web page is not needed there, and it cannot be updated or replaced from the app.
- **Connectors are services the user signs in to once** (GitHub, Notion, Linear and the like), under 连接器 (Connectors) in the sidebar; the services are listed once the DS Bot plugin is running. A connected service is an MCP server mounted for the whole engine, so its tools are there in every session as `mcp__<id>__*`, this one included, not only for Bots. If a task needs a service whose tools you do not have, ask the user to connect it there; you cannot connect one yourself. Only connectors at a web address work: one that starts a local command cannot run here.
- **Say this before building it.** If the user asks for something they will see, tell them first that a browser half appears only in the web interface, the DSH 网页 row in the sidebar. If it must work in the native interface, put the feature in the Host half instead: a tool the agent can call.
- **Report where it appears.** Being in the profile, loading in the engine, or working in a web page does not show that it appears in the native interface. Name the interface you checked, and do not say a plugin's interface is in the app without saying it is the web interface.
- **`localStorage` belongs to the web interface.** Data a browser half keeps there never reaches the engine or the native interface.
- **A plugin that never finishes loading keeps the whole app out.** The interface opens only once every plugin has loaded, so do not make a plugin's startup wait on anything that can hang, such as a network request. If one does, the launch screen offers 停用第三方插件并重启: it switches off every plugin that is neither DSH's own (`@deepseek-ai/…`) nor built into the app, leaves them installed, and lists them once the app is in. The user then switches them back on one at a time under 插件 to find the one that hangs.
- **Dynamic Cordis plugins** with Client code cannot be activated from the native interface. Define a Host-only version, or run it from the web interface.
- **Device capabilities are for you, not for plugins.** Building a plugin on them is out of scope — do not do it and do not offer to, even if the user's idea would work. Say why if they ask: nothing is promised here, the names and arguments change between versions, and a plugin that wrote them down breaks silently on an update. You are fine because you re-read the skill every session.
- **A plugin they install can still reach them**, and nothing stops that: whatever the app is allowed to do, a plugin they install is allowed to do. That is a fact about installing plugins, so say it plainly when you build one for them — it is the reason the install warning reads the way it does.
