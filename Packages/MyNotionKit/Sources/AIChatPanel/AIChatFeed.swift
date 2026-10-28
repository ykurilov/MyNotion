import AIAgent
import SwiftUI

/// Лента чата: сообщения человека, ответы с рассуждениями под спойлером, короткие строки вызовов инструментов
/// и ответ, который приходит сейчас.
struct AIChatFeed: View {
    let controller: AIChatController

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(controller.entries.filter(AIChatEntryView.hasContent)) { entry in
                    AIChatEntryView(entry: entry)
                }
                if let reply = controller.reply {
                    AIChatLiveReplyView(reply: reply)
                }
            }
            .padding(.horizontal, AIChatStyle.horizontalPadding)
            .padding(.vertical, 12)
        }
        .defaultScrollAnchor(.bottom)
        .accessibilityIdentifier("ai-chat-feed")
    }
}

struct AIChatEntryView: View {
    let entry: ChatEntry

    /// Ход модели, где были одни вызовы инструментов, своей строки не занимает: их видно ниже.
    static func hasContent(_ entry: ChatEntry) -> Bool {
        entry.kind != .assistant || !entry.text.isEmpty || !(entry.reasoning ?? "").isEmpty || entry.error != nil || entry.stopped == true
    }

    var body: some View {
        switch entry.kind {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(entry.text)
                    .font(AIChatStyle.bodyFont)
                    .foregroundStyle(AIChatStyle.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(AIChatStyle.userBubble))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(AIChatStyle.border.opacity(0.6), lineWidth: 1))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                if let reasoning = entry.reasoning, !reasoning.isEmpty {
                    AIChatReasoning(text: reasoning, isThinking: false)
                }
                if !entry.text.isEmpty { AIChatMarkdown(text: entry.text) }
                if let error = entry.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(AIChatStyle.bodyFont)
                        .foregroundStyle(AIChatStyle.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if entry.stopped == true {
                    Text("Остановлено").font(AIChatStyle.smallFont).foregroundStyle(AIChatStyle.secondary)
                }
            }
        case .tool:
            AIChatToolRow(title: entry.title ?? entry.toolName ?? "", state: entry.ok == false ? .failed : .done)
        }
    }
}

struct AIChatLiveReplyView: View {
    let reply: AIChatController.LiveReply

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !reply.reasoning.isEmpty || reply.text.isEmpty && reply.runningTool == nil {
                AIChatReasoning(text: reply.reasoning, isThinking: reply.text.isEmpty)
            }
            if !reply.text.isEmpty { AIChatMarkdown(text: reply.text) }
            if let tool = reply.runningTool { AIChatToolRow(title: tool, state: .running) }
        }
    }
}

/// Рассуждения модели: свёрнуты, по щелчку раскрываются.
struct AIChatReasoning: View {
    let text: String
    let isThinking: Bool
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { if !text.isEmpty { isExpanded.toggle() } } label: {
                HStack(spacing: 5) {
                    if isThinking { ProgressView().controlSize(.mini) }
                    Text(isThinking ? "Думает…" : "Рассуждения")
                    if !text.isEmpty {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                    }
                }
                .font(AIChatStyle.smallFont)
                .foregroundStyle(AIChatStyle.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                Text(text)
                    .font(AIChatStyle.smallFont)
                    .foregroundStyle(AIChatStyle.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(AIChatStyle.divider).frame(width: 2) }
            }
        }
    }
}

/// Вызов инструмента одной строкой: «Читает страницу «План»».
struct AIChatToolRow: View {
    enum State { case running, done, failed }

    let title: String
    let state: State

    var body: some View {
        HStack(spacing: 6) {
            switch state {
            case .running: ProgressView().controlSize(.mini).frame(width: 14)
            case .done: Image(systemName: "checkmark.circle").foregroundStyle(AIChatStyle.secondary).frame(width: 14)
            case .failed: Image(systemName: "xmark.circle").foregroundStyle(AIChatStyle.destructive).frame(width: 14)
            }
            Text(title).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 13))
        .foregroundStyle(AIChatStyle.secondary)
    }
}

/// Ответ в Markdown: заголовки, списки и код — блоками, выделение и ссылки внутри строки.
struct AIChatMarkdown: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let line):
                    inline(line).font(.system(size: 15, weight: .semibold))
                case .item(let marker, let line):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).foregroundStyle(AIChatStyle.secondary)
                        inline(line)
                    }
                case .code(let code):
                    Text(code)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(AIChatStyle.userBubble))
                case .paragraph(let line):
                    inline(line)
                }
            }
        }
        .font(AIChatStyle.bodyFont)
        .foregroundStyle(AIChatStyle.text)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func inline(_ line: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: line, options: options)) ?? AttributedString(line))
    }
}

enum MarkdownBlock: Hashable {
    case heading(String)
    case item(marker: String, String)
    case code(String)
    case paragraph(String)

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var code: [String]?
        var paragraph: [String] = []

        func closeParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    closeParagraph()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(raw)
                continue
            }
            if line.isEmpty {
                closeParagraph()
            } else if let heading = line.firstMatch(of: #/^#{1,6}\s+(.*)$/#) {
                closeParagraph()
                blocks.append(.heading(String(heading.1)))
            } else if let task = line.firstMatch(of: #/^[-*+]\s+\[([ xX])\]\s+(.*)$/#) {
                closeParagraph()
                blocks.append(.item(marker: task.1 == " " ? "☐" : "☑", String(task.2)))
            } else if let bullet = line.firstMatch(of: #/^[-*+]\s+(.*)$/#) {
                closeParagraph()
                blocks.append(.item(marker: "•", String(bullet.1)))
            } else if let number = line.firstMatch(of: #/^(\d+[.)])\s+(.*)$/#) {
                closeParagraph()
                blocks.append(.item(marker: String(number.1), String(number.2)))
            } else {
                paragraph.append(line)
            }
        }
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        closeParagraph()
        return blocks
    }
}
