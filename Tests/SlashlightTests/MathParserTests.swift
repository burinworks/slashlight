import Testing
@testable import Slashlight

@Suite("Calculator parser")
struct MathParserTests {
    private func eval(_ text: String) -> Double? {
        var parser = MathParser(text)
        return parser?.evaluate()
    }

    @Test(arguments: [
        ("1+2", 3.0), ("2*3+4", 10), ("2+3*4", 14), ("(3+4)*2^3", 56), ("2^3^2", 512),
        ("-5+2", -3), ("10/4", 2.5), ("sqrt(16)", 4), ("15% of 80", 12), ("2pi", 2 * Double.pi),
    ])
    func evaluates(text: String, expected: Double) throws {
        let value = try #require(eval(text))
        #expect(abs(value - expected) < 1e-9)
    }

    @Test(arguments: ["", "2+", "(1+2", "hello", "*3"])
    func rejectsInvalid(text: String) {
        #expect(eval(text) == nil)
    }

    @Test func plainNumberIsNotACalculation() {
        var plain = MathParser("42")
        _ = plain?.evaluate()
        #expect(plain?.isCalculation == false)
        var sum = MathParser("40+2")
        _ = sum?.evaluate()
        #expect(sum?.isCalculation == true)
    }

    @Test func formatting() {
        #expect(CalculatorExtension.format(1234567, grouping: false) == "1234567")
        #expect(CalculatorExtension.format(0.5, grouping: false) == "0.5")
    }
}

@Suite("Calculator percentages")
struct PercentTests {
    @Test func addPercent() {
        var p = MathParser("200 + 10%")
        #expect(p?.evaluate() == 220)
    }
}
