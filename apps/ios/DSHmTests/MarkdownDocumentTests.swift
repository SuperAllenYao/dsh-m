import XCTest
import SwiftUI
@testable import DSHm

/// Block-level markdown parser + render-support tests.
final class MarkdownDocumentTests: XCTestCase {

    private func parse(_ text: String) -> [MarkdownBlock] {
        MarkdownParser.parse(text)
    }

    // MARK: - Headings

    func testATXHeadingsAllLevels() {
        let blocks = parse("# h1\n## h2\n### h3\n#### h4\n##### h5\n###### h6")
        XCTAssertEqual(blocks.count, 6)
        XCTAssertEqual(blocks[0], .heading(level: 1, text: "h1"))
        XCTAssertEqual(blocks[1], .heading(level: 2, text: "h2"))
        XCTAssertEqual(blocks[2], .heading(level: 3, text: "h3"))
        XCTAssertEqual(blocks[3], .heading(level: 4, text: "h4"))
        XCTAssertEqual(blocks[4], .heading(level: 5, text: "h5"))
        XCTAssertEqual(blocks[5], .heading(level: 6, text: "h6"))
    }

    func testHeadingClosingHashesAndEdgeCases() {
        XCTAssertEqual(parse("## Title ##"), [.heading(level: 2, text: "Title")])
        XCTAssertEqual(parse("### C#"), [.heading(level: 3, text: "C#")])
        // No space after the hash run is not a heading.
        XCTAssertEqual(parse("#hashtag"), [.paragraph("#hashtag")])
        XCTAssertEqual(parse("####### seven"), [.paragraph("####### seven")])
    }

    func testHeadingFollowedByParagraphNeedsNoBlankLine() {
        let blocks = parse("# Title\nBody right after heading")
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "Title"),
            .paragraph("Body right after heading"),
        ])
    }

    // MARK: - Paragraphs

    func testParagraphPreservesSoftLineBreaks() {
        XCTAssertEqual(parse("line one\nline two"), [.paragraph("line one\nline two")])
    }

    func testBlankLineSplitsParagraphs() {
        let blocks = parse("first paragraph\n\nsecond paragraph")
        XCTAssertEqual(blocks, [.paragraph("first paragraph"), .paragraph("second paragraph")])
    }

    // MARK: - Lists

    func testUnorderedListCombinesMarkerStyles() {
        let blocks = parse("- alpha\n* beta\n+ gamma")
        guard case .list(let list)? = blocks.first else {
            return XCTFail("expected one list block, got \(blocks)")
        }
        XCTAssertFalse(list.ordered)
        XCTAssertEqual(list.items.map(\.text), ["alpha", "beta", "gamma"])
        XCTAssertEqual(list.items.map(\.level), [0, 0, 0])
        XCTAssertEqual(blocks.count, 1)
    }

    func testOrderedListKeepsStartNumber() {
        let blocks = parse("3. three\n4. four")
        guard case .list(let list)? = blocks.first else {
            return XCTFail("expected one list block, got \(blocks)")
        }
        XCTAssertTrue(list.ordered)
        XCTAssertEqual(list.start, 3)
        XCTAssertEqual(list.items.map(\.text), ["three", "four"])
    }

    func testNestedListSupportsTwoLevels() {
        let blocks = parse("- top\n  - nested\n  - nested two\n- top again")
        guard case .list(let list)? = blocks.first, blocks.count == 1 else {
            return XCTFail("expected one list block, got \(blocks)")
        }
        XCTAssertEqual(list.items.map(\.level), [0, 1, 1, 0])
        XCTAssertEqual(list.items.map(\.text), ["top", "nested", "nested two", "top again"])
    }

    func testListKindChangeStartsNewBlock() {
        let blocks = parse("- bullet\n1. ordered")
        XCTAssertEqual(blocks.count, 2)
        guard case .list(let first)? = blocks.first, case .list(let second)? = blocks.last else {
            return XCTFail("expected two list blocks, got \(blocks)")
        }
        XCTAssertFalse(first.ordered)
        XCTAssertTrue(second.ordered)
    }

    func testTaskListStates() {
        let blocks = parse("- [ ] todo\n- [x] done\n- [X] done caps\n- plain item")
        guard case .list(let list)? = blocks.first else {
            return XCTFail("expected one list block, got \(blocks)")
        }
        XCTAssertEqual(list.items.map(\.task), [.unchecked, .checked, .checked, nil])
        XCTAssertEqual(list.items.map(\.text), ["todo", "done", "done caps", "plain item"])
    }

    // MARK: - Fenced code

    func testFencedCodeBlockKeepsLanguageAndBlankLines() {
        let blocks = parse("```swift\nlet a = 1\n\nprint(a)\n```")
        XCTAssertEqual(blocks, [.codeBlock(language: "swift", code: "let a = 1\n\nprint(a)")])
    }

    func testFencedCodeBlockWithoutLanguage() {
        let blocks = parse("~~~\nplain code\n~~~")
        XCTAssertEqual(blocks, [.codeBlock(language: nil, code: "plain code")])
    }

    func testUnterminatedFenceConsumesRestOfText() {
        let blocks = parse("```\nlet a = 1\n# not a heading")
        XCTAssertEqual(blocks, [.codeBlock(language: nil, code: "let a = 1\n# not a heading")])
    }

    func testCodeBlockFollowedByParagraph() {
        let blocks = parse("```js\nvar x = 1\n```\nafter code")
        XCTAssertEqual(blocks, [
            .codeBlock(language: "js", code: "var x = 1"),
            .paragraph("after code"),
        ])
    }

    // MARK: - Blockquote

    func testBlockquoteStripsMarkerAndKeepsLines() {
        XCTAssertEqual(parse("> line one\n> line two"), [.quote(["line one", "line two"])])
    }

    func testBlockquoteSeparatedFromFollowingParagraph() {
        let blocks = parse("> quoted\n\nafter")
        XCTAssertEqual(blocks, [.quote(["quoted"]), .paragraph("after")])
    }

    // MARK: - Thematic break

    func testThematicBreakVariants() {
        XCTAssertEqual(parse("---\n\n***\n\n___"), [.horizontalRule, .horizontalRule, .horizontalRule])
        XCTAssertEqual(parse("* * *"), [.horizontalRule])
    }

    // MARK: - Tables

    func testTableHeaderAndRows() {
        let text = """
        | Name | Age |
        | --- | ---: |
        | Alice | 30 |
        | Bob | 4 |
        """
        let blocks = parse(text)
        guard case .table(let table)? = blocks.first, blocks.count == 1 else {
            return XCTFail("expected one table block, got \(blocks)")
        }
        XCTAssertEqual(table.header, ["Name", "Age"])
        XCTAssertEqual(table.rows, [["Alice", "30"], ["Bob", "4"]])
    }

    func testTableWithoutDelimiterRowFallsBackToParagraph() {
        let blocks = parse("| a | b |\n| nope | --- |")
        XCTAssertEqual(blocks.count, 1)
        guard case .paragraph(let text)? = blocks.first else {
            return XCTFail("expected paragraph fallback, got \(blocks)")
        }
        XCTAssertTrue(text.contains("| a | b |"))
    }

    func testTableHeaderOnlyAndRaggedRows() {
        let headerOnly = parse("| a | b |\n| --- | --- |")
        XCTAssertEqual(headerOnly, [.table(MarkdownTable(header: ["a", "b"], rows: []))])

        let ragged = parse("| a | b |\n| --- | --- |\n| only one |")
        guard case .table(let table)? = ragged.first else {
            return XCTFail("expected table, got \(ragged)")
        }
        XCTAssertEqual(table.rows, [["only one", ""]])
    }

    func testTableEscapedPipeStaysInCell() {
        let blocks = parse("| a | b |\n| --- | --- |\n| x \\| y | z |")
        guard case .table(let table)? = blocks.first else {
            return XCTFail("expected table, got \(blocks)")
        }
        XCTAssertEqual(table.rows, [["x | y", "z"]])
    }

    // MARK: - Mixed documents

    func testMixedDocumentBlockOrder() {
        let text = """
        # Title

        Intro paragraph with **bold**.

        - item one
        - item two

        ```swift
        let x = 1
        ```

        > quoted line

        ---

        | a | b |
        | --- | --- |
        | 1 | 2 |
        """
        let blocks = parse(text)
        XCTAssertEqual(blocks.count, 7)
        guard blocks.count == 7 else { return }
        guard case .heading(let level, let headingText) = blocks[0] else { return XCTFail("0 not heading") }
        XCTAssertEqual(level, 1)
        XCTAssertEqual(headingText, "Title")
        guard case .paragraph = blocks[1] else { return XCTFail("1 not paragraph") }
        guard case .list = blocks[2] else { return XCTFail("2 not list") }
        guard case .codeBlock(let language, _) = blocks[3] else { return XCTFail("3 not code") }
        XCTAssertEqual(language, "swift")
        guard case .quote = blocks[4] else { return XCTFail("4 not quote") }
        XCTAssertEqual(blocks[5], .horizontalRule)
        guard case .table = blocks[6] else { return XCTFail("6 not table") }
    }

    // MARK: - Robustness

    func testEmptyAndWhitespaceOnlyText() {
        XCTAssertEqual(parse(""), [])
        XCTAssertEqual(parse("   \n\n\t\n"), [])
    }

    func testMalformedInputDoesNotCrash() {
        let samples = [
            "```", "~~~", "|", "||", "| --- |", "> ", ">", "- ", "1.", "[x]", "#", "#####",
            "---", "> > >", "- [", "| a |\n| ", "text | pipe", "**unclosed bold", "`unclosed code",
            "[broken](link", "\\|\\|", "\u{0}\u{1}", "- [ ]", "- [x]",
        ]
        for sample in samples {
            XCTAssertNoThrow(MarkdownParser.parse(sample), "threw on: \(sample.debugDescription)")
            _ = MarkdownParser.parse(sample)
        }
        // Unterminated inline markdown still renders as plain text.
        XCTAssertEqual(parse("|"), [.paragraph("|")])
    }

    func testVeryLongLineDoesNotCrash() {
        let longLine = String(repeating: "word ", count: 20_000) // ~100 KB single line
        let blocks = parse(longLine)
        XCTAssertEqual(blocks.count, 1)
        guard case .paragraph(let text)? = blocks.first else { return XCTFail("expected paragraph") }
        XCTAssertEqual(text.count, longLine.trimmingCharacters(in: .whitespaces).count)
    }

    // MARK: - Inline markdown (AttributedString)

    func testInlineFormattingAttributes() {
        let attributed = MarkdownInline.attributed("~~gone~~ and **bold** and [link](https://example.com)")
        var struckThrough = false
        var stronglyEmphasized = false
        var link: URL?
        for run in attributed.runs {
            if run.inlinePresentationIntent?.contains(.strikethrough) == true { struckThrough = true }
            if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true { stronglyEmphasized = true }
            if let runLink = run.link { link = runLink }
        }
        XCTAssertTrue(struckThrough)
        XCTAssertTrue(stronglyEmphasized)
        XCTAssertEqual(link?.absoluteString, "https://example.com")
        XCTAssertEqual(String(attributed.characters), "gone and bold and link")
    }

    func testInlineCodeGetsMonospacedFont() {
        let attributed = MarkdownInline.attributed("run `xcodebuild test` now")
        var codeFont: Font?
        var codeColor: Color?
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            codeFont = run.font
            codeColor = run.foregroundColor
        }
        XCTAssertNotNil(codeFont, "inline code should carry a monospaced font attribute")
        XCTAssertNotNil(codeColor)
        XCTAssertEqual(String(attributed.characters), "run xcodebuild test now")
    }

    // MARK: - Cache & render policy

    /// Smoke test for the SwiftUI side: build the whole view tree (lists, code
    /// block scroll view, quote, table measurement) and rasterize it, so a layout
    /// or measurement crash fails here instead of on-device.
    func testDocumentViewRendersMixedAndMalformedInput() {
        let mixed = """
        # Heading

        Paragraph with **bold**, `code` and a [link](https://example.com).

        - top item
          - nested item
        - [x] done task

        ```swift
        let value = 1
        ```

        > quoted line

        ---

        | Name | Value |
        | --- | --- |
        | a | 1 |
        """
        let expectation = expectation(description: "markdown views rendered")
        DispatchQueue.main.async {
            let mixedRenderer = ImageRenderer(content: MarkdownDocumentView(text: mixed).frame(width: 360))
            mixedRenderer.scale = 1
            XCTAssertNotNil(mixedRenderer.uiImage)

            let malformedRenderer = ImageRenderer(
                content: MarkdownDocumentView(text: "```\n| a |\n| --- |\n> **unclosed\n- [").frame(width: 320)
            )
            malformedRenderer.scale = 1
            XCTAssertNotNil(malformedRenderer.uiImage)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10)
    }

    func testCacheParsesOncePerDistinctText() {        let cache = MarkdownDocumentCache(countLimit: 8, totalCostLimit: 1024 * 1024)
        let source = "# Title\n\n- item"
        let first = cache.blocks(for: source)
        XCTAssertEqual(cache.missCount, 1)
        let second = cache.blocks(for: source)
        XCTAssertEqual(second, first)
        XCTAssertEqual(cache.missCount, 1, "same text should hit the cache")

        _ = cache.blocks(for: "# Other")
        XCTAssertEqual(cache.missCount, 2)
    }

    func testRenderPolicyFallsBackAbove512KB() {
        XCTAssertEqual(MarkdownRenderPolicy.maxParseBytes, 512 * 1024)
        let atLimit = String(repeating: "a", count: MarkdownRenderPolicy.maxParseBytes)
        let overLimit = atLimit + "a"
        XCTAssertTrue(MarkdownRenderPolicy.shouldParse(atLimit))
        XCTAssertFalse(MarkdownRenderPolicy.shouldParse(overLimit))
    }
}
