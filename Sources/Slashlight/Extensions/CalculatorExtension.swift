import AppKit
import SlashlightKit

/// Live answers while typing: arithmetic ("(3+4)*2^3", "15% of 80"), units ("5 km in mi") and currencies ("100 usd to eur").
/// Shows nothing unless the text is clearly a calculation, so plain words and bare numbers still reach apps and files.
final class CalculatorExtension: Extension {
    struct Answer {
        /// What ↵ copies and ⌘↵ pastes: a plain number, no grouping separators.
        var value: String
        /// The big title: the number with its unit or currency.
        var display: String
        /// The subtitle: what was understood.
        var expression: String
    }

    private var rates: [String: Double] = [:]
    private var ratesDate: Date?
    private var fetching: Task<Void, Never>?

    override var manifest: Manifest {
        Manifest(id: "calculator", title: "Calculator", subtitle: "Math, units and currencies as you type", icon: .symbol("equal.square"))
    }

    override var triggers: [Trigger] { [.defaultSearch] }

    private var ratesFile: URL { context.supportDirectory.appendingPathComponent("rates.json") }

    override func activate(context: ExtensionContext) async {
        loadCachedRates()
    }

    override func rootView() -> ListView? {
        ListView(title: manifest.title, icon: manifest.icon, placeholder: "2^10, 15% of 80, 5 km in mi, 100 usd to eur…") { [unowned self] q in
            try await self.search(q)
        }
    }

    override func search(_ query: Query) async throws -> [Section] {
        let text = query.text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let a = await answer(text) else { return [] }
        return [Section("Calculator", [
            Item(id: "result", title: a.display, subtitle: a.expression, icon: .symbol("equal.square"),
                 primary: Action("Copy Result", icon: .symbol("doc.on.doc")) { [weak self] in
                     self?.context.copy(a.value)
                     return .hud("Copied \(a.value)")
                 },
                 secondary: Action("Paste Result", icon: .symbol("arrow.down.doc")) { .paste(a.value) },
                 more: [
                    Action("Copy with Unit", icon: .symbol("textformat"), shortcut: Shortcut("c", [.command, .shift])) { [weak self] in
                        self?.context.copy(a.display)
                        return .hud("Copied \(a.display)")
                    },
                 ]),
        ])]
    }

    // MARK: Answers

    private func answer(_ raw: String) async -> Answer? {
        var text = raw.hasSuffix("=") ? String(raw.dropLast()).trimmingCharacters(in: .whitespaces) : raw
        // "$100 to eur" reads as "100 USD to eur".
        if let first = text.first, let code = Self.currencySymbols[first],
           let end = text.dropFirst().firstIndex(where: { !($0.isNumber || $0 == "." || $0 == "," || $0 == " ") }) {
            text = text[text.index(after: text.startIndex)..<end].trimmingCharacters(in: .whitespaces) + " \(code) " + text[end...]
        }

        if let (amountText, fromText, toText) = Self.splitConversion(text) {
            var amount = MathParser(amountText)
            guard let value = amount?.evaluate() else { return nil }
            if let a = Self.convertUnits(value, fromText, toText) { return a }
            return await convertCurrency(value, fromText, toText)
        }

        guard var parser = MathParser(text), let value = parser.evaluate(), parser.isCalculation, value.isFinite else { return nil }
        let plain = Self.format(value, grouping: false)
        return Answer(value: plain, display: Self.format(value, grouping: true), expression: parser.normalized + " =")
    }

    /// "5 km in mi" → ("5", "km", "mi"). The amount may itself be an expression ("2*3 kg to lb").
    private static func splitConversion(_ text: String) -> (String, String, String)? {
        let unit = "[a-zA-Z°µ$€£¥][a-zA-Z°µ/²³ .]*?"
        let pattern = "^(.+?)\\s*(\(unit))\\s+(?:to|in|into|as)\\s+(\(unit))\\s*$"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges == 4,
              let a = Range(m.range(at: 1), in: text), let f = Range(m.range(at: 2), in: text), let t = Range(m.range(at: 3), in: text)
        else { return nil }
        return (String(text[a]), String(text[f]).trimmingCharacters(in: .whitespaces), String(text[t]).trimmingCharacters(in: .whitespaces))
    }

    private static func convertUnits(_ value: Double, _ fromText: String, _ toText: String) -> Answer? {
        guard let from = unit(fromText), let to = unit(toText), dimension(from) == dimension(to) else { return nil }
        let result = to.converter.value(fromBaseUnitValue: from.converter.baseUnitValue(fromValue: value))
        guard result.isFinite else { return nil }
        return Answer(value: format(result, grouping: false, digits: 6), display: "\(format(result, grouping: true, digits: 6)) \(to.symbol)",
                      expression: "\(format(value, grouping: true)) \(from.symbol) → \(to.symbol)")
    }

    private func convertCurrency(_ value: Double, _ fromText: String, _ toText: String) async -> Answer? {
        let codes = Set(Locale.commonISOCurrencyCodes)
        let from = fromText.uppercased(), to = toText.uppercased()
        guard codes.contains(from), codes.contains(to) else { return nil }
        await ensureRates()
        guard let rf = rates[from], let rt = rates[to], rf > 0 else { return nil }
        let result = value / rf * rt
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = result != 0 && abs(result) < 0.01 ? 6 : 2
        f.usesGroupingSeparator = false
        let plain = f.string(from: NSNumber(value: result)) ?? "\(result)"
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        let shown = f.string(from: NSNumber(value: result)) ?? plain
        let age = ratesDate.flatMap { Date().timeIntervalSince($0) > 60 ? " · rates from \($0.relative)" : nil } ?? ""
        return Answer(value: plain, display: "\(shown) \(to)", expression: "\(Self.format(value, grouping: true)) \(from) → \(to)\(age)")
    }

    // MARK: Currency rates

    /// Uses the cached rates when fresh (12 h); otherwise refreshes them, waiting only if there are none yet.
    private func ensureRates() async {
        let stale = ratesDate.map { Date().timeIntervalSince($0) > 12 * 3600 } ?? true
        guard stale else { return }
        if fetching == nil {
            fetching = Task { [weak self] in
                await self?.fetchRates()
                self?.fetching = nil
            }
        }
        if rates.isEmpty { await fetching?.value }
    }

    private struct RatesResponse: Codable {
        var result: String
        var rates: [String: Double]
    }

    private func fetchRates() async {
        guard let url = URL(string: "https://open.er-api.com/v6/latest/USD") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        // Offline or a bad response: keep whatever is cached and stay silent.
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let decoded = try? JSONDecoder().decode(RatesResponse.self, from: data), decoded.result == "success" else { return }
        rates = decoded.rates
        ratesDate = Date()
        try? data.write(to: ratesFile, options: .atomic)
    }

    private func loadCachedRates() {
        guard let data = try? Data(contentsOf: ratesFile), let decoded = try? JSONDecoder().decode(RatesResponse.self, from: data) else { return }
        rates = decoded.rates
        ratesDate = (try? ratesFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static let currencySymbols: [Character: String] = ["$": "USD", "€": "EUR", "£": "GBP", "¥": "JPY", "₽": "RUB", "₹": "INR"]

    // MARK: Formatting

    /// Plain decimal notation with up to `digits` significant digits; scientific only for extreme magnitudes.
    nonisolated static func format(_ value: Double, grouping: Bool, digits: Int = 12) -> String {
        if value != 0 && (abs(value) >= 1e15 || abs(value) < 1e-9) { return String(format: "%.6g", value) }
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesSignificantDigits = true
        f.maximumSignificantDigits = digits
        f.usesGroupingSeparator = grouping
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: value == 0 ? 0 : value)) ?? "\(value)"
    }

    // MARK: Units

    /// Built-in units can be private subclasses, so compare by the public dimension class instead of `type(of:)`.
    private static func dimension(_ unit: Dimension) -> ObjectIdentifier? {
        let kinds: [Dimension.Type] = [UnitLength.self, UnitMass.self, UnitTemperature.self, UnitVolume.self, UnitSpeed.self,
                                       UnitDuration.self, UnitInformationStorage.self]
        return kinds.first { unit.isKind(of: $0) }.map { ObjectIdentifier($0) }
    }

    private static func unit(_ text: String) -> Dimension? {
        let t = text.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        if let u = caseSensitiveUnits[t] { return u }
        let lower = t.lowercased()
        if let u = units[lower] { return u }
        // "kilometres" → "kilometre", "kgs" → "kg".
        if lower.hasSuffix("s"), let u = units[String(lower.dropLast())] { return u }
        return nil
    }

    /// Bits and bytes differ only by case: "Mb" is megabits, "MB" (and "mb") megabytes.
    private static let caseSensitiveUnits: [String: Dimension] = [
        "kb": UnitInformationStorage.kilobytes, "Kb": UnitInformationStorage.kilobits, "Mb": UnitInformationStorage.megabits,
        "Gb": UnitInformationStorage.gigabits, "Tb": UnitInformationStorage.terabits,
    ]

    private static let units: [String: Dimension] = {
        var u: [String: Dimension] = [:]
        func add(_ unit: Dimension, _ names: String...) { for n in names { u[n] = unit } }

        add(UnitLength.millimeters, "mm", "millimeter", "millimetre")
        add(UnitLength.centimeters, "cm", "centimeter", "centimetre")
        add(UnitLength.meters, "m", "meter", "metre")
        add(UnitLength.kilometers, "km", "kilometer", "kilometre")
        add(UnitLength.inches, "in", "inch", "inches", "\"")
        add(UnitLength.feet, "ft", "foot", "feet", "'")
        add(UnitLength.yards, "yd", "yard")
        add(UnitLength.miles, "mi", "mile")
        add(UnitLength.nauticalMiles, "nmi", "nautical mile")

        add(UnitMass.milligrams, "mg", "milligram")
        add(UnitMass.grams, "g", "gram", "gramme")
        add(UnitMass.kilograms, "kg", "kilo", "kilogram")
        add(UnitMass.metricTons, "t", "ton", "tonne", "metric ton")
        add(UnitMass.ounces, "oz", "ounce")
        add(UnitMass.pounds, "lb", "lbs", "pound")
        add(UnitMass.stones, "st", "stone")

        add(UnitTemperature.celsius, "c", "°c", "celsius", "degc")
        add(UnitTemperature.fahrenheit, "f", "°f", "fahrenheit", "degf")
        add(UnitTemperature.kelvin, "k", "kelvin")

        add(UnitVolume.milliliters, "ml", "milliliter", "millilitre")
        add(UnitVolume.liters, "l", "liter", "litre")
        add(UnitVolume.cubicMeters, "m3", "m³", "cubic meter")
        add(UnitVolume.teaspoons, "tsp", "teaspoon")
        add(UnitVolume.tablespoons, "tbsp", "tablespoon")
        add(UnitVolume.fluidOunces, "fl oz", "floz", "fluid ounce")
        add(UnitVolume.cups, "cup")
        add(UnitVolume.pints, "pt", "pint")
        add(UnitVolume.quarts, "qt", "quart")
        add(UnitVolume.gallons, "gal", "gallon")

        add(UnitSpeed.metersPerSecond, "m/s", "mps")
        add(UnitSpeed.kilometersPerHour, "km/h", "kmh", "kph")
        add(UnitSpeed.milesPerHour, "mph", "mi/h")
        add(UnitSpeed.knots, "kn", "kt", "knot")

        add(UnitDuration.milliseconds, "ms", "millisecond")
        add(UnitDuration.seconds, "s", "sec", "second")
        add(UnitDuration.minutes, "min", "minute")
        add(UnitDuration.hours, "h", "hr", "hour")
        add(UnitDuration(symbol: "d", converter: UnitConverterLinear(coefficient: 86_400)), "d", "day")
        add(UnitDuration(symbol: "wk", converter: UnitConverterLinear(coefficient: 604_800)), "wk", "week")
        add(UnitDuration(symbol: "yr", converter: UnitConverterLinear(coefficient: 31_557_600)), "yr", "year")

        add(UnitInformationStorage.bits, "bit")
        add(UnitInformationStorage.bytes, "b", "byte")
        add(UnitInformationStorage.kilobytes, "kilobyte")
        add(UnitInformationStorage.megabytes, "mb", "megabyte")
        add(UnitInformationStorage.gigabytes, "gb", "gigabyte")
        add(UnitInformationStorage.terabytes, "tb", "terabyte")
        add(UnitInformationStorage.kibibytes, "kib", "kibibyte")
        add(UnitInformationStorage.mebibytes, "mib", "mebibyte")
        add(UnitInformationStorage.gibibytes, "gib", "gibibyte")
        add(UnitInformationStorage.megabits, "mbit", "megabit")
        add(UnitInformationStorage.gigabits, "gbit", "gigabit")
        return u
    }()
}

/// Recursive-descent evaluator for the calculator. NSExpression raises Objective-C exceptions on malformed input;
/// this returns nil instead.
///
///     expression := term (("+" | "-") term)*          a + b% means a + b% of a
///     term       := unary (("*" | "/" | "%" | "mod") unary | "of" unary)*   "of" only after a percentage
///     unary      := ("-" | "+") unary | power
///     power      := postfix ("^" unary)?
///     postfix    := primary ("%" | "!")*
///     primary    := number [implicit ×] | "(" expression ")" | constant | function (primary | power)
struct MathParser {
    enum Token: Equatable {
        case number(Double)
        case op(Character)
        case lparen, rparen
        case ident(String)
    }

    private(set) var tokens: [Token] = []
    private var pos = 0
    /// Set once a binary operator, percentage or function is used: the text is a calculation, not just a number.
    private(set) var isCalculation = false

    private static let constants: [String: Double] = ["pi": .pi, "π": .pi, "e": M_E, "tau": 2 * .pi]
    private static let functions: [String: (Double) -> Double] = [
        "sqrt": { $0.squareRoot() }, "cbrt": { cbrt($0) }, "abs": { abs($0) }, "round": { $0.rounded() },
        "floor": { $0.rounded(.down) }, "ceil": { $0.rounded(.up) }, "exp": { exp($0) },
        "sin": { sin($0) }, "cos": { cos($0) }, "tan": { tan($0) }, "asin": { asin($0) }, "acos": { acos($0) }, "atan": { atan($0) },
        "log": { log10($0) }, "lg": { log10($0) }, "ln": { log($0) }, "log2": { log2($0) },
    ]

    init?(_ text: String) {
        var chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isNumber || c == "." {
                var s = ""
                while i < chars.count, chars[i].isNumber || chars[i] == "." || chars[i] == "," || chars[i] == "_" {
                    if chars[i] == "." { s.append(".") } else if chars[i].isNumber { s.append(chars[i]) }
                    i += 1
                }
                guard let v = Double(s) else { return nil }
                tokens.append(.number(v))
                continue
            }
            if c.isLetter {
                var s = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber { s.append(chars[i]); i += 1 }
                tokens.append(.ident(s.lowercased()))
                continue
            }
            switch c {
            case "+": tokens.append(.op("+"))
            case "-", "−", "–": tokens.append(.op("-"))
            case "*", "×", "·":
                if i + 1 < chars.count, chars[i + 1] == "*" { tokens.append(.op("^")); chars.remove(at: i + 1) } else { tokens.append(.op("*")) }
            case "/", "÷": tokens.append(.op("/"))
            case "^": tokens.append(.op("^"))
            case "%": tokens.append(.op("%"))
            case "!": tokens.append(.op("!"))
            case "(": tokens.append(.lparen)
            case ")": tokens.append(.rparen)
            default: return nil
            }
            i += 1
        }
        if tokens.isEmpty { return nil }
    }

    /// The value, or nil when the text does not parse completely.
    mutating func evaluate() -> Double? {
        pos = 0
        guard let (v, _) = expression(), pos == tokens.count else { return nil }
        return v
    }

    /// The tokens re-printed with typographic operators: "(3 + 4) × 2 ^ 3".
    var normalized: String {
        var out = ""
        var prev: Token?
        var prevWasSign = false
        for (i, t) in tokens.enumerated() {
            let afterOperand: Bool
            switch prev {
            case .number?, .rparen?: afterOperand = true
            case .ident(let s)?: afterOperand = Self.constants[s] != nil
            case .op(let o)?: afterOperand = o == "%" || o == "!"
            default: afterOperand = false
            }
            var space = !(prev == nil || prev == .lparen || prevWasSign)
            var isSign = false
            let piece: String
            switch t {
            case .number(let v): piece = CalculatorExtension.format(v, grouping: true)
            case .ident(let s): piece = s == "pi" ? "π" : s
            case .lparen:
                piece = "("
                if case .ident(let s)? = prev, Self.functions[s] != nil { space = false }
            case .rparen:
                piece = ")"
                space = false
            case .op(let o):
                let next = i + 1 < tokens.count ? tokens[i + 1] : nil
                let isModulo: Bool
                switch next {
                case .number?, .lparen?: isModulo = o == "%"
                case .ident(let s)?: isModulo = o == "%" && s != "of"
                default: isModulo = false
                }
                piece = isModulo ? "mod" : ["*": "×", "/": "÷", "-": "−"][o] ?? String(o)
                if (o == "%" || o == "!") && !isModulo { space = false }
                isSign = (o == "-" || o == "+") && !afterOperand
            }
            out += (space ? " " : "") + piece
            prev = t
            prevWasSign = isSign
        }
        return out
    }

    // MARK: Grammar — each returns (value, isBarePercentage)

    private func peek() -> Token? { pos < tokens.count ? tokens[pos] : nil }

    private mutating func expression() -> (Double, Bool)? {
        guard var (value, pct) = term() else { return nil }
        while case .op(let o) = peek(), o == "+" || o == "-" {
            pos += 1
            isCalculation = true
            guard let (rhs, rhsPct) = term() else { return nil }
            // 100 + 10% = 110, like a desk calculator.
            let delta = rhsPct ? value * rhs : rhs
            value = o == "+" ? value + delta : value - delta
            pct = false
        }
        return (value, pct)
    }

    private mutating func term() -> (Double, Bool)? {
        guard var (value, pct) = unary() else { return nil }
        while let t = peek() {
            let op: Character
            switch t {
            case .op(let o) where o == "*" || o == "/" || o == "%": op = o
            case .ident("mod"): op = "%"
            case .ident("of") where pct: op = "*"
            default: return (value, pct)
            }
            pos += 1
            isCalculation = true
            guard let (rhs, _) = unary() else { return nil }
            switch op {
            case "*": value *= rhs
            case "/": value /= rhs
            default: value = value.truncatingRemainder(dividingBy: rhs)
            }
            pct = false
        }
        return (value, pct)
    }

    private mutating func unary() -> (Double, Bool)? {
        if case .op(let o) = peek(), o == "-" || o == "+" {
            pos += 1
            guard let (v, pct) = unary() else { return nil }
            return (o == "-" ? -v : v, pct)
        }
        return power()
    }

    private mutating func power() -> (Double, Bool)? {
        guard let (base, pct) = postfix() else { return nil }
        if case .op("^") = peek() {
            pos += 1
            isCalculation = true
            guard let (exponent, _) = unary() else { return nil }
            return (pow(base, exponent), false)
        }
        return (base, pct)
    }

    private mutating func postfix() -> (Double, Bool)? {
        guard var value = primary() else { return nil }
        var pct = false
        while case .op(let o) = peek(), o == "%" || o == "!" {
            if o == "%" {
                // "10 % 3" is modulo; "15%", "15% of 80", "(15%)" are percentages.
                let next = pos + 1 < tokens.count ? tokens[pos + 1] : nil
                switch next {
                case .number?, .lparen?: return (value, pct)
                case .ident(let s)? where s != "of": return (value, pct)
                default: break
                }
                value /= 100
                pct = true
            } else {
                guard value >= 0, value <= 170, value == value.rounded() else { return nil }
                value = tgamma(value + 1)
                pct = false
            }
            pos += 1
            isCalculation = true
        }
        return (value, pct)
    }

    private mutating func primary() -> Double? {
        guard let t = peek() else { return nil }
        pos += 1
        switch t {
        case .number(let v):
            // Implicit multiplication: "2pi", "3(4+1)".
            switch peek() {
            case .lparen?: isCalculation = true; return primary().map { v * $0 }
            case .ident(let s)? where Self.constants[s] != nil || Self.functions[s] != nil:
                isCalculation = true
                return primary().map { v * $0 }
            default: return v
            }
        case .lparen:
            guard let (v, _) = expression(), peek() == .rparen else { return nil }
            pos += 1
            return v
        case .ident(let name):
            if let c = Self.constants[name] { return c }
            guard let f = Self.functions[name] else { return nil }
            isCalculation = true
            if peek() == .lparen { return primary().map(f) }
            return power().map { f($0.0) }
        default:
            return nil
        }
    }
}
