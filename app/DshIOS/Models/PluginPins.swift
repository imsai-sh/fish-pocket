import Foundation

/// Plugins the app keeps at one tested version (`engine/plugins/ios-host/pins.json`, shipped in the
/// engine bundle). The engine refuses every other version; the app reads the same file to say so
/// before an install starts, and turns the engine's refusal into a sentence.
enum PluginPins {
    private static let versions: [String: String] = {
        let url = EnginePaths.real("/opt/dsh/nodejs-project/plugins/ios-host/pins.json")
        guard let data = try? Data(contentsOf: url),
              let pins = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return [:] }
        return pins.compactMapValues { $0["version"] as? String }
    }()

    /// The version a pinned package is kept at; nil for any other package.
    static func version(of package: String) -> String? { versions[package] }

    /// The note for installing `version` of `package`, when the app keeps it at another one.
    static func note(package: String, version: String) -> String? {
        guard let pinned = self.version(of: package), version != pinned else { return nil }
        return String(localized: "Fish Pocket 目前固定使用 \(package) \(pinned)，不能安装 \(version)。")
    }

    /// The engine's refusal (`pinRefusal` in pins.mjs) as a sentence; nil for any other text.
    static func refusal(_ text: String?) -> String? {
        guard let text, let match = text.firstMatch(of: /^(\S+) is pinned to (\S+) in Fish Pocket; (.+) cannot be installed\.$/) else { return nil }
        let wanted = String(match.3) == "default branch" ? String(localized: "默认分支") : String(match.3)
        return String(localized: "Fish Pocket 目前固定使用 \(String(match.1)) \(String(match.2))，不能安装 \(wanted)。")
    }
}
