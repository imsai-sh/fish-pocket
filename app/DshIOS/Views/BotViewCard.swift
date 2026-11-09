import Charts
import SwiftUI

/// A card a Bot sent with `show_view` and waits on: its content drawn natively, its inputs
/// and answer parts (options, a confirm, a form, a submit button) sent back with `view-reply`.
///
/// The schema is deep-view's: `{type, …}` nodes. A value written as a formula (`{"=": …}`)
/// shows as a dash; the Bot reads the inputs themselves, which are sent as set.
struct BotViewCard: View {
    @Environment(AppModel.self) private var app
    let bot: BotInfo
    /// The pending view: `{id, title, view}`.
    let pending: JSON

    @State private var inputs: [String: JSON] = [:]
    @State private var fields: [String: String] = [:]
    @State private var picked: [String: Set<String>] = [:]
    @State private var sending = false
    /// The content's own height: the card is as tall as it, up to a scrolling limit.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let root = pending["view"]
        BotCard {
            HStack(alignment: .firstTextBaseline) {
                if let title = pending["title"].string, !title.isEmpty {
                    Text(title).font(.subheadline.weight(.semibold))
                }
                Spacer(minLength: 0)
                Button {
                    Task { await app.botTeam.dismissView(of: bot) }
                } label: {
                    Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(Palette.secondary)
                }
                .buttonStyle(.plain)
                .hitTarget(32)
                .accessibilityLabel("先不回答")
            }
            ScrollView {
                node(root).frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(contentHeight, 1), 420))
        }
        .disabled(sending)
        .onAppear { seed(root) }
    }

    // MARK: Nodes

    private func node(_ node: JSON) -> AnyView {
        switch node["type"].string ?? "" {
        case "stack":
            return AnyView(VStack(alignment: .leading, spacing: 10) { children(node) })
        case "row":
            return AnyView(HStack(alignment: .top, spacing: 10) { children(node) })
        case "text":
            return AnyView(Text(Self.display(node["text"])).font(.subheadline)
                .foregroundStyle(node["tone"].string == "muted" ? Palette.secondary : Palette.ink)
                .textSelection(.enabled))
        case "metric":
            return AnyView(metric(node))
        case "table":
            return AnyView(table(node))
        case "chart":
            return AnyView(chart(node))
        case "progress":
            return AnyView(progress(node))
        case "callout":
            return AnyView(Text(Self.display(node["text"])).font(.subheadline)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Self.tone(node["tone"].string).opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous)))
        case "sources":
            return AnyView(VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(node["items"].array.enumerated()), id: \.offset) { _, item in
                    if let url = item["url"].string.flatMap(URL.init(string:)) {
                        Link(item["label"].string ?? url.absoluteString, destination: url).font(.footnote)
                    }
                }
            })
        case "html":
            return AnyView(Text(node["summary"].string ?? "").font(.footnote).foregroundStyle(Palette.secondary))
        case "slider", "number":
            return AnyView(numberInput(node))
        case "choice":
            return AnyView(choiceInput(node))
        case "toggle":
            return AnyView(Toggle(node["label"].string ?? "", isOn: Binding(
                get: { inputs[node["id"].string ?? ""]?.bool ?? false },
                set: { inputs[node["id"].string ?? ""] = .bool($0) }
            )).font(.subheadline))
        case "options":
            return AnyView(options(node))
        case "confirm":
            return AnyView(confirm(node))
        case "form":
            return AnyView(form(node))
        case "submit":
            return AnyView(Button(node["label"].string ?? String(localized: "提交")) { send(node["id"].string, [:]) }
                .buttonStyle(.capsule(height: 36, fill: false)))
        default:
            return AnyView(children(node))
        }
    }

    private func children(_ node: JSON) -> some View {
        ForEach(Array(node["children"].array.enumerated()), id: \.offset) { _, child in self.node(child) }
    }

    private func metric(_ node: JSON) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.display(node["label"])).font(.caption).foregroundStyle(Palette.secondary)
            Text(Self.display(node["value"])).font(.title3.weight(.semibold)).monospacedDigit()
                .foregroundStyle(node["tone"].isNull ? Palette.ink : Self.tone(node["tone"].string))
            if !node["caption"].isNull { Text(Self.display(node["caption"])).font(.caption2).foregroundStyle(Palette.faint) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func table(_ node: JSON) -> some View {
        let columns = node["columns"].array
        return ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                        Text(column["label"].string ?? "").font(.caption.weight(.semibold)).foregroundStyle(Palette.secondary)
                    }
                }
                Divider()
                ForEach(Array(node["rows"].array.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.array.enumerated()), id: \.offset) { _, cell in
                            Text(Self.display(cell)).font(.footnote).lineLimit(3)
                        }
                    }
                }
            }
        }
    }

    private struct Point: Identifiable {
        let id = UUID()
        let series: String
        let category: String
        let value: Double
    }

    @ViewBuilder
    private func chart(_ node: JSON) -> some View {
        let categories = node["categories"].array.map { Self.display($0) }
        let points = node["series"].array.enumerated().flatMap { index, series in
            series["values"].array.enumerated().compactMap { offset, value -> Point? in
                guard offset < categories.count, let number = value.double else { return nil }
                return Point(series: series["name"].string ?? "\(index + 1)", category: categories[offset], value: number)
            }
        }
        let kind = node["kind"].string ?? "bar"
        VStack(alignment: .leading, spacing: 4) {
            Chart(points) { point in
                switch kind {
                case "line": LineMark(x: .value("", point.category), y: .value("", point.value)).foregroundStyle(by: .value("", point.series))
                case "area": AreaMark(x: .value("", point.category), y: .value("", point.value)).foregroundStyle(by: .value("", point.series))
                case "hbar": BarMark(x: .value("", point.value), y: .value("", point.category)).foregroundStyle(by: .value("", point.series))
                case "donut": SectorMark(angle: .value("", point.value), innerRadius: .ratio(0.6)).foregroundStyle(by: .value("", point.category))
                default: BarMark(x: .value("", point.category), y: .value("", point.value)).foregroundStyle(by: .value("", point.series))
                }
            }
            .frame(height: 180)
            if !node["caption"].isNull { Text(Self.display(node["caption"])).font(.caption2).foregroundStyle(Palette.faint) }
        }
    }

    private func progress(_ node: JSON) -> some View {
        let fraction: Double = if let percent = node["percent"].double { percent / 100 } else if let value = node["value"].double, let max = node["max"].double, max > 0 { value / max } else { 0 }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                if !node["label"].isNull { Text(Self.display(node["label"])).font(.caption) }
                Spacer()
                Text(node["valueLabel"].string ?? "\(Int((fraction * 100).rounded()))%").font(.caption).monospacedDigit().foregroundStyle(Palette.secondary)
            }
            ProgressView(value: min(1, max(0, fraction))).tint(node["tone"].isNull ? Palette.ink : Self.tone(node["tone"].string))
        }
    }

    // MARK: Inputs

    private func numberInput(_ node: JSON) -> some View {
        let id = node["id"].string ?? ""
        let low = node["min"].double ?? 0
        let high = node["max"].double ?? max(low + 100, 100)
        let step = node["step"].double ?? 1
        let unit = node["unit"].string.map { " \($0)" } ?? ""
        let value = Binding(get: { inputs[id]?.double ?? low }, set: { inputs[id] = .number(($0 / step).rounded() * step) })
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(node["label"].string ?? "").font(.subheadline)
                Spacer()
                Text(verbatim: "\(value.wrappedValue.formatted())\(unit)").font(.subheadline).monospacedDigit().foregroundStyle(Palette.secondary)
            }
            if node["type"].string == "slider" {
                Slider(value: value, in: low...max(high, low + step), step: step)
            } else {
                Stepper("", value: value, in: low...max(high, low + step), step: step).labelsHidden()
            }
        }
    }

    private func choiceInput(_ node: JSON) -> some View {
        let id = node["id"].string ?? ""
        let options = node["options"].array.map { (label: $0["label"].string ?? "", value: $0["value"].string ?? $0["label"].string ?? "") }
        return Picker(node["label"].string ?? "", selection: Binding(get: { inputs[id]?.string ?? options.first?.value ?? "" }, set: { inputs[id] = .string($0) })) {
            ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
        }
        .font(.subheadline)
    }

    // MARK: Answers

    private func options(_ node: JSON) -> some View {
        let id = node["id"].string ?? ""
        let multi = node["multi"].bool ?? false
        let chosen = picked[id] ?? []
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(node["options"].array.compactMap { option in option["label"].string.map { ($0, option["description"].string) } }, id: \.0) { label, detail in
                Button {
                    if multi {
                        Haptics.select()
                        var next = chosen
                        if next.contains(label) { next.remove(label) } else { next.insert(label) }
                        picked[id] = next
                    } else {
                        send(id, ["selected": [.string(label)]])
                    }
                } label: {
                    HStack(spacing: 8) {
                        if multi { Image(systemName: chosen.contains(label) ? "checkmark.square.fill" : "square") }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label).multilineTextAlignment(.leading)
                            if let detail { Text(detail).font(.caption).foregroundStyle(Palette.secondary).multilineTextAlignment(.leading) }
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.subheadline)
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(minHeight: 40)
                    .background(Palette.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Palette.stroke))
                }
                .buttonStyle(.plain)
            }
            if multi {
                Button("提交") { send(id, ["selected": .array(chosen.sorted().map(JSON.string))]) }
                    .buttonStyle(.capsule(height: 36, fill: false))
                    .disabled(chosen.isEmpty)
            }
        }
    }

    private func confirm(_ node: JSON) -> some View {
        let id = node["id"].string
        return HStack(spacing: 8) {
            Button(node["confirmLabel"].string ?? String(localized: "确认")) { send(id, ["confirmed": true]) }
                .buttonStyle(.capsule(height: 36, fill: false))
            Button(node["cancelLabel"].string ?? String(localized: "取消")) { send(id, ["confirmed": false]) }
                .buttonStyle(.capsule(.outline, height: 36, fill: false))
        }
    }

    private func form(_ node: JSON) -> some View {
        let id = node["id"].string
        let items = node["fields"].array
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, field in
                let key = field["id"].string ?? ""
                VStack(alignment: .leading, spacing: 4) {
                    Text(field["label"].string ?? "").font(.caption).foregroundStyle(Palette.secondary)
                    if field["readOnly"].bool == true {
                        Text(field["value"].string ?? "").font(.subheadline)
                    } else {
                        TextField(field["placeholder"].string ?? "", text: Binding(get: { fields[key] ?? "" }, set: { fields[key] = String($0.prefix(2000)) }),
                                  axis: field["multiline"].bool == true ? .vertical : .horizontal)
                            .lineLimit(field["multiline"].bool == true ? 3 : 1, reservesSpace: field["multiline"].bool == true)
                            .font(.subheadline)
                            .padding(10)
                            .background(Palette.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
            HStack(spacing: 8) {
                Button(node["submitLabel"].string ?? String(localized: "提交")) {
                    let editable = items.filter { $0["readOnly"].bool != true }.compactMap { $0["id"].string }
                    send(id, ["fields": .object(Dictionary(uniqueKeysWithValues: editable.map { ($0, JSON.string(fields[$0] ?? "")) }))])
                }
                .buttonStyle(.capsule(height: 36, fill: false))
                Button(node["cancelLabel"].string ?? String(localized: "取消")) { send(id, ["canceled": true]) }
                    .buttonStyle(.capsule(.outline, height: 36, fill: false))
            }
        }
    }

    // MARK: Sending

    private func send(_ action: String?, _ values: [String: JSON]) {
        guard let action, !sending else { return }
        var values = values
        if !inputs.isEmpty { values["inputs"] = .object(inputs) }
        sending = true
        Haptics.tap()
        Task {
            _ = await app.botTeam.reply(to: pending, of: bot, action: action, values: .object(values))
            sending = false
        }
    }

    /// Inputs and form fields start at the values the Bot gave them.
    private func seed(_ node: JSON) {
        switch node["type"].string {
        case "slider", "number":
            if let id = node["id"].string, inputs[id] == nil { inputs[id] = .number(node["value"].double ?? node["min"].double ?? 0) }
        case "choice":
            if let id = node["id"].string, inputs[id] == nil {
                let first = node["options"].array.first.map { $0["value"].string ?? $0["label"].string ?? "" }
                inputs[id] = .string(node["value"].string ?? first ?? "")
            }
        case "toggle":
            if let id = node["id"].string, inputs[id] == nil { inputs[id] = .bool(node["value"].bool ?? false) }
        case "form":
            for field in node["fields"].array {
                if let id = field["id"].string, fields[id] == nil { fields[id] = field["value"].string ?? "" }
            }
        default: break
        }
        node["children"].array.forEach(seed)
    }

    // MARK: Values

    /// A shown value: text, a number, or a formula (drawn as a dash).
    static func display(_ value: JSON) -> String {
        if let text = value.string { return text }
        if let number = value.double { return number.formatted() }
        if let bool = value.bool { return bool ? "✓" : "✗" }
        return "—"
    }

    static func tone(_ tone: String?) -> Color {
        switch tone {
        case "good": Palette.added
        case "warn": Palette.waiting
        case "bad": Palette.removed
        default: Palette.secondary
        }
    }
}
