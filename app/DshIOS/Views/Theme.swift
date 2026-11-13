import SwiftUI

/// Design tokens (docs/design/README.md §3). Each is a Color Set in
/// Assets.xcassets with a light and a dark value; views use only these names.
enum Palette {
    static let background = Color("Background")
    static let ink = Color("Ink")
    /// Links in replies: the system's link blue, in both appearances.
    static let link = Color(uiColor: .link)
    static let onInk = Color("OnInk")
    static let secondary = Color("TextSecondary")
    static let faint = Color("TextFaint")
    /// Composer and command blocks.
    static let field = Color("Field")
    /// Grouped lists and the terminal.
    static let grouped = Color("Grouped")
    /// User bubbles, the search field, the selected row.
    static let bubble = Color("Bubble")
    /// Secondary buttons (reject, restart).
    static let control = Color("Control")
    static let stroke = Color("Stroke")
    static let running = Color("StatusRunning")
    static let waiting = Color("StatusWaiting")
    static let addedBackground = Color("DiffAddBackground")
    static let added = Color("DiffAddText")
    static let removedBackground = Color("DiffDeleteBackground")
    static let removed = Color("DiffDeleteText")
    static let scrim = Color("Scrim")
}

/// The appearance choice lives in the engine (`ui-theme.preference`, shared with the web and
/// desktop clients). The app keeps the last value it read, because the screens shown while
/// the engine starts need it before the engine can answer.
enum ThemePreference {
    static let key = "dsh.theme.preference"
    static let system = "system"

    static func style(_ preference: String) -> UIUserInterfaceStyle {
        switch preference {
        case "light": .light
        case "dark": .dark
        default: .unspecified
        }
    }
}

/// Sets the appearance on the window itself. `preferredColorScheme(nil)` does not bring a
/// sheet that is already up back to the system's: going from 深色 to 跟随系统 left 设置 dark.
struct WindowAppearance: UIViewRepresentable {
    let style: UIUserInterfaceStyle

    func makeUIView(context: Context) -> Probe { Probe(style: style) }

    func updateUIView(_ view: Probe, context: Context) {
        view.style = style
        view.window?.overrideUserInterfaceStyle = style
    }

    final class Probe: UIView {
        var style: UIUserInterfaceStyle

        init(style: UIUserInterfaceStyle) {
            self.style = style
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used from a nib") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            window?.overrideUserInterfaceStyle = style
        }
    }
}

/// Pill buttons: `.primary` is ink on the page, `.secondary` the grey control fill.
struct CapsuleButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, outline }
    var kind: Kind = .primary
    var height: CGFloat = 52
    var fill = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(height >= 44 ? .callout.weight(.semibold) : .subheadline.weight(.semibold))
            .foregroundStyle(kind == .primary ? Palette.onInk : Palette.ink)
            .padding(.horizontal, 16)
            .frame(maxWidth: fill ? .infinity : nil, minHeight: height)
            .background {
                switch kind {
                case .primary: Capsule().fill(Palette.ink)
                case .secondary: Capsule().fill(Palette.control)
                case .outline: Capsule().strokeBorder(Palette.stroke)
                }
            }
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension ButtonStyle where Self == CapsuleButtonStyle {
    static func capsule(_ kind: CapsuleButtonStyle.Kind = .primary, height: CGFloat = 52, fill: Bool = true) -> CapsuleButtonStyle {
        CapsuleButtonStyle(kind: kind, height: height, fill: fill)
    }
}

extension EnvironmentValues {
    /// 设置 and the pages under it wear the system's own list look: its background, separators
    /// and switch. Set on the settings stack and on the sheets that open one of its pages directly;
    /// every other screen keeps the monochrome look.
    @Entry var systemLists = false
}

/// The monochrome switch: ink track with a page-coloured knob when on, so it
/// reads in both appearances (the system knob is always white). Under 设置 it is the system's.
struct MonoToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        @Environment(\.systemLists) private var system
        let configuration: Configuration

        var body: some View {
            if system {
                // The ink tint of the page would paint the track black, and white in the dark.
                Toggle(isOn: configuration.$isOn) { configuration.label }
                    .toggleStyle(.switch)
                    .tint(.green)
            } else {
                HStack(spacing: 16) {
                    configuration.label
                    Spacer(minLength: 0)
                    MonoSwitch(isOn: configuration.$isOn)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isToggle)
                .accessibilityValue(configuration.isOn ? Text("开") : Text("关"))
                .accessibilityAction { configuration.isOn.toggle() }
            }
        }
    }
}

/// The switch alone, for rows that lay out their own label (plugins).
struct MonoSwitch: View {
    @Environment(\.systemLists) private var system
    @Binding var isOn: Bool
    var label: Text?

    var body: some View {
        if system {
            Toggle(isOn: $isOn) { label ?? Text("") }
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.green)
        } else {
            mono
        }
    }

    private var mono: some View {
        Capsule()
            .fill(isOn ? Palette.ink : Palette.control)
            .frame(width: 48, height: 28)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(isOn ? Palette.background : Palette.faint)
                    .frame(width: 22, height: 22)
                    .padding(3)
            }
            .animation(.snappy(duration: 0.2), value: isOn)
            .contentShape(Capsule())
            .onTapGesture { isOn.toggle(); Haptics.select() }
            .accessibilityElement()
            .accessibilityLabel(label ?? Text(""))
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(isOn ? Text("开") : Text("关"))
            .accessibilityAction { isOn.toggle() }
    }
}

extension ToggleStyle where Self == MonoToggleStyle {
    static var mono: MonoToggleStyle { MonoToggleStyle() }
}

/// Running / waiting indicator: the only colour besides diffs.
struct StatusDot: View {
    enum State { case running, waiting }
    let state: State
    var size: CGFloat = 7
    var halo = false

    var body: some View {
        let color = state == .running ? Palette.running : Palette.waiting
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .background { if halo { Circle().fill(color.opacity(0.15)).frame(width: size + 8, height: size + 8) } }
            .accessibilityLabel(state == .running ? Text("运行中") : Text("等待允许"))
    }
}

/// Grouped rows on the page background (plugins, workbench lists); under 设置, the system's grouped list.
struct GroupedListStyle: ViewModifier {
    @Environment(\.systemLists) private var system

    func body(content: Content) -> some View {
        if system {
            content.listStyle(.insetGrouped)
        } else {
            content
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(Palette.background)
        }
    }
}

/// What shows around a list's rows: the system's grouped background under 设置, the page colour elsewhere.
private struct PageBackground: ViewModifier {
    @Environment(\.systemLists) private var system

    func body(content: Content) -> some View {
        content.background(system ? Color(.systemGroupedBackground) : Palette.background)
    }
}

/// The fill of rows in a `groupedList()`; the system's own rows and separators under 设置.
private struct GroupedRowStyle: ViewModifier {
    @Environment(\.systemLists) private var system

    func body(content: Content) -> some View {
        if system {
            content
        } else {
            content.listRowBackground(Palette.grouped).listRowSeparator(.hidden)
        }
    }
}

extension View {
    func groupedList() -> some View { modifier(GroupedListStyle()) }

    /// A settings page and everything pushed or presented from it, as 设置 is drawn: the system's
    /// grouped lists, separators and switches, with the app's ink for what can be tapped. Goes on
    /// the navigation stack (or the sheet's content), so the pages inside inherit it.
    func settingsStyle() -> some View {
        environment(\.systemLists, true).toggleStyle(.mono).tint(Palette.ink)
    }

    /// A picker's value in the grey of the other rows' values; the page's ink tint would paint it black.
    /// Only the value: the row's icon keeps the ink.
    func pickerValueTint() -> some View { tint(.secondary) }

    /// The background of a page that puts something of its own (tabs, an empty state) around a `groupedList()`.
    func pageBackground() -> some View { modifier(PageBackground()) }

    /// A conversation's top bar. From iOS 26 it is the system's see-through bar: the messages
    /// run up under its buttons, sharp, and blur only under the status bar, above them, so the
    /// clock stays readable; the bottom edge, under the composer, softens as before. Before, a
    /// bar in the page colour.
    @ViewBuilder
    func conversationBar() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .bottom)
                .scrollEdgeEffectHidden(true, for: .top)
                .overlay(alignment: .top) { StatusBarSoftening() }
        } else {
            toolbarBackground(Palette.background, for: .navigationBar)
        }
    }

    /// A conversation's title in the bar. From iOS 26 the bar is see-through with no blur at the
    /// top, so the title sits on glass, as the bar's buttons do, to stay readable over the messages.
    @ViewBuilder
    func barTitleGlass() -> some View {
        if #available(iOS 26.0, *) {
            padding(.horizontal, 6).glassEffect(.regular.interactive(), in: .capsule)
        } else {
            self
        }
    }

    /// A conversation's composer at the bottom. From iOS 26 it floats as the top bar does:
    /// the messages run on under it and soften at the edge. Before, on the page colour.
    @ViewBuilder
    func conversationDock(@ViewBuilder _ dock: () -> some View) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .bottom, spacing: 0, content: dock)
        } else {
            safeAreaInset(edge: .bottom, spacing: 0) { dock().background(Palette.background) }
        }
    }

    /// A floating control's surface: the system's glass from iOS 26, the outlined page colour before.
    @ViewBuilder
    func floatingGlass(in shape: some Shape) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(Palette.background, in: shape)
                .overlay(shape.stroke(Palette.stroke))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
        }
    }

    /// The composer's own surface. From iOS 26 the system's glass, so the messages it floats
    /// over show through it as they do through the bars. Before, the field's fill.
    @ViewBuilder
    func composerSurface() -> some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(Palette.field, in: shape)
        }
    }

    /// A small control keeps its look; the tappable area grows to the 44 pt a thumb needs.
    func hitTarget(_ size: CGFloat = 44) -> some View {
        frame(minWidth: size, minHeight: size)
            .contentShape(Rectangle())
            // A pointer (iPad): the area lights up as it passes.
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 12, style: .continuous))
            .hoverEffect(.highlight)
    }

    /// The reading column of a wide window, centred. A phone is narrower: nothing changes there.
    func readableWidth() -> some View {
        frame(maxWidth: readableColumnWidth, alignment: .leading).frame(maxWidth: .infinity)
    }

    /// One saving model for edit pages: 取消 and 保存 in the toolbar, where the keyboard never covers them.
    func saveToolbar(canSave: Bool, saving: Bool = false, cancel: (() -> Void)? = nil, save: @escaping () -> Void) -> some View {
        toolbar {
            if let cancel { ToolbarItem(placement: .cancellationAction) { Button("取消", action: cancel) } }
            ToolbarItem(placement: .confirmationAction) {
                if saving { ProgressView() } else { Button("保存", action: save).disabled(!canSave) }
            }
        }
    }

    /// Row fill (and no separators: rows group by space) for lists styled with
    /// `groupedList()`; applies to every row of a `Section`.
    func groupedRow() -> some View { modifier(GroupedRowStyle()) }

    /// A close button for a view presented as a sheet (it may also be pushed, where it has none).
    func closeButton(_ dismiss: DismissAction) -> some View {
        closeButton { dismiss() }
    }

    /// The same button, for a view its presenter closes.
    func closeButton(action: @escaping () -> Void) -> some View {
        toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: action) { Image(systemName: "xmark") }
                    .accessibilityLabel("关闭")
            }
        }
    }

    /// Leaves the page once `done` turns true: pops it, or closes the sheet it is the root of.
    /// For pushed pages that push further, which must not read `dismiss` themselves: on iOS 17
    /// that value moves with the navigation stack, so the page's body and the stack kept
    /// updating each other until the app was killed. Here nothing reads it before it is used.
    func dismisses(when done: Bool) -> some View {
        background { if done { Dismissal() } }
    }
}

private struct Dismissal: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Color.clear.onAppear { dismiss() }
    }
}

extension GeometryProxy {
    /// iPhone Duo's fold while the device is partly open: the strip it takes out of this view,
    /// in the view's own coordinates. Nil when the device is flat or closed, when the fold
    /// misses this view, and on everything that does not fold.
    var fold: CGRect? {
        // Reserved regions came with the iOS 27.1 SDK (SwiftUI 8.1): Xcode 26 still builds the app.
        #if canImport(SwiftUI, _version: 8.1)
        guard #available(iOS 27.1, *) else { return nil }
        let bounds = CGRect(origin: .zero, size: size)
        return reservedRegions(kind: .division).map(\.frame).first { $0.intersects(bounds) }
        #else
        return nil
        #endif
    }
}

/// Lines past this are hard to follow, and a window can be far wider.
let readableColumnWidth: CGFloat = 760

/// Haptics, one vocabulary for the whole app (they follow the system's vibration setting):
/// a light tap for sending and small actions, a firmer one for stopping, a selection tick
/// for switches and pickers, and notifications for approvals, success and errors.
@MainActor
enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func firm() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    /// Keys and repeated small presses.
    static func soft() { UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6) }
    static func select() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}

/// Copy with a success tick.
@MainActor
func copyToPasteboard(_ text: String) {
    UIPasteboard.general.string = text
    Haptics.success()
}

/// Hide the keyboard, whichever field (or the terminal) holds it. Not by sending
/// `resignFirstResponder` up the responder chain: the terminal answers
/// `canPerformAction` for its own menu only, so that action passes it by.
@MainActor
func dismissKeyboard() {
    for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
        scene.windows.forEach { $0.endEditing(true) }
    }
}

/// Empty the focused text view in place. Clearing a SwiftUI binding while a Chinese
/// input method is composing leaves the old text on screen (the binding is empty, the
/// view is not); ending the composition and emptying the view directly keeps the two
/// in step without rebuilding the field, so focus and the keyboard stay.
@MainActor
func clearFocusedTextInput() {
    switch UIResponder.focused {
    case let view as UITextView:
        view.unmarkText()
        view.text = ""
    case let field as UITextField:
        field.unmarkText()
        field.text = ""
    default:
        break
    }
}

private extension UIResponder {
    static weak var found: UIResponder?

    /// The first responder: an action sent to nil reaches it.
    static var focused: UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(captureFirstResponder), to: nil, from: nil, for: nil)
        return found
    }

    @objc func captureFirstResponder() { UIResponder.found = self }
}

/// The drawer button: two lines, the lower one shorter.
struct DrawerGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let unit = rect.width / 24
        path.move(to: CGPoint(x: 4 * unit, y: rect.minY + 8 * unit))
        path.addLine(to: CGPoint(x: 20 * unit, y: rect.minY + 8 * unit))
        path.move(to: CGPoint(x: 4 * unit, y: rect.minY + 16 * unit))
        path.addLine(to: CGPoint(x: 14 * unit, y: rect.minY + 16 * unit))
        return path
    }
}

struct DrawerButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            DrawerGlyph()
                .stroke(Palette.ink, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .frame(width: 22, height: 22)
        }
        .accessibilityLabel("打开侧边栏")
    }
}

/// A blur under the system status bar alone, fading out above the bar's own buttons: what scrolls
/// up there stays out of the clock's way, while the messages under the title stay sharp.
private struct StatusBarSoftening: View {
    var body: some View {
        // The window's top inset is the status bar (or the Dynamic Island's band); this view's own
        // inset also holds the navigation bar, which is left clear.
        let height = Self.statusBarHeight
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(Palette.background.opacity(0.35))
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.6), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(height: height + 10)
            .frame(maxWidth: .infinity, alignment: .top)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @MainActor
    private static var statusBarHeight: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        return window?.safeAreaInsets.top ?? 54
    }
}
