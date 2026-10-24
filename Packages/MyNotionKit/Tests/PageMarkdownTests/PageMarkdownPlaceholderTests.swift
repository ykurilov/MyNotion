import Testing
@testable import PageMarkdown

/// Цель тестов готова к этапу 2 (RoundTripTests, PlainMarkdownTests).
@Test func pageMarkdownModuleLinks() {
    #expect(String(describing: PageMarkdown.self) == "PageMarkdown")
}
