import Testing
@testable import SpotterCore

struct ChatGPTReplyTests {
    @Test func muscleCoverageTablePreservesValuesAndAlignment() {
        let blocks = ChatGPTReplyParser.parse("Coverage:\n\n| Muscle group | Working sets |\n|---|---:|\n| Glutes | 2 |\n| Shoulders | 3 |\n\nMissing logs aren’t proof of no training.")
        #expect(blocks == [.paragraph("Coverage:"), .table(headers: ["Muscle group", "Working sets"], rows: [["Glutes", "2"], ["Shoulders", "3"]], alignments: [.leading, .trailing]), .paragraph("Missing logs aren’t proof of no training.")])
    }
    @Test func inlinePipesAndEscapesDoNotCreateExtraColumns() {
        let blocks = ChatGPTReplyParser.parse("Name | Notes\n--- | ---\nA \\| B | `left|right`")
        #expect(blocks == [.table(headers: ["Name", "Notes"], rows: [["A | B", "`left|right`"]], alignments: [.leading, .leading])])
    }
    @Test func incompleteStreamedRowsKeepTextWithoutDroppingExtraCells() {
        let blocks = ChatGPTReplyParser.parse("| Muscle | Sets |\n|---|---|\n| Glutes | 2\n| Shoul")
        #expect(blocks == [.table(headers: ["Muscle", "Sets"], rows: [["Glutes", "2"], ["Shoul", ""]], alignments: [.leading, .leading])])
        let extra = ChatGPTReplyParser.parse("A | B\n--- | ---\n1 | 2 | 3")
        #expect(extra.last == .paragraph("1 | 2 | 3"))
    }
    @Test func codeIsNotInterpretedAsTableAndMalformedTablesRemainText() {
        #expect(ChatGPTReplyParser.parse("```\nA | B\n--- | ---\n1 | 2\n```") == [.code("A | B\n--- | ---\n1 | 2")])
        #expect(ChatGPTReplyParser.parse("A | B\nnot a separator\n1 | 2") == [.paragraph("A | B\nnot a separator\n1 | 2")])
    }
    @Test func headingsListsAndQuotesRetainTheirContent() {
        #expect(ChatGPTReplyParser.parse("## Next steps\n- Keep **2 RIR**\n- Add 5 lb\n\n1. Train\n2. Rest\n\n> Estimated, not measured") == [.heading(2, "Next steps"), .list([(marker: "•", text: "Keep **2 RIR**"), (marker: "•", text: "Add 5 lb")]), .list([(marker: "1.", text: "Train"), (marker: "2.", text: "Rest")]), .quote("Estimated, not measured")])
    }
}
