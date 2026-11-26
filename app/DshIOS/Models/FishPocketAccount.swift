import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import Security
import StoreKit
import UIKit

/// One credit pack on sale: the App Store product and the credits it grants.
struct FishPocketPack: Identifiable {
    let product: Product
    let credits: Int
    var id: String { product.id }
}

/// Invites: this account's code and how many it has brought in, and whether it may still enter
/// someone else's (`GET /v1/invites`). The rules are the server's; the app only shows them.
struct FishPocketInvites: Equatable {
    enum Redeem: Equatable {
        /// May enter a code, until the deadline (none for accounts from before invites opened).
        case open(deadline: Date?)
        case used
        case closed
    }

    let code: String
    let invited: Int
    let limit: Int
    /// Credits each side gets, and how many days they last.
    let reward: Int
    let rewardDays: Int
    let redeem: Redeem

    init?(_ json: JSON) {
        guard let code = json["code"].string, !code.isEmpty else { return nil }
        self.code = code
        invited = json["invited"].int ?? 0
        limit = json["limit"].int ?? 0
        reward = json["reward"].int ?? 0
        rewardDays = json["rewardDays"].int ?? 0
        switch json["redeem"]["status"].string {
        case "open": redeem = .open(deadline: json["redeem"]["deadline"].double.map { Date(timeIntervalSince1970: $0 / 1000) })
        case "used": redeem = .used
        default: redeem = .closed
        }
    }
}

/// The Fish Pocket account: sign-in (Apple or a phone code), the credit balance,
/// credit packs bought through In-App Purchase, and the runtime key the
/// engine's `fish-pocket` model route spends credits with.
///
/// The session (1 h) and refresh token (30 d) stay in the Keychain and only go
/// to the Fish Pocket API. The engine gets the runtime key alone, through the
/// credentials service, as it gets a DeepSeek API key.
@MainActor
@Observable
final class FishPocketAccount {
    private enum Stored {
        static let session = "session"
        static let refresh = "refresh"
        static let runtimeKey = "runtime-key"
    }

    struct User: Equatable {
        let uid: String
        let provider: String
        let name: String?
        let email: String?
        let phoneMasked: String?

        init(_ json: JSON) {
            uid = json["uid"].string ?? ""
            provider = json["provider"].string ?? ""
            name = json["name"].string
            email = json["email"].string
            phoneMasked = json["phoneMasked"].string
        }

        /// What identifies the account on screen.
        var label: String {
            if let name, !name.isEmpty { return name }
            if let phoneMasked { return phoneMasked }
            if let email { return email }
            return provider == "apple" ? String(localized: "Apple 账号") : String(localized: "已登录")
        }
    }

    @ObservationIgnored private let engine: EngineClient
    @ObservationIgnored private let http: FishPocketHTTP?

    private(set) var signedIn: Bool
    private(set) var user: User?
    /// Spendable credits; nil until read.
    private(set) var balance: Int?
    /// The part of the balance that expires soonest (invite rewards), when any does within a year.
    private(set) var expiring: (credits: Int, date: Date)?
    /// Invites, once read; nil while the service has them off.
    private(set) var invites: FishPocketInvites?
    /// The server credits this account's sandbox purchases.
    private(set) var sandboxPurchases = false
    private(set) var packs: [FishPocketPack] = []
    private(set) var packsFailed = false
    /// What one credit buys, as the server states it with the packs: tokens of input, and of output.
    private(set) var tokensPerCredit: (input: Int, output: Int)?
    /// A pack purchase in progress.
    private(set) var purchasing: String?
    /// The packs, about buying more: opened from a conversation's out-of-balance card.
    var quotaPrompt = false
    var toast: String?
    /// This device's runtime key changed (issued, replaced, or gone on signing out).
    @ObservationIgnored var onRuntimeKeyChange: (() -> Void)?

    @ObservationIgnored private var transactionTask: Task<Void, Never>?
    @ObservationIgnored private var refreshing: Task<String?, Never>?
    /// Transactions being redeemed: `Transaction.updates` and `.unfinished` both deliver them at launch.
    @ObservationIgnored private var redeeming: Set<UInt64> = []

    init(engine: EngineClient) {
        self.engine = engine
        http = FishPocketAPI.baseURL.map(FishPocketHTTP.init(base:))
        signedIn = FishPocketKeychain.read(Stored.refresh) != nil
    }

    var available: Bool { http != nil }

    /// This device's runtime key, while signed in: the engine spends credits with it, and so does
    /// the speech relay (`VolcCredential.fishPocket`).
    nonisolated static var storedRuntimeKey: String? { FishPocketKeychain.read(Stored.runtimeKey) }

    /// A call anyone may make, sent with the account when signed in (a plugin report): a session
    /// that can't be renewed any more goes out without one rather than failing the call.
    func sendAsUser(_ method: String, _ path: String, body: JSON? = nil) async throws -> JSON {
        guard let http else { throw FishPocketError(status: 0, code: "unavailable", message: "") }
        guard signedIn else { return try await http.send(method, path, body: body) }
        do {
            return try await authorized(method, path, body: body)
        } catch let error as FishPocketError where error.status == 401 || error.code == "account_deleted" {
            return try await http.send(method, path, body: body)
        }
    }

    // MARK: Start

    /// On each engine connection: make sure the engine holds this device's
    /// runtime key, read the balance and redeem purchases left unfinished.
    func start() async {
        guard available else { return }
        if transactionTask == nil {
            transactionTask = Task { [weak self] in
                for await update in Transaction.updates { await self?.handle(update) }
            }
        }
        guard signedIn else { return }
        await ensureRuntimeKey()
        await refresh()
        for await unfinished in Transaction.unfinished { await handle(unfinished) }
    }

    // MARK: Sign-in

    /// The nonce for one Sign in with Apple request: the raw value goes to the
    /// server, its SHA-256 to Apple, which signs it into the identity token.
    nonisolated static func appleNonce() -> (raw: String, hashed: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let raw = base64url(Data(bytes))
        // The server compares the token's nonce claim with base64url(SHA-256(raw)), unpadded.
        let hashed = base64url(Data(SHA256.hash(data: Data(raw.utf8))))
        return (raw, hashed)
    }

    nonisolated private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    func signInWithApple(_ credential: ASAuthorizationAppleIDCredential, rawNonce: String) async throws {
        guard let http, let tokenData = credential.identityToken, let token = String(data: tokenData, encoding: .utf8) else {
            throw FishPocketError(status: 0, code: "invalid_credential", message: String(localized: "没有拿到 Apple 登录凭证，请重试。"))
        }
        var body: [String: JSON] = ["identityToken": .string(token), "rawNonce": .string(rawNonce)]
        // Apple hands out the name and email on the first sign-in only.
        if let name = credential.fullName.flatMap({ PersonNameComponentsFormatter().string(from: $0) }), !name.isEmpty {
            body["fullName"] = .string(name)
        }
        if let email = credential.email { body["email"] = .string(email) }
        try await completeSignIn(http.send("POST", "v1/auth/apple", body: .object(body)))
    }

    /// Ask for a code; returns when another may be requested.
    func sendPhoneCode(_ phone: String) async throws -> Date {
        guard let http else { throw FishPocketError(status: 0, code: "unavailable", message: "") }
        let reply = try await http.send("POST", "v1/auth/phone/code", body: ["phone": .string(phone)])
        return reply["resendAt"].double.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date().addingTimeInterval(60)
    }

    func signInWithPhone(_ phone: String, code: String) async throws {
        guard let http else { throw FishPocketError(status: 0, code: "unavailable", message: "") }
        try await completeSignIn(http.send("POST", "v1/auth/phone", body: ["phone": .string(phone), "code": .string(code)]))
    }

    private func completeSignIn(_ reply: JSON) async throws {
        guard let session = reply["sessionToken"].string, let refreshToken = reply["refreshToken"].string else {
            throw FishPocketError(status: 0, code: "invalid_reply", message: String(localized: "登录失败，请重试。"))
        }
        FishPocketKeychain.write(Stored.session, session)
        FishPocketKeychain.write(Stored.refresh, refreshToken)
        do {
            try await issueRuntimeKey()
        } catch {
            // Without a runtime key the account is of no use here: do not half sign in.
            FishPocketKeychain.write(Stored.session, nil)
            FishPocketKeychain.write(Stored.refresh, nil)
            throw error
        }
        user = User(reply["user"])
        signedIn = true
        await refresh()
        // Purchases made before signing in are credited now.
        for await unfinished in Transaction.unfinished { await handle(unfinished) }
    }

    /// A fresh runtime key for this device. The engine gets it now if it is up; otherwise
    /// `ensureRuntimeKey` hands it over on the next connection.
    private func issueRuntimeKey() async throws {
        let reply = try await authorized("POST", "v1/runtime-keys", body: ["label": .string(UIDeviceName.current)])
        guard let key = reply["runtimeKey"].string else {
            throw FishPocketError(status: 0, code: "invalid_reply", message: String(localized: "登录失败，请重试。"))
        }
        let previous = FishPocketKeychain.read(Stored.runtimeKey)
        FishPocketKeychain.write(Stored.runtimeKey, key)
        VolcSpeech.shared.reloadFishPocketKey()
        onRuntimeKeyChange?()
        _ = try? await engine.call("credentials/set", ["ref": .string(FishPocketAPI.runtimeKeyRef), "value": .string(key)])
        // A replaced key is revoked so keys do not pile up on the server (best effort).
        if let previous, previous != key {
            _ = try? await authorized("POST", "v1/runtime-keys/revoke", body: ["runtimeKey": .string(previous)])
        }
    }

    /// The gateway refused this device's runtime key (AUTH): issue a new one. A session that
    /// cannot be renewed signs the account out, which is then the user's cue to sign in again.
    func repairRuntimeKey() async {
        guard signedIn else { return }
        do {
            try await issueRuntimeKey()
            toast = String(localized: "已重新连接 Fish Pocket")
        } catch {
            if signedIn { toast = String(localized: "暂时无法连接 Fish Pocket，请稍后再试") }
        }
    }

    /// The engine's data can be reset without the Keychain: give it the key again, or a new one.
    private func ensureRuntimeKey() async {
        let described = try? await engine.call("credentials/describe", ["refs": [.string(FishPocketAPI.runtimeKeyRef)]])
        let configured = described?.array.first?["configured"].bool ?? described?[FishPocketAPI.runtimeKeyRef]["configured"].bool
        guard configured == false else { return }
        if let key = FishPocketKeychain.read(Stored.runtimeKey) {
            _ = try? await engine.call("credentials/set", ["ref": .string(FishPocketAPI.runtimeKeyRef), "value": .string(key)])
        } else {
            try? await issueRuntimeKey()
        }
    }

    // MARK: Account

    func refresh() async {
        guard signedIn, let reply = try? await authorized("GET", "v1/me") else { return }
        user = User(reply["user"])
        balance = reply["balance"]["total"].int
        expiring = Self.soonestExpiring(reply["balance"]["buckets"].array)
        sandboxPurchases = reply["sandboxPurchases"].bool ?? false
    }

    /// Purchased credits last for decades; what runs out within a year is a reward.
    private static func soonestExpiring(_ buckets: [JSON]) -> (credits: Int, date: Date)? {
        let horizon = Date().addingTimeInterval(365 * 24 * 3600)
        let dated = buckets.compactMap { bucket -> (Int, Date)? in
            guard let credits = bucket["remaining"].int, credits > 0, let ms = bucket["expiresAt"].double else { return nil }
            let date = Date(timeIntervalSince1970: ms / 1000)
            return date < horizon ? (credits, date) : nil
        }
        guard let soonest = dated.map(\.1).min() else { return nil }
        // Rewards issued the same day expire within the same day: one line for them.
        let day = Calendar.current.startOfDay(for: soonest)
        let credits = dated.filter { Calendar.current.startOfDay(for: $0.1) == day }.reduce(0) { $0 + $1.0 }
        return (credits, soonest)
    }

    // MARK: Invites

    func loadInvites() async {
        guard signedIn else { return }
        do {
            invites = FishPocketInvites(try await authorized("GET", "v1/invites"))
        } catch let error as FishPocketError where error.code == "unavailable" || error.status == 404 {
            // Off on the service (or a service from before invites): no invite page.
            invites = nil
        } catch {
            // A failed read keeps what was shown.
        }
    }

    /// Enter someone's code: both accounts get the reward. Throws with a message to show.
    func redeemInvite(_ code: String) async throws {
        do {
            let reply = try await authorized("POST", "v1/invites/redeem", body: ["code": .string(code)])
            if let granted = reply["granted"].int { toast = String(localized: "已到账 \(granted) 积分") }
            Haptics.success()
        } catch let error as FishPocketError {
            await loadInvites()
            throw FishPocketError(status: error.status, code: error.code, message: Self.inviteMessage(error))
        }
        async let balance: Void = refresh()
        async let invites: Void = loadInvites()
        _ = await (balance, invites)
    }

    private static func inviteMessage(_ error: FishPocketError) -> String {
        switch error.code {
        case "invalid_code": String(localized: "邀请码不存在，请检查后再试。")
        case "own_code": String(localized: "不能填自己的邀请码。")
        case "mutual": String(localized: "对方已经填过你的邀请码，不能互相填写。")
        case "inviter_full": String(localized: "这个邀请码的邀请人数已满。")
        case "already_redeemed": String(localized: "你已经填过邀请码了。")
        case "not_eligible": String(localized: "邀请码只能在注册后 7 天内填写。")
        case "network": error.message
        default: String(localized: "暂时无法领取，请稍后再试。")
        }
    }

    /// A purchase in a TestFlight build is a sandbox one. The service credits those only to
    /// the accounts it names (App Review's, which buys in the sandbox too), so packs are sold
    /// there to them alone. Signing in is open to everyone: credits bought in the App Store
    /// version are spent here as well.
    var canPurchase: Bool { AppDistribution.channel != .testFlight || sandboxPurchases }

    /// Sign out this device: the server revokes its session and runtime key, the engine forgets the key.
    func signOut() async {
        if FishPocketKeychain.read(Stored.refresh) != nil {
            // Built per attempt: a renewal in between rotates the refresh token to revoke.
            _ = try? await authorized("POST", "v1/auth/logout") {
                var body: [String: JSON] = [:]
                if let refresh = FishPocketKeychain.read(Stored.refresh) { body["refreshToken"] = .string(refresh) }
                if let key = FishPocketKeychain.read(Stored.runtimeKey) { body["runtimeKey"] = .string(key) }
                return .object(body)
            }
        }
        await forget()
    }

    /// Delete the account; remaining credits are forfeited.
    func deleteAccount() async throws {
        _ = try await authorized("DELETE", "v1/me")
        await forget()
    }

    private func forget() async {
        FishPocketKeychain.write(Stored.session, nil)
        FishPocketKeychain.write(Stored.refresh, nil)
        FishPocketKeychain.write(Stored.runtimeKey, nil)
        VolcSpeech.shared.reloadFishPocketKey()
        onRuntimeKeyChange?()
        signedIn = false
        user = nil
        balance = nil
        expiring = nil
        invites = nil
        sandboxPurchases = false
        quotaPrompt = false
        _ = try? await engine.call("credentials/unset", ["ref": .string(FishPocketAPI.runtimeKeyRef)])
    }

    // MARK: Sessions

    /// A call with the session, renewed once through the refresh token when it has expired.
    @discardableResult
    private func authorized(_ method: String, _ path: String, body: JSON? = nil) async throws -> JSON {
        try await authorized(method, path) { body }
    }

    /// A read with the session (the records page).
    func read(_ path: String, query: [URLQueryItem] = []) async throws -> JSON {
        try await authorized("GET", path, query: query) { nil }
    }

    /// `body` is built for each attempt, after any renewal.
    @discardableResult
    private func authorized(_ method: String, _ path: String, query: [URLQueryItem] = [], body: () -> JSON?) async throws -> JSON {
        guard let http else { throw FishPocketError(status: 0, code: "unavailable", message: "") }
        let session = FishPocketKeychain.read(Stored.session)
        do {
            return try await http.send(method, path, query: query, body: body(), bearer: session)
        } catch let error as FishPocketError where error.status == 401 {
            guard let renewed = await renewSession() else { throw error }
            return try await http.send(method, path, query: query, body: body(), bearer: renewed)
        } catch let error as FishPocketError where error.code == "account_deleted" {
            // Deleted on another device: nothing here can work any more.
            await signedOutRemotely()
            throw error
        }
    }

    /// One refresh at a time: concurrent callers share it (the refresh token rotates on use).
    private func renewSession() async -> String? {
        if let refreshing { return await refreshing.value }
        let task = Task<String?, Never> { [http] in
            guard let http, let refresh = FishPocketKeychain.read(Stored.refresh) else { return nil }
            do {
                let reply = try await http.send("POST", "v1/auth/refresh", body: ["refreshToken": .string(refresh)])
                guard let session = reply["sessionToken"].string, let next = reply["refreshToken"].string,
                      // Signed out (or in again) meanwhile: these tokens belong to nobody now.
                      FishPocketKeychain.read(Stored.refresh) == refresh else { return nil }
                FishPocketKeychain.write(Stored.session, session)
                FishPocketKeychain.write(Stored.refresh, next)
                return session
            } catch let error as FishPocketError where [401, 403].contains(error.status) {
                await self.signedOutRemotely()
                return nil
            } catch {
                return nil
            }
        }
        refreshing = task
        let session = await task.value
        refreshing = nil
        return session
    }

    /// The refresh token stopped working (expired, revoked, account deleted elsewhere).
    private func signedOutRemotely() async {
        await forget()
        toast = String(localized: "Fish Pocket 登录已失效，请重新登录")
    }

    // MARK: Sign-in options

    /// Whether phone sign-in is offered beside Sign in with Apple. The service decides, so it can
    /// be closed and opened again without an update; until it says so (or when it cannot be
    /// reached) there is none. Closed, it still lets App Review's demo number through.
    private(set) var phoneSignIn = false

    func loadSignInOptions() async {
        guard let http, let reply = try? await http.send("GET", "v1/auth/options") else { return }
        phoneSignIn = reply["phone"].bool ?? false
    }

    // MARK: Credit packs

    func loadPacks() async {
        guard let http else { return }
        do {
            let reply = try await http.send("GET", "v1/products")
            // The first rate is the model this route offers.
            if let rate = reply["rates"].array.first, let input = rate["inputTokensPerCredit"].int,
               let output = rate["outputTokensPerCredit"].int, input > 0, output > 0 {
                tokensPerCredit = (input, output)
            }
            let offers = reply["products"].array.compactMap { item -> (String, Int)? in
                guard let id = item["appleProductId"].string, let credits = item["credits"].int else { return nil }
                return (id, credits)
            }
            let products = try await Product.products(for: offers.map(\.0))
            packs = offers.compactMap { id, credits in
                products.first { $0.id == id }.map { FishPocketPack(product: $0, credits: credits) }
            }
            .sorted { $0.credits < $1.credits }
            packsFailed = packs.isEmpty
        } catch {
            packsFailed = true
        }
    }

    /// Buy a pack. Credits land once the server has verified the transaction;
    /// only then is the transaction finished, so a failure retries at next launch.
    func purchase(_ pack: FishPocketPack) async {
        guard signedIn, canPurchase, purchasing == nil else { return }
        purchasing = pack.id
        defer { purchasing = nil }
        do {
            switch try await pack.product.purchase() {
            case .success(let verification):
                await handle(verification)
            case .pending:
                toast = String(localized: "购买待确认，确认后额度会自动到账")
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            toast = String(localized: "购买未完成，请重试")
        }
    }

    /// Redeem one transaction with the server, then finish it. Unverified
    /// transactions and other products are left alone; signed out, it waits.
    private func handle(_ verification: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = verification, transaction.productType == .consumable, signedIn,
              !redeeming.contains(transaction.id) else { return }
        redeeming.insert(transaction.id)
        defer { redeeming.remove(transaction.id) }
        do {
            let reply = try await authorized("POST", "v1/purchases/apple", body: ["signedTransaction": .string(verification.jwsRepresentation)])
            await transaction.finish()
            if let total = reply["balance"].int { balance = total }
            if let granted = reply["granted"].int, granted > 0, reply["alreadyProcessed"].bool != true {
                toast = String(localized: "已到账 \(granted) 积分")
                quotaPrompt = false
            }
        } catch let error as FishPocketError where error.status == 400 && transaction.environment != .production {
            // A sandbox purchase (a development or TestFlight build) the server turned down: the
            // production service credits only real ones (and App Review's demo account). Nothing
            // was paid and it never goes through, so it is finished quietly: left unfinished,
            // StoreKit handed it back at every launch, and every launch said it would retry.
            await transaction.finish()
        } catch {
            // Left unfinished: StoreKit hands it back at the next launch or sign-in, and the
            // server's redemption is idempotent. Every consumable here is a Fish Pocket pack,
            // so even "unknown product" (a catalog not yet seeded) must not drop a paid purchase.
            toast = String(localized: "额度暂未到账，稍后会自动重试")
        }
    }

    /// Whether a conversation that ran out of balance may offer Fish Pocket credits: only in the
    /// App Store build, where they can be bought (TestFlight cannot use in-app purchase).
    var offeredOnQuota: Bool { available && AppDistribution.channel == .appStore }
}

/// The device name shown next to its runtime key on the server (e.g. "iPhone").
enum UIDeviceName {
    @MainActor static var current: String { UIDevice.current.model }
}
