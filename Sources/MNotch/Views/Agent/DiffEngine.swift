import SwiftUI

/// Typed view of a tool's `tool_input`, parsed once at request ingest so the
/// UI never touches raw JSON.
enum RequestDetail: Equatable, Sendable {
    case edit(path: String, old: String, new: String)
    case multiEdit(path: String, edits: [EditPair])
    case write(path: String, content: String)
    case bash(command: String)
    case patch(patch: String)
    case plan(markdown: String)
    case generic
}

struct EditPair: Equatable, Sendable {
    let old: String
    let new: String
}

// MARK: - Line diff

enum DiffKind: Equatable, Sendable { case equal, remove, add }

struct DiffRow: Identifiable, Sendable {
    let id: Int
    let kind: DiffKind
    let text: String
    let oldNo: Int?
    let newNo: Int?
}

struct DiffResult: Sendable {
    let rows: [DiffRow]
    let adds: Int
    let dels: Int
}

enum DiffEngine {
    /// Line-level LCS diff with old/new line numbers. Guards against a
    /// pathological n·m blow-up by falling back to a plain remove-all/add-all
    /// block diff.
    nonisolated static func rows(old: String, new: String) -> DiffResult {
        let a = old.components(separatedBy: "\n")
        let b = new.components(separatedBy: "\n")
        let n = a.count, m = b.count

        if n * m > 40_000 {
            var r: [DiffRow] = []
            for (i, l) in a.enumerated() {
                r.append(.init(id: r.count, kind: .remove, text: l, oldNo: i + 1, newNo: nil))
            }
            for (j, l) in b.enumerated() {
                r.append(.init(id: r.count, kind: .add, text: l, oldNo: nil, newNo: j + 1))
            }
            return DiffResult(rows: r, adds: b.count, dels: a.count)
        }

        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }

        var r: [DiffRow] = []
        var i = 0, j = 0, oNo = 1, nNo = 1, adds = 0, dels = 0
        func emit(_ k: DiffKind, _ t: String) {
            switch k {
            case .equal:  r.append(.init(id: r.count, kind: .equal, text: t, oldNo: oNo, newNo: nNo)); oNo += 1; nNo += 1
            case .remove: r.append(.init(id: r.count, kind: .remove, text: t, oldNo: oNo, newNo: nil)); oNo += 1; dels += 1
            case .add:    r.append(.init(id: r.count, kind: .add, text: t, oldNo: nil, newNo: nNo)); nNo += 1; adds += 1
            }
        }
        while i < n && j < m {
            if a[i] == b[j] { emit(.equal, a[i]); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { emit(.remove, a[i]); i += 1 }
            else { emit(.add, b[j]); j += 1 }
        }
        while i < n { emit(.remove, a[i]); i += 1 }
        while j < m { emit(.add, b[j]); j += 1 }
        return DiffResult(rows: r, adds: adds, dels: dels)
    }
}

enum DiffPalette {
    static let box = Color.white.opacity(0.04)
    static let delBG = Color(red: 0.42, green: 0.12, blue: 0.14).opacity(0.55)
    static let addBG = Color(red: 0.12, green: 0.34, blue: 0.18).opacity(0.55)
    static let delText = Color(red: 1.0, green: 0.62, blue: 0.62)
    static let addText = Color(red: 0.6, green: 0.92, blue: 0.66)
    static let equalTx = Color.white.opacity(0.55)
    static let gutter = Color.white.opacity(0.28)
}
