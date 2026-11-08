import AIAgent
import SwiftUI

/// Лента чата: сообщения человека, ответы и между ними шаги агента — одной строкой-сводкой, которая раскрывается.
struct AIChatFeed: View {
    let controller: AIChatController

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AIChatStyle.messageSpacing) {
                ForEach(AIChatFeedLayout.items(entries: controller.entries, reply: controller.reply)) { item in
                    switch item {
                    case .user(let entry): AIChatUserMessage(text: entry.text)
                    case .answer(let entry): AIChatAnswer(entry: entry)
                    case .steps(let group):
                        AIChatSteps(group: group, isExpanded: controller.expandedSteps.contains(group.id)) {
                            controller.toggleSteps(group.id)
                        }
                    case .liveText(let text): AIChatMarkdown(text: text)
                    }
                }
            }
            .padding(.horizontal, AIChatStyle.horizontalPadding)
            .padding(.vertical, 12)
        }
        .defaultScrollAnchor(.bottom)
        .accessibilityIdentifier("ai-chat-feed")
    }
}

struct AIChatUserMessage: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            Text(text)
                .font(AIChatStyle.bodyFont)
                .lineSpacing(AIChatStyle.bodyLineSpacing)
                .foregroundStyle(AIChatStyle.text)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12).fill(AIChatStyle.userBubble))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(AIChatStyle.border.opacity(0.6), lineWidth: 1))
        }
    }
}

/// Ответ модели: текст, ошибка, пометка «остановлено». Рассуждения к нему — в сводке шагов выше.
struct AIChatAnswer: View {
    let entry: ChatEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
            if let notice = entry.notice {
                Label(notice, systemImage: "info.circle")
                    .font(AIChatStyle.smallFont)
                    .foregroundStyle(AIChatStyle.secondary)
                    .help("Ответ пришёл через OpenRouter")
            }
        }
    }
}

/// Шаги агента одной строкой: пока ход идёт — текущий шаг, после — «Работал 14 с». По щелчку — все шаги списком.
struct AIChatSteps: View {
    let group: AIChatStepGroup
    let isExpanded: Bool
    let toggle: () -> Void

    /// Пройденные шаги под сводкой; текущий уже виден в самой строке.
    private var listed: [AIChatStep] { group.isRunning ? Array(group.steps.dropLast()) : group.steps }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { if !listed.isEmpty { toggle() } } label: {
                HStack(spacing: 6) {
                    if let current = group.current {
                        ProgressView().controlSize(.mini).frame(width: 14)
                        Text(current.title).lineLimit(1).truncationMode(.middle)
                    } else {
                        Text(group.summary)
                    }
                    if !listed.isEmpty {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                    }
                }
                .font(AIChatStyle.stepFont)
                .foregroundStyle(AIChatStyle.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ai-chat-steps")
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(listed.enumerated()), id: \.offset) { _, step in
                        switch step.kind {
                        case .reasoning: AIChatReasoning(title: step.title, text: step.detail ?? "")
                        case .tool: AIChatToolRow(title: step.title, state: step.state)
                        }
                    }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(AIChatStyle.divider).frame(width: 2) }
            }
        }
    }
}

/// Рассуждение внутри шагов: подпись, по щелчку — текст.
struct AIChatReasoning: View {
    let title: String
    let text: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { if !text.isEmpty { isExpanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain").frame(width: 14)
                    Text(title)
                    if !text.isEmpty {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                Text(text)
                    .font(AIChatStyle.smallFont)
                    .lineSpacing(AIChatStyle.smallLineSpacing)
                    .textSelection(.enabled)
                    .padding(.leading, 20)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(AIChatStyle.stepFont)
        .foregroundStyle(AIChatStyle.secondary)
    }
}

/// Вызов инструмента одной строкой: «Читает страницу «План»».
struct AIChatToolRow: View {
    let title: String
    let state: AIChatStep.State

    var body: some View {
        HStack(spacing: 6) {
            switch state {
            case .running: ProgressView().controlSize(.mini).frame(width: 14)
            case .done: Image(systemName: "checkmark.circle").foregroundStyle(AIChatStyle.secondary).frame(width: 14)
            case .failed: Image(systemName: "xmark.circle").foregroundStyle(AIChatStyle.destructive).frame(width: 14)
            }
            Text(title).lineLimit(1).truncationMode(.middle)
        }
        .font(AIChatStyle.stepFont)
        .foregroundStyle(AIChatStyle.secondary)
    }
}

/// Ответ в Markdown: заголовки, списки и код — блоками, выделение и ссылки внутри строки.
struct AIChatMarkdown: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: AIChatStyle.blockSpacing) {
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
        .lineSpacing(AIChatStyle.bodyLineSpacing)
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
