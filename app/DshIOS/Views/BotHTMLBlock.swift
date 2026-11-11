import SwiftUI
import WebKit

/// The `html` part of a view card: markup a Bot wrote, for what the other parts cannot draw.
/// It runs shut in: its own page with no address, a policy ahead of the markup that blocks
/// every network request, nothing kept, and no way to leave the page or reach the app.
struct BotHTMLBlock: View {
    let html: String
    let summary: String
    let height: Double?
    @State private var measured: CGFloat = 0
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Sandbox(document: Self.document(html, dark: scheme == .dark), height: $measured)
                .frame(height: max(24, min(height.map { CGFloat($0) } ?? measured, 480)))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel(summary)
            if !summary.isEmpty { Text(summary).font(.caption2).foregroundStyle(Palette.faint) }
        }
    }

    /// deep-view's frame policy: inline scripts and styles only, pictures from data.
    private static let policy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; media-src data: blob:; form-action 'none'; base-uri 'none'"

    /// The page the block loads: the policy and the theme come before the markup, so nothing
    /// in the markup runs ahead of them. The colours are the ones `show_view` teaches (`--view-*`).
    private static func document(_ html: String, dark: Bool) -> String {
        let vars: [(String, String)] = dark
            ? [("ink", "#f2f2f3"), ("ink-2", "#a0a0a8"), ("ink-3", "#6f6f78"), ("line", "#34343a"), ("line-2", "#2a2a2f"), ("card", "#1c1c1f"), ("main", "#141416"), ("hover", "#26262b"), ("accent", "#f2f2f3"), ("accent-ink", "#141416"), ("green", "#34c38f"), ("star", "#f5b545"), ("danger", "#ff5c6c")]
            : [("ink", "#141416"), ("ink-2", "#5c5c66"), ("ink-3", "#9a9aa3"), ("line", "#e3e3e8"), ("line-2", "#efeff2"), ("card", "#f5f5f7"), ("main", "#ffffff"), ("hover", "#ececf0"), ("accent", "#141416"), ("accent-ink", "#ffffff"), ("green", "#10b981"), ("star", "#e8a317"), ("danger", "#e5484d")]
        let root = vars.map { "--view-\($0.0):\($0.1);--bt-\($0.0):\($0.1)" }.joined(separator: ";")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(policy)">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <style>:root{\(root);color-scheme:\(dark ? "dark" : "light")}html,body{margin:0;padding:0;background:transparent;color:var(--view-ink);font:15px -apple-system,system-ui,sans-serif;overflow-wrap:anywhere}</style>
        <script>(()=>{const send=()=>window.webkit.messageHandlers.height.postMessage(Math.ceil(document.documentElement.getBoundingClientRect().height));new ResizeObserver(send).observe(document.documentElement);addEventListener('load',send)})()</script>
        </head><body>\(html)</body></html>
        """
    }

    private struct Sandbox: UIViewRepresentable {
        let document: String
        @Binding var height: CGFloat

        func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

        func makeUIView(context: Context) -> WKWebView {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.userContentController.add(context.coordinator, name: "height")
            let view = WKWebView(frame: .zero, configuration: configuration)
            view.navigationDelegate = context.coordinator
            view.isOpaque = false
            view.backgroundColor = .clear
            view.scrollView.backgroundColor = .clear
            view.scrollView.bounces = false
            return view
        }

        func updateUIView(_ view: WKWebView, context: Context) {
            guard context.coordinator.loaded != document else { return }
            context.coordinator.loaded = document
            view.loadHTMLString(document, baseURL: nil)
        }

        static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
            view.configuration.userContentController.removeScriptMessageHandler(forName: "height")
        }

        final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
            var loaded: String?
            private let height: Binding<CGFloat>

            init(height: Binding<CGFloat>) { self.height = height }

            func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
                guard let value = message.body as? Double, value.isFinite else { return }
                let next = CGFloat(max(24, min(value, 4000)))
                if abs(next - height.wrappedValue) > 0.5 { height.wrappedValue = next }
            }

            /// Only the page itself loads; a link or a script that tries to go elsewhere is stopped.
            func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
                decisionHandler(action.navigationType == .other && action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
            }
        }
    }
}
