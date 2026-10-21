import SwiftUI

/// The permission-request card (reference design 3): header, tool line,
/// per-tool preview, +N/-N stats for edits, and Deny/Allow buttons. Sizes to
/// its content; the notch panel measures this and springs to fit.
struct AgentRequestCard: View {
    let session: AgentSession
    let request: PendingRequest
    let agents: AgentMonitorService
    let viewModel: NotchViewModel

    @State private var diff: DiffResult?

    private nonisolated static func buildDiff(_ detail: RequestDetail) -> DiffResult? {
        func bounded(_ text: String) -> String {
            text.count > 40_000 ? String(text.prefix(40_000)) : text
        }
        let full: DiffResult?
        switch detail {
        case .edit(_, let old, let new):
            full = DiffEngine.rows(old: bounded(old), new: bounded(new))
        case .multiEdit(_, let edits):
            var all: [DiffRow] = []
            var adds = 0, dels = 0
            for pair in edits.prefix(20) {
                let r = DiffEngine.rows(
                    old: bounded(pair.old),
                    new: bounded(pair.new)
                )
                // This is a bounded preview, not an editor. Cap both work and
                // row construction so a generated mega-patch cannot make
                // SwiftUI create thousands of views.
                let remaining = max(300 - all.count, 0)
                if remaining > 0 {
                    let base = all.count
                    all += r.rows.prefix(remaining).enumerated().map { offset, row in
                        DiffRow(
                            id: base + offset,
                            kind: row.kind,
                            text: row.text,
                            oldNo: row.oldNo,
                            newNo: row.newNo
                        )
                    }
                }
                adds += r.adds
                dels += r.dels
            }
            full = DiffResult(rows: all, adds: adds, dels: dels)
        default:
            full = nil
        }
        guard let full else { return nil }
        return DiffResult(rows: Array(full.rows.prefix(300)), adds: full.adds, dels: full.dels)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            toolLine
            AgentPreview(detail: request.detail, summary: request.toolSummary, diff: diff)
            if let diff, diff.adds + diff.dels > 0 {
                HStack(spacing: 10) {
                    Text("+\(diff.adds)").foregroundStyle(DiffPalette.addText)
                    Text("-\(diff.dels)").foregroundStyle(DiffPalette.delText)
                }
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            buttons
        }
        .task(id: request.id) {
            diff = nil
            let detail = request.detail
            let result = await Task.detached(priority: .userInitiated) {
                Self.buildDiff(detail)
            }.value
            guard !Task.isCancelled else { return }
            diff = result
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Circle().fill(.orange).frame(width: 6, height: 6)
            Text(String(
                format: L10n.string("%@ Permission"),
                session.kind.capitalized
            ))
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.4)
                .foregroundStyle(.white.opacity(0.55))
            Spacer(minLength: 8)
            Text(session.folderName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(1)
            Button { agents.jump(session) } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string("Open terminal"))
            .help(L10n.string("Open terminal"))
        }
    }

    private var toolLine: some View {
        HStack(spacing: 8) {
            Image(systemName: style.glyph)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(style.tint)
            Text(LocalizedStringKey(style.verb))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
            if let path = style.path {
                Text(path)
                    .font(.system(size: 12).monospaced())
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Button { resolve(false) } label: {
                buttonLabel("Deny", "⌘N", fg: .white.opacity(0.85), bg: .white.opacity(0.08))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: .command)
            Button { resolve(true) } label: {
                buttonLabel("Allow", "⌘Y", fg: .black, bg: .white)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("y", modifiers: .command)
        }
    }

    private func buttonLabel(_ title: String, _ hint: String, fg: Color, bg: Color) -> some View {
        HStack(spacing: 6) {
            Text(LocalizedStringKey(title)).font(.system(size: 13, weight: .semibold))
            Text(hint).font(.system(size: 11, weight: .medium)).opacity(0.5)
        }
        .foregroundStyle(fg)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(bg, in: RoundedRectangle(cornerRadius: 9))
    }

    private func resolve(_ approved: Bool) {
        // Only the last pending request celebrates; earlier ones just advance.
        if agents.pendingCount <= 1 {
            viewModel.confirmAgentDecision(approved: approved)   // before respond → collapse no-ops
        }
        if approved { agents.approve(session) } else { agents.reject(session) }
    }

    // MARK: - Per-tool header style

    private struct ToolStyle { let glyph: String; let verb: String; let tint: Color; let path: String? }

    private var style: ToolStyle {
        switch request.detail {
        case .edit(let path, _, _):
            ToolStyle(glyph: "exclamationmark.triangle.fill", verb: "Edit", tint: .orange, path: path)
        case .multiEdit(let path, let edits):
            ToolStyle(
                glyph: "exclamationmark.triangle.fill",
                verb: String(format: L10n.string("Edit ×%d"), edits.count),
                tint: .orange,
                path: path
            )
        case .write(let path, _):
            ToolStyle(glyph: "square.and.pencil", verb: "Write", tint: .orange, path: path)
        case .bash:
            ToolStyle(glyph: "terminal.fill", verb: "Run", tint: .yellow, path: nil)
        case .patch:
            ToolStyle(glyph: "doc.badge.gearshape", verb: "Patch", tint: .orange, path: nil)
        case .plan:
            ToolStyle(glyph: "list.bullet.clipboard", verb: "Plan", tint: .blue, path: nil)
        case .generic:
            ToolStyle(glyph: "hammer", verb: request.toolName, tint: .orange, path: nil)
        }
    }
}
