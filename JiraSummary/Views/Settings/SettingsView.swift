//
//  SettingsView.swift
//  JiraSummary
//
//  Configuration for refresh interval, AI backends, and menu bar
//  Full multi-backend AI settings matching Blompie pattern
//  Created by Jordan Koch on 2026-02-17.
//

import SwiftUI

struct SettingsView: View {
    @State private var refreshInterval: Double = 30
    @State private var enableMenuBar = false
    @State private var defaultPeriod: SummaryPeriod = .weekly
    @State private var openRouterKeyInput = ""

    private var aiManager = AIBackendManager.shared
    private let menuBarManager = MenuBarManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Settings")
                    .modernHeader(size: .large)

                generalSection
                menuBarSection
                aiBackendSection
                aiLocalBackendsSection
                aiCloudBackendsSection
                aiLoadBalancerSection
                aiParametersSection
                aiUsageSection
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

    // MARK: - AI Backend Selection

    private var aiBackendSection: some View {
        settingsSection("AI Backend") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Bindable(aiManager).isEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Enable AI summaries")
                            .font(.system(size: 13, design: .rounded))
                            .foregroundColor(ModernColors.textPrimary)

                        Text("Generate natural language summaries of team activity")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundColor(ModernColors.textTertiary)
                    }
                }
                .toggleStyle(.switch)

                if aiManager.isEnabled {
                    AIBackendStatusMenu()

                    Divider().opacity(0.3)

                    // Active backend picker
                    HStack {
                        Text("Active backend")
                            .font(.system(size: 13, design: .rounded))
                            .foregroundColor(ModernColors.textPrimary)
                        Spacer()
                        Picker("Backend", selection: Bindable(aiManager).activeBackend) {
                            ForEach(AIBackend.allCases) { backend in
                                HStack {
                                    Image(systemName: backend.icon)
                                    Text(backend.rawValue)
                                }
                                .tag(backend)
                            }
                        }
                        .frame(width: 180)
                        .onChange(of: aiManager.activeBackend) { _, _ in
                            aiManager.saveConfiguration()
                        }
                    }

                    // Ollama model picker
                    if aiManager.activeBackend == .ollama && !aiManager.ollamaModels.isEmpty {
                        HStack {
                            Text("Ollama model")
                                .font(.system(size: 13, design: .rounded))
                                .foregroundColor(ModernColors.textPrimary)
                            Spacer()
                            Picker("Model", selection: Bindable(aiManager).selectedOllamaModel) {
                                ForEach(aiManager.ollamaModels, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }
                            .frame(width: 220)
                            .onChange(of: aiManager.selectedOllamaModel) { _, _ in
                                aiManager.saveConfiguration()
                            }
                        }
                    }

                    // Available backends summary
                    HStack(spacing: 8) {
                        Text("Available:")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundColor(ModernColors.textTertiary)

                        let available = aiManager.availableBackends
                        if available.isEmpty {
                            Text("None")
                                .font(.system(size: 11, design: .rounded))
                                .foregroundColor(ModernColors.accentRed)
                        } else {
                            ForEach(available) { backend in
                                HStack(spacing: 2) {
                                    Image(systemName: backend.icon)
                                        .font(.system(size: 9))
                                    Text(backend.rawValue)
                                        .font(.system(size: 10, design: .rounded))
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(ModernColors.accentGreen.opacity(0.15))
                                )
                                .foregroundColor(ModernColors.accentGreen)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Local Backends Configuration

    private var aiLocalBackendsSection: some View {
        Group {
            if aiManager.isEnabled {
                settingsSection("Local Backends") {
                    VStack(alignment: .leading, spacing: 12) {
                        serverURLRow(label: "Ollama", binding: Bindable(aiManager).ollamaServerURL, defaultValue: "http://localhost:11434", available: aiManager.isOllamaAvailable)
                        serverURLRow(label: "TinyLLM", binding: Bindable(aiManager).tinyLLMServerURL, defaultValue: "http://localhost:8000", available: aiManager.isTinyLLMAvailable)
                        serverURLRow(label: "TinyChat", binding: Bindable(aiManager).tinyChatServerURL, defaultValue: "http://localhost:8000", available: aiManager.isTinyChatAvailable)
                        serverURLRow(label: "OpenWebUI", binding: Bindable(aiManager).openWebUIServerURL, defaultValue: "http://localhost:8080", available: aiManager.isOpenWebUIAvailable)

                        HStack(spacing: 4) {
                            Image(systemName: "cpu")
                                .font(.system(size: 11))
                            Text("MLX")
                                .font(.system(size: 12, design: .rounded))
                                .foregroundColor(ModernColors.textSecondary)
                                .frame(width: 80, alignment: .trailing)
                            Text(aiManager.isMLXAvailable ? "Installed (mlx_lm found)" : "Not installed")
                                .font(.system(size: 12, design: .rounded))
                                .foregroundColor(aiManager.isMLXAvailable ? ModernColors.accentGreen : ModernColors.textTertiary)
                            Spacer()
                            statusDot(aiManager.isMLXAvailable)
                        }

                        Button {
                            Task { await aiManager.refreshAllBackends() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.clockwise")
                                Text("Refresh All Backends")
                            }
                        }
                        .buttonStyle(ModernButtonStyle(color: ModernColors.purple, style: .outlined))
                    }
                }
            }
        }
    }

    // MARK: - Cloud Backends Configuration

    private var aiCloudBackendsSection: some View {
        Group {
            if aiManager.isEnabled {
                settingsSection("Cloud Backends") {
                    VStack(alignment: .leading, spacing: 12) {
                        apiKeyRow(label: "OpenAI", binding: Bindable(aiManager).openAIKey, placeholder: "sk-...")
                        apiKeyRow(label: "Google Cloud", binding: Bindable(aiManager).googleCloudKey, placeholder: "AIza...")

                        Divider().opacity(0.3)

                        apiKeyRow(label: "Azure Key", binding: Bindable(aiManager).azureKey, placeholder: "API key")
                        HStack {
                            Text("Azure Endpoint")
                                .font(.system(size: 12, design: .rounded))
                                .foregroundColor(ModernColors.textSecondary)
                                .frame(width: 100, alignment: .trailing)
                            SecureField("https://your-resource.openai.azure.com", text: Bindable(aiManager).azureEndpoint)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                        }

                        Divider().opacity(0.3)

                        apiKeyRow(label: "AWS Access", binding: Bindable(aiManager).awsAccessKey, placeholder: "AKIA...")
                        apiKeyRow(label: "AWS Secret", binding: Bindable(aiManager).awsSecretKey, placeholder: "Secret key")
                        HStack {
                            Text("AWS Region")
                                .font(.system(size: 12, design: .rounded))
                                .foregroundColor(ModernColors.textSecondary)
                                .frame(width: 100, alignment: .trailing)
                            TextField("us-east-1", text: Bindable(aiManager).awsRegion)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(width: 160)
                            Spacer()
                        }

                        Divider().opacity(0.3)

                        apiKeyRow(label: "IBM Watson", binding: Bindable(aiManager).ibmKey, placeholder: "API key")
                        HStack {
                            Text("IBM URL")
                                .font(.system(size: 12, design: .rounded))
                                .foregroundColor(ModernColors.textSecondary)
                                .frame(width: 100, alignment: .trailing)
                            SecureField("Service URL", text: Bindable(aiManager).ibmURL)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                        }

                        Text("API keys are stored locally and never transmitted to third parties")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundColor(ModernColors.textTertiary)
                            .padding(.top, 4)
                    }
                    .onChange(of: aiManager.openAIKey) { _, _ in aiManager.saveConfiguration() }
                    .onChange(of: aiManager.googleCloudKey) { _, _ in aiManager.saveConfiguration() }
                    .onChange(of: aiManager.azureKey) { _, _ in aiManager.saveConfiguration() }
                    .onChange(of: aiManager.awsAccessKey) { _, _ in aiManager.saveConfiguration() }
                    .onChange(of: aiManager.ibmKey) { _, _ in aiManager.saveConfiguration() }
                }
            }
        }
    }

    // MARK: - Shared Multi-Model Load Balancer

    private var aiLoadBalancerSection: some View {
        Group {
            if aiManager.isEnabled {
                settingsSection("Load Balancer") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Fan summary generation out across multiple models. When any toggle is on, requests are spread over the healthy pool via least-busy balancing.")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundColor(ModernColors.textTertiary)

                        Toggle(isOn: Bindable(aiManager).useAllLocalModels) {
                            Text("Balance across all local models")
                                .font(.system(size: 13, design: .rounded))
                                .foregroundColor(ModernColors.textPrimary)
                        }
                        .toggleStyle(.switch)
                        .onChange(of: aiManager.useAllLocalModels) { _, _ in aiManager.saveConfiguration() }

                        Toggle(isOn: Bindable(aiManager).enableAllFrontierModels) {
                            Text("Balance across all frontier models (OpenRouter)")
                                .font(.system(size: 13, design: .rounded))
                                .foregroundColor(ModernColors.textPrimary)
                        }
                        .toggleStyle(.switch)
                        .onChange(of: aiManager.enableAllFrontierModels) { _, _ in aiManager.saveConfiguration() }

                        Toggle(isOn: Bindable(aiManager).useNovaGateway) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Include Nova Gateway")
                                    .font(.system(size: 13, design: .rounded))
                                    .foregroundColor(ModernColors.textPrimary)
                                Text("Optional — dropped from the pool if the health check fails")
                                    .font(.system(size: 10, design: .rounded))
                                    .foregroundColor(ModernColors.textTertiary)
                            }
                        }
                        .toggleStyle(.switch)
                        .onChange(of: aiManager.useNovaGateway) { _, _ in aiManager.saveConfiguration() }

                        Divider().opacity(0.3)

                        // OpenRouter API key (single Keychain-backed key)
                        HStack {
                            Text("OpenRouter Key")
                                .font(.system(size: 12, design: .rounded))
                                .foregroundColor(ModernColors.textSecondary)
                                .frame(width: 110, alignment: .trailing)
                            SecureField(aiManager.hasOpenRouterKey ? "•••••• (stored)" : "sk-or-...", text: $openRouterKeyInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                                .onSubmit { commitOpenRouterKey() }
                            Button("Save") { commitOpenRouterKey() }
                                .buttonStyle(.borderless)
                            statusDot(aiManager.isOpenRouterAvailable)
                        }

                        // Nova Gateway URL
                        HStack {
                            Text("Nova Gateway")
                                .font(.system(size: 12, design: .rounded))
                                .foregroundColor(ModernColors.textSecondary)
                                .frame(width: 110, alignment: .trailing)
                            TextField(ModelRegistry.novaGatewayDefaultURL, text: Bindable(aiManager).novaGatewayURL)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                                .onChange(of: aiManager.novaGatewayURL) { _, _ in aiManager.saveConfiguration() }
                            statusDot(aiManager.isNovaGatewayAvailable)
                        }

                        Text("The OpenRouter key is stored in the macOS Keychain, never in UserDefaults.")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundColor(ModernColors.textTertiary)
                            .padding(.top, 4)
                    }
                }
            }
        }
    }

    private func commitOpenRouterKey() {
        guard !openRouterKeyInput.isEmpty else { return }
        aiManager.setOpenRouterAPIKey(openRouterKeyInput)
        openRouterKeyInput = ""
        Task { await aiManager.refreshAllBackends() }
    }

    // MARK: - AI Generation Parameters

    private var aiParametersSection: some View {
        Group {
            if aiManager.isEnabled {
                settingsSection("Generation Parameters") {
                    VStack(alignment: .leading, spacing: 12) {
                        // Temperature
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Temperature")
                                    .font(.system(size: 13, design: .rounded))
                                    .foregroundColor(ModernColors.textPrimary)
                                Spacer()
                                Text(String(format: "%.2f", aiManager.temperature))
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundColor(ModernColors.purple)
                            }
                            Slider(value: Bindable(aiManager).temperature, in: 0...1, step: 0.05)
                                .onChange(of: aiManager.temperature) { _, _ in aiManager.saveConfiguration() }
                            HStack {
                                Text("Precise")
                                    .font(.system(size: 10, design: .rounded))
                                    .foregroundColor(ModernColors.textTertiary)
                                Spacer()
                                Text("Creative")
                                    .font(.system(size: 10, design: .rounded))
                                    .foregroundColor(ModernColors.textTertiary)
                            }
                        }

                        // Max tokens
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Max tokens")
                                    .font(.system(size: 13, design: .rounded))
                                    .foregroundColor(ModernColors.textPrimary)
                                Spacer()
                                Text("\(aiManager.maxTokens)")
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundColor(ModernColors.purple)
                            }
                            Slider(
                                value: Binding(
                                    get: { Double(aiManager.maxTokens) },
                                    set: { aiManager.maxTokens = Int($0) }
                                ),
                                in: 50...2000,
                                step: 50
                            )
                            .onChange(of: aiManager.maxTokens) { _, _ in aiManager.saveConfiguration() }
                            HStack {
                                Text("Brief")
                                    .font(.system(size: 10, design: .rounded))
                                    .foregroundColor(ModernColors.textTertiary)
                                Spacer()
                                Text("Detailed")
                                    .font(.system(size: 10, design: .rounded))
                                    .foregroundColor(ModernColors.textTertiary)
                            }
                        }

                        // Connection test
                        connectionTestSection
                    }
                }
            }
        }
    }

    // MARK: - Connection Test

    private var connectionTestSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().opacity(0.3)

            Text("Connection Test")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(ModernColors.textSecondary)

            HStack(spacing: 12) {
                Button {
                    Task {
                        let result = await aiManager.testConnection(for: aiManager.activeBackend)
                        _ = result
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill")
                        Text("Test \(aiManager.activeBackend.rawValue)")
                    }
                }
                .buttonStyle(ModernButtonStyle(color: ModernColors.purple, style: .outlined))

                if let result = aiManager.connectionTestResults[aiManager.activeBackend] {
                    HStack(spacing: 4) {
                        Image(systemName: result.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(result.isSuccess ? ModernColors.accentGreen : ModernColors.accentRed)
                        Text(result.message)
                            .font(.system(size: 12, design: .rounded))
                            .foregroundColor(result.isSuccess ? ModernColors.accentGreen : ModernColors.accentRed)
                    }
                }
            }
        }
    }

    // MARK: - Usage Stats

    private var aiUsageSection: some View {
        Group {
            if aiManager.isEnabled && aiManager.usageStats.totalRequests > 0 {
                settingsSection("AI Usage") {
                    VStack(alignment: .leading, spacing: 8) {
                        usageRow("Total requests", value: "\(aiManager.usageStats.totalRequests)")
                        usageRow("Total tokens", value: "\(aiManager.usageStats.totalTokens)")
                        usageRow("Estimated cost", value: String(format: "$%.4f", aiManager.usageStats.totalCost))
                        usageRow("Avg response time", value: String(format: "%.1fs", aiManager.usageStats.averageResponseTime))

                        if let lastUsed = aiManager.usageStats.lastUsed {
                            usageRow("Last used", value: lastUsed.formatted(date: .abbreviated, time: .shortened))
                        }

                        // Per-backend metrics
                        if !aiManager.performanceMetrics.isEmpty {
                            Divider().opacity(0.3)
                            Text("Per-Backend Metrics")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundColor(ModernColors.textSecondary)

                            ForEach(Array(aiManager.performanceMetrics.keys.sorted(by: { $0.rawValue < $1.rawValue })), id: \.self) { backend in
                                if let metrics = aiManager.performanceMetrics[backend] {
                                    HStack {
                                        Image(systemName: backend.icon)
                                            .font(.system(size: 10))
                                            .frame(width: 16)
                                        Text(backend.rawValue)
                                            .font(.system(size: 11, design: .rounded))
                                            .foregroundColor(ModernColors.textPrimary)
                                            .frame(width: 80, alignment: .leading)
                                        Text("\(metrics.successfulAttempts)/\(metrics.totalAttempts)")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(ModernColors.textSecondary)
                                        Text(String(format: "%.0f%%", metrics.successRate * 100))
                                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                                            .foregroundColor(metrics.successRate > 0.8 ? ModernColors.accentGreen : ModernColors.accentRed)
                                        Spacer()
                                        Text(String(format: "%.1fs avg", metrics.averageLatency))
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(ModernColors.textTertiary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        settingsSection("About") {
            VStack(alignment: .leading, spacing: 8) {
                Text("JiraSummary v1.0.0")
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

    private func serverURLRow(label: String, binding: Binding<String>, defaultValue: String, available: Bool) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, design: .rounded))
                .foregroundColor(ModernColors.textSecondary)
                .frame(width: 80, alignment: .trailing)
            TextField(defaultValue, text: binding)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .onChange(of: binding.wrappedValue) { _, _ in aiManager.saveConfiguration() }
            statusDot(available)
        }
    }

    private func apiKeyRow(label: String, binding: Binding<String>, placeholder: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, design: .rounded))
                .foregroundColor(ModernColors.textSecondary)
                .frame(width: 100, alignment: .trailing)
            SecureField(placeholder, text: binding)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
            statusDot(!binding.wrappedValue.isEmpty)
        }
    }

    private func statusDot(_ active: Bool) -> some View {
        Circle()
            .fill(active ? ModernColors.accentGreen : Color.gray.opacity(0.3))
            .frame(width: 8, height: 8)
    }

    private func usageRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, design: .rounded))
                .foregroundColor(ModernColors.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(ModernColors.textPrimary)
        }
    }
}
