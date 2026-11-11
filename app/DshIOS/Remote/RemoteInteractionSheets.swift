import SwiftUI

/// The words of a request, in the reader's language: agents send their titles and buttons in English.
enum RemoteNoticeText {
    static func title(of action: RemoteNotice.Action, in notice: RemoteNotice) -> String {
        switch action.id {
        case "approve": String(localized: "允许")
        case "approve_for_session": String(localized: "本会话都允许")
        case "reject": String(localized: "拒绝")
        case "cancel": notice.isApproval ? String(localized: "停止这一轮") : String(localized: "取消")
        case "dismiss": String(localized: "关闭")
        case "submit": String(localized: "提交")
        default: action.label
        }
    }

    static func heading(_ notice: RemoteNotice) -> String {
        guard notice.isApproval else { return notice.title }
        switch notice.context["kind"].string {
        case "command": return String(localized: "允许运行这条命令？")
        case "file_change": return String(localized: "允许修改这些文件？")
        case "permissions": return String(localized: "允许额外的权限？")
        default:
            if let tool = notice.context["toolName"].string ?? notice.source["toolName"].string { return String(localized: "允许使用「\(tool)」？") }
            return notice.title
        }
    }

    /// What is being approved, every character of it.
    static func detail(_ notice: RemoteNotice, call: ToolCall?) -> String? {
        let context = notice.context
        if let command = context["command"].string, !command.isEmpty { return command }
        if let command = call?.arguments["command"].string, !command.isEmpty { return command }
        let input = context["toolInput"]
        if let command = input["command"].string, !command.isEmpty { return command }
        if let path = input["file_path"].string ?? input["path"].string { return path }
        for value in [input, context["permissions"]] where !value.object.isEmpty { return pretty(value) }
        return call?.summary.isEmpty == false ? call?.summary : nil
    }

    static func pretty(_ value: JSON) -> String {
        if let text = value.string { return text }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

/// A set of questions the agent put to the user (`inputRequest`, version 1): each with choices
/// and, unless it says otherwise, room for an answer of the user's own.
struct RemoteQuestionForm: Hashable {
    struct Question: Identifiable, Hashable {
        struct Option: Identifiable, Hashable { let id: String; let label: String; let detail: String? }
        let id: String
        let prompt: String
        let header: String?
        let multiple: Bool
        let allowCustom: Bool
        let options: [Option]
    }

    let actionId: String
    let questions: [Question]

    init?(_ notice: RemoteNotice) {
        guard notice.interaction == "input_request",
              let action = notice.actions.first(where: { $0.uiSchema["component"].string == "inputRequest" && $0.uiSchema["version"].int == 1 }) else { return nil }
        var questions: [Question] = []
        for item in action.uiSchema["questions"].array {
            guard let id = item["id"].string, !id.isEmpty, let prompt = item["prompt"].string, !prompt.isEmpty else { return nil }
            var options: [Question.Option] = []
            for option in item["options"].array {
                guard let id = option["id"].string, let label = option["label"].string, !label.isEmpty else { return nil }
                options.append(.init(id: id, label: label, detail: option["description"].string))
            }
            questions.append(Question(id: id, prompt: prompt, header: item["header"].string, multiple: item["multiple"].bool == true,
                                      allowCustom: item["allowCustom"].bool != false, options: options))
        }
        guard !questions.isEmpty, Set(questions.map(\.id)).count == questions.count else { return nil }
        actionId = action.id
        self.questions = questions
    }

    func answered(_ question: Question, choices: [String: Set<String>], custom: [String: String]) -> Bool {
        !(choices[question.id] ?? []).isEmpty || !(custom[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// nil until every question has an answer.
    func payload(choices: [String: Set<String>], custom: [String: String]) -> JSON? {
        var answers: [String: JSON] = [:]
        for question in questions {
            guard answered(question, choices: choices, custom: custom) else { return nil }
            let selected = choices[question.id] ?? []
            var answer: [String: JSON] = ["optionIds": .array(question.options.filter { selected.contains($0.id) }.map { .string($0.id) })]
            let text = question.allowCustom ? (custom[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : ""
            if !text.isEmpty { answer["customText"] = .string(text) }
            answers[question.id] = .object(answer)
        }
        return .object(["answers": .object(answers)])
    }
}

/// The fields an action asks for, from its JSON schema: text, numbers, switches and choices,
/// nested objects flattened. A schema with anything else is not shown as a form at all.
struct RemoteFieldForm {
    struct Field: Identifiable {
        enum Kind { case text(secure: Bool), number, toggle, choice([JSON]), choices([JSON]) }
        let path: [String]
        let title: String
        let detail: String?
        let kind: Kind
        let required: Bool
        let initial: JSON?
        var id: String { path.joined(separator: "\u{1F}") }
    }

    let fields: [Field]

    init?(schema: JSON, ui: JSON) {
        guard schema["type"].string == "object" else { return nil }
        var fields: [Field] = []
        guard Self.read(schema, ui: ui, path: [], into: &fields) else { return nil }
        self.fields = fields
    }

    private static func read(_ schema: JSON, ui: JSON, path: [String], into fields: inout [Field]) -> Bool {
        guard path.count < 6 else { return false }
        let required = Set(schema["required"].array.compactMap(\.string))
        for key in schema["properties"].object.keys.sorted() {
            let value = schema["properties"][key]
            if value["type"].string == "object" {
                guard read(value, ui: ui[key], path: path + [key], into: &fields) else { return false }
                continue
            }
            let kind: Field.Kind
            if !value["enum"].array.isEmpty {
                kind = .choice(value["enum"].array)
            } else {
                switch value["type"].string {
                case "string": kind = .text(secure: ["password", "secure"].contains(ui[key]["component"].string ?? ""))
                case "boolean": kind = .toggle
                case "integer", "number": kind = .number
                case "array":
                    guard !value["items"]["enum"].array.isEmpty else { return false }
                    kind = .choices(value["items"]["enum"].array)
                default: return false
                }
            }
            fields.append(Field(path: path + [key], title: value["title"].string ?? key, detail: value["description"].string,
                                kind: kind, required: required.contains(key), initial: value["default"].nonNull))
        }
        return true
    }

    /// nil while a required field is empty or a number does not read as one.
    func payload(_ values: [String: JSON]) -> JSON? {
        var result = JSON.object([:])
        for field in fields {
            var value = values[field.id] ?? field.initial
            if case .toggle = field.kind, value == nil { value = false }
            if case .number = field.kind, let text = value?.string {
                if text.isEmpty { value = nil } else if let number = Double(text) { value = .number(number) } else { return nil }
            }
            if case .text = field.kind, value?.string?.isEmpty == true { value = nil }
            guard let value else {
                if field.required { return nil }
                continue
            }
            result = Self.insert(value, at: field.path, into: result)
        }
        return result
    }

    private static func insert(_ value: JSON, at path: [String], into object: JSON) -> JSON {
        guard let key = path.first else { return value }
        var fields = object.object
        fields[key] = insert(value, at: Array(path.dropFirst()), into: fields[key] ?? .object([:]))
        return .object(fields)
    }
}

/// A request from the agent, in the shape of the local approval and question sheets: what it
/// is about, then the answers under the thumb. Pulling it down keeps it waiting behind the
/// line above the composer. An approval is two buttons; questions come one a page; a form
/// shows its fields. A kind this app does not draw says so and points at Agents Anywhere.
struct RemoteNoticeSheet: View {
    let notice: RemoteNotice
    let model: RemoteSessionModel
    @Environment(\.openURL) private var openURL
    @State private var page = 0
    @State private var choices: [String: Set<String>] = [:]
    @State private var custom: [String: String] = [:]
    @State private var others: Set<String> = []
    @State private var values: [String: [String: JSON]] = [:]
    @FocusState private var typing: Bool

    private var questions: RemoteQuestionForm? { RemoteQuestionForm(notice) }

    /// Workflows of other agent kinds carry their own dialog protocol.
    private var unsupported: Bool {
        notice.metadata["ownerGeneration"].string != nil
            || notice.actions.contains { $0.uiSchema["component"].string == "runtimeDialog" }
            || (questions == nil && notice.actions.contains { $0.required && form(for: $0) == nil })
    }

    private var answered: Bool { model.answering.contains(notice.id) }
    /// This session's approvals cannot be answered from a remote client right now.
    private var approvalBlocked: Bool { notice.isApproval && notice.status == "open" && !answered && model.current && !model.canApprove }
    private var enabled: Bool { model.current && notice.answerable && !answered && !model.working && !approvalBlocked }

    var body: some View {
        PinnedActionsSheet {
            VStack(alignment: .leading, spacing: 14) {
                if let questions, !unsupported {
                    questionPage(questions)
                } else {
                    Text(RemoteNoticeText.heading(notice)).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    if let message = notice.message, !message.isEmpty, message != detail {
                        Text(message).font(.subheadline).foregroundStyle(Palette.secondary).lineSpacing(2)
                    }
                    if let detail { RemoteCommandBlock(text: detail) }
                    if unsupported {
                        Text("这种请求要在 Agents Anywhere 里回应。").font(.subheadline).foregroundStyle(Palette.secondary)
                    } else {
                        ForEach(notice.actions) { action in
                            if let form = form(for: action), !form.fields.isEmpty { fields(form, action: action) }
                        }
                    }
                }
                status
            }
            .padding(EdgeInsets(top: 28, leading: 22, bottom: 8, trailing: 22))
        } actions: {
            actions.padding(EdgeInsets(top: 10, leading: 22, bottom: 22, trailing: 22))
        }
    }

    private var detail: String? {
        guard notice.isApproval || !notice.context.object.isEmpty else { return nil }
        if notice.isApproval { return RemoteNoticeText.detail(notice, call: notice.targetItemId.flatMap(model.toolCall)) }
        return nil
    }

    private func form(for action: RemoteNotice.Action) -> RemoteFieldForm? {
        action.schema.isNull ? nil : RemoteFieldForm(schema: action.schema, ui: action.uiSchema)
    }

    @ViewBuilder
    private var status: some View {
        Group {
            if answered {
                Text("已提交，等待智能体确认…")
            } else if approvalBlocked {
                Text("这个会话的审批现在不能从这里回应，请在电脑上处理。")
            } else if ["responding", "response_accepted", "resolving"].contains(notice.status) {
                Text("智能体正在处理回应…")
            } else if let failure = notice.failure {
                Text(failure).foregroundStyle(Palette.removed)
            } else if notice.status == "failed" {
                Text("上次回应没有完成，请重新选择。")
            } else if let expires = notice.expiresAt, expires <= .now {
                Text("这个请求已过期，等待智能体更新。")
            }
        }
        .font(.footnote)
        .foregroundStyle(Palette.secondary)
    }

    // MARK: Answers

    @ViewBuilder
    private var actions: some View {
        if unsupported {
            Button("打开 Agents Anywhere") { openURL(RemoteStore.Links.app) }.buttonStyle(.capsule())
        } else if let questions {
            questionFooter(questions)
        } else {
            let primary = notice.actions.first { $0.style == "primary" } ?? notice.actions.first { !["reject", "cancel", "dismiss"].contains($0.id) }
            let negative = notice.actions.first { $0.id == "reject" } ?? notice.actions.first { ["cancel", "dismiss"].contains($0.id) && $0.id != primary?.id }
            let rest = notice.actions.filter { $0.id != primary?.id && $0.id != negative?.id }
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    if let negative { button(negative, style: .secondary) }
                    if let primary { button(primary, style: .primary) }
                }
                if !rest.isEmpty {
                    HStack(spacing: 18) {
                        ForEach(rest) { action in
                            Button(RemoteNoticeText.title(of: action, in: notice)) { answer(action) }
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(Palette.secondary)
                                .frame(minHeight: 36)
                                .disabled(!enabled || !ready(action))
                        }
                    }
                }
            }
        }
    }

    private func button(_ action: RemoteNotice.Action, style: CapsuleButtonStyle.Kind) -> some View {
        Button(RemoteNoticeText.title(of: action, in: notice)) { answer(action) }
            .buttonStyle(.capsule(style))
            .disabled(!enabled || !ready(action))
            .opacity(enabled && ready(action) ? 1 : 0.5)
    }

    private func input(for action: RemoteNotice.Action) -> JSON? {
        guard let form = form(for: action), !form.fields.isEmpty else { return nil }
        return form.payload(values[action.id] ?? [:])
    }

    private func ready(_ action: RemoteNotice.Action) -> Bool {
        guard let form = form(for: action), !form.fields.isEmpty else { return !action.required || action.schema.isNull }
        if !action.required, (values[action.id] ?? [:]).isEmpty { return true }
        return form.payload(values[action.id] ?? [:]) != nil
    }

    private func answer(_ action: RemoteNotice.Action) {
        guard enabled else { return }
        let positive = !["reject", "cancel", "dismiss"].contains(action.id)
        if positive { Haptics.success() } else { Haptics.tap() }
        typing = false
        let input = !action.required && (values[action.id] ?? [:]).isEmpty ? nil : input(for: action)
        Task { _ = await model.respond(notice, action: action.id, input: input) }
    }

    // MARK: Fields

    private func fields(_ form: RemoteFieldForm, action: RemoteNotice.Action) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(form.fields) { field in
                VStack(alignment: .leading, spacing: 6) {
                    Text(field.title).font(.subheadline.weight(.medium))
                    if let detail = field.detail { Text(detail).font(.footnote).foregroundStyle(Palette.secondary) }
                    control(field, action: action)
                }
            }
        }
        .disabled(!enabled)
    }

    private func binding(_ field: RemoteFieldForm.Field, _ action: RemoteNotice.Action) -> Binding<JSON?> {
        Binding(get: { values[action.id]?[field.id] ?? field.initial }, set: { values[action.id, default: [:]][field.id] = $0 })
    }

    @ViewBuilder
    private func control(_ field: RemoteFieldForm.Field, action: RemoteNotice.Action) -> some View {
        let value = binding(field, action)
        let text = Binding(get: { value.wrappedValue?.string ?? value.wrappedValue?.double.map { String($0) } ?? "" }, set: { value.wrappedValue = .string($0) })
        switch field.kind {
        case .text(let secure):
            Group {
                if secure { SecureField(field.title, text: text) } else { TextField(field.title, text: text, axis: .vertical).lineLimit(1...4) }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($typing)
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Palette.field, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        case .number:
            TextField(field.title, text: text)
                .keyboardType(.numbersAndPunctuation)
                .focused($typing)
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Palette.field, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        case .toggle:
            Toggle(isOn: Binding(get: { value.wrappedValue?.bool ?? false }, set: { value.wrappedValue = .bool($0) })) { EmptyView() }
                .toggleStyle(.mono)
        case .choice(let options):
            optionList(options, selected: { value.wrappedValue == $0 }, multiple: false) { value.wrappedValue = $0 }
        case .choices(let options):
            let current = value.wrappedValue?.array ?? []
            optionList(options, selected: { current.contains($0) }, multiple: true) { option in
                value.wrappedValue = .array(current.contains(option) ? current.filter { $0 != option } : current + [option])
            }
        }
    }

    private func optionList(_ options: [JSON], selected: @escaping (JSON) -> Bool, multiple: Bool, pick: @escaping (JSON) -> Void) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button { Haptics.select(); pick(option) } label: {
                    HStack(spacing: 12) {
                        marker(on: selected(option), multiple: multiple)
                        Text(RemoteNoticeText.pretty(option)).font(.callout).foregroundStyle(Palette.ink)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(Palette.grouped, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func marker(on: Bool, multiple: Bool) -> some View {
        Image(systemName: on ? (multiple ? "checkmark.circle.fill" : "largecircle.fill.circle") : "circle")
            .font(.title3)
            .foregroundStyle(on ? Palette.ink : Palette.faint)
    }

    // MARK: Questions

    @ViewBuilder
    private func questionPage(_ form: RemoteQuestionForm) -> some View {
        let index = min(page, form.questions.count - 1)
        let question = form.questions[index]
        VStack(alignment: .leading, spacing: 10) {
            if form.questions.count > 1 || question.header != nil {
                HStack(spacing: 8) {
                    if index > 0 {
                        Button { move(to: index - 1) } label: {
                            Image(systemName: "chevron.left").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink).hitTarget()
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, -14)
                        .accessibilityLabel("上一题")
                    }
                    if form.questions.count > 1 {
                        Text(verbatim: "\(index + 1)/\(form.questions.count)").font(.subheadline.monospacedDigit()).foregroundStyle(Palette.secondary)
                    }
                    if let header = question.header { Text(header).font(.footnote).foregroundStyle(Palette.secondary) }
                }
                .frame(minHeight: 24)
            }
            Text(question.prompt).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
        }
        VStack(spacing: 0) {
            ForEach(question.options) { option in
                let on = choices[question.id]?.contains(option.id) ?? false
                Button { pick(option, in: question, form: form, index: index) } label: {
                    HStack(alignment: .top, spacing: 12) {
                        marker(on: on, multiple: question.multiple)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option.label).font(.callout).foregroundStyle(Palette.ink)
                            if let detail = option.detail { Text(detail).font(.footnote).foregroundStyle(Palette.secondary) }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            if question.allowCustom {
                let open = question.options.isEmpty || others.contains(question.id) || !(custom[question.id] ?? "").isEmpty
                if !question.options.isEmpty {
                    Button { toggleOther(question, open: open) } label: {
                        HStack(spacing: 12) {
                            marker(on: open, multiple: question.multiple)
                            Text("其他…").font(.callout).foregroundStyle(Palette.ink)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 13)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if open {
                    TextField("输入你的答案", text: Binding(get: { custom[question.id] ?? "" }, set: { text in
                        custom[question.id] = text
                        if !question.multiple, !text.isEmpty { choices[question.id] = [] }
                    }), axis: .vertical)
                    .font(.callout)
                    .lineLimit(1...6)
                    .focused($typing)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                }
            }
        }
        .background(Palette.grouped, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .disabled(!enabled)
    }

    private func move(to next: Int) {
        typing = false
        withAnimation(.snappy(duration: 0.2)) { page = next }
    }

    private func pick(_ option: RemoteQuestionForm.Question.Option, in question: RemoteQuestionForm.Question, form: RemoteQuestionForm, index: Int) {
        Haptics.select()
        var selected = choices[question.id] ?? []
        if question.multiple {
            if !selected.insert(option.id).inserted { selected.remove(option.id) }
        } else {
            selected = [option.id]
            custom[question.id] = nil
            others.remove(question.id)
        }
        choices[question.id] = selected
        if !question.multiple, index < form.questions.count - 1 { move(to: index + 1) }
    }

    private func toggleOther(_ question: RemoteQuestionForm.Question, open: Bool) {
        Haptics.select()
        if open {
            others.remove(question.id)
            custom[question.id] = nil
            typing = false
        } else {
            others.insert(question.id)
            if !question.multiple { choices[question.id] = [] }
            Task {
                try? await Task.sleep(for: .milliseconds(50))
                typing = true
            }
        }
    }

    @ViewBuilder
    private func questionFooter(_ form: RemoteQuestionForm) -> some View {
        let index = min(page, form.questions.count - 1)
        let last = index == form.questions.count - 1
        let payload = form.payload(choices: choices, custom: custom)
        VStack(spacing: 6) {
            if last {
                Button("提交") {
                    guard let payload, enabled else { return }
                    Haptics.success()
                    typing = false
                    Task { _ = await model.respond(notice, action: form.actionId, input: payload) }
                }
                .buttonStyle(.capsule())
                .disabled(payload == nil || !enabled)
                .opacity(payload == nil || !enabled ? 0.5 : 1)
            } else {
                let done = form.answered(form.questions[index], choices: choices, custom: custom)
                Button("下一题") { move(to: index + 1) }
                    .buttonStyle(.capsule())
                    .disabled(!done)
                    .opacity(done ? 1 : 0.5)
            }
            let rest = notice.actions.filter { $0.id != form.actionId && !$0.required }
            if !rest.isEmpty {
                HStack(spacing: 18) {
                    ForEach(rest) { action in
                        Button(RemoteNoticeText.title(of: action, in: notice)) { answer(action) }
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Palette.secondary)
                            .frame(minHeight: 36)
                            .disabled(!enabled)
                    }
                }
            }
        }
    }
}

/// What is being approved: lines wrap, and a long one scrolls in its own block.
private struct RemoteCommandBlock: View {
    let text: String
    @State private var height: CGFloat = 52
    private let limit: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView {
                Text(text)
                    .font(.subheadline.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            }
            .frame(height: min(height, limit))
            .scrollBounceBehavior(.basedOnSize)
            .background(Palette.field, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            if height > limit {
                Text("内容较长，滑动查看全部").font(.caption).foregroundStyle(Palette.secondary)
            }
        }
    }
}

/// A plan the agent wrote in its plan mode: run it, send it back with a note, or leave it.
struct RemotePlanSheet: View {
    let plan: RemotePlan
    let model: RemoteSessionModel
    @State private var revising = false
    @State private var feedback = ""
    @FocusState private var typing: Bool

    var body: some View {
        PinnedActionsSheet {
            VStack(alignment: .leading, spacing: 14) {
                Text("计划待确认").font(.footnote).foregroundStyle(Palette.secondary)
                if !plan.title.isEmpty { Text(plan.title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader) }
                MarkdownView(text: plan.markdown).modifier(LinkOpening())
                if revising {
                    TextField("要改什么", text: $feedback, axis: .vertical)
                        .font(.callout)
                        .lineLimit(2...6)
                        .focused($typing)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Palette.field, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .padding(EdgeInsets(top: 28, leading: 22, bottom: 8, trailing: 22))
        } actions: {
            VStack(spacing: 6) {
                if revising {
                    HStack(spacing: 10) {
                        Button("返回") { revising = false; typing = false }.buttonStyle(.capsule(.secondary))
                        Button("发送修改意见") { act("request_revision", feedback: feedback.trimmingCharacters(in: .whitespacesAndNewlines)) }
                            .buttonStyle(.capsule())
                            .disabled(feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.working)
                    }
                } else {
                    HStack(spacing: 10) {
                        Button("不执行") { act("dismiss_review") }.buttonStyle(.capsule(.secondary))
                        Button("同意并执行") { Haptics.success(); act("approve_and_execute") }.buttonStyle(.capsule())
                    }
                    .disabled(model.working)
                    Button("要求修改…") { revising = true; typing = true }
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Palette.secondary)
                        .frame(minHeight: 36)
                }
            }
            .padding(EdgeInsets(top: 10, leading: 22, bottom: 22, trailing: 22))
        }
    }

    private func act(_ action: String, feedback: String = "") {
        typing = false
        Task { _ = await model.respond(plan: plan, action: action, feedback: feedback) }
    }
}
