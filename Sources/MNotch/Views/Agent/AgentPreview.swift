import SwiftUI

/// The per-tool content preview inside the request card: a syntax-free red/
/// green diff for edits, a content/command box for write/bash, rendered
/// markdown for plans, or a dim summary line for anything else. Every variant
/// is height-capped so the measured card height stays bounded.
struct AgentPreview: View {
    let detail: RequestDetail
    let summary: String
    let diff: DiffResult?

    var body: some View {
        switch detail {
        case .edit, .multiEdit:
            if let diff, !diff.rows.isEmpty {
                DiffBox(rows: diff.rows)
            }
        case .write(_, let content):
            codeBox(content, maxHeight: 200, wrap: false)
        case .bash(let command):
            codeBox(command, maxHeight: 120, wrap: true)
        case .patch(let patch):
            codeBox(patch, maxHeight: 210, wrap: false)
        case .plan(let markdown):
            ScrollView {
                // Permission payloads can contain an entire generated plan.
                // Parsing a bounded preview avoids reprocessing megabytes on
                // every view update while preserving the useful first page.
                Text(Self.rendered(String(markdown.prefix(12_000))))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.8))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 210)
        case .generic:
            if !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func codeBox(_ text: String, maxHeight: CGFloat, wrap: Bool) -> some View {
        ScrollView {
            Text(text.count > 4000 ? String(text.prefix(4000)) + "…" : text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.82))
                .textSelection(.enabled)
                .lineLimit(wrap ? nil : nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: maxHeight)
        .padding(10)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Lightweight Markdown → AttributedString for plan previews.
    static func rendered(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: markdown, options: options))
            ?? AttributedString(markdown)
    }
}

/// Scrollable red/green line diff with a line-number gutter.
private struct DiffBox: View {
    let rows: [DiffRow]

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    HStack(spacing: 0) {
                        Text(row.newNo.map(String.init) ?? row.oldNo.map(String.init) ?? "")
                            .frame(width: 28, alignment: .trailing)
                            .foregroundStyle(DiffPalette.gutter)
                        Text(marker(row.kind))
                            .frame(width: 12)
                            .foregroundStyle(fg(row.kind).opacity(0.9))
                        Text(row.text.isEmpty ? " " : row.text)
                            .foregroundStyle(fg(row.kind))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.vertical, 1.5)
                    .padding(.horizontal, 8)
                    .background(bg(row.kind))
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 210)
        .background(DiffPalette.box)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func marker(_ k: DiffKind) -> String {
        switch k { case .remove: "-"; case .add: "+"; case .equal: " " }
    }
    private func fg(_ k: DiffKind) -> Color {
        switch k { case .remove: DiffPalette.delText; case .add: DiffPalette.addText; case .equal: DiffPalette.equalTx }
    }
    private func bg(_ k: DiffKind) -> Color {
        switch k { case .remove: DiffPalette.delBG; case .add: DiffPalette.addBG; case .equal: .clear }
    }
}
