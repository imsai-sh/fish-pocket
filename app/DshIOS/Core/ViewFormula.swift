import Foundation

/// The formulas of a view card (`{"=": "price * qty"}`, deep-view's expression language):
/// names, numbers, strings, `+ - * / %`, comparisons, `&& || !`, `a ? b : c`, and a fixed
/// set of functions. A card works its numbers out here each time an input moves; nothing
/// goes back to the model for it.
enum ViewFormula {
    enum Value: Equatable {
        case number(Double)
        case text(String)
        case flag(Bool)

        /// As the card shows it: numbers lose float noise (0.1 + 0.2 reads 0.3).
        var shown: String {
            switch self {
            case .text(let text): return text
            case .flag(let flag): return flag ? "true" : "false"
            case .number(let number):
                guard number.isFinite else { return number.isNaN ? "NaN" : (number < 0 ? "-Infinity" : "Infinity") }
                let rounded = Double(String(format: "%.12g", number)) ?? number
                return rounded == rounded.rounded() && abs(rounded) < 1e15 ? String(Int64(rounded)) : String(rounded)
            }
        }

        var truthy: Bool {
            switch self {
            case .text(let text): !text.isEmpty
            case .flag(let flag): flag
            case .number(let number): number != 0 && !number.isNaN
            }
        }
    }

    struct Failure: Error {}

    indirect enum Node {
        case value(Value)
        case name(String)
        case unary(String, Node)
        case binary(String, Node, Node)
        case choice(Node, Node, Node)
        case call(String, [Node])
    }

    // MARK: Parsing

    private enum Token: Equatable {
        case number(Double), name(String), string(String), op(String)
    }

    private static let operators = ["==", "!=", "<=", ">=", "&&", "||", "+", "-", "*", "/", "%", "<", ">", "!", "?", ":", "(", ")", ","]
    private static let levels: [[String]] = [["||"], ["&&"], ["==", "!="], ["<", "<=", ">", ">="], ["+", "-"], ["*", "/", "%"]]
    private static let arity: [String: ClosedRange<Int>] = [
        "min": 1...64, "max": 1...64, "abs": 1...1, "floor": 1...1, "ceil": 1...1, "sqrt": 1...1, "pow": 2...2,
        "round": 1...2, "clamp": 3...3, "fixed": 1...2, "format": 1...2, "percent": 1...2,
    ]

    private static func tokenize(_ source: String) throws -> [Token] {
        var tokens: [Token] = []
        let chars = Array(source)
        var at = 0
        while at < chars.count {
            let ch = chars[at]
            if ch.isWhitespace { at += 1; continue }
            if ch.isNumber && ch.isASCII || (ch == "." && at + 1 < chars.count && chars[at + 1].isNumber) {
                var end = at
                while end < chars.count, chars[end].isASCII, chars[end].isNumber || chars[end] == "." { end += 1 }
                if end < chars.count, chars[end] == "e" || chars[end] == "E" {
                    var exp = end + 1
                    if exp < chars.count, chars[exp] == "+" || chars[exp] == "-" { exp += 1 }
                    if exp < chars.count, chars[exp].isNumber {
                        while exp < chars.count, chars[exp].isNumber { exp += 1 }
                        end = exp
                    }
                }
                guard let number = Double(String(chars[at..<end])) else { throw Failure() }
                tokens.append(.number(number))
                at = end
                continue
            }
            if ch.isASCII, ch.isLetter || ch == "_" {
                var end = at
                while end < chars.count, chars[end].isASCII, chars[end].isLetter || chars[end].isNumber || chars[end] == "_" { end += 1 }
                tokens.append(.name(String(chars[at..<end])))
                at = end
                continue
            }
            if ch == "\"" || ch == "'" {
                var end = at + 1
                var text = ""
                while end < chars.count, chars[end] != ch {
                    if chars[end] == "\\", end + 1 < chars.count { text.append(chars[end + 1]); end += 2; continue }
                    text.append(chars[end])
                    end += 1
                }
                guard end < chars.count else { throw Failure() }
                tokens.append(.string(text))
                at = end + 1
                continue
            }
            let rest = String(chars[at...])
            guard let op = operators.first(where: { rest.hasPrefix($0) }) else { throw Failure() }
            tokens.append(.op(op))
            at += op.count
        }
        return tokens
    }

    private struct Parser {
        let tokens: [Token]
        var index = 0
        var depth = 0

        var peek: Token? { index < tokens.count ? tokens[index] : nil }
        func isOp(_ value: String) -> Bool { peek == .op(value) }
        mutating func expect(_ value: String) throws {
            guard isOp(value) else { throw Failure() }
            index += 1
        }

        mutating func ternary() throws -> Node {
            depth += 1
            defer { depth -= 1 }
            guard depth <= 64 else { throw Failure() }
            let test = try binary(0)
            guard isOp("?") else { return test }
            index += 1
            let yes = try ternary()
            try expect(":")
            return .choice(test, yes, try ternary())
        }

        mutating func binary(_ level: Int) throws -> Node {
            if level == ViewFormula.levels.count { return try unary() }
            var left = try binary(level + 1)
            while case .op(let op)? = peek, ViewFormula.levels[level].contains(op) {
                index += 1
                left = .binary(op, left, try binary(level + 1))
            }
            return left
        }

        mutating func unary() throws -> Node {
            if case .op(let op)? = peek, ["-", "!", "+"].contains(op) {
                index += 1
                depth += 1
                defer { depth -= 1 }
                guard depth <= 64 else { throw Failure() }
                return .unary(op, try unary())
            }
            return try primary()
        }

        mutating func primary() throws -> Node {
            guard let token = peek else { throw Failure() }
            index += 1
            switch token {
            case .number(let number): return .value(.number(number))
            case .string(let text): return .value(.text(text))
            case .op("("):
                let inner = try ternary()
                try expect(")")
                return inner
            case .name(let name):
                guard isOp("(") else {
                    if name == "true" { return .value(.flag(true)) }
                    if name == "false" { return .value(.flag(false)) }
                    return .name(name)
                }
                guard let takes = ViewFormula.arity[name] else { throw Failure() }
                index += 1
                var args: [Node] = []
                if !isOp(")") {
                    args.append(try ternary())
                    while isOp(",") { index += 1; args.append(try ternary()) }
                }
                try expect(")")
                guard takes.contains(args.count) else { throw Failure() }
                return .call(name, args)
            default: throw Failure()
            }
        }
    }

    static func parse(_ source: String) -> Node? {
        guard let tokens = try? tokenize(source), !tokens.isEmpty else { return nil }
        var parser = Parser(tokens: tokens)
        guard let tree = try? parser.ternary(), parser.index == tokens.count else { return nil }
        return tree
    }

    // MARK: Evaluation

    private static func number(_ value: Value) throws -> Double {
        switch value {
        case .number(let number): return number
        case .flag(let flag): return flag ? 1 : 0
        case .text(let text):
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty, let parsed = Double(text.trimmingCharacters(in: .whitespaces)) else { throw Failure() }
            return parsed
        }
    }

    private static func digits(_ value: Value?) throws -> Int {
        guard let value else { return 0 }
        let number = try number(value)
        guard number == number.rounded(), (0...10).contains(number) else { throw Failure() }
        return Int(number)
    }

    private static func round(_ value: Double, to digits: Int) -> Double {
        let scale = pow(10, Double(digits))
        return (value * scale).rounded(.toNearestOrAwayFromZero) / scale
    }

    /// `1234567.5` as `1,234,567.5`: thousands grouped, a fixed number of decimals.
    private static func grouped(_ value: Double, _ digits: Int) -> String {
        guard value.isFinite else { return Value.number(value).shown }
        let text = String(format: "%.\(digits)f", abs(round(value, to: digits)))
        let parts = text.split(separator: ".", maxSplits: 1).map(String.init)
        var whole = ""
        for (offset, ch) in parts[0].reversed().enumerated() {
            if offset > 0, offset % 3 == 0 { whole.append(",") }
            whole.append(ch)
        }
        let zero = Double(parts.joined()) == 0
        return (value < 0 && !zero ? "-" : "") + String(whole.reversed()) + (parts.count > 1 ? "." + parts[1] : "")
    }

    static func run(_ node: Node, _ lookup: (String) throws -> Value) throws -> Value {
        switch node {
        case .value(let value): return value
        case .name(let name): return try lookup(name)
        case .unary(let op, let inner):
            let value = try run(inner, lookup)
            if op == "!" { return .flag(!value.truthy) }
            return .number(op == "-" ? -(try number(value)) : try number(value))
        case .choice(let test, let yes, let no):
            return try run(test, lookup).truthy ? try run(yes, lookup) : try run(no, lookup)
        case .call(let name, let nodes):
            let args = try nodes.map { try run($0, lookup) }
            let first = try number(args[0])
            switch name {
            case "min": return .number(try args.map(number).min() ?? first)
            case "max": return .number(try args.map(number).max() ?? first)
            case "abs": return .number(abs(first))
            case "floor": return .number(first.rounded(.down))
            case "ceil": return .number(first.rounded(.up))
            case "sqrt": return .number(first.squareRoot())
            case "pow": return .number(pow(first, try number(args[1])))
            case "round": return .number(round(first, to: try digits(args.count > 1 ? args[1] : nil)))
            case "clamp": return .number(min(max(first, try number(args[1])), try number(args[2])))
            case "fixed":
                let places = try digits(args.count > 1 ? args[1] : nil)
                return .text(String(format: "%.\(places)f", round(first, to: places)))
            case "format": return .text(grouped(first, try digits(args.count > 1 ? args[1] : nil)))
            default: return .text(grouped(first * 100, try digits(args.count > 1 ? args[1] : nil)) + "%")
            }
        case .binary(let op, let leftNode, let rightNode):
            if op == "&&" {
                let left = try run(leftNode, lookup)
                return left.truthy ? try run(rightNode, lookup) : .flag(false)
            }
            if op == "||" {
                let left = try run(leftNode, lookup)
                return left.truthy ? left : try run(rightNode, lookup)
            }
            let left = try run(leftNode, lookup), right = try run(rightNode, lookup)
            switch op {
            case "+":
                if case .text = left { return .text(left.shown + right.shown) }
                if case .text = right { return .text(left.shown + right.shown) }
                return .number(try number(left) + number(right))
            case "-": return .number(try number(left) - number(right))
            case "*": return .number(try number(left) * number(right))
            case "/": return .number(try number(left) / number(right))
            case "%": return .number(try number(left).truncatingRemainder(dividingBy: number(right)))
            case "==": return .flag(left == right)
            case "!=": return .flag(left != right)
            case "<": return .flag(try number(left) < number(right))
            case "<=": return .flag(try number(left) <= number(right))
            case ">": return .flag(try number(left) > number(right))
            default: return .flag(try number(left) >= number(right))
            }
        }
    }

    /// One view's names: its inputs as they stand, and the `let` names worked out on demand.
    /// A name that reads itself, or one that is missing, fails the formula that reads it.
    final class Scope {
        private let inputs: [String: Value]
        private let lets: [String: Node]
        private var done: [String: Value] = [:]
        private var busy: Set<String> = []

        init(inputs: [String: JSON], lets: JSON) {
            self.inputs = inputs.compactMapValues { value in
                if let bool = value.bool { return .flag(bool) }
                if let number = value.double { return .number(number) }
                return value.string.map(Value.text)
            }
            var parsed: [String: Node] = [:]
            for (name, source) in lets.object { parsed[name] = source.string.flatMap(ViewFormula.parse) }
            self.lets = parsed
        }

        private func lookup(_ name: String) throws -> Value {
            if let value = inputs[name] { return value }
            if let value = done[name] { return value }
            guard let tree = lets[name], !busy.contains(name) else { throw Failure() }
            busy.insert(name)
            defer { busy.remove(name) }
            let value = try ViewFormula.run(tree, lookup)
            done[name] = value
            return value
        }

        /// A formula's value; nil when it cannot be worked out.
        func value(of source: String) -> Value? {
            guard let tree = ViewFormula.parse(source) else { return nil }
            return try? ViewFormula.run(tree, lookup)
        }
    }
}
