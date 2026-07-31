import SwiftUI

/// A lightweight, dependency-free renderer for the Markdown GitHub returns in
/// review bodies. Inline syntax uses AttributedString; block syntax is laid out
/// as native SwiftUI views so headings, lists, quotes, and code stay readable.
struct MarkdownContentView: View {
    private let blocks: [MarkdownBlock]

    init(_ markdown: String) {
        blocks = MarkdownBlock.parse(markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks) { block in
                switch block.kind {
                case .heading(let level, let text):
                    Text(markdownInline(text))
                        .font(headingFont(level))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, level <= 2 ? 5 : 1)

                case .paragraph(let text):
                    Text(markdownInline(text))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)

                case .list(let items):
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•").fontWeight(.semibold)
                                Text(markdownInline(item))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.leading, CGFloat(indexedIndent(item)))
                        }
                    }

                case .quote(let text):
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(BrandColor.prPurple.opacity(0.75))
                            .frame(width: 3)
                        Text(markdownInline(text))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)

                case .code(let text):
                    Text(text)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .textSelection(.enabled)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.bold()
        case 2: .title3.bold()
        default: .headline.bold()
        }
    }

    private func markdownInline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .full))) ?? AttributedString(text)
    }

    private func indexedIndent(_ item: String) -> Int {
        item.prefix { $0 == " " }.count > 1 ? 16 : 0
    }
}

private struct MarkdownBlock: Identifiable {
    enum Kind {
        case heading(level: Int, text: String)
        case paragraph(String)
        case list([String])
        case quote(String)
        case code(String)
    }

    let id = UUID()
    let kind: Kind

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown.components(separatedBy: .newlines)
        var blocks: [MarkdownBlock] = []
        var index = 0

        func isBoundary(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("```") || trimmed.hasPrefix(">") || trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ")
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { index += 1; continue }

            if trimmed.hasPrefix("```") {
                index += 1
                var code: [String] = []
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index]); index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(.init(kind: .code(code.joined(separator: "\n"))))
                continue
            }

            let level = trimmed.prefix { $0 == "#" }.count
            if level > 0, level <= 6, trimmed.dropFirst(level).first == " " {
                blocks.append(.init(kind: .heading(level: level, text: String(trimmed.dropFirst(level + 1)))))
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                var quote: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    let item = lines[index].trimmingCharacters(in: .whitespaces)
                    quote.append(String(item.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.init(kind: .quote(quote.joined(separator: "\n"))))
                continue
            }

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                var items: [String] = []
                while index < lines.count {
                    let candidate = lines[index]
                    let candidateTrimmed = candidate.trimmingCharacters(in: .whitespaces)
                    guard candidateTrimmed.hasPrefix("- ") || candidateTrimmed.hasPrefix("* ") else { break }
                    items.append(String(candidateTrimmed.dropFirst(2)))
                    index += 1
                }
                blocks.append(.init(kind: .list(items)))
                continue
            }

            var paragraph = [line]
            index += 1
            while index < lines.count, !isBoundary(lines[index]) {
                paragraph.append(lines[index]); index += 1
            }
            blocks.append(.init(kind: .paragraph(paragraph.joined(separator: "\n"))))
        }
        return blocks
    }
}
