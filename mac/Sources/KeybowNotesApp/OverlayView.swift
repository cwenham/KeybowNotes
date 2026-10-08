import KeybowKit
import SwiftUI

struct OverlayView: View {
    let model: OverlayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Group {
                if let outcome = model.outcome {
                    OutcomeView(outcome: outcome)
                } else if let notice = model.notice {
                    Label(notice.text, systemImage: notice.symbol)
                        .font(.system(size: 15, weight: .medium))
                } else if !model.snapshot.isIdle {
                    ChoosingView(snapshot: model.snapshot, pending: model.pendingSummary)
                } else if let page = model.page {
                    PageView(page: page, colours: model.snapshot.colours)
                } else if let working = model.working {
                    WorkingView(working: working, cancel: { model.onCancel?() })
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            // Still waiting on replies while something else is on show.
            if let working = model.working,
               model.outcome != nil || model.notice != nil || !model.snapshot.isIdle {
                WorkingRow(working: working, cancel: { model.onCancel?() })
            }
            ForEach(model.moduleStatuses, id: \.moduleID) { status in
                ModuleStatusRow(status: status)
            }
        }
        .padding(20)
        .frame(width: 560, alignment: .leading)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Choosing

private struct ChoosingView: View {
    let snapshot: SelectionSnapshot
    let pending: ActionSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    if let tree = snapshot.tree { TreeBadge(tree: tree) }
                    Breadcrumb(labels: snapshot.selection?.labels ?? [])
                }
                Spacer(minLength: 0)
                KeypadMirror(colours: snapshot.colours)
            }

            if let pending, let window = snapshot.pending {
                PendingView(summary: pending, window: window)
            } else if let row = snapshot.currentRow {
                OptionsRow(row: row, tree: snapshot.tree, options: snapshot.options)
            }
        }
    }
}

/// A page turned to: its name, and its keys where they sit on the keypad.
private struct PageView: View {
    let page: SelectionSnapshot.Page
    let colours: [KeyColour]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    TreeBadge(tree: page.tree, pages: true)
                    HStack(spacing: 8) {
                        Circle().fill(page.colour.swatch).frame(width: 10, height: 10)
                        Text(page.label).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                KeypadMirror(colours: colours)
            }
            VStack(spacing: 8) {
                ForEach(0..<page.tree.pageKeys / KeybowProtocol.columns, id: \.self) { row in
                    HStack(spacing: 8) {
                        ForEach(0..<KeybowProtocol.columns, id: \.self) { column in
                            if let key = page.keys.first(where: { $0.column == row * KeybowProtocol.columns + column }) {
                                OptionTile(option: key)
                            } else {
                                RoundedRectangle(cornerRadius: 9)
                                    .strokeBorder(.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                    .frame(maxWidth: .infinity, minHeight: 48)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct TreeBadge: View {
    let tree: TreeKind
    var pages = false

    var body: some View {
        // The same diagram and colour as the editor's tab for this tree.
        HStack(spacing: 5) {
            TreeGridIcon(tree: tree, cell: 2.5, gap: 0.8)
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.6)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tree.tint.opacity(0.28), in: Capsule())
        .foregroundStyle(.secondary)
    }

    private var title: String {
        if pages { return "Row \(tree.startRow + 1) pages" }
        let arrow = tree == .main ? "" : tree == .bottom ? "  ↑" : "  ↓"
        return "\(tree.title) tree\(arrow)"
    }
}

private struct Breadcrumb: View {
    let labels: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                Text(label)
                    .font(.system(size: 17, weight: index == labels.count - 1 ? .semibold : .regular))
                    .foregroundStyle(index == labels.count - 1 ? .primary : .secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// The next row's choices, laid out where they sit on the keypad.
private struct OptionsRow: View {
    let row: Int
    let tree: TreeKind?
    let options: [SelectionSnapshot.Option]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Row \(row + 1)")
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(.tertiary)
            HStack(spacing: 8) {
                ForEach(0..<KeybowProtocol.columns, id: \.self) { column in
                    if let option = options.first(where: { $0.column == column }) {
                        OptionTile(option: option)
                    } else {
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                }
            }
        }
    }
}

private struct OptionTile: View {
    let option: SelectionSnapshot.Option

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(option.colour.swatch)
                .frame(width: 8, height: 8)
            Text(option.label)
                .font(.system(size: LabelFit.size(for: option.label, base: 13, weight: .medium, width: 64, smallest: 9),
                              weight: .medium))
                .lineLimit(2)
            Spacer(minLength: 0)
            if !option.isLeaf {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 48)
        .background(option.colour.swatch.opacity(0.16), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(option.colour.swatch.opacity(0.45), lineWidth: 1))
    }
}

private struct PendingView: View {
    let summary: ActionSummary
    let window: ClosedRange<Date>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ActionHeadline(summary: summary, caption: summary.verb)
            ProgressView(timerInterval: window, countsDown: true) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(.linear)
            .tint(.white.opacity(0.7))
            Text("Press any key to cancel")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Outcomes

private struct OutcomeView: View {
    let outcome: OverlayModel.Outcome

    var body: some View {
        switch outcome {
        case .previewed(let summary, let path):
            ResultLayout(symbol: "eye.circle.fill", tint: .blue) {
                ActionHeadline(summary: summary, caption: "\(summary.verb) — dry run, nothing was done")
                Text(path).font(.system(size: 11)).foregroundStyle(.tertiary)
                if !summary.missing.isEmpty {
                    Warning(text: "Config still needs \(summary.missing.joined(separator: ", "))")
                }
            }

        case .running(let summary, let path):
            HStack(alignment: .center, spacing: 14) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 6) {
                    ActionHeadline(summary: summary, caption: "\(summary.verb)…")
                    Text(path).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }

        case .finished(let result, let summary, let warnings):
            ResultLayout(symbol: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.octagon.fill",
                         tint: result.succeeded ? .green : .red) {
                Text(summary.verb)
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Text(result.message)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(2)
                if let detail = result.detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                }
                ForEach(warnings, id: \.self) { Warning(text: $0) }
            }

        case .refused(let reason, let summary):
            ResultLayout(symbol: "exclamationmark.triangle.fill", tint: .orange) {
                ActionHeadline(summary: summary, caption: "Can't \(summary.verb.lowercased()) yet")
                Text(reason).font(.system(size: 12)).foregroundStyle(.orange).lineLimit(3)
            }

        case .cleared(let reason):
            Label(text(for: reason), systemImage: "xmark.circle.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private func text(for reason: NavigatorEvent.ClearReason) -> String {
        switch reason {
        case .cancelled: return "Cancelled"
        case .longPress: return "Cleared"
        case .idleTimeout: return "Timed out"
        case .completed: return "Done"
        }
    }
}

/// A large status symbol beside a column of text.
private struct ResultLayout<Content: View>: View {
    let symbol: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 30))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 5) { content }
        }
    }
}

private struct Warning: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.orange)
            .lineLimit(3)
    }
}

private struct ActionHeadline: View {
    let summary: ActionSummary
    let caption: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .frame(width: 26)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(caption)
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Text(summary.subject)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(2)
                if !summary.details.isEmpty {
                    Text(summary.details.joined(separator: "  ·  "))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var symbol: String {
        ModuleRegistry.shared.vocabulary.describe(summary.type)?.symbol ?? "questionmark.circle"
    }
}

// MARK: - Waiting on replies

/// "Asking Claude…", how long it's been, and a way out.
private struct WorkingView: View {
    let working: OverlayModel.Working
    let cancel: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 6) {
                ActionHeadline(summary: working.summary, caption: working.title)
                HStack(spacing: 8) {
                    // A live timer's text takes all the width it's offered
                    // unless held to its own.
                    Text(working.since, style: .timer)
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Text(working.path).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                }
                .padding(.leading, 36)          // under the title, past the action's icon
            }
            Spacer(minLength: 8)
            CancelButton(action: cancel)
        }
    }
}

/// The same, in a line, under whatever else the HUD is showing.
private struct WorkingRow: View {
    let working: OverlayModel.Working
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text(working.title).foregroundStyle(.secondary)
            Text(working.since, style: .timer)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .fixedSize()
            Spacer(minLength: 0)
            CancelButton(action: cancel)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(.white.opacity(0.07), in: Capsule())
    }
}

/// Drawn by SwiftUI rather than an AppKit button, so it answers the first
/// click in a window that never becomes key.
private struct CancelButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Cancel", systemImage: "xmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.white.opacity(0.14), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Stop waiting, and don't run the action")
    }
}

// MARK: - Modules

/// A module at work in the background: "⏱ Stopwatch  3:12  Lap 2: 1:05".
private struct ModuleStatusRow: View {
    let status: ModuleStatus

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: status.symbol)
                .foregroundStyle(.secondary)
            Text(status.title)
                .foregroundStyle(.secondary)
            Group {
                if let since = status.countingFrom {
                    Text(since, style: .timer)
                } else {
                    Text(status.text)
                }
            }
            .font(.system(size: 13, weight: .semibold).monospacedDigit())
            if let detail = status.detail {
                Text(detail).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.white.opacity(0.07), in: Capsule())
    }
}

// MARK: - Keypad mirror

/// A small copy of what the keys are showing.
private struct KeypadMirror: View {
    let colours: [KeyColour]

    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<KeybowProtocol.rows, id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(0..<KeybowProtocol.columns, id: \.self) { column in
                        let colour = colours[KeybowProtocol.key(row: row, column: column)]
                        RoundedRectangle(cornerRadius: 3)
                            .fill(colour.display)
                            .frame(width: 13, height: 13)
                    }
                }
            }
        }
        .padding(6)
        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
    }
}

extension KeyColour {
    /// The colour at full strength, as configured.
    var swatch: Color {
        Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }

    /// An LED's colour on screen. Dimmed LEDs are dark in RGB terms, which reads
    /// as mud on a dark HUD, so restore the hue and show brightness as opacity.
    var display: Color {
        let peak = max(red, green, blue)
        guard peak > 0 else { return .white.opacity(0.07) }
        let lift = 255.0 / Double(peak)
        return Color(red: Double(red) * lift / 255, green: Double(green) * lift / 255, blue: Double(blue) * lift / 255)
            .opacity(max(0.3, Double(peak) / 255))
    }
}
