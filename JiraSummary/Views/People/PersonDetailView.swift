//
//  PersonDetailView.swift
//  JiraSummary
//
//  Full activity detail for a tracked person
//  Created by Jordan Koch on 2026-02-17.
//

import SwiftUI
import NovaAIKit

struct PersonDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let person: TrackedPerson

    @State private var dataStore = DataStore.shared
    @State private var selectedTab = 0

    private var activities: [TicketActivity] {
        dataStore.activities(for: person.id).sorted { $0.updatedDate > $1.updatedDate }
    }

    private var summary: PersonSummary? {
        dataStore.personSummaries.first { $0.personId == person.id }
    }

    private var connection: SystemConnection? {
        dataStore.connections.first { $0.id == person.systemId }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(person.displayName)
                        .modernHeader(size: .medium)

                    HStack(spacing: 8) {
                        if let conn = connection {
                            Image(systemName: conn.type.icon)
                                .foregroundColor(ModernColors.systemTypeColor(conn.type))
                            Text(conn.name)
                                .font(.system(size: 13, design: .rounded))
                                .foregroundColor(ModernColors.textSecondary)
                        }

                        Text(person.systemUserId)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(ModernColors.textTertiary)
                    }
                }

                Spacer()

                if let s = summary {
                    HStack(spacing: 16) {
                        VStack(spacing: 2) {
                            Text("\(s.totalTickets)")
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .foregroundColor(ModernColors.accent)
                            Text("Total")
                                .font(.system(size: 10, design: .rounded))
                                .foregroundColor(ModernColors.textTertiary)
                        }

                        CircularGauge(
                            value: s.completionRate,
                            color: ModernColors.accentGreen,
                            size: 48,
                            lineWidth: 4,
                            label: "done"
                        )

                        if s.committedPoints > 0 {
                            CircularGauge(
                                value: s.velocityPercentage,
                                color: ModernColors.purple,
                                size: 48,
                                lineWidth: 4,
                                label: "vel"
                            )
                        }
                    }
                }

                Button("Close") { dismiss() }
                    .buttonStyle(ModernButtonStyle(color: ModernColors.textTertiary, style: .outlined))
            }
            .padding(20)

            // AI Summary
            if let aiSummary = summary?.aiSummary {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundColor(ModernColors.purple)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(aiSummary)
                            .font(.system(size: 13, design: .rounded))
                            .foregroundColor(ModernColors.textSecondary)
                        if let source = summary?.aiSummarySource {
                            Text(source)
                                .font(.system(size: 10, design: .rounded))
                                .foregroundColor(ModernColors.textTertiary)
                        }
                    }
                    Spacer(minLength: 0)
                    NovaAIStatusIndicator(ai: AppAI.shared, showsLabel: false)
                }
                .padding(12)
                .compactGlassCard(borderColor: ModernColors.purple.opacity(0.3))
                .padding(.horizontal, 20)
            }

            Divider().background(ModernColors.glassBorder).padding(.top, 12)

            // Tabs
            Picker("View", selection: $selectedTab) {
                Text("Tickets").tag(0)
                Text("Timeline").tag(1)
                Text("Sprints").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(16)

            // Tab content
            switch selectedTab {
            case 0:
                TicketListView(activities: activities)
            case 1:
                ActivityTimelineView(activities: activities)
            case 2:
                let sprints = dataStore.sprints(for: person.systemId)
                SprintVelocityView(sprints: sprints, personId: person.id)
            default:
                TicketListView(activities: activities)
            }
        }
        .background(.ultraThickMaterial)
    }
}
