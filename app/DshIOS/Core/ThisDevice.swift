import UIKit

/// What this device is, for naming it next to the account's computers: iPhone, iPhone Duo
/// or iPad. Anything not told apart (an iPad app on a Mac, say) is just 手机.
enum ThisDevice {
    /// Model identifiers of iPhone Duo. Apple gives no API that says a phone folds, and the
    /// fold only shows itself while the device is partly open, so the model is what tells.
    private static let duoModels: Set<String> = ["iPhone19,4"]

    @MainActor static var name: String {
        if ProcessInfo.processInfo.isiOSAppOnMac { return String(localized: "手机") }
        switch UIDevice.current.userInterfaceIdiom {
        case .pad: return "iPad"
        case .phone: return duoModels.contains(model) ? "iPhone Duo" : "iPhone"
        default: return String(localized: "手机")
        }
    }

    @MainActor static var symbol: String { name == "iPad" ? "ipad" : "iphone" }

    /// `iPhone18,1` and the like. A simulator's `machine` is the Mac's architecture: the
    /// device it stands in for is in the environment.
    static var model: String {
        if let simulated = simulatedModel { return simulated }
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) {
            String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }

    static var simulatedModel: String? { ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] }
}
