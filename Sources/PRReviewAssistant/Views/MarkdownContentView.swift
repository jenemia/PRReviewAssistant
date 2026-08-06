import SwiftUI

/// Converts a raw internal code-location URL into readable Markdown while
/// retaining the same safe `prreview://open` target for the side-panel action.
enum CodeLocationLinkFormatter {
    static func format(_ markdown: String) -> String {
        let pattern = "\\(prreview://open\\?[^\\s)]+\\)"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return markdown }
        let range = NSRange(markdown.startIndex..., in: markdown)
        let matches = expression.matches(in: markdown, range: range)
        return matches.reversed().reduce(markdown) { result, match in
            guard let matchRange = Range(match.range, in: result) else { return result }
            let wrappedURL = String(result[matchRange])
            let url = String(wrappedURL.dropFirst().dropLast())
            guard let label = label(for: url) else { return result }
            return result.replacingCharacters(in: matchRange, with: "[\(label)](\(url))")
        }
    }

    private static func label(for url: String) -> String? {
        guard let pathStart = url.range(of: "path=")?.upperBound else { return nil }
        let pathEnd = url[pathStart...].range(of: "&")?.lowerBound ?? url.endIndex
        let path = String(url[pathStart..<pathEnd]).removingPercentEncoding ?? String(url[pathStart..<pathEnd])
        let scriptName = URL(fileURLWithPath: path).lastPathComponent
        guard !scriptName.isEmpty else { return nil }

        let line: String?
        if let lineStart = url.range(of: "line=")?.upperBound {
            let lineEnd = url[lineStart...].range(of: "&")?.lowerBound ?? url.endIndex
            line = String(url[lineStart..<lineEnd])
        } else {
            line = nil
        }
        return line.map { "\(scriptName) · \($0)행" } ?? scriptName
    }
}

/// GitHub cannot open the app-local `prreview://` links. Reply drafts therefore
/// keep only a compact code reference instead of exposing a local file path.
enum ReviewResponseReferenceFormatter {
    static func format(_ text: String) -> String {
        let markdownPattern = "\\[([^\\]]*)\\]\\(prreview://open\\?([^)]*)\\)"
        let rawPattern = "\\(prreview://open\\?([^\\s)]+)\\)"
        let afterMarkdown = replacing(text, pattern: markdownPattern) { match, value in
            let label = value(match.range(at: 1))
            let query = value(match.range(at: 2))
            return reference(label: label, query: query) ?? label
        }
        return replacing(afterMarkdown, pattern: rawPattern) { match, value in
            let query = value(match.range(at: 1))
            return reference(label: nil, query: query) ?? "코드 위치"
        }
    }

    private static func replacing(_ text: String, pattern: String, transform: (NSTextCheckingResult, (NSRange) -> String) -> String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).reversed().reduce(text) { result, match in
            guard let matchRange = Range(match.range, in: result) else { return result }
            let value: (NSRange) -> String = { range in
                guard range.location != NSNotFound, let swiftRange = Range(range, in: result) else { return "" }
                return String(result[swiftRange])
            }
            return result.replacingCharacters(in: matchRange, with: transform(match, value))
        }
    }

    private static func reference(label: String?, query: String) -> String? {
        guard let pathStart = query.range(of: "path=")?.upperBound else { return nil }
        let pathEnd = query[pathStart...].range(of: "&")?.lowerBound ?? query.endIndex
        let path = String(query[pathStart..<pathEnd]).removingPercentEncoding ?? String(query[pathStart..<pathEnd])
        let className = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        guard !className.isEmpty else { return nil }
        let line: String
        if let lineStart = query.range(of: "line=")?.upperBound {
            let lineEnd = query[lineStart...].range(of: "&")?.lowerBound ?? query.endIndex
            line = String(query[lineStart..<lineEnd])
        } else {
            line = "-"
        }
        let method = label?
            .split(separator: "—", maxSplits: 1)
            .dropFirst()
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let method, !method.isEmpty {
            return "\(className).\(method) · \(line)행"
        }
        return "\(className) · \(line)행"
    }
}

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
