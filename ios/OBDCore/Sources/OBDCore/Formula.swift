import Foundation

/// Fórmulas estilo Torque Pro: A, B, C... son los bytes de datos después del eco
/// del servicio y del PID/DID. Gramática (idéntica a tools/pidtool.py):
///
///   expr    := term (('+' | '-') term)*
///   term    := unary (('*' | '/') unary)*
///   unary   := '-' unary | primary
///   primary := número | 0xHEX | BYTE | func '(' expr (',' expr)* ')' | '(' expr ')'
///   func    := s8 u16 s16 u24 u32 s32 bit min max abs
public struct Formula: Sendable, Equatable {
    public let source: String
    let root: Node
    /// Índice más alto de byte usado (A=0). -1 si no usa bytes.
    public let maxByteIndex: Int
    /// Bytes (A=0) que usa la fórmula, ordenados.
    public let byteIndices: [Int]

    public enum FormulaError: Error, Equatable, CustomStringConvertible {
        case syntax(String)
        case missingByte(Character, available: Int)
        case divisionByZero

        public var description: String {
            switch self {
            case .syntax(let s): return "fórmula inválida: \(s)"
            case .missingByte(let c, let n): return "falta el byte \(c) (llegaron \(n))"
            case .divisionByZero: return "división entre cero"
            }
        }
    }

    indirect enum Node: Sendable, Equatable {
        case number(Double)
        case byte(Int)
        case neg(Node)
        case binary(Character, Node, Node)
        case call(String, [Node])
    }

    static let arity: [String: Int] = [
        "s8": 1, "u16": 2, "s16": 2, "u24": 3, "u32": 4, "s32": 4,
        "bit": 2, "min": 2, "max": 2, "abs": 1,
    ]

    public init(_ source: String) throws {
        self.source = source
        var p = Parser(tokens: try Formula.tokenize(source))
        let node = try p.parseExpr()
        guard p.pos == p.tokens.count else { throw FormulaError.syntax("sobra texto en \(source)") }
        root = node
        maxByteIndex = Formula.maxIndex(node)
        byteIndices = Array(Formula.indices(node)).sorted()
    }

    public func evaluate(_ data: [UInt8]) throws -> Double {
        try Formula.eval(root, data)
    }

    // MARK: - Tokenizer

    enum Token: Equatable {
        case num(Double), ident(String), op(Character)
    }

    static func tokenize(_ s: String) throws -> [Token] {
        var out: [Token] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if "+-*/(),".contains(c) { out.append(.op(c)); i += 1; continue }
            if c == "0", i + 1 < chars.count, chars[i + 1] == "x" || chars[i + 1] == "X" {
                var j = i + 2
                while j < chars.count, chars[j].isHexDigit { j += 1 }
                guard j > i + 2, let v = UInt64(String(chars[(i + 2)..<j]), radix: 16) else {
                    throw FormulaError.syntax("hex inválido")
                }
                out.append(.num(Double(v))); i = j; continue
            }
            if c.isNumber || c == "." {
                var j = i
                while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
                guard let v = Double(String(chars[i..<j])) else { throw FormulaError.syntax("número inválido") }
                out.append(.num(v)); i = j; continue
            }
            if c.isLetter {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                out.append(.ident(String(chars[i..<j]))); i = j; continue
            }
            throw FormulaError.syntax("carácter inesperado '\(c)'")
        }
        return out
    }

    // MARK: - Parser

    struct Parser {
        let tokens: [Token]
        var pos = 0

        func peek() -> Token? { pos < tokens.count ? tokens[pos] : nil }

        mutating func expect(_ c: Character) throws {
            guard peek() == .op(c) else { throw FormulaError.syntax("se esperaba '\(c)'") }
            pos += 1
        }

        mutating func parseExpr() throws -> Node {
            var lhs = try parseTerm()
            while let t = peek(), t == .op("+") || t == .op("-") {
                pos += 1
                guard case .op(let o) = t else { break }
                lhs = .binary(o, lhs, try parseTerm())
            }
            return lhs
        }

        mutating func parseTerm() throws -> Node {
            var lhs = try parseUnary()
            while let t = peek(), t == .op("*") || t == .op("/") {
                pos += 1
                guard case .op(let o) = t else { break }
                lhs = .binary(o, lhs, try parseUnary())
            }
            return lhs
        }

        mutating func parseUnary() throws -> Node {
            if peek() == .op("-") { pos += 1; return .neg(try parseUnary()) }
            return try parsePrimary()
        }

        mutating func parsePrimary() throws -> Node {
            guard let t = peek() else { throw FormulaError.syntax("fin inesperado") }
            pos += 1
            switch t {
            case .num(let v):
                return .number(v)
            case .op("("):
                let e = try parseExpr()
                try expect(")")
                return e
            case .ident(let name):
                if peek() == .op("(") {
                    pos += 1
                    var args = [try parseExpr()]
                    while peek() == .op(",") { pos += 1; args.append(try parseExpr()) }
                    try expect(")")
                    guard let n = Formula.arity[name] else { throw FormulaError.syntax("función desconocida \(name)") }
                    guard n == args.count else { throw FormulaError.syntax("\(name) espera \(n) argumentos") }
                    return .call(name, args)
                }
                if name.count == 1, let a = name.unicodeScalars.first, a.value >= 65, a.value <= 90 {
                    return .byte(Int(a.value) - 65)
                }
                throw FormulaError.syntax("identificador desconocido \(name)")
            default:
                throw FormulaError.syntax("token inesperado")
            }
        }
    }

    // MARK: - Eval

    static func maxIndex(_ n: Node) -> Int {
        switch n {
        case .number: return -1
        case .byte(let i): return i
        case .neg(let x): return maxIndex(x)
        case .binary(_, let a, let b): return max(maxIndex(a), maxIndex(b))
        case .call(_, let args): return args.map(maxIndex).max() ?? -1
        }
    }

    static func indices(_ n: Node) -> Set<Int> {
        switch n {
        case .number: return []
        case .byte(let i): return [i]
        case .neg(let x): return indices(x)
        case .binary(_, let a, let b): return indices(a).union(indices(b))
        case .call(_, let args): return args.reduce(into: Set<Int>()) { $0.formUnion(indices($1)) }
        }
    }

    static func unsigned(_ v: [Double]) -> Double {
        v.reduce(0) { $0 * 256 + $1 }
    }

    static func signed(_ v: [Double]) -> Double {
        let u = unsigned(v)
        let half = pow(2.0, Double(8 * v.count - 1))
        return u >= half ? u - 2 * half : u
    }

    static func eval(_ n: Node, _ data: [UInt8]) throws -> Double {
        switch n {
        case .number(let v): return v
        case .byte(let i):
            guard i < data.count else {
                throw FormulaError.missingByte(Character(UnicodeScalar(65 + i)!), available: data.count)
            }
            return Double(data[i])
        case .neg(let x): return -(try eval(x, data))
        case .binary(let o, let a, let b):
            let l = try eval(a, data), r = try eval(b, data)
            switch o {
            case "+": return l + r
            case "-": return l - r
            case "*": return l * r
            default:
                guard r != 0 else { throw FormulaError.divisionByZero }
                return l / r
            }
        case .call(let name, let args):
            let v = try args.map { try eval($0, data) }
            switch name {
            case "s8", "s16", "s32": return signed(v)
            case "u16", "u24", "u32": return unsigned(v)
            case "bit": return Double((Int(v[0]) >> Int(v[1])) & 1)
            case "min": return Swift.min(v[0], v[1])
            case "max": return Swift.max(v[0], v[1])
            default: return Swift.abs(v[0])
            }
        }
    }
}
