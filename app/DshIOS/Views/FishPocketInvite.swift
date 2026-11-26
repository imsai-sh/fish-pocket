import SwiftUI

/// Fish Pocket 账号 → 邀请好友: this account's invite code to share, and a place to enter a friend's.
/// When someone enters a code, both accounts get the reward. Every rule (the amount, the limit, who
/// may still enter a code) is the service's: the page shows what `GET /v1/invites` says.
struct FishPocketInvitePage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.systemLists) private var systemLists
    @State private var entry = ""
    @State private var redeeming = false
    @State private var failure: String?
    @State private var copied = false
    @FocusState private var entryFocused: Bool

    private var account: FishPocketAccount { app.fishPocket }

    /// What was typed, as the service reads it: case, spaces and dashes don't matter.
    private var normalized: String {
        entry.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if let invites = account.invites {
                    hero(invites)
                    codeCard(invites)
                    switch invites.redeem {
                    case .open(let deadline): redeemCard(deadline)
                    case .used: usedNote
                    case .closed: EmptyView()
                    }
                    rules(invites)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
            .animation(.snappy, value: account.invites)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(systemLists ? Color(.systemGroupedBackground) : Palette.grouped)
        .actionTray(shown: account.invites.map { $0.invited < $0.limit } ?? false) {
            if let invites = account.invites { shareButton(invites) }
        }
        .navigationTitle("邀请好友")
        .navigationBarTitleDisplayMode(.inline)
        .task { await account.loadInvites() }
        .refreshable { await account.loadInvites() }
    }

    // MARK: Parts

    private func hero(_ invites: FishPocketInvites) -> some View {
        VStack(spacing: 0) {
            Image(systemName: "gift.fill")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(Palette.ink)
                .frame(width: 84, height: 84)
                .background(Palette.ink.opacity(0.06), in: Circle())
                .accessibilityHidden(true)
            Text("邀请好友，各得 \(invites.reward) 积分")
                .font(.title2.bold())
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 16)
            Text("好友注册 Fish Pocket 账号后，填写你的邀请码，你们都能得到 \(invites.reward) 积分。")
                .font(.subheadline)
                .foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.horizontal, 8)
    }

    private func codeCard(_ invites: FishPocketInvites) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Text("我的邀请码")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.secondary)
                Text(verbatim: invites.code)
                    .font(.system(size: 36, weight: .bold, design: .monospaced))
                    .tracking(6)
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Button {
                    UIPasteboard.general.string = invites.code
                    Haptics.tap()
                    withAnimation(.snappy) { copied = true }
                } label: {
                    Label(copied ? "已复制" : "复制邀请码", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.subheadline.weight(.medium))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.capsule(.secondary, height: 36, fill: false))
                .padding(.top, 4)
                .task(id: copied) {
                    guard copied else { return }
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation(.snappy) { copied = false }
                }
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 16)
            Divider().padding(.leading, 16)
            HStack {
                Text("已邀请").foregroundStyle(Palette.ink)
                Spacer(minLength: 12)
                Text("\(invites.invited) / \(invites.limit) 人")
                    .monospacedDigit()
                    .foregroundStyle(Palette.secondary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
        }
        .frame(maxWidth: .infinity)
        .cardSurface()
    }

    private func shareButton(_ invites: FishPocketInvites) -> some View {
        // The App Store, not a page of ours: the friend types the code in after signing up.
        ShareLink(item: String(localized: "我在用 Fish Pocket，在 iPhone 上就能和 DeepSeek 对话，还能让它帮我干活。下载后登录 Fish Pocket 账号，在「邀请好友」里填我的邀请码 \(invites.code)，我们各得 \(invites.reward) 积分。\n\(AppLinks.appStore.absoluteString)")) {
            Label("分享邀请", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(.capsule())
    }

    private func redeemCard(_ deadline: Date?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("填写好友的邀请码")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.secondary)
                .padding(.horizontal, 4)
            HStack(spacing: 10) {
                TextField("邀请码", text: $entry)
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($entryFocused)
                    .onSubmit { Task { await redeem() } }
                    .onChange(of: entry) { failure = nil }
                Button { Task { await redeem() } } label: {
                    if redeeming { ProgressView().tint(Palette.onInk) } else { Text("领取") }
                }
                .buttonStyle(.capsule(height: 40, fill: false))
                .disabled(normalized.count != 6 || redeeming)
                .opacity(normalized.count == 6 ? 1 : 0.35)
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .frame(minHeight: 56)
            .cardSurface()
            Group {
                if let failure {
                    Text(failure).foregroundStyle(Palette.removed)
                } else if let deadline {
                    Text("新注册的账号要在 \(deadline.formatted(date: .abbreviated, time: .shortened)) 前填写，每个账号只能填一次。")
                        .foregroundStyle(Palette.secondary)
                } else {
                    Text("每个账号只能填一次。").foregroundStyle(Palette.secondary)
                }
            }
            .font(.footnote)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
        }
    }

    private var usedNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Palette.ink)
                    .accessibilityHidden(true)
                Text("你已经填过好友的邀请码").foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
            .cardSurface()
            if let failure {
                Text(failure).font(.footnote).foregroundStyle(Palette.removed).padding(.horizontal, 4)
            }
        }
    }

    private func rules(_ invites: FishPocketInvites) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("规则").font(.footnote.weight(.semibold))
            Group {
                Text("• 好友填了你的邀请码，你们立刻各得 \(invites.reward) 积分。")
                Text("• 每个邀请码最多邀请 \(invites.limit) 人，满了就不能再用。")
                Text("• 每个账号只能填一次邀请码，新注册的账号要在 7 天内填写；不能和对方互相填写。")
                Text("• 奖励的积分 \(invites.rewardDays) 天内有效，对话时先扣它。")
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote)
        .foregroundStyle(Palette.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    private func redeem() async {
        guard normalized.count == 6, !redeeming else { return }
        redeeming = true
        failure = nil
        defer { redeeming = false }
        do {
            try await account.redeemInvite(normalized)
            entry = ""
            entryFocused = false
        } catch {
            failure = error.localizedDescription
            Haptics.error()
        }
    }
}

/// The way into 邀请好友 on the Fish Pocket account page.
struct FishPocketInviteRow: View {
    let invites: FishPocketInvites

    var body: some View {
        NavigationLink {
            FishPocketInvitePage()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "gift")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("邀请好友").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                    Group {
                        if case .open = invites.redeem {
                            Text("邀请好友或填写好友的邀请码，双方各得 \(invites.reward) 积分。")
                        } else {
                            Text("好友填了你的邀请码，你们各得 \(invites.reward) 积分。")
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.faint)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(PressableCardStyle())
    }
}
