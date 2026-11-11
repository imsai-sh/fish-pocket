import AVFoundation
import SwiftUI

/// 远程控制: before signing in, what it is and how to connect; after, the account and its computers.
/// It is a page of 设置 and the sheet the sidebar opens.
struct RemoteControlPage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if app.remote.signedIn { RemoteDevicesList() } else { RemoteSignInPage() }
        }
        .navigationTitle("远程控制")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: Signing in

/// What remote control does, what it needs on the computer, and the two ways to sign in.
private struct RemoteSignInPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var scanning = false
    @State private var typing = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "laptopcomputer.and.iphone").font(.system(size: 34)).foregroundStyle(Palette.ink)
                    Text("在手机上管电脑里的智能体").font(.title3.weight(.semibold))
                    Text("电脑上的 Codex、Claude Code 和 DeepSeek Harness 在干什么，这里都能看到：跟进进度、接着聊、回应审批和提问、随时打断。")
                        .font(.subheadline)
                        .foregroundStyle(Palette.secondary)
                        .lineSpacing(2)
                }
                .padding(.vertical, 6)
                if app.remote.expired {
                    Label("登录已失效，请重新登录。", systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(Palette.waiting)
                }
            }
            .groupedRow()

            Section {
                step(1, "在电脑上安装 Agents Anywhere 并登录", "它是开源的桌面应用，负责把电脑上的智能体接到你的账号。") {
                    // What step 1 installs: its download sits in the step, not as a row after step 3.
                    Button { openURL(RemoteStore.Links.download) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle")
                            Text("下载 Agents Anywhere")
                        }
                    }
                    .buttonStyle(.capsule(.secondary, height: 34, fill: false))
                    .padding(.top, 6)
                }
                step(2, "在它的「设置 → 连接手机」里点「开始连接」", "电脑上会显示一个登录二维码。")
                step(3, "回到这里扫码", "在电脑上确认后就连上了。")
            } header: {
                Text("怎么连接")
            }
            .groupedRow()

            Section {
                Button { Haptics.tap(); scanning = true } label: {
                    Label("扫码登录", systemImage: "qrcode.viewfinder").font(.callout.weight(.semibold)).foregroundStyle(Palette.ink)
                }
                Button { typing = true } label: {
                    Label("用邮箱和密码登录", systemImage: "envelope").foregroundStyle(Palette.ink)
                }
            } footer: {
                Text("远程控制通过开源项目 Agents Anywhere 实现。会话内容经它的服务器转发：官方云服务，或你自己部署的服务器。本机的会话不受影响，也不会上传。")
            }
            .groupedRow()

            Section {
                link("Agents Anywhere 官网", "globe", RemoteStore.Links.site)
                link("开源仓库", "chevron.left.forwardslash.chevron.right", RemoteStore.Links.repository)
                link("Agents Anywhere 的 iOS App", "arrow.up.forward.app", RemoteStore.Links.app)
            } footer: {
                Text("添加智能体、模型配置、终端等更完整的功能在 Agents Anywhere 自己的 App 里。")
            }
            .groupedRow()
        }
        .groupedList()
        .sheet(isPresented: $scanning) { RemoteScanSheet() }
        .sheet(isPresented: $typing) { RemotePasswordSheet() }
    }

    private func step(_ number: Int, _ title: LocalizedStringKey, _ detail: LocalizedStringKey,
                      @ViewBuilder action: () -> some View = { EmptyView() }) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: "\(number)").font(.footnote.weight(.semibold).monospacedDigit()).foregroundStyle(Palette.onInk)
                .frame(width: 22, height: 22).background(Palette.ink, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink)
                Text(detail).font(.footnote).foregroundStyle(Palette.secondary)
                action()
            }
        }
        .padding(.vertical, 2)
        // Every step's separator starts at its number, whatever the step holds.
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
    }

    private func link(_ title: LocalizedStringKey, _ icon: String, _ url: URL) -> some View {
        Button { openURL(url) } label: {
            HStack {
                Label(title, systemImage: icon).foregroundStyle(Palette.ink)
                Spacer()
                Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.faint)
            }
        }
    }
}

/// Scan the code on the computer, then wait for the confirmation there.
private struct RemoteScanSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var code: RemoteLoginCode?
    @State private var failure: String?
    @State private var cameraDenied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let code {
                    waiting(code)
                } else if cameraDenied {
                    ContentUnavailableView {
                        Label("需要相机权限", systemImage: "camera")
                    } description: {
                        Text("扫描电脑上的登录二维码要用到相机。")
                    } actions: {
                        Button("打开系统设置") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    }
                } else {
                    RemoteCodeScanner { text in
                        guard code == nil else { return }
                        guard let scanned = RemoteLoginCode(scanned: text) else {
                            failure = String(localized: "这不是 Agents Anywhere 的登录二维码。")
                            return
                        }
                        Haptics.success()
                        failure = nil
                        code = scanned
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay(alignment: .bottom) {
                        Text("对准电脑上的登录二维码").font(.footnote.weight(.medium)).foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(.bottom, 16)
                    }
                    .padding(.horizontal, 20)
                    Text("在电脑上打开 Agents Anywhere 的「设置 → 连接手机」，点「开始连接」。")
                        .font(.footnote)
                        .foregroundStyle(Palette.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }
                if let failure {
                    Text(failure).font(.footnote).foregroundStyle(Palette.removed).multilineTextAlignment(.center).padding(.horizontal, 28)
                }
            }
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.background)
            .navigationTitle("扫码登录")
            .navigationBarTitleDisplayMode(.inline)
            .closeButton(dismiss)
        }
        .tint(Palette.ink)
        .task {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .denied, .restricted: cameraDenied = true
            case .notDetermined: cameraDenied = !(await AVCaptureDevice.requestAccess(for: .video))
            default: break
            }
        }
        // The request and the wait belong to the scanned code: closing the sheet ends them.
        .task(id: code) {
            guard let code else { return }
            do {
                try await app.remote.requestLogin(code)
                try await app.remote.awaitLogin(code)
                Haptics.success()
                dismiss()
            } catch {
                let problem = RemoteError(error)
                guard problem.kind != .cancelled else { return }
                Haptics.error()
                failure = problem.message
                self.code = nil
            }
        }
    }

    private func waiting(_ code: RemoteLoginCode) -> some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView().controlSize(.large)
            Text("请在电脑上确认登录").font(.title3.weight(.semibold))
            Text(code.server.host ?? "").font(.footnote.monospaced()).foregroundStyle(Palette.secondary)
            Text("电脑上会显示这台设备的登录请求，点确认后这里自动完成。")
                .font(.subheadline)
                .foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Button("重新扫描") { self.code = nil }.buttonStyle(.capsule(.outline, height: 44, fill: false))
        }
    }
}

/// The camera, reporting each QR code it reads.
private struct RemoteCodeScanner: UIViewRepresentable {
    let found: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    func makeUIView(context: Context) -> Preview {
        let view = Preview()
        view.backgroundColor = .black
        let session = AVCaptureSession()
        context.coordinator.session = session
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return view }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return view }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(context.coordinator, queue: .main)
        output.metadataObjectTypes = [.qr]
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        return view
    }

    func updateUIView(_ view: Preview, context: Context) { context.coordinator.found = found }

    static func dismantleUIView(_ view: Preview, coordinator: Coordinator) {
        let session = coordinator.session
        DispatchQueue.global(qos: .userInitiated).async { session?.stopRunning() }
    }

    final class Preview: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        var found: (String) -> Void
        var session: AVCaptureSession?
        private var last = ""
        private var lastAt = Date.distantPast

        init(found: @escaping (String) -> Void) { self.found = found }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard let text = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            // The same code is read many times a second: report it once every two seconds.
            if text == last, Date().timeIntervalSince(lastAt) < 2 { return }
            last = text
            lastAt = Date()
            found(text)
        }
    }
}

/// A server of the user's own takes an email and a password (the cloud's accounts sign in by QR code).
private struct RemotePasswordSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var server = RemoteStore.Links.cloud.absoluteString
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var failure: String?

    private var canSubmit: Bool {
        !busy && RemoteClient.serverURL(from: server) != nil && !email.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("服务器地址", text: $server)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                    TextField("邮箱", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.username)
                    SecureField("密码", text: $password)
                        .textContentType(.password)
                        .onSubmit { if canSubmit { submit() } }
                } footer: {
                    if let failure {
                        Text(failure).foregroundStyle(Palette.removed)
                    } else {
                        Text("自己部署的服务器填它的地址。这种登录没有续期，过期后要重新登录；扫码登录可以保持更久。")
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .groupedRow()
            }
            .groupedList()
            .navigationTitle("登录 Agents Anywhere")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else { Button("登录", action: submit).disabled(!canSubmit) }
                }
            }
        }
        .tint(Palette.ink)
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(busy)
    }

    private func submit() {
        guard let url = RemoteClient.serverURL(from: server) else { return }
        busy = true
        failure = nil
        Task {
            defer { busy = false }
            do {
                try await app.remote.signIn(server: url, email: email, password: password)
                Haptics.success()
                dismiss()
            } catch {
                Haptics.error()
                failure = RemoteError(error).message
            }
        }
    }
}

// MARK: The account's computers

/// The signed-in account, its computers and the agents on each.
private struct RemoteDevicesList: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var renaming: RemoteDevice?
    @State private var name = ""
    @State private var removing: RemoteDevice?
    @State private var signingOut = false

    private var remote: RemoteStore { app.remote }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle").font(.title2).foregroundStyle(Palette.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(remote.account?.name ?? "").font(.callout.weight(.medium)).foregroundStyle(Palette.ink)
                        Text(remote.account?.server.host ?? "").font(.caption).foregroundStyle(Palette.secondary)
                    }
                    Spacer(minLength: 8)
                    if !remote.connected {
                        Text(remote.loaded ? "未连接" : "连接中").font(.caption).foregroundStyle(Palette.waiting)
                    }
                }
                if let problem = remote.problem, !remote.connected {
                    Label(problem, systemImage: "wifi.exclamationmark").font(.footnote).foregroundStyle(Palette.secondary)
                }
            }
            .groupedRow()

            Section {
                if remote.devices.isEmpty {
                    Text(remote.loaded ? "这个账号下还没有电脑。在电脑上安装 Agents Anywhere 并登录同一个账号，它会自动出现在这里。" : "正在读取…")
                        .font(.subheadline)
                        .foregroundStyle(Palette.secondary)
                }
                ForEach(remote.devices) { device in deviceRow(device) }
            } header: {
                Text("电脑")
            }
            .groupedRow()

            Section {
                Button { app.remoteSessionRequest = RemoteSessionTarget() } label: {
                    Label("在电脑上新建会话", systemImage: "square.and.pencil").foregroundStyle(Palette.ink)
                }
                .disabled(!remote.devices.contains(where: \.online))
            }
            .groupedRow()

            Section {
                link("下载 Agents Anywhere 桌面应用", "arrow.down.circle", RemoteStore.Links.download)
                link("Agents Anywhere 的 iOS App", "arrow.up.forward.app", RemoteStore.Links.app)
                link("开源仓库", "chevron.left.forwardslash.chevron.right", RemoteStore.Links.repository)
            } footer: {
                Text("添加电脑和智能体、模型配置、终端、账号资料等在 Agents Anywhere 里完成。远程会话的内容经它的服务器转发。")
            }
            .groupedRow()

            Section {
                Button(role: .destructive) { signingOut = true } label: { Text("退出登录") }
            }
            .groupedRow()
        }
        .groupedList()
        .refreshable { await remote.refresh() }
        .task(id: remote.devices.map(\.id)) {
            for device in remote.devices where device.online { await remote.loadAgents(on: device.id) }
        }
        .alert("重命名电脑", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名称", text: $name)
            Button("取消", role: .cancel) { renaming = nil }
            Button("重命名") {
                guard let device = renaming else { return }
                let next = name.trimmingCharacters(in: .whitespacesAndNewlines)
                renaming = nil
                Task { if let failure = await remote.rename(device: device.id, to: next) { app.showToast(failure, tone: .warning) } }
            }
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog(Text("移除「\(removing?.name ?? "")」？"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { device in
            Button("移除电脑", role: .destructive) {
                Task { if let failure = await remote.remove(device: device.id) { app.showToast(failure, tone: .warning) } }
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("这台电脑会从账号里移除，它的会话不再显示。电脑上的文件和智能体自己的记录不受影响；要再用得在电脑上重新登录。")
        }
        .confirmationDialog("退出远程控制？", isPresented: $signingOut, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) { remote.signOut() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("电脑上的会话不再显示在这里，电脑上的一切保持原样。本机的会话不受影响。")
        }
    }

    private func deviceRow(_ device: RemoteDevice) -> some View {
        let agents = remote.agents(on: device.id)
        let count = remote.sessions.values.filter { $0.deviceId == device.id && !$0.archived }.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: device.symbol).font(.title3).foregroundStyle(device.online ? Palette.ink : Palette.faint).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.callout.weight(.medium)).foregroundStyle(Palette.ink).lineLimit(1)
                    HStack(spacing: 6) {
                        if device.online { StatusDot(state: .running) }
                        Text(status(device, sessions: count)).font(.caption).foregroundStyle(Palette.secondary)
                    }
                }
                Spacer(minLength: 8)
                Menu {
                    Button { app.remoteSessionRequest = RemoteSessionTarget(deviceId: device.id) } label: { Label("新建会话", systemImage: "square.and.pencil") }
                        .disabled(!device.online)
                    Button { name = device.name; renaming = device } label: { Label("重命名", systemImage: "pencil") }
                    Button(role: .destructive) { removing = device } label: { Label("移除电脑", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(Palette.secondary).hitTarget()
                }
            }
            if !agents.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(agents) { agent in
                        HStack(spacing: 8) {
                            Text(agent.name).font(.footnote).foregroundStyle(Palette.ink)
                            Text(agent.statusText).font(.caption).foregroundStyle(agent.status == "error" ? Palette.removed : Palette.secondary)
                            if let reason = agent.reason, !reason.isEmpty, !agent.ready {
                                Text(reason).font(.caption).foregroundStyle(Palette.faint).lineLimit(1)
                            }
                        }
                    }
                }
                .padding(.leading, 40)
            } else if device.online {
                Text("还没有智能体。在电脑上的 Agents Anywhere 里添加。").font(.caption).foregroundStyle(Palette.faint).padding(.leading, 40)
            }
        }
        .padding(.vertical, 4)
    }

    private func status(_ device: RemoteDevice, sessions: Int) -> String {
        let state = device.online ? String(localized: "在线") : device.lastSeen.map { String(localized: "离线 · 上次在线 \(TimelineFormat.clock($0))") } ?? String(localized: "离线")
        return sessions > 0 ? String(localized: "\(state) · \(sessions) 个会话") : state
    }

    private func link(_ title: LocalizedStringKey, _ icon: String, _ url: URL) -> some View {
        Button { openURL(url) } label: {
            HStack {
                Label(title, systemImage: icon).foregroundStyle(Palette.ink)
                Spacer()
                Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.faint)
            }
        }
    }
}
