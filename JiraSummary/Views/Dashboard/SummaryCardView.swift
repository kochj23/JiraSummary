//
//  SummaryCardView.swift
//  JiraSummary
//
//  Per-person summary card for the dashboard
//  Created by Jordan Koch on 2026-02-17.
//

import SwiftUI

struct SummaryCardView: View {
    let summary: PersonSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.personName)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundColor(ModernColors.textPrimary)

                    Text(summary.systemName)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundColor(ModernColors.textSecondary)
                }

                Spacer()

                // Velocity gauge
                if summary.committedPoints > 0 {
                    CircularGauge(
                        value: summary.velocityPercentage,
                        color: velocityColor,
                        size: 50,
                        lineWidth: 5,
                        label: "vel"
                    )
                }
            }

            // Ticket counts
            HStack(spacing: 12) {
                ticketBadge(count: summary.ticketsCompleted, label: "Done", color: ModernColors.accentGreen)
                ticketBadge(count: summary.ticketsInProgress, label: "Active", color: ModernColors.accentBlue)
                ticketBadge(count: summary.ticketsBlocked, label: "Blocked", color: ModernColors.accentRed)
                ticketBadge(count: summary.ticketsCreated, label: "Created", color: ModernColors.purple)
            }

            // Sprint info
            if let sprintName = summary.sprintName {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10))
                        .foregroundColor(ModernColors.textTertiary)

                    Text(sprintName)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundColor(ModernColors.textSecondary)

                    if summary.committedPoints > 0 {
                        Text("\(Int(summary.completedPoints))/\(Int(summary.committedPoints)) pts")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(velocityColor)
                    }
                }
            }

            // AI Summary
            if let aiSummary = summary.aiSummary {
                VStack(alignment: .leading, spacing: 2) {
                    Text(aiSummary)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundColor(ModernColors.textSecondary)
                        .lineLimit(3)
                    if let source = summary.aiSummarySource {
                        Text(source)
                            .font(.system(size: 10, design: .rounded))
                            .foregroundColor(ModernColors.textTertiary)
                    }
                }
                .padding(.top, 4)
            }

            // Recent ticket previews
            if !summary.recentTickets.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(summary.recentTickets.prefix(3)) { ticket in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(ModernColors.ticketStatusColor(ticket.currentStatus))
                                .frame(width: 6, height: 6)

                            Text(ticket.ticketKey)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(ModernColors.accent)

                            Text(ticket.title)
                                .font(.system(size: 11, design: .rounded))
                                .foregroundColor(ModernColors.textSecondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(20)
        .compactGlassCard()
    }

    private func ticketBadge(count: Int, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text("\(count)")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(color)

            Text(label)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundColor(ModernColors.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private var velocityColor: Color {
        if summary.velocityPercentage >= 80 { return ModernColors.accentGreen }
        if summary.velocityPercentage >= 50 { return ModernColors.accentOrange }
        return ModernColors.accentRed
    }
}
