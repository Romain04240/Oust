import Foundation
import OustLocalization

/// La sortie de `oust` pour qui la lit dans un terminal. Les agents, eux,
/// passent `--json`.
enum HumanText {

    static func scan(_ report: ScanReport) -> [String] {
        guard !report.items.isEmpty else { return [L10n.string("cli.scan.empty")] }
        var lines: [String] = []
        let width = report.items.map(\.safetyLabel.count).max() ?? 0
        for item in report.items {
            let size = Formatters.compactBytes(item.sizes.freeableBytes)
            let label = item.safetyLabel.padding(toLength: width, withPad: " ", startingAt: 0)
            let owner = item.owner.isEmpty || item.owner == item.title ? "" : " — " + item.owner
            lines.append("\(marker(item.agent.verdict)) \(label)  \(String(repeating: " ", count: max(0, 8 - size.count)))\(size)  \(item.title)\(owner)")
            lines.append("    \(item.id)")
            if item.agent.verdict != "allowed" { lines.append("    \(item.agent.label)") }
            for protection in item.protections { lines.append("    · \(protection.label)") }
        }
        lines.append("")
        if report.truncated {
            lines.append(L10n.string("cli.scan.truncated", String(report.totals.shown), String(report.totals.items)))
        }
        lines.append(L10n.string("cli.scan.summary", String(report.totals.items),
                                 Formatters.bytes(report.totals.freeableBytes), Formatters.bytes(report.totals.allowedBytes)))
        if report.totals.needsAllowReviewBytes > 0 {
            lines.append(L10n.string("cli.scan.review", Formatters.bytes(report.totals.needsAllowReviewBytes)))
        }
        if let token = report.token, let expires = report.expiresAt {
            lines.append(L10n.string("cli.scan.token", token, Formatters.timestamp(expires)))
        }
        return lines
    }

    static func explain(_ report: ExplainReport) -> [String] {
        var lines = [report.title]
        func section(_ key: String, _ text: String) {
            lines.append("")
            lines.append(L10n.string(key))
            lines.append("  " + text)
        }
        section("explain.what", report.what)
        section("explain.back", report.back)
        if let method = report.method { section("explain.method", method) }
        if !report.protections.isEmpty { section("explain.protected", report.protections.joined(separator: "\n  ")) }
        if let item = report.item {
            section("explain.where", item.paths.joined(separator: "\n  "))
            lines.append("")
            lines.append(L10n.string("explain.sizes", Formatters.bytes(item.sizes.allocatedBytes),
                                     Formatters.bytes(item.sizes.freeableBytes)))
        }
        return lines
    }

    static func outcome(_ outcome: OutcomeReport) -> String {
        let symbol = outcome.succeeded ? "✓" : outcome.result == "failed" ? "✗" : "–"
        let size = outcome.bytes > 0 ? " (\(Formatters.bytes(outcome.bytes)))" : ""
        return "\(symbol) \(outcome.title)\(size) — \(outcome.label)"
    }

    static func clean(_ report: CleanReport) -> [String] {
        var lines: [String] = []
        if report.dryRun {
            lines += report.outcomes.map(outcome)
            lines.append("")
            lines.append(L10n.string("cli.clean.dryRun"))
            lines.append(L10n.string("cli.clean.wouldFree", Formatters.bytes(report.totals.freedNowBytes),
                                     Formatters.bytes(report.totals.pendingInTrashBytes)))
            return lines
        }
        lines.append(L10n.string("cli.clean.summary", Formatters.bytes(report.totals.freedNowBytes),
                                 Formatters.bytes(report.totals.pendingInTrashBytes)))
        if report.totals.heldBackBytes > 0 {
            lines.append(L10n.string("cli.clean.heldBack", Formatters.bytes(report.totals.heldBackBytes)))
        }
        return lines
    }

    /// ✓ nettoyable, ? avec `--allow-review`, ✗ refusé.
    static func marker(_ verdict: String) -> String {
        switch verdict {
        case "allowed": "✓"
        case "needsAllowReview": "?"
        default: "✗"
        }
    }
}
