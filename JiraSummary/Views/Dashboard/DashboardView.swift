//
//  DashboardView.swift
//  JiraSummary
//
//  All-person overview dashboard with summary cards
//  Created by Jordan Koch on 2026-02-17.
//

import SwiftUI
import NovaAIKit

struct DashboardView: View {
    @State private var dataStore = DataStore.shared
    @State private var coordinator = DataFetchCoordinator.shared
    @State private var selectedPeriod: SummaryPeriod = .weekly
    @State private var selectedPerson: TrackedPerson?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Dashboard")
                            .modernHeader(size: .large)

                        Text("\(dataStore.trackedPeople.count) people across \(dataStore.connections.count) systems")
                            .font(.system(size: 14, design: .rounded))
                            .foregroundColor(ModernColors.textSecondary)
                    }

                    Spacer()

                    // AI status (summaries); click re-checks
                    NovaAIStatusIndicator(ai: AppAI.shared)
                        .help("AI summaries backend. Configure in Settings > AI.")

                    // Period picker
                    Picker("Period", selection: $selectedPeriod) {
                        ForEach(SummaryPeriod.allCases, id: \.self) { period in
                            Text(period.rawValue).tag(period)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 300)

                    // Refresh button
                    Button {
                        Task { await coordinator.fetchAll(period: selectedPeriod) }
                    } label: {
                        HStack(spacing: 6) {
                            if coordinator.isFetching {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .tint(.white)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text("Refresh")
                        }
                    }
                    .buttonStyle(ModernButtonStyle(color: ModernColors.cyan, style: .filled))
                    .disabled(coordinator.isFetching)
                }
                .padding(.horizontal, 24)

                // Error banner
                if !coordinator.fetchErrors.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(coordinator.fetchErrors, id: \.self) { error in
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(ModernColors.accentOrange)
                                Text(error)
                                    .font(.system(size: 12, design: .rounded))
                                    .foregroundColor(ModernColors.textSecondary)
                            }
                        }
                    }
                    .padding(16)
                    .compactGlassCard(borderColor: ModernColors.accentOrange.opacity(0.3))
                    .padding(.horizontal, 24)
                }

                // Aggregate stats
                if !dataStore.personSummaries.isEmpty {
                    aggregateStatsRow
                }

                // Person cards grid
                if dataStore.trackedPeople.isEmpty {
                    emptyState
                } else {
                    personCardsGrid
                }
            }
            .padding(.vertical, 24)
        }
        .sheet(item: $selectedPerson) { person in
            PersonDetailView(person: person)
                .frame(minWidth: 700, minHeight: 500)
        }
    }

    // MARK: - Aggregate Stats

    private var aggregateStatsRow: some View {
        let summaries = filteredSummaries

        let totalTickets = summaries.reduce(0) { $0 + $1.totalTickets }
        let completed = summaries.reduce(0) { $0 + $1.ticketsCompleted }
        let inProgress = summaries.reduce(0) { $0 + $1.ticketsInProgress }
        let blocked = summaries.reduce(0) { $0 + $1.ticketsBlocked }
        let avgVelocity = summaries.isEmpty ? 0 : summaries.map { $0.velocityPercentage }.reduce(0, +) / Double(summaries.count)

        return HStack(spacing: 16) {
            StatCard(title: "Total Tickets", value: "\(totalTickets)", icon: "ticket.fill", color: ModernColors.accent)
            StatCard(title: "Completed", value: "\(completed)", icon: "checkmark.circle.fill", color: ModernColors.accentGreen)
            StatCard(title: "In Progress", value: "\(inProgress)", icon: "arrow.right.circle.fill", color: ModernColors.accentBlue)
            StatCard(title: "Blocked", value: "\(blocked)", icon: "xmark.octagon.fill", color: ModernColors.accentRed)
            StatCard(title: "Avg Velocity", value: String(format: "%.0f%%", avgVelocity), icon: "gauge.medium", color: ModernColors.purple)
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Person Cards Grid

    private var personCardsGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 380, maximum: 500), spacing: 16)], spacing: 16) {
            ForEach(dataStore.trackedPeople) { person in
                if let summary = filteredSummaries.first(where: { $0.personId == person.id }) {
                    SummaryCardView(summary: summary)
                        .onTapGesture { selectedPerson = person }
                } else {
                    pendingCard(for: person)
                }
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 48))
                .foregroundColor(ModernColors.textTertiary)

            Text("No People Tracked")
                .modernHeader(size: .medium)

            Text("Add a system connection and start tracking team members to see their activity here.")
                .font(.system(size: 14, design: .rounded))
                .foregroundColor(ModernColors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private func pendingCard(for person: TrackedPerson) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(person.displayName)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(ModernColors.textPrimary)
                Spacer()
                Text("No data yet")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(ModernColors.textTertiary)
            }
            Text("Refresh to fetch activity data")
                .font(.system(size: 13, design: .rounded))
                .foregroundColor(ModernColors.textSecondary)
        }
        .padding(20)
        .compactGlassCard()
    }

    private var filteredSummaries: [PersonSummary] {
        dataStore.personSummaries.filter { $0.period == selectedPeriod }
    }
}

// MARK: - Stat Card

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundColor(color)

            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundColor(ModernColors.textPrimary)

            Text(title)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(ModernColors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .compactGlassCard()
    }
}
