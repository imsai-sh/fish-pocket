import Charts
import SwiftUI

/// A card a Bot sent with `show_view` and waits on: its content drawn natively, its inputs
/// and answer parts (options, a confirm, a form, a submit button) sent back with `view-reply`.
struct BotViewCard: View {
    @Environment(AppModel.self) private var app
    let bot: BotInfo
    /// The pending view: `{id, title, view}`.
    let pending: JSON

    @State private var sending = false
    /// The content's own height: the card is as tall as it, up to a scrolling limit.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
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
                BotViewBody(root: pending["view"]) { action, values in
                    guard !sending else { return }
                    sending = true
                    Haptics.tap()
                    Task {
                        _ = await app.botTeam.reply(to: pending, of: bot, action: action, values: values)
                        sending = false
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(contentHeight, 1), 420))
        }
        .disabled(sending)
    }
}

/// A view a Bot showed without waiting for an answer (a chart, a table, a calculator): it
/// stays in the reply it came with. Its inputs still move its numbers.
struct BotShownView: View {
    let title: String
    let root: JSON

    var body: some View {
        BotCard {
            if !title.isEmpty { Text(title).font(.subheadline.weight(.semibold)) }
            BotViewBody(root: root, send: nil).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A view drawn natively. The schema is deep-view's: `{type, …}` nodes; a value written as
/// a formula (`{"=": …}`) is worked out from the inputs each time one moves. `send` takes
/// an answer part's id and its values; nil for a view that answers nothing.
struct BotViewBody: View {
    let root: JSON
    let send: ((String, JSON) -> Void)?

    @State private var inputs: [String: JSON] = [:]
    @State private var fields: [String: String] = [:]
    @State private var picked: [String: Set<String>] = [:]
    @State private var chartTables: Set<String> = []

    var body: some View {
        // One scope per pass: every formula of the view reads the same inputs.
        let scope = ViewFormula.Scope(inputs: inputs, lets: root["let"])
        node(root, scope, path: "0")
            .onAppear { seed(root) }
    }

    // MARK: Nodes

    private func node(_ node: JSON, _ scope: ViewFormula.Scope, path: String) -> AnyView {
        switch node["type"].string ?? "" {
        case "stack":
            return AnyView(VStack(alignment: .leading, spacing: 10) { children(node, scope, path) })
        case "row":
            return AnyView(HStack(alignment: .top, spacing: 10) { children(node, scope, path) })
        case "text":
            return AnyView(Text(Self.display(node["text"], scope)).font(.subheadline)
                .foregroundStyle(node["tone"].string == "muted" ? Palette.secondary : Palette.ink)
                .textSelection(.enabled))
        case "metric":
            return AnyView(metric(node, scope))
        case "table":
            return AnyView(table(node, scope))
        case "chart":
            return AnyView(chart(node, scope, path: path))
        case "progress":
            return AnyView(progress(node, scope))
        case "callout":
            return AnyView(Text(Self.display(node["text"], scope)).font(.subheadline)
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
            return AnyView(BotHTMLBlock(html: node["html"].string ?? "", summary: node["summary"].string ?? "", height: node["height"].double))
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
            return send == nil ? AnyView(EmptyView()) : AnyView(options(node))
        case "confirm":
            return send == nil ? AnyView(EmptyView()) : AnyView(confirm(node))
        case "form":
            return send == nil ? AnyView(EmptyView()) : AnyView(form(node))
        case "submit":
            return send == nil ? AnyView(EmptyView()) : AnyView(Button(node["label"].string ?? String(localized: "提交")) { reply(node["id"].string, [:]) }
                .buttonStyle(.capsule(height: 36, fill: false)))
        default:
            return AnyView(children(node, scope, path))
        }
    }

    private func children(_ node: JSON, _ scope: ViewFormula.Scope, _ path: String) -> some View {
        ForEach(Array(node["children"].array.enumerated()), id: \.offset) { index, child in self.node(child, scope, path: "\(path).\(index)") }
    }

    private func metric(_ node: JSON, _ scope: ViewFormula.Scope) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.display(node["label"], scope)).font(.caption).foregroundStyle(Palette.secondary)
            Text(Self.display(node["value"], scope)).font(.title3.weight(.semibold)).monospacedDigit()
                .foregroundStyle(node["tone"].isNull ? Palette.ink : Self.tone(node["tone"].string))
                .contentTransition(.numericText())
            if !node["caption"].isNull { Text(Self.display(node["caption"], scope)).font(.caption2).foregroundStyle(Palette.faint) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func table(_ node: JSON, _ scope: ViewFormula.Scope) -> some View {
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
                            Text(Self.display(cell, scope)).font(.footnote).lineLimit(3)
                        }
                    }
                }
            }
        }
    }

    fileprivate struct Point: Identifiable {
        var id: String { series + "\u{1}" + category }
        let series: String
        let category: String
        let value: Double
    }

    /// The chart itself, also drawn off screen for the picture to share.
    fileprivate struct ChartPicture: View {
        let kind: String
        let points: [Point]

        var body: some View {
            Chart(points) { point in
                switch kind {
                case "line": LineMark(x: .value("", point.category), y: .value("", point.value)).foregroundStyle(by: .value("", point.series))
                case "area": AreaMark(x: .value("", point.category), y: .value("", point.value)).foregroundStyle(by: .value("", point.series))
                case "hbar": BarMark(x: .value("", point.value), y: .value("", point.category)).foregroundStyle(by: .value("", point.series))
                case "donut": SectorMark(angle: .value("", point.value), innerRadius: .ratio(0.6)).foregroundStyle(by: .value("", point.category))
                default: BarMark(x: .value("", point.category), y: .value("", point.value)).foregroundStyle(by: .value("", point.series))
                }
            }
        }
    }

    private func points(_ node: JSON, _ scope: ViewFormula.Scope) -> (categories: [String], series: [String], points: [Point]) {
        let categories = node["categories"].array.map { Self.display($0, scope) }
        let names = node["series"].array.enumerated().map { index, series in series["name"].string ?? "\(index + 1)" }
        let points = node["series"].array.enumerated().flatMap { index, series in
            series["values"].array.enumerated().compactMap { offset, value -> Point? in
                guard offset < categories.count, let number = Self.number(value, scope) else { return nil }
                return Point(series: names[index], category: categories[offset], value: number)
            }
        }
        return (categories, names, points)
    }

    @ViewBuilder
    private func chart(_ node: JSON, _ scope: ViewFormula.Scope, path: String) -> some View {
        let data = points(node, scope)
        let kind = node["kind"].string ?? "bar"
        let asTable = chartTables.contains(path)
        let drawn = ChartPicture(kind: kind, points: data.points)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                if !node["title"].isNull { Text(Self.display(node["title"], scope)).font(.caption.weight(.semibold)) }
                Spacer(minLength: 0)
                Menu {
                    Button {
                        if asTable { chartTables.remove(path) } else { chartTables.insert(path) }
                    } label: { Label(asTable ? "看图表" : "看表格", systemImage: asTable ? "chart.bar" : "tablecells") }
                    Button { copyToPasteboard(Self.tsv(data)) } label: { Label("复制数据", systemImage: "doc.on.doc") }
                    if let image = ImageRenderer(content: drawn.frame(width: 640, height: 360).padding(16).background(Color.white).environment(\.colorScheme, .light)).uiImage {
                        ShareLink(item: Image(uiImage: image), preview: SharePreview(String(localized: "图表"), image: Image(uiImage: image))) {
                            Label("保存或分享图片", systemImage: "square.and.arrow.up")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.caption.weight(.semibold)).foregroundStyle(Palette.secondary).hitTarget(32)
                }
                .accessibilityLabel("图表操作")
            }
            if asTable {
                ScrollView(.horizontal, showsIndicators: false) {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        GridRow {
                            Text("")
                            ForEach(data.series, id: \.self) { Text($0).font(.caption.weight(.semibold)).foregroundStyle(Palette.secondary) }
                        }
                        Divider()
                        ForEach(data.categories, id: \.self) { category in
                            GridRow {
                                Text(category).font(.footnote)
                                ForEach(data.series, id: \.self) { series in
                                    Text(data.points.first { $0.series == series && $0.category == category }?.value.formatted() ?? "—")
                                        .font(.footnote).monospacedDigit()
                                }
                            }
                        }
                    }
                }
            } else {
                drawn.frame(height: 180)
            }
            if !node["caption"].isNull { Text(Self.display(node["caption"], scope)).font(.caption2).foregroundStyle(Palette.faint) }
        }
    }

    /// The chart's numbers as tab-separated rows, for a spreadsheet.
    private static func tsv(_ data: (categories: [String], series: [String], points: [Point])) -> String {
        var rows = [([""] + data.series).joined(separator: "\t")]
        for category in data.categories {
            let cells = data.series.map { series in data.points.first { $0.series == series && $0.category == category }?.value.formatted(.number.grouping(.never)) ?? "" }
            rows.append(([category] + cells).joined(separator: "\t"))
        }
        return rows.joined(separator: "\n")
    }

    private func progress(_ node: JSON, _ scope: ViewFormula.Scope) -> some View {
        let fraction: Double = if let percent = Self.number(node["percent"], scope) { percent / 100 } else if let value = Self.number(node["value"], scope), let max = Self.number(node["max"], scope), max > 0 { value / max } else { 0 }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                if !node["label"].isNull { Text(Self.display(node["label"], scope)).font(.caption) }
                Spacer()
                Text(node["valueLabel"].isNull ? "\(Int((fraction * 100).rounded()))%" : Self.display(node["valueLabel"], scope)).font(.caption).monospacedDigit().foregroundStyle(Palette.secondary)
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
                        reply(id, ["selected": [.string(label)]])
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
                Button("提交") { reply(id, ["selected": .array(chosen.sorted().map(JSON.string))]) }
                    .buttonStyle(.capsule(height: 36, fill: false))
                    .disabled(chosen.isEmpty)
            }
        }
    }

    private func confirm(_ node: JSON) -> some View {
        let id = node["id"].string
        return HStack(spacing: 8) {
            Button(node["confirmLabel"].string ?? String(localized: "确认")) { reply(id, ["confirmed": true]) }
                .buttonStyle(.capsule(height: 36, fill: false))
            Button(node["cancelLabel"].string ?? String(localized: "取消")) { reply(id, ["confirmed": false]) }
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
                    reply(id, ["fields": .object(Dictionary(uniqueKeysWithValues: editable.map { ($0, JSON.string(fields[$0] ?? "")) }))])
                }
                .buttonStyle(.capsule(height: 36, fill: false))
                Button(node["cancelLabel"].string ?? String(localized: "取消")) { reply(id, ["canceled": true]) }
                    .buttonStyle(.capsule(.outline, height: 36, fill: false))
            }
        }
    }

    // MARK: Sending

    private func reply(_ action: String?, _ values: [String: JSON]) {
        guard let action, let send else { return }
        var values = values
        if !inputs.isEmpty { values["inputs"] = .object(inputs) }
        send(action, .object(values))
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

    /// A shown value: text, a number, or a formula worked out from the inputs (a dash when it cannot be).
    static func display(_ value: JSON, _ scope: ViewFormula.Scope) -> String {
        if let text = value.string { return text }
        if let number = value.double { return number.formatted() }
        if let bool = value.bool { return bool ? "✓" : "✗" }
        if let formula = value["="].string {
            switch scope.value(of: formula) {
            case .number(let number)?: return number.isFinite ? ViewFormula.Value.number(number).shown : "—"
            case .text(let text)?: return text
            case .flag(let flag)?: return flag ? "✓" : "✗"
            case nil: return "—"
            }
        }
        return "—"
    }

    /// A number given outright or as a formula.
    static func number(_ value: JSON, _ scope: ViewFormula.Scope) -> Double? {
        if let number = value.double { return number }
        guard let formula = value["="].string, case .number(let number)? = scope.value(of: formula), number.isFinite else { return nil }
        return number
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
