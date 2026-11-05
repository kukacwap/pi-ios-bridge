import Foundation

// MARK: - Content blocks (from pi message types)

enum MessageBlock {
    case text(String)
    case thinking(String)
    case toolCall(id: String, name: String, args: [String: Any])
    case image(data: Data, mimeType: String)
}

/// A parsed historical message (role + content blocks), delivered from get_messages.
struct HistoryMessage {
    let role: String
    let blocks: [MessageBlock]
}

// MARK: - Artifacts (Claude-style rendered panels)

enum ArtifactKind: String {
    case diff        // unified git diff or write/edit result
    case file        // a written/edited file's content
    case image       // inline image
    case html        // exported session HTML
    case text        // generic output (bash, read)
}

struct Artifact: Identifiable, Equatable {
    let id = UUID()
    var kind: ArtifactKind
    var title: String
    var content: String          // diff/text/html source or image data description
    var imageData: Data?         // for .image
    var mimeType: String?        // for .image
    var timestamp: Date = Date()

    static func == (l: Artifact, r: Artifact) -> Bool { l.id == r.id }
}

// MARK: - Sessions

struct SessionInfo: Identifiable, Equatable {
    var id: String { path }
    let path: String
    var name: String
    var mtime: Double           // ms
    var preview: String

    var dateLabel: String {
        let d = Date(timeIntervalSince1970: mtime / 1000.0)
        return d.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Fork messages (step 4: per-message fork)

struct ForkMessage: Identifiable, Equatable {
    var id: String { entryId }
    let entryId: String
    let text: String
}

// MARK: - Commands / skills (step 5: skills launcher)

struct CommandInfo: Identifiable, Equatable {
    var id: String { name }
    let name: String          // invoke via prompt("/name")
    let description: String?
    let source: String        // "skill" | "prompt" | "extension"
}

// MARK: - Extension UI dialogs (ask-style clarifications)

struct ExtensionUIDialog: Identifiable {
    let id: String
    let method: String          // select | confirm | input | editor
    var title: String
    var message: String?        // confirm
    var options: [String]?      // select
    var placeholder: String?    // input
    var prefill: String?        // editor
    var timeoutMs: Int?

    var isDialog: Bool { ["select", "confirm", "input", "editor"].contains(method) }
}

// MARK: - Unified diff parsing (for styled rendering)

struct DiffLine: Identifiable, Equatable {
    enum Kind { case context, add, remove, hunk, file }
    let id = UUID()
    let kind: Kind
    let text: String
}

enum DiffParser {
    /// Parse a unified diff into styled lines.
    static func parse(_ diff: String) -> [DiffLine] {
        var lines: [DiffLine] = []
        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(raw)
            if s.hasPrefix("+++") || s.hasPrefix("---") {
                lines.append(.init(kind: .file, text: s))
            } else if s.hasPrefix("@@") {
                lines.append(.init(kind: .hunk, text: s))
            } else if s.hasPrefix("+") {
                lines.append(.init(kind: .add, text: String(s.dropFirst())))
            } else if s.hasPrefix("-") {
                lines.append(.init(kind: .remove, text: String(s.dropFirst())))
            } else {
                lines.append(.init(kind: .context, text: s))
            }
        }
        return lines
    }

    static func counts(_ diff: String) -> (add: Int, remove: Int) {
        var add = 0, remove = 0
        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(raw)
            if s.hasPrefix("+") && !s.hasPrefix("+++") { add += 1 }
            else if s.hasPrefix("-") && !s.hasPrefix("---") { remove += 1 }
        }
        return (add, remove)
    }
}
