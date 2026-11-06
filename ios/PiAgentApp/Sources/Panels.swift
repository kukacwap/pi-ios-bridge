import SwiftUI
import UIKit

// MARK: - Styled unified diff (phase 2)

struct DiffView: View {
    let diff: String
    var body: some View {
        let lines = DiffParser.parse(diff)
        let (add, remove) = DiffParser.counts(diff)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("+\(add)").foregroundStyle(.green)
                Text("−\(remove)").foregroundStyle(.red)
                Spacer()
                Text("unified diff").font(.caption2).foregroundStyle(.secondary)
                // improvement #12: copy diff to clipboard
                Button {
                    UIPasteboard.general.string = diff
                } label: {
                    Image(systemName: "doc.on.doc").font(.caption2)
                }
                .buttonStyle(.plain)
            }
            .padding(6)
            .background(Color.gray.opacity(0.1))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        HStack(spacing: 0) {
                            Text(line.kind.sign).frame(width: 16).foregroundStyle(line.kind.color)
                            Text(line.text)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 0.5)
                        .background(line.kind.background)
                    }
                }
            }
        }
    }
}

extension DiffLine.Kind {
    var sign: String {
        switch self {
        case .add: return "+"
        case .remove: return "−"
        case .hunk: return "@@"
        case .file: return ""
        case .context: return " "
        }
    }
    var color: Color {
        switch self {
        case .add: return .green
        case .remove: return .red
        case .hunk: return .blue
        case .file: return .primary
        case .context: return .secondary
        }
    }
    var background: Color {
        switch self {
        case .add: return .green.opacity(0.12)
        case .remove: return .red.opacity(0.12)
        case .hunk: return .blue.opacity(0.08)
        default: return .clear
        }
    }
}

// MARK: - Artifact panel (Claude-style rendered output)

struct ArtifactView: View {
    let artifact: Artifact
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()
                content
            }
            .navigationTitle(artifact.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(accent)
            Text(artifact.kind.rawValue).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if artifact.kind == .diff {
                let (a, r) = DiffParser.counts(artifact.content)
                Text("+\(a) −\(r)").font(.caption.monospaced())
                    .foregroundStyle(.green).padding(.trailing, 4)
                Text("−\(r)").font(.caption.monospaced()).foregroundStyle(.red)
            }
        }
        .padding(8)
    }

    @ViewBuilder private var content: some View {
        switch artifact.kind {
        case .diff:
            DiffView(diff: artifact.content)
        case .image:
            if let data = artifact.imageData, let ui = UIImage(data: data) {
                Image(uiImage: ui).resizable().scaledToFit()
                    .frame(maxWidth: .infinity)
            } else {
                Text("No image data").foregroundStyle(.secondary)
            }
        case .html:
            ScrollView {
                Text(artifact.content)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding()
            }
        case .file, .text:
            ScrollView {
                Text(artifact.content)
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .padding()
            }
        }
    }

    private var icon: String {
        switch artifact.kind {
        case .diff: return "doc.text.magnifyingglass"
        case .file: return "doc"
        case .image: return "photo"
        case .html: return "doc.richtext"
        case .text: return "text.alignleft"
        }
    }
    private var accent: Color {
        switch artifact.kind {
        case .diff, .file: return .orange
        case .image: return .blue
        case .html: return .purple
        case .text: return .secondary
        }
    }
}

// MARK: - Session browser (phase 1)

struct SessionListView: View {
    @ObservedObject var model: ChatModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.sessions.isEmpty {
                    ContentUnavailableView("No sessions", systemImage: "clock",
                                           description: Text("Sessions appear here after the agent runs."))
                } else {
                    List(model.sessions) { s in
                        Button {
                            model.openSession(s)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(s.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                    Spacer()
                                    Text(s.dateLabel).font(.caption2).foregroundStyle(.secondary)
                                }
                                if !s.preview.isEmpty {
                                    Text(s.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Last response viewer (improvement #14)

struct LastResponseView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.system(size: 14, design: .default))
                    .padding()
            }
            .navigationTitle("Last response")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

// MARK: - Extension UI dialog (phase 3: ask-style clarifications)

struct ExtensionUISheet: View {
    let dialog: ExtensionUIDialog
    var onAnswer: (String?, Bool?, Bool) -> Void   // value, confirmed, cancelled

    @State private var selected: String?
    @State private var text = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(dialog.title).font(.headline)
                if let m = dialog.message { Text(m).foregroundStyle(.secondary) }

                switch dialog.method {
                case "select":
                    if let options = dialog.options {
                        Picker("Select", selection: $selected) {
                            ForEach(options, id: \.self) { Text($0).tag(Optional($0)) }
                        }.pickerStyle(.inline)
                    }
                case "confirm":
                    HStack {
                        Button("No") { onAnswer(nil, false, false) }
                        Spacer()
                        Button("Yes", role: .destructive) { onAnswer(nil, true, false) }
                    }
                case "input":
                    TextField(dialog.placeholder ?? "Enter a value", text: $text)
                        .textFieldStyle(.roundedBorder)
                case "editor":
                    TextEditor(text: $text).frame(minHeight: 160)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.3)))
                default:
                    Text("Unsupported dialog: \(dialog.method)").foregroundStyle(.secondary)
                }

                Spacer()

                HStack {
                    Button("Cancel") { onAnswer(nil, nil, true) }
                        .buttonStyle(.bordered)
                    if dialog.method == "select" || dialog.method == "input" || dialog.method == "editor" {
                        Button("Send") {
                            let v = dialog.method == "select" ? selected : text
                            onAnswer(v, nil, false)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding()
            .navigationTitle("Clarification")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
