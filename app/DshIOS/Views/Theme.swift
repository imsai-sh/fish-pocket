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
    /// A swipe action's button. The system draws its label white, and the ink is near white in
    /// dark mode, which hid 归档 and 取消归档: there it is the secondary grey, as 置顶 is.
    static let swipe = Color(uiColor: UIColor { traits in
        UIColor(named: traits.userInterfaceStyle == .dark ? "TextSecondary" : "Ink") ?? .label
    })
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
    /// The one color of the drawn icons on 探索: the piece of each that says what it does.
    static let spot = Color("Spot")
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
    /// 设置 and the pages under it wear the system's own list look: its background and separators.
    /// Set on the settings stack and on the sheets that open one of its pages directly; every other
    /// screen keeps the monochrome look.
    @Entry var systemLists = false
}

/// Every switch in the app: the system's, in its green. Left to the page's ink tint, the track is
/// black, and in the dark white under the white knob: one white block, on or off hard to tell.
/// Set on the window, so a plain `Toggle` gets it; but under an explicit `.tint(…)` the window's
/// style no longer reaches the switch, so the ink is always set with `inkTint()`, which sets this
/// style again with it. A new switch, not `Toggle(configuration)`: that one keeps the page's tint.
/// In a menu the toggle stays a checkmark.
struct AppSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(isOn: configuration.$isOn) { configuration.label }
            .toggleStyle(.switch)
            .tint(.green)
    }
}

extension ToggleStyle where Self == AppSwitchStyle {
    static var appSwitch: AppSwitchStyle { AppSwitchStyle() }
}

extension View {
    /// The app's ink for what can be tapped, keeping the switches green (`AppSwitchStyle`).
    func inkTint() -> some View { tint(Palette.ink).toggleStyle(.appSwitch) }
}

/// The switch alone, for rows that lay out their own label (plugins).
struct AppSwitch: View {
    @Binding var isOn: Bool
    var label: Text?

    var body: some View {
        Toggle(isOn: $isOn) { label ?? Text("") }
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(.green)
    }
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
    /// grouped lists and separators, with the app's ink for what can be tapped. Goes on the
    /// navigation stack (or the sheet's content), so the pages inside inherit it.
    func settingsStyle() -> some View {
        environment(\.systemLists, true).inkTint()
    }

    /// A picker's value in the grey of the other rows' values; the page's ink tint would paint it black.
    /// Only the value: the row's icon keeps the ink.
    func pickerValueTint() -> some View { tint(.secondary) }

    /// The background of a page that puts something of its own (tabs, an empty state) around a `groupedList()`.
    func pageBackground() -> some View { modifier(PageBackground()) }

    /// A tab's own list, between the title bar and the tab bar: from iOS 26 both bars are
    /// see-through and what scrolls under them softens, as on the system's pages. Left to the
    /// system the bottom edge stayed sharp, and the top was a frosted band ending in a line.
    @ViewBuilder
    func tabEdgesSoftened() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        } else {
            self
        }
    }

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
    /// The dock tells its window where it starts (`BottomDocks`), for the notices above it.
    @ViewBuilder
    func conversationDock(@ViewBuilder _ dock: () -> some View) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .bottom, spacing: 0) { dock().modifier(DockReport()) }
        } else {
            safeAreaInset(edge: .bottom, spacing: 0) { dock().modifier(DockReport()).background(Palette.background) }
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

    /// A text field in a bar answers only on its lines; the bar's room above and below them,
    /// `beyond` past the field's own frame, puts the caret in it too. With one line that room is
    /// most of the bar, and a tap there went nowhere: it took a second tap. A UIKit tap, as a
    /// SwiftUI one this close to the bottom of the screen arrives late on a device.
    func focusesOnTap(_ focus: FocusState<Bool>.Binding, beyond: CGFloat = 0) -> some View {
        background {
            FocusTap { focus.wrappedValue = true }
                .padding(.vertical, -beyond)
                .accessibilityHidden(true)
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

/// The system share sheet, presented from whatever is on top. Not `ShareLink`:
/// in a sheet opened from the chat, a `ShareLink` (in a toolbar menu at least)
/// presents from the root controller, which is already presenting that sheet,
/// so UIKit refuses and the tap does nothing.
@MainActor
func presentShareSheet(_ items: [Any]) {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    guard var top = scene?.keyWindow?.rootViewController else { return }
    while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
    let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
    // iPad shows it as a popover, which needs an anchor: the middle of the page, no arrow.
    if let popover = controller.popoverPresentationController {
        popover.sourceView = top.view
        popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
        popover.permittedArrowDirections = []
    }
    top.present(controller, animated: true)
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

/// The same for the system's search field, when code ends its search (a match was picked).
/// Left alone, the field commits what a Chinese input method was composing as it closes and
/// writes it back to the binding just emptied: the list stays on the matches, with the field
/// out of sight. Only a search field: beside a conversation the keyboard may be the composer's.
@MainActor
func clearFocusedSearchField() {
    guard let field = UIResponder.focused as? UISearchTextField else { return }
    field.unmarkText()
    field.text = ""
}

extension UIResponder {
    /// The text view holding the keyboard, if one does (a multi-line SwiftUI field is one).
    @MainActor static var focusedTextView: UITextView? { focused as? UITextView }
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
    /// The conversation reaches the top of the window, where the status bar is. A column that
    /// starts lower has none over it (an iPad's, under the floating tab bar; a sheet's): there
    /// the blur showed as a lighter band of its own, behind the tab bar and beside a list with none.
    @State private var underStatusBar = false

    var body: some View {
        // The window's top inset is the status bar (or the Dynamic Island's band); this view's own
        // inset also holds the navigation bar, which is left clear. With no status bar along the
        // top (iPhone Duo unfolded keeps it in a column at the side) the inset is next to nothing,
        // and the messages were cut off hard at the screen's edge: a band of its own still fades them.
        let height = max(Self.statusBarHeight, 24)
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(Palette.background.opacity(0.35))
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.6), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(height: height + 10)
            .frame(maxWidth: .infinity, alignment: .top)
            // Read here, inside: outside `ignoresSafeArea` the frame is the safe area's, below the bars.
            .onGeometryChange(for: Bool.self) { $0.frame(in: .global).minY < 1 } action: { underStatusBar = $0 }
            .ignoresSafeArea(edges: .top)
            .opacity(underStatusBar ? 1 : 0)
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

/// The tap behind a bar's text field (`focusesOnTap`).
private struct FocusTap: UIViewRepresentable {
    let tapped: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap)))
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { context.coordinator.tapped = tapped }

    func makeCoordinator() -> Coordinator { Coordinator(tapped: tapped) }

    @MainActor
    final class Coordinator: NSObject {
        var tapped: () -> Void
        init(tapped: @escaping () -> Void) { self.tapped = tapped }
        @objc func tap() { tapped() }
    }
}

/// A dock reporting its place to its window's `BottomDocks`, while it is on screen.
private struct DockReport: ViewModifier {
    @Environment(BottomDocks.self) private var docks: BottomDocks?
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { docks?.move(id, to: $0) }
            .onAppear { docks?.show(id) }
            .onDisappear { docks?.hide(id) }
    }
}
