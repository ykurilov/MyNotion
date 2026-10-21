/// Ошибка формулы по-русски с местом в тексте (contracts/formulas.md, «Редактор»).
public struct FormulaError: Error, Sendable, Hashable, CustomStringConvertible {
    public var message: String
    /// Место в тексте формулы (смещения в символах Swift).
    public var range: Range<Int>?

    public init(_ message: String, at range: Range<Int>? = nil) {
        self.message = message
        self.range = range
    }

    public var description: String { message }
}
