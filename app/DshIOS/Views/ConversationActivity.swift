import SwiftUI

/// What the agent has going on beside the conversation, floating over its foot: the web page it
/// works in and its background jobs. One tap opens either, without a trip to the top bar. Each shows
/// only while there is something to see; a running one carries the green dot.
struct ConversationActivity: View {
    let sessionId: String
    let jobs: JobsModel
    /// The workbench already shows the browser beside the conversation (iPad).
    let browserShown: Bool
    let openBrowser: () -> Void
    let openJobs: () -> Void
    @Environment(AppModel.self) private var app

    /// A subagent works in the browser of the conversation that started it.
    @MainActor
    static func browser(of sessionId: String, in app: AppModel) -> BrowserModel? {
        guard let model = BrowserModel.existing(BrowserAgent.owner(of: sessionId, in: app)), model.started else { return nil }
        return model
    }

    /// Whether any chip shows, so the timeline can leave room for them under its last row.
    @MainActor
    static func shows(sessionId: String, jobs: JobsModel, browserShown: Bool, in app: AppModel) -> Bool {
        jobs.visibleCount > 0 || (!browserShown && browser(of: sessionId, in: app) != nil)
    }

    private var browser: BrowserModel? { Self.browser(of: sessionId, in: app) }

    var body: some View {
        // Read here so the chips follow a browser made after this view.
        let browser = browserShown ? nil : browser
        HStack(spacing: 8) {
            if let browser {
                chip(
                    icon: "globe",
                    text: Text(Self.host(browser.page) ?? String(localized: "浏览器")),
                    running: browser.agentBusy || browser.loading,
                    label: Text("浏览器：\(Self.host(browser.page) ?? "")"),
                    action: openBrowser
                )
            }
            if jobs.visibleCount > 0 {
                chip(
                    icon: "list.bullet.rectangle",
                    text: jobs.live.isEmpty ? Text("\(jobs.visibleCount) 个后台任务") : Text("\(jobs.live.count) 个后台任务运行中"),
                    running: !jobs.live.isEmpty,
                    label: nil,
                    action: openJobs
                )
            }
        }
        .animation(.snappy(duration: 0.18), value: browser == nil)
        .animation(.snappy(duration: 0.18), value: jobs.visibleCount)
    }

    /// `www.` says nothing; the rest of the host is the site.
    private static func host(_ url: URL?) -> String? {
        guard let host = url?.host(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func chip(icon: String, text: Text, running: Bool, label: Text?, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.footnote.weight(.semibold))
                    .overlay(alignment: .topTrailing) {
                        if running { Circle().fill(Palette.running).frame(width: 7, height: 7).offset(x: 3, y: -3) }
                    }
                text.font(.footnote.weight(.medium)).lineLimit(1)
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .floatingGlass(in: Capsule())
            .hitTarget()
        }
        .buttonStyle(.plain)
        .transition(.opacity.combined(with: .scale(scale: 0.8)))
        .accessibilityLabel(label ?? text)
    }
}
