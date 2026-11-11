//
//  SettingsView.swift
//  JiraSummary
//
//  Configuration for refresh interval, AI backends, and menu bar
//  AI settings come from NovaAIKit (NovaAISettingsView)
//  Created by Jordan Koch on 2026-02-17.
//

import SwiftUI
import NovaAIKit

struct SettingsView: View {
    @State private var refreshInterval: Double = 30
    @State private var enableMenuBar = false
    @State private var defaultPeriod: SummaryPeriod = .weekly

    private let menuBarManager = MenuBarManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Settings")
                    .modernHeader(size: .large)

                generalSection
                menuBarSection
                aiSection
                aboutSection
            }
            .padding(24)
        }
    }

    // MARK: - General

    private var generalSection: some View {
        settingsSection("General") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Auto-refresh interval")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundColor(ModernColors.textPrimary)
                    Spacer()
                    Picker("Interval", selection: $refreshInterval) {
                        Text("15 min").tag(15.0)
                        Text("30 min").tag(30.0)
                        Text("1 hour").tag(60.0)
                        Text("2 hours").tag(120.0)
                        Text("Manual only").tag(0.0)
                    }
                    .frame(width: 160)
                }

                HStack {
                    Text("Default summary period")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundColor(ModernColors.textPrimary)
                    Spacer()
                    Picker("Period", selection: $defaultPeriod) {
                        ForEach(SummaryPeriod.allCases, id: \.self) { period in
                            Text(period.rawValue).tag(period)
                        }
                    }
                    .frame(width: 160)
                }
            }
        }
    }

    // MARK: - Menu Bar

    private var menuBarSection: some View {
        settingsSection("Menu Bar") {
            Toggle(isOn: $enableMenuBar) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Show in menu bar")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundColor(ModernColors.textPrimary)

                    Text("Quick access to summary stats from the menu bar")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundColor(ModernColors.textTertiary)
                }
            }
            .toggleStyle(.switch)
            .onChange(of: enableMenuBar) { _, newValue in
                menuBarManager.isEnabled = newValue
            }
        }
    }

    // MARK: - AI (NovaAIKit)

    private var aiSection: some View {
        settingsSection("AI") {
            NovaAISettingsView(
                ai: AppAI.shared,
                footer: "AI writes the 2-3 sentence activity summaries on the dashboard. When AI is off or unreachable, "
                    + "JiraSummary writes a built-in summary from the ticket counts and sprint points. Cloud backends "
                    + "(OpenRouter, OpenAI) receive names and ticket titles; pick a local backend to keep work data on this network."
            )
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        settingsSection("About") {
            VStack(alignment: .leading, spacing: 8) {
                Text("JiraSummary v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(ModernColors.textPrimary)

                Text("Track team activity across Jira and Azure DevOps")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(ModernColors.textSecondary)

                Text("Created by Jordan Koch")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(ModernColors.textTertiary)
            }
        }
    }

    // MARK: - Helpers

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(ModernColors.textPrimary)

            content()
                .padding(16)
                .compactGlassCard()
        }
    }
}
