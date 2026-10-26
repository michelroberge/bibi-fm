import BibiCore
import Foundation

/// Printing reports, findings and history in the terminal.
extension TerminalReporter {
    /// Findings with their numbered actions (numbers match `actions`, the flat list the prompt selects from).
    func report(_ result: SkillResult) {
        var n = 0
        let withActions = result.findings.filter { !$0.recommendations.isEmpty }
        let quiet = result.findings.filter { $0.recommendations.isEmpty }
        if !quiet.isEmpty {
            heading("Findings")
            for f in quiet { finding(f, result, brief: true) }
        }
        if !withActions.isEmpty { heading("Recommended actions") }
        for f in withActions {
            let merged = f.recommendations.count == 1 && f.recommendations[0].title == f.title
            if !merged {
                info("• [\(severity(f.severity))] \(c("1", f.title))  (confidence \(f.confidence)%, uncertainty \(f.uncertainty.rawValue))")
                info("  \(f.explanation)")
            }
            for a in f.recommendations {
                n += 1
                let label = merged ? "[\(severity(f.severity))] \(a.title)" : a.title
                info("\(c("1", String(format: "%3d.", n))) \(c("1", label))")
                var meta: [String] = []
                if a.bytes > 0 { meta.append(human(a.bytes)) }
                meta.append("safety \(a.safety)/10")
                meta.append("confidence \(a.confidence)/10")
                meta.append(a.reversible ? "undoable" : "not undoable")
                if a.privilege == .admin { meta.append(c("33", "admin: asks for your password")) }
                info("     " + meta.joined(separator: "  ·  "))
                info("     why: \(merged && f.explainedBy == "model" ? f.explanation : a.reason)")
                info(c("2", "     cmd: \(a.command)"))
            }
        }
        if !result.hypotheses.isEmpty {
            heading("Possible connections (fm)")
            for h in result.hypotheses {
                info("• \(c("1", h.title))  [\(h.findingIDs.joined(separator: ", ")); confidence \(h.confidence)%]")
                info("  \(h.explanation)")
                for d in h.diagnostics.compactMap(Diagnostics.get) { info(c("2", "  check: \(d.template)")) }
            }
        }
        if let d = result.diff {
            heading("Changes since \(d.baselineDate.formatted(date: .abbreviated, time: .shortened))")
            if d.changes.isEmpty { info("  nothing changed") }
            for ch in d.changes.prefix(20) { info("  \(ch.kind == .added ? "+" : ch.kind == .removed ? "-" : "~") \(ch.text)") }
            if d.changes.count > 20 { info("  ... and \(d.changes.count - 20) more") }
        }
    }

    func severity(_ s: Severity) -> String {
        switch s {
        case .high: c("31", "high")
        case .medium: c("33", "medium")
        case .low: c("36", "low")
        case .info: c("2", "info")
        }
    }

    func finding(_ f: Finding, _ result: SkillResult, brief: Bool) {
        info("• [\(severity(f.severity))] \(c("1", f.title))  (confidence \(f.confidence)%, uncertainty \(f.uncertainty.rawValue))")
        info("  \(f.explanation)")
        let diags = f.diagnostics.compactMap(Diagnostics.get)
        if !brief {
            info("  evidence:")
            for id in f.observationIDs {
                guard let o = result.observation(id) else { continue }
                info("    \(o.id): \(o.text.prefix(300))")
                info(c("2", "        from: \(o.source)"))
            }
        }
        for d in diags {
            let cmd = d.command(subject: f.subject).map(Shell.join) ?? d.template
            info(c("2", "  check: \((d.admin ? "sudo " : "") + cmd)   # \(d.title)"))
        }
    }
}
