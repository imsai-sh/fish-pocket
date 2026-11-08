import AuthenticationServices
import SwiftUI

/// What the Fish Pocket service sees, shown wherever signing in to it starts.
struct FishPocketPrivacyNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield").font(.subheadline).foregroundStyle(Palette.secondary)
            Text("登录信息只发给 Fish Pocket 服务器，用来识别账号和记录额度。用额度对话时，消息经 Fish Pocket 服务器转发给 DeepSeek 模型的服务商，服务器只记录用量，不保存对话内容。")
                .font(.footnote)
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.control, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// 设置 → Fish Pocket 额度: sign in, balance, credit packs, sign-out and account deletion.
struct FishPocketPage: View {
    @Environment(AppModel.self) private var app
    @State private var phoneSignIn = false
    @State private var confirmingSignOut = false
    @State private var confirmingDelete = false
    @State private var failure: String?

    private var account: FishPocketAccount { app.fishPocket }

    var body: some View {
        List {
            if account.signedIn {
                Section {
                    LabeledContent(account.user?.label ?? String(localized: "已登录")) {
                        Text(account.balance.map { String(localized: "\($0) 积分") } ?? String(localized: "加载中…"))
                            .font(.title3.weight(.medium).monospacedDigit())
                            .foregroundStyle(Palette.ink)
                    }
                    .padding(.vertical, 4)
                } footer: {
                    Text("用「Fish Pocket 额度」里的模型对话时，按实际用量扣除积分。")
                }
                .groupedRow()
                Section {
                    FishPocketPackList()
                } header: {
                    Text("购买额度")
                }
                .groupedRow()
                Section {
                    Button("退出登录", role: .destructive) { confirmingSignOut = true }
                    Button("注销账号", role: .destructive) { confirmingDelete = true }
                } footer: {
                    if let failure { Text(failure).foregroundStyle(Palette.removed) }
                }
                .groupedRow()
            } else {
                signedOut
            }
        }
        .groupedList()
        .navigationTitle("Fish Pocket 额度")
        .navigationBarTitleDisplayMode(.inline)
        // The pack list loads its own packs.
        .task { await account.refresh() }
        .refreshable { await account.refresh() }
        .sheet(isPresented: $phoneSignIn) { PhoneSignInSheet().environment(app) }
        .alert("退出登录", isPresented: $confirmingSignOut) {
            Button("取消", role: .cancel) {}
            Button("退出登录", role: .destructive) { Task { await account.signOut() } }
        } message: {
            Text("退出后剩余积分仍保留在账号里，重新登录即可继续使用。")
        }
        .alert("注销账号", isPresented: $confirmingDelete) {
            Button("取消", role: .cancel) {}
            Button("注销", role: .destructive) { Task { await deleteAccount() } }
        } message: {
            Text("注销后账号无法恢复，剩余积分将作废。")
        }
    }

    private var signedOut: some View {
        Section {
            VStack(spacing: 16) {
                VStack(spacing: 4) {
                    Text("登录 Fish Pocket").font(.subheadline).foregroundStyle(Palette.ink)
                    Text("不需要 DeepSeek 账号或 API Key，用 Fish Pocket 额度直接调用 DeepSeek 模型，在 App 内购买额度。")
                        .font(.footnote).foregroundStyle(Palette.secondary)
                }
                .multilineTextAlignment(.center)
                AppleSignInButton { failure = $0 }
                Button("手机号登录") { phoneSignIn = true }
                    .buttonStyle(.capsule(.outline, height: 44))
                if let failure {
                    Text(failure).font(.footnote).foregroundStyle(Palette.removed)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        } footer: {
            FishPocketPrivacyNote().padding(.top, 8)
        }
        .groupedRow()
    }

    private func deleteAccount() async {
        failure = nil
        do {
            try await account.deleteAccount()
        } catch {
            failure = error.localizedDescription
            Haptics.error()
        }
    }
}

/// Sign in with Apple, finishing with the Fish Pocket server.
struct AppleSignInButton: View {
    /// A failure to show; nil clears it.
    let report: (String?) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    @State private var nonce = FishPocketAccount.appleNonce()
    @State private var busy = false

    var body: some View {
        SignInWithAppleButton(.signIn) { request in
            nonce = FishPocketAccount.appleNonce()
            request.requestedScopes = [.fullName, .email]
            request.nonce = nonce.hashed
        } onCompletion: { result in
            switch result {
            case .success(let authorization):
                guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else { return }
                let raw = nonce.raw
                Task {
                    busy = true
                    defer { busy = false }
                    do {
                        try await app.fishPocket.signInWithApple(credential, rawNonce: raw)
                        report(nil)
                        Haptics.success()
                    } catch {
                        report(error.localizedDescription)
                        Haptics.error()
                    }
                }
            case .failure(let error):
                if (error as? ASAuthorizationError)?.code != .canceled { report(String(localized: "Apple 登录未完成，请重试。")) }
            }
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        // The style is read once: rebuild on an appearance change.
        .id(colorScheme)
        .frame(height: 44)
        .clipShape(Capsule())
        .disabled(busy)
        .overlay { if busy { ProgressView() } }
    }
}

/// Phone number and SMS code (mainland China numbers).
struct PhoneSignInSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var phone = ""
    @State private var code = ""
    @State private var resendAt: Date?
    @State private var sending = false
    @State private var signingIn = false
    @State private var failure: String?
    @FocusState private var focus: Field?

    enum Field { case phone, code }

    /// E.164 for an 11-digit mainland number, as typed with or without +86.
    private var e164: String? {
        let digits = phone.filter(\.isNumber)
        let local = digits.hasPrefix("86") && digits.count == 13 ? String(digits.dropFirst(2)) : digits
        return local.count == 11 && local.hasPrefix("1") ? "+86\(local)" : nil
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text(verbatim: "+86").foregroundStyle(Palette.secondary)
                        TextField("手机号", text: $phone)
                            .keyboardType(.phonePad)
                            .textContentType(.telephoneNumber)
                            .focused($focus, equals: .phone)
                    }
                    HStack {
                        TextField("验证码", text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .focused($focus, equals: .code)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let wait = resendAt.map { Int($0.timeIntervalSince(context.date).rounded(.up)) } ?? 0
                            Button(wait > 0 ? String(localized: "\(wait) 秒后重发") : String(localized: "获取验证码")) { Task { await send() } }
                                .buttonStyle(.borderless)
                                .disabled(e164 == nil || sending || wait > 0)
                        }
                    }
                } footer: {
                    if let failure { Text(failure).foregroundStyle(Palette.removed) } else { Text("目前只支持中国大陆手机号。") }
                }
                .groupedRow()
                Section {
                    Button { Task { await signIn() } } label: {
                        HStack {
                            Spacer()
                            if signingIn { ProgressView() } else { Text("登录") }
                            Spacer()
                        }
                    }
                    .disabled(e164 == nil || code.count < 4 || signingIn)
                } footer: {
                    FishPocketPrivacyNote().padding(.top, 8)
                }
                .groupedRow()
            }
            .groupedList()
            .navigationTitle("手机号登录")
            .navigationBarTitleDisplayMode(.inline)
            .closeButton(dismiss)
            .onAppear { focus = .phone }
        }
        .presentationDetents([.medium, .large])
    }

    private func send() async {
        guard let e164 else { return }
        sending = true
        failure = nil
        defer { sending = false }
        do {
            resendAt = try await app.fishPocket.sendPhoneCode(e164)
            focus = .code
        } catch let error as FishPocketError {
            failure = error.message
            if let next = error.resendAt { resendAt = next }
        } catch {
            failure = error.localizedDescription
        }
    }

    private func signIn() async {
        guard let e164 else { return }
        signingIn = true
        failure = nil
        defer { signingIn = false }
        do {
            try await app.fishPocket.signInWithPhone(e164, code: code)
            Haptics.success()
            dismiss()
        } catch {
            failure = error.localizedDescription
            Haptics.error()
        }
    }
}

/// The credit packs, each bought through In-App Purchase.
struct FishPocketPackList: View {
    @Environment(AppModel.self) private var app

    private var account: FishPocketAccount { app.fishPocket }

    var body: some View {
        if account.packs.isEmpty {
            if account.packsFailed {
                Button("暂时无法获取额度包，轻点重试") { Task { await account.loadPacks() } }
                    .foregroundStyle(Palette.secondary)
            } else {
                HStack { Text("加载中…").foregroundStyle(Palette.secondary); Spacer(); ProgressView() }
                    .task { await account.loadPacks() }
            }
        } else {
            ForEach(account.packs) { pack in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(pack.credits) 积分").foregroundStyle(Palette.ink)
                        if let days = pack.validityDays {
                            Text("购买后 \(days) 天内有效").font(.footnote).foregroundStyle(Palette.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        Task { await account.purchase(pack) }
                    } label: {
                        if account.purchasing == pack.id { ProgressView() } else { Text(pack.product.displayPrice) }
                    }
                    .buttonStyle(.capsule(.outline, height: 36, fill: false))
                    .disabled(account.purchasing != nil)
                }
            }
        }
    }
}

/// A conversation on Fish Pocket credits ran out: the balance and the packs.
struct FishPocketTopUpSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("剩余积分") {
                        Text(app.fishPocket.balance.map(String.init) ?? "—").monospacedDigit()
                    }
                } footer: {
                    Text("购买额度后，把刚才的消息重新发送一次。")
                }
                .groupedRow()
                Section { FishPocketPackList() } header: { Text("购买额度") }
                    .groupedRow()
            }
            .groupedList()
            .navigationTitle("Fish Pocket 额度已用完")
            .navigationBarTitleDisplayMode(.inline)
            .closeButton(dismiss)
            .task { await app.fishPocket.refresh() }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The Fish Pocket toast line (purchases credited, sign-in lost).
struct FishPocketNotices: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack {
            if let toast = app.fishPocket.toast {
                Text(toast)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Palette.onInk)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Palette.ink, in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: toast) {
                        // Cancelled by a newer toast: leave that one up.
                        do { try await Task.sleep(for: .seconds(3)) } catch { return }
                        withAnimation { app.fishPocket.toast = nil }
                    }
            }
        }
        .animation(.snappy, value: app.fishPocket.toast)
    }
}
