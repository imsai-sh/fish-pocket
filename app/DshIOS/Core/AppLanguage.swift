import Foundation

/// The language the UI is showing: the first of the reader's languages the app is translated
/// into (Settings → Fish Pocket → Language, else the system's), English when none is.
/// Engine texts (`{en, zh, …}` plugin and schema strings) and date formats follow it too,
/// so a screen never mixes the app's language with another.
enum AppLanguage {
    /// `zh-Hans`, `en`…: a localization in the bundle.
    static var code: String { Bundle.main.preferredLocalizations.first ?? "en" }

    static var isChinese: Bool { code.lowercased().hasPrefix("zh") }

    /// `zh-Hant`: written for Taiwan, and what Hong Kong and Macau readers get too (iOS falls back
    /// from `zh-HK` to it).
    static var isTraditionalChinese: Bool { code.lowercased().hasPrefix("zh-hant") }

    static var locale: Locale { Locale(identifier: code) }

    /// The languages the settings picker offers: the bundle's localizations, each named in itself.
    static let choices: [(code: String, name: String)] = [
        ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("en", "English"), ("es", "Español"), ("ja", "日本語"),
        ("ko", "한국어"),
    ]

    /// The language chosen for this app, `nil` when it follows the system. It is the same
    /// `AppleLanguages` entry that Settings → Fish Pocket → Language writes, read from the app's own
    /// domain so the system's list does not count; it takes effect the next time the app starts.
    static var chosen: String? {
        get {
            guard let id = Bundle.main.bundleIdentifier,
                  let first = (UserDefaults.standard.persistentDomain(forName: id)?["AppleLanguages"] as? [String])?.first
            else { return nil }
            let language = first.lowercased()
            if language.hasPrefix("zh") { return isTraditional(language) ? "zh-Hant" : "zh-Hans" }
            return choices.first { language.hasPrefix($0.code.lowercased()) }?.code
        }
        set {
            if let newValue { UserDefaults.standard.set([newValue], forKey: "AppleLanguages") }
            else { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        }
    }

    /// `zh-hans` → `zh`: the key the engine's `{en, zh, …}` texts use.
    static var primary: String { String(code.lowercased().prefix { $0 != "-" && $0 != "_" }) }

    /// The Chinese text of an engine's `{en, zh, …}` object: a Traditional one (`zh-Hant`, `zh-TW`,
    /// `zh-HK`) first for a Traditional reader, else the plain `zh` (Simplified), which they can read.
    static func chinese(in object: [String: JSON]) -> String? {
        let keys = object.keys.filter { $0.lowercased().hasPrefix("zh") }
        let traditional = keys.first { isTraditional($0.lowercased()) }
        let simplified = keys.first { !isTraditional($0.lowercased()) }
        let order = isTraditionalChinese ? [traditional, simplified] : [simplified, traditional]
        return order.compactMap { $0 }.lazy.compactMap { object[$0]?.string }.first
    }

    /// `zh-hant`, `zh-tw`, `zh_hk`, `zh-hant-mo`… but not `zh-hans-hk`: a lowercased Chinese tag.
    private static func isTraditional(_ tag: String) -> Bool {
        if tag.contains("hans") { return false }
        return tag.contains("hant") || ["tw", "hk", "mo"].contains { tag.hasSuffix("-\($0)") || tag.hasSuffix("_\($0)") }
    }
}
