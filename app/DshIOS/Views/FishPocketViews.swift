import AuthenticationServices
import SwiftUI

/// What the Fish Pocket service sees, shown wherever signing in to it starts.
struct FishPocketPrivacyNote: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "lock.fill").font(.caption)
            Text("登录信息只发给 Fish Pocket 服务器，用来识别账号和记录积分。对话、提示词和声音经服务器转给 DeepSeek 模型的服务商和火山引擎，服务器只记录用量，不保存内容。")
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Palette.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// 设置 → Fish Pocket 账号, and the sheet a conversation opens. One page on both sides of
/// signing in: before, what credits are spent on and what they cost, with signing in at the
/// bottom; after, the balance, the packs with one button that buys the chosen one, what
/// credits are spent on, and the account. One balance pays for chat, images and speech.
struct FishPocketPage: View {
    /// Opened because a conversation ran out of credits: the page is then about buying more.
    var topUp = false
    @Environment(AppModel.self) private var app
    @Environment(\.systemLists) private var systemLists
    @State private var selected: String?
    @State private var phoneSheet = false
    @State private var confirmingSignOut = false
    @State private var confirmingDelete = false
    @State private var failure: String?
    @State private var recordsOpen = false

    private var account: FishPocketAccount { app.fishPocket }
    /// The first pack starts chosen.
    private var chosen: FishPocketPack? {
        account.packs.first { $0.id == selected } ?? account.packs.first
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if account.signedIn {
                    VStack(spacing: 10) {
                        FishPocketBalance(balance: account.balance, expiring: account.expiring, depleted: topUp, sells: account.canPurchase)
                        if !topUp { recordsLink }
                    }
                    if account.canPurchase { packs } else { FishPocketNoPurchaseNote() }
                    if !topUp, let invites = account.invites { FishPocketInviteRow(invites: invites) }
                    FishPocketUses(rate: account.tokensPerCredit)
                    FishPocketRules()
                    if !topUp { accountCard }
                } else {
                    FishPocketIntro()
                    FishPocketUses(rate: account.tokensPerCredit)
                    packs
                    FishPocketRules()
                    FishPocketPrivacyNote().padding(.horizontal, 4)
                }
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        // Under 设置 the page continues the grey of the lists it was opened from.
        .background(systemLists ? Color(.systemGroupedBackground) : Palette.grouped)
        .actionTray(shown: !account.signedIn || (account.canPurchase && chosen != nil)) {
            if account.signedIn { buyBar } else { signInBar }
        }
        .animation(.snappy, value: account.signedIn)
        // Signed out, the page's own heading is the title.
        .navigationTitle(account.signedIn ? Text(topUp && account.canPurchase ? "购买积分" : "Fish Pocket 账号") : Text(verbatim: ""))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $recordsOpen) { FishPocketRecordsPage() }
        .task { await account.refresh() }
        #if DEBUG
        .task { if UserDefaults.standard.string(forKey: "dshOpen") == "credits", account.signedIn, !topUp { recordsOpen = true } }
        #endif
        .task { if account.packs.isEmpty { await account.loadPacks() } }
        // Signed out, the ways to sign in; signed in (after signing in too), the invites.
        .task(id: account.signedIn) {
            if account.signedIn { await account.loadInvites() } else { await account.loadSignInOptions() }
        }
        .refreshable { await account.refresh() }
        .sheet(isPresented: $phoneSheet) { PhoneSignInSheet().environment(app) }
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

    /// 积分明细: usage by day and the credits that came in.
    private var recordsLink: some View {
        Button {
            Haptics.tap()
            recordsOpen = true
        } label: {
            HStack(spacing: 4) {
                Text("积分明细")
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Palette.faint)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Palette.control, in: Capsule())
            .hitTarget()
        }
        .buttonStyle(.plain)
    }

    // MARK: Packs

    private var packs: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("积分包")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.secondary)
                .padding(.horizontal, 4)
            if account.packs.isEmpty {
                Group {
                    if account.packsFailed {
                        Button("暂时无法获取积分包，轻点重试") { Task { await account.loadPacks() } }
                            .font(.subheadline)
                            .foregroundStyle(Palette.secondary)
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 132)
                .cardSurface()
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                    ForEach(account.packs) { pack in
                        FishPocketPackTile(
                            pack: pack,
                            saving: saving(pack),
                            selected: account.signedIn ? chosen?.id == pack.id : nil
                        ) {
                            Haptics.tap()
                            withAnimation(.snappy) { selected = pack.id }
                        }
                    }
                }
            }
        }
    }

    /// How much less a credit costs in this pack than in the smallest one, in whole percent
    /// (rounded down, from the App Store's prices for this storefront); nil when it is no cheaper.
    private func saving(_ pack: FishPocketPack) -> Int? {
        guard let smallest = account.packs.first, smallest.id != pack.id else { return nil }
        func perCredit(_ pack: FishPocketPack) -> Double {
            NSDecimalNumber(decimal: pack.product.price).doubleValue / Double(max(pack.credits, 1))
        }
        let base = perCredit(smallest)
        guard base > 0 else { return nil }
        let percent = Int((1 - perCredit(pack) / base) * 100)
        return percent >= 1 ? percent : nil
    }

    // MARK: The action at the bottom

    @ViewBuilder
    private var buyBar: some View {
        if let chosen {
            VStack(spacing: 8) {
                Button { Task { await account.purchase(chosen) } } label: {
                    if account.purchasing != nil {
                        ProgressView().tint(Palette.onInk)
                    } else {
                        Text("购买 \(chosen.credits) 积分 · \(chosen.product.displayPrice)")
                    }
                }
                .buttonStyle(.capsule())
                .disabled(account.purchasing != nil)
                Text("一次性购买，不会自动续费。")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondary)
                    .padding(.bottom, 2)
            }
        }
    }

    private var signInBar: some View {
        VStack(spacing: 10) {
            if let failure {
                Text(failure).font(.footnote).foregroundStyle(Palette.removed).multilineTextAlignment(.center)
            }
            AppleSignInButton { failure = $0 }
            if account.phoneSignIn {
                Button { phoneSheet = true } label: {
                    Label("手机号登录", systemImage: "iphone")
                        .font(.system(size: 19, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 16)
                        .foregroundStyle(Palette.ink)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Capsule().strokeBorder(Palette.stroke))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Account

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("账号").foregroundStyle(Palette.ink)
                    Spacer(minLength: 0)
                    Text(account.user?.label ?? "").foregroundStyle(Palette.secondary).lineLimit(1)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 50)
                Divider().padding(.leading, 16)
                accountAction("退出登录", color: Palette.ink) { confirmingSignOut = true }
                Divider().padding(.leading, 16)
                accountAction("注销账号", color: Palette.removed) { confirmingDelete = true }
            }
            .cardSurface()
            if let failure {
                Text(failure).font(.footnote).foregroundStyle(Palette.removed).padding(.horizontal, 4)
            }
        }
    }

    private func accountAction(_ title: LocalizedStringKey, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .foregroundStyle(color)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

extension View {
    /// A surface on the grouped page: white, and in the dark a step up from the near-black page.
    func cardSurface(selected: Bool = false) -> some View { modifier(CardSurface(selected: selected)) }

    /// The page's one action, in a tray that floats over the end of its scroll: the system's
    /// glass from iOS 26, the page colour with an outline before. Nothing to do, no tray.
    @ViewBuilder
    func actionTray(shown: Bool, @ViewBuilder _ actions: () -> some View) -> some View {
        let shape = RoundedRectangle(cornerRadius: 34, style: .continuous)
        let tray = actions()
            .padding(12)
            .frame(maxWidth: 464)
        if !shown {
            self
        } else if #available(iOS 26.0, *) {
            safeAreaBar(edge: .bottom, spacing: 0) {
                tray.glassEffect(.regular, in: shape).padding(.horizontal, 12).padding(.bottom, 4)
            }
            .scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            safeAreaInset(edge: .bottom, spacing: 0) {
                tray.background(Palette.background, in: shape)
                    .overlay(shape.strokeBorder(Palette.stroke))
                    .shadow(color: .black.opacity(0.1), radius: 16, y: 6)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
        }
    }
}

struct CardSurface: ViewModifier {
    var selected = false
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        content
            .background(colorScheme == .dark ? Palette.field : Palette.background, in: shape)
            .overlay { shape.strokeBorder(selected ? Palette.ink : Palette.stroke.opacity(0.6), lineWidth: selected ? 2 : 1) }
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
        .frame(height: 50)
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

    private var canSignIn: Bool { e164 != nil && code.count >= 4 }

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
                        if signingIn { ProgressView().tint(Palette.onInk) } else { Text("登录") }
                    }
                    .buttonStyle(.capsule())
                    .disabled(!canSignIn || signingIn)
                    .opacity(canSignIn ? 1 : 0.35)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } footer: {
                    FishPocketPrivacyNote().padding(.top, 12)
                }
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

/// Before signing in: what this is, under the app's own icon.
struct FishPocketIntro: View {
    var body: some View {
        VStack(spacing: 0) {
            AppIconMark(size: 72)
                .shadow(color: .black.opacity(0.14), radius: 20, y: 10)
            Text("Fish Pocket 账号")
                .font(.largeTitle.bold())
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 16)
            Text("不用 API Key，也不用别家的账号。一份积分，对话、生图、语音都能用。")
                .font(.subheadline)
                .foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
    }
}

/// The balance, as the page's heading: the number is what the account holds.
struct FishPocketBalance: View {
    let balance: Int?
    /// The part that expires soonest (invite rewards).
    var expiring: (credits: Int, date: Date)?
    /// The conversation that opened the page ran out.
    var depleted = false
    /// Packs are sold on this page: running out says to buy one.
    var sells = true

    var body: some View {
        VStack(spacing: 2) {
            Text(depleted ? "额度已用完" : "剩余积分")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Palette.secondary)
            Group {
                if let balance { Text(balance, format: .number) } else { Text(verbatim: "—") }
            }
            .font(.system(size: 64, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(Palette.ink)
            .contentTransition(.numericText())
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            if let expiring, !depleted {
                Text("其中 \(expiring.credits) 积分将在 \(expiring.date.formatted(date: .abbreviated, time: .omitted)) 过期")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondary)
                    .multilineTextAlignment(.center)
            }
            if depleted, sells {
                Text("购买额度后，把刚才的消息重新发送一次。")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .animation(.snappy, value: balance)
        .accessibilityElement(children: .combine)
    }
}

/// What credits are spent on: chat, images and speech, each with its model and how it is charged.
/// Speech lists its features: input, reading aloud (when it is set to Volcengine), voice messages, calls.
struct FishPocketUses: View {
    /// What one credit buys of chat, once the server has said.
    var rate: (input: Int, output: Int)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("积分能用来")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.secondary)
                .padding(.horizontal, 4)
            VStack(spacing: 0) {
                use(.chat, Text("对话"), model: "DeepSeek-V4.1-Flash") {
                    note(rate.map {
                        Text("支持深度思考和工具调用。1 积分约 \($0.input) 个输入 Token 或 \($0.output) 个输出 Token。")
                    } ?? Text("支持深度思考和工具调用，按 Token 扣积分。"))
                }
                Divider().padding(.leading, 64)
                use(.imageGen, Text("生图"), model: "Seedream 5.5") {
                    note(Text("按生成的张数扣，图越大、参考图越多扣得越多；没生成出来的不扣。"))
                }
                Divider().padding(.leading, 64)
                use(.voice, Text("语音"), model: String(localized: "火山引擎")) {
                    VStack(alignment: .leading, spacing: 6) {
                        feature(Text("语音输入"), Text("说话转成文字，按说话时长扣。"))
                        feature(Text("朗读"), Text("用火山引擎的声音念回复，按字数扣。"))
                        feature(Text("语音消息"), Text("AI 回一条语音，按念的字数扣。"))
                        feature(Text("语音通话"), Text("和 AI 打电话，听你说按时长扣，念回答按字数扣。"))
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
    }

    private func use(_ icon: ExploreGlyph.Kind, _ title: Text, model: String, @ViewBuilder _ detail: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ExploreGlyph(kind: icon, size: 34)
                .padding(.top, -5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    title.font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                    Text(verbatim: model)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                detail()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private func note(_ text: Text) -> some View {
        text
            .font(.footnote)
            .foregroundStyle(Palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// One of the speech features: its name, then what it does and how it is charged. The names
    /// share one column, as wide as the widest of them in this language, so the details line up.
    private func feature(_ name: Text, _ detail: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            ZStack(alignment: .leading) {
                Group { Text("语音输入"); Text("朗读"); Text("语音消息"); Text("语音通话") }.hidden()
                name.foregroundStyle(Palette.ink)
            }
            .fontWeight(.medium)
            .fixedSize()
            detail
                .foregroundStyle(Palette.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote)
    }
}

/// How credits are charged and kept, the same whatever they are spent on.
struct FishPocketRules: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            rule("gauge.with.dots.needle.33percent", Text("用多少扣多少"), Text("不用不扣，没有月费。"))
            rule("infinity", Text("购买的积分不会过期"), Text("没有有效期，什么时候用完都可以。"))
            // Images and speech go through Fish Pocket only when chosen (no automatic switching).
            rule("arrow.triangle.branch", Text("一个余额，处处通用"), Text("生图和语音在各自的设置里选「Fish Pocket 账号」后，从同一个余额里扣。"))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func rule(_ icon: String, _ title: Text, _ detail: Text) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Palette.ink)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                title.font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                detail
                    .font(.footnote)
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Where the packs would be in a TestFlight build, which does not sell them (`FishPocketAccount.canPurchase`).
private struct FishPocketNoPurchaseNote: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "info.circle")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Palette.ink)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("TestFlight 版本不能购买额度").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                Text("请在 App Store 版本里购买，额度在两个版本里通用。")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .combine)
    }
}

/// One pack: the credits, large, over the App Store's price.
struct FishPocketPackTile: View {
    let pack: FishPocketPack
    /// How much less a credit costs here than in the smallest pack, in percent.
    var saving: Int?
    /// nil before signing in: the tile is then on show only.
    var selected: Bool?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(pack.credits, format: .number)
                        .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                        .minimumScaleFactor(0.6)
                    Spacer(minLength: 0)
                    if let selected {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(selected ? Palette.ink : Palette.faint)
                    }
                }
                Text("积分")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondary)
                Text(pack.product.displayPrice)
                    .font(.headline.monospacedDigit())
                    .minimumScaleFactor(0.7)
                    .padding(.top, 16)
            }
            .lineLimit(1)
            .foregroundStyle(Palette.ink)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(selected: selected == true)
            // The saving rides the tile's top edge, clear of whatever the price's length is.
            .overlay(alignment: .topLeading) {
                if let saving {
                    Text("省 \(saving.formatted(.percent))")
                        .font(.caption2.weight(.bold))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .foregroundStyle(Palette.onInk)
                        .background(Palette.ink, in: Capsule())
                        .padding(.leading, 14)
                        .alignmentGuide(.top) { $0.height * 0.6 }
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(PressableCardStyle())
        .disabled(selected == nil)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected == true ? .isSelected : [])
    }
}

/// A conversation on Fish Pocket credits ran out: the same page, about buying more.
struct FishPocketTopUpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            FishPocketPage(topUp: true).closeButton(dismiss)
        }
        .presentationDetents([.large])
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
