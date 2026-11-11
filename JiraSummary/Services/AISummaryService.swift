//
//  AISummaryService.swift
//  JiraSummary
//
//  Natural-language activity summaries for a tracked person, through NovaAIKit (AppAI.shared).
//  AI off, offline or a rejected reply → a deterministic summary built from the counts.
//  Created by Jordan Koch on 2026-02-17.
//

import Foundation
import NovaAIKit

@MainActor
enum AISummaryService {
    nonisolated static let systemPrompt = "You are a concise engineering manager writing brief activity summaries. "
        + "Be specific and factual. Use only the facts given. Write 2-3 plain sentences, no lists, no markdown."

    /// Longest summary the cards show.
    nonisolated static let maxSummaryLength = 600

    /// Summarize one person: AI when enabled and reachable, otherwise the built-in summary.
    /// Never throws; the result's `source.label` says where the text came from.
    static func summarize(_ summary: PersonSummary, ai: NovaAI? = nil) async -> NovaAIResult<String> {
        let ai = ai ?? AppAI.shared
        let builtIn = fallbackSummary(for: summary)
        guard summary.totalTickets > 0 else {
            return NovaAIResult(value: builtIn, source: .fallback(.unavailable("no activity to summarize")))
        }
        let prompt = buildPrompt(from: summary)
        let request = NovaAIRequest(prompt: prompt, system: systemPrompt, temperature: 0.3, maxTokens: 300)
        return await ai.text(request, validate: validator(source: prompt)) { builtIn }
    }

    /// Fills `aiSummary` / `aiSummarySource` on a copy of `summary`.
    static func annotate(_ summary: PersonSummary, ai: NovaAI? = nil) async -> PersonSummary {
        let result = await summarize(summary, ai: ai)
        var copy = summary
        copy.aiSummary = result.value
        copy.aiSummarySource = result.source.label
        return copy
    }

    // MARK: - Validation

    /// Accepts a non-empty plain-text reply of reasonable length whose numbers all appear in the prompt
    /// (no invented counts or story points).
    nonisolated static func validator(source: String) -> @Sendable (String) throws -> String {
        { reply in
            let text = NovaAIText.plain(try NovaAI.nonEmpty(reply), max: maxSummaryLength)
            guard text.count >= 20 else { throw NovaAIValidationError("summary too short") }
            guard NovaAIText.grounded(text, in: source) else {
                throw NovaAIValidationError("summary contains numbers that are not in the activity data")
            }
            return text
        }
    }

    // MARK: - Built-in summary

    /// Deterministic summary from the counts; used when AI is off, unreachable or its reply is rejected.
    nonisolated static func fallbackSummary(for s: PersonSummary) -> String {
        let window = periodPhrase(s.period)
        guard s.totalTickets > 0 else {
            return "\(s.personName) had no tracked ticket activity in \(s.systemName) \(window)."
        }
        var parts = ["\(s.ticketsCompleted) completed", "\(s.ticketsInProgress) in progress"]
        if s.ticketsBlocked > 0 { parts.append("\(s.ticketsBlocked) blocked") }
        if s.ticketsCreated > 0 { parts.append("\(s.ticketsCreated) created") }
        let noun = s.totalTickets == 1 ? "ticket" : "tickets"
        var text = "\(s.personName) touched \(s.totalTickets) \(noun) in \(s.systemName) \(window): "
            + parts.joined(separator: ", ") + "."
        if s.committedPoints > 0 {
            text += " \(s.sprintName ?? "Current sprint"): \(Int(s.completedPoints)) of \(Int(s.committedPoints)) points completed."
        }
        if let latest = s.recentTickets.first {
            text += " Most recent: \(latest.ticketKey) (\(latest.currentStatus))."
        }
        return text
    }

    nonisolated static func periodPhrase(_ period: SummaryPeriod) -> String {
        switch period {
        case .daily: return "today"
        case .weekly: return "this week"
        case .sprint: return "this sprint"
        case .monthly: return "this month"
        }
    }

    // MARK: - Prompt

    nonisolated static func buildPrompt(from summary: PersonSummary) -> String {
        var lines: [String] = []
        lines.append("Summarize this person's work activity in 2-3 sentences. Be specific about what they accomplished.")
        lines.append("")
        lines.append("Person: \(summary.personName)")
        lines.append("System: \(summary.systemName)")
        lines.append("Period: \(summary.period.rawValue)")
        lines.append("Total tickets touched: \(summary.totalTickets)")
        lines.append("Completed: \(summary.ticketsCompleted)")
        lines.append("In progress: \(summary.ticketsInProgress)")
        lines.append("Blocked: \(summary.ticketsBlocked)")
        lines.append("Created: \(summary.ticketsCreated)")

        if summary.committedPoints > 0 {
            lines.append("Sprint: \(summary.sprintName ?? "Current")")
            lines.append("Points committed: \(Int(summary.committedPoints)), completed: \(Int(summary.completedPoints))")
        }

        if !summary.recentTickets.isEmpty {
            lines.append("")
            lines.append("Recent tickets:")
            for ticket in summary.recentTickets.prefix(5) {
                lines.append("- \(ticket.ticketKey): \(ticket.title) [\(ticket.currentStatus)]")
            }
        }

        lines.append("")
        lines.append("Write a brief, factual summary (2-3 sentences):")
        return lines.joined(separator: "\n")
    }
}
