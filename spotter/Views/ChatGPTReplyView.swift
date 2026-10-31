import SwiftUI

struct ChatGPTReplyView: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(ChatGPTReplyParser.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text): inline(text).lineSpacing(3)
                case .heading(let level, let text):
                    inline(text).font(level == 1 ? .title3.weight(.semibold) : .headline)
                        .accessibilityAddTraits(.isHeader)
                case .list(let items):
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(items.indices, id: \.self) { index in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(items[index].marker).foregroundStyle(.secondary).monospacedDigit()
                                    .frame(minWidth: 16, alignment: .trailing)
                                inline(items[index].text).frame(maxWidth: .infinity, alignment: .leading)
                            }.accessibilityElement(children: .combine)
                        }
                    }
                case .table(let headers, let rows, let alignments):
                    if headers.count > 3 {
                        ScrollView(.horizontal) { table(headers, rows: rows, alignments: alignments).fixedSize(horizontal: true, vertical: false) }
                    } else { table(headers, rows: rows, alignments: alignments) }
                case .code(let text):
                    ScrollView(.horizontal) {
                        Text(text).font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    }.background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                case .quote(let text): inline(text).foregroundStyle(.secondary).padding(.leading, 12)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading).textSelection(.enabled)
    }
    private func inline(_ text: String) -> Text {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
    }
    private func table(_ headers: [String], rows: [[String]], alignments: [ChatGPTTableAlignment]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
            GridRow {
                ForEach(headers.indices, id: \.self) { column in
                    inline(headers[column]).font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: alignment(alignments[column]))
                        .accessibilityAddTraits(.isHeader)
                }
            }
            Divider().gridCellColumns(headers.count)
            ForEach(rows.indices, id: \.self) { row in
                GridRow {
                    ForEach(headers.indices, id: \.self) { column in
                        inline(rows[row][column]).font(.subheadline).monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: alignment(alignments[column]))
                            .accessibilityLabel("\(headers[column]): \(rows[row][column])")
                    }
                }
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
    private func alignment(_ alignment: ChatGPTTableAlignment) -> Alignment {
        switch alignment { case .leading: .leading; case .center: .center; case .trailing: .trailing }
    }
}
