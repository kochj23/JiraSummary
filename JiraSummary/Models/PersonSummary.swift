//
//  PersonSummary.swift
//  JiraSummary
//
//  Aggregated summary for a tracked person over a time period
//  Created by Jordan Koch on 2026-02-17.
//

import Foundation

struct PersonSummary: Codable, Identifiable {
    let id: UUID
    let personId: UUID
    let systemId: UUID
    var personName: String
    var systemName: String
    var period: SummaryPeriod
    var generatedDate: Date

    // Ticket activity counts
    var ticketsCreated: Int
    var ticketsInProgress: Int
    var ticketsCompleted: Int
    var ticketsBlocked: Int
    var totalTickets: Int

    // Sprint velocity
    var sprintName: String?
    var committedPoints: Double
    var completedPoints: Double
    var carryOverPoints: Double

    // Recent activity
    var recentTickets: [TicketActivity]
    var recentTransitions: [StatusTransition]

    // Natural-language summary (AI via NovaAIKit, or the built-in summary when AI is off/unavailable)
    var aiSummary: String?
    /// Where `aiSummary` came from: "AI · Ollama (model)" or "Built-in".
    var aiSummarySource: String?

    init(personId: UUID, systemId: UUID, personName: String, systemName: String, period: SummaryPeriod) {
        self.id = UUID()
        self.personId = personId
        self.systemId = systemId
        self.personName = personName
        self.systemName = systemName
        self.period = period
        self.generatedDate = Date()
        self.ticketsCreated = 0
        self.ticketsInProgress = 0
        self.ticketsCompleted = 0
        self.ticketsBlocked = 0
        self.totalTickets = 0
        self.committedPoints = 0
        self.completedPoints = 0
        self.carryOverPoints = 0
        self.recentTickets = []
        self.recentTransitions = []
    }

    var velocityPercentage: Double {
        guard committedPoints > 0 else { return 0 }
        return (completedPoints / committedPoints) * 100
    }

    var completionRate: Double {
        guard totalTickets > 0 else { return 0 }
        return Double(ticketsCompleted) / Double(totalTickets) * 100
    }
}

enum SummaryPeriod: String, Codable, CaseIterable {
    case daily = "Daily"
    case weekly = "Weekly"
    case sprint = "Sprint"
    case monthly = "Monthly"

    var days: Int {
        switch self {
        case .daily: return 1
        case .weekly: return 7
        case .sprint: return 14
        case .monthly: return 30
        }
    }
}
