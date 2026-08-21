//
//  AIBackendManager.swift
//  JiraSummary
//
//  Centralized AI backend detection and management
//  Supports local (Ollama, MLX, TinyLLM, TinyChat, OpenWebUI) and
//  cloud (OpenAI, Google Cloud, Azure, AWS, IBM Watson) backends.
//  Matches Blompie AI infrastructure pattern.
//  Created by Jordan Koch on 2026-02-17.
//

import Foundation
import os.log
import Observation
import Security

enum AIBackend: String, CaseIterable, Codable, Identifiable {
    case ollama = "Ollama"
    case mlx = "MLX"
    case tinyLLM = "TinyLLM"
    case tinyChat = "TinyChat"
    case openWebUI = "OpenWebUI"
    case openAI = "OpenAI"
    case googleCloud = "Google Cloud"
    case azure = "Azure"
    case aws = "AWS"
    case ibmWatson = "IBM Watson"
    case openRouter = "OpenRouter"
    case novaGateway = "Nova Gateway"

    var id: String { rawValue }

    var isLocal: Bool {
        switch self {
        case .ollama, .mlx, .tinyLLM, .tinyChat, .openWebUI: return true
        case .openAI, .googleCloud, .azure, .aws, .ibmWatson, .openRouter: return false
        // Nova Gateway runs on the local machine (127.0.0.1) — treated as local.
        case .novaGateway: return true
        }
    }

    var icon: String {
        switch self {
        case .ollama: return "brain"
        case .mlx: return "cpu"
        case .tinyLLM: return "memorychip"
        case .tinyChat: return "bubble.left.fill"
        case .openWebUI: return "globe"
        case .openAI: return "sparkles"
        case .googleCloud: return "cloud.fill"
        case .azure: return "cloud.bolt.fill"
        case .aws: return "cloud.sun.fill"
        case .ibmWatson: return "wand.and.stars"
        case .openRouter: return "cloud"
        case .novaGateway: return "sparkle.magnifyingglass"
        }
    }

    var defaultURL: String {
        switch self {
        case .ollama: return "http://localhost:11434"
        case .mlx: return ""
        case .tinyLLM: return "http://localhost:8000"
        case .tinyChat: return "http://localhost:8000"
        case .openWebUI: return "http://localhost:8080"
        case .openAI: return "https://api.openai.com"
        case .googleCloud: return "https://generativelanguage.googleapis.com"
        case .azure: return ""
        case .aws: return ""
        case .ibmWatson: return ""
        case .openRouter: return OpenRouterProvider.baseURL
        case .novaGateway: return ModelRegistry.novaGatewayDefaultURL
        }
    }
}

@MainActor
@Observable
final class AIBackendManager {
    static let shared = AIBackendManager()

    // MARK: - Published State

    var activeBackend: AIBackend = .ollama
    var isEnabled = false

    // Backend availability
    var isOllamaAvailable = false
    var isMLXAvailable = false
    var isTinyLLMAvailable = false
    var isTinyChatAvailable = false
    var isOpenWebUIAvailable = false
    var isOpenRouterAvailable = false
    var isNovaGatewayAvailable = false

    // Model management
    var ollamaModels: [String] = []
    var selectedOllamaModel: String = "llama3"
    var openRouterModels: [String] = OpenRouterProvider.fallbackModels
    var selectedOpenRouterModel: String = OpenRouterProvider.defaultModel

    // Configuration
    var ollamaServerURL: String = "http://localhost:11434"
    var tinyLLMServerURL: String = "http://localhost:8000"
    var tinyChatServerURL: String = "http://localhost:8000"
    var openWebUIServerURL: String = "http://localhost:8080"
    var novaGatewayURL: String = ModelRegistry.novaGatewayDefaultURL

    // MARK: - Shared multi-model load balancer

    /// Fan out the daily-summary generation across ALL enabled local models.
    var useAllLocalModels = false
    /// Include ALL OpenRouter frontier models in the balanced pool.
    var enableAllFrontierModels = false
    /// Include Nova Gateway in the balanced pool. Nova is ALWAYS optional — a
    /// failed health check simply drops it from the pool, never a hard dependency.
    var useNovaGateway = false

    /// Pure, network-free balancer that spreads work across the enabled pool.
    let balancer = LoadBalancer()
    /// Balancer policy (least-busy mirrors how Nova's gateway spreads load).
    var balancerPolicy: BalancerPolicy = .leastBusy
    /// Keychain-backed store for the single OpenRouter API key.
    let openRouterKeychain = KeychainStore()
    /// Models currently discovered for the balancer (all enabled sources).
    var discoveredModels: [DiscoveredModel] = []

    /// True when any load-balancing toggle is on, so a summary should be
    /// dispatched through the balanced path rather than the single-backend path.
    var isBalancingEnabled: Bool {
        useAllLocalModels || enableAllFrontierModels || useNovaGateway
    }

    // Cloud API keys
    var openAIKey: String = ""
    var googleCloudKey: String = ""
    var azureKey: String = ""
    var azureEndpoint: String = ""
    var awsAccessKey: String = ""
    var awsSecretKey: String = ""
    var awsRegion: String = "us-east-1"
    var ibmKey: String = ""
    var ibmURL: String = ""

    // Generation parameters
    var temperature: Double = 0.3
    var maxTokens: Int = 300

    // Usage tracking
    var usageStats: UsageStats = UsageStats()
    var performanceMetrics: [AIBackend: PerformanceMetrics] = [:]
    var connectionTestResults: [AIBackend: ConnectionTestResult] = [:]

    let logger = Logger(subsystem: "com.jordankoch.JiraSummary", category: "AIBackend")
    private var monitoringTask: Task<Void, Never>?

    // MARK: - Init

    private init() {
        loadConfiguration()
        Task { await refreshAllBackends() }
    }

    // MARK: - Availability Checks

    func refreshAllBackends() async {
        async let ollama = checkOllama()
        async let mlx = checkMLX()
        async let tiny = checkTinyLLM()
        async let chat = checkTinyChat()
        async let webui = checkOpenWebUI()
        async let router = checkOpenRouter()
        async let nova = checkNovaGateway()

        let results = await (ollama, mlx, tiny, chat, webui, router, nova)
        isOllamaAvailable = results.0
        isMLXAvailable = results.1
        isTinyLLMAvailable = results.2
        isTinyChatAvailable = results.3
        isOpenWebUIAvailable = results.4
        isOpenRouterAvailable = results.5
        isNovaGatewayAvailable = results.6

        if isOllamaAvailable {
            await fetchOllamaModels()
        }

        logger.info("Backend refresh: Ollama=\(self.isOllamaAvailable), MLX=\(self.isMLXAvailable), TinyLLM=\(self.isTinyLLMAvailable), TinyChat=\(self.isTinyChatAvailable), OpenWebUI=\(self.isOpenWebUIAvailable), OpenRouter=\(self.isOpenRouterAvailable), NovaGateway=\(self.isNovaGatewayAvailable)")
    }

    func isAvailable(_ backend: AIBackend) -> Bool {
        switch backend {
        case .ollama: return isOllamaAvailable
        case .mlx: return isMLXAvailable
        case .tinyLLM: return isTinyLLMAvailable
        case .tinyChat: return isTinyChatAvailable
        case .openWebUI: return isOpenWebUIAvailable
        case .openAI: return !openAIKey.isEmpty
        case .googleCloud: return !googleCloudKey.isEmpty
        case .azure: return !azureKey.isEmpty && !azureEndpoint.isEmpty
        case .aws: return !awsAccessKey.isEmpty && !awsSecretKey.isEmpty
        case .ibmWatson: return !ibmKey.isEmpty && !ibmURL.isEmpty
        case .openRouter: return openRouterKeychain.hasValue
        // Nova is optional: availability is health-driven, never assumed.
        case .novaGateway: return isNovaGatewayAvailable
        }
    }

    // MARK: - OpenRouter API key (Keychain-backed)

    /// Store the OpenRouter API key in the Keychain (empty string clears it).
    func setOpenRouterAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            openRouterKeychain.delete()
        } else {
            openRouterKeychain.set(trimmed)
        }
    }

    /// Read the stored OpenRouter API key, if any.
    func openRouterAPIKey() -> String? { openRouterKeychain.get() }

    /// True when an OpenRouter key has been configured.
    var hasOpenRouterKey: Bool { openRouterKeychain.hasValue }

    var anyBackendAvailable: Bool {
        AIBackend.allCases.contains { isAvailable($0) }
    }

    var availableBackends: [AIBackend] {
        AIBackend.allCases.filter { isAvailable($0) }
    }

    // MARK: - Individual Backend Checks

    private func checkOllama() async -> Bool {
        await checkHTTPEndpoint(urlString: "\(ollamaServerURL)/api/tags")
    }

    private func checkTinyLLM() async -> Bool {
        await checkHTTPEndpoint(urlString: "\(tinyLLMServerURL)/health")
    }

    private func checkTinyChat() async -> Bool {
        await checkHTTPEndpoint(urlString: "\(tinyChatServerURL)/api/chat")
    }

    private func checkOpenWebUI() async -> Bool {
        await checkHTTPEndpoint(urlString: "\(openWebUIServerURL)/api/chat")
    }

    private func checkMLX() async -> Bool {
        FileManager.default.fileExists(atPath: "/usr/local/bin/mlx_lm") ||
        FileManager.default.fileExists(atPath: "/opt/homebrew/bin/mlx_lm")
    }

    /// OpenRouter is available only when a key is configured and a lightweight
    /// `/models` fetch succeeds (which also refreshes the model picker).
    private func checkOpenRouter() async -> Bool {
        guard let key = openRouterAPIKey(), !key.isEmpty,
              let url = URL(string: OpenRouterProvider.modelsURL) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        for (header, value) in OpenRouterProvider.authHeaders(apiKey: key) {
            request.setValue(value, forHTTPHeaderField: header)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            let models = OpenRouterProvider.parseModels(data)
            if !models.isEmpty {
                openRouterModels = models
                if !models.contains(selectedOpenRouterModel) {
                    selectedOpenRouterModel = models.contains(OpenRouterProvider.defaultModel)
                        ? OpenRouterProvider.defaultModel : models[0]
                }
            }
            return true
        } catch {
            return false
        }
    }

    /// Nova Gateway health probe against its OpenAI-compatible `/v1/models`
    /// listing. Nova is ALWAYS optional — a failure just marks it unavailable and
    /// it never becomes a hard dependency of the app.
    private func checkNovaGateway() async -> Bool {
        let candidates = ["\(novaGatewayURL)/v1/models", "\(novaGatewayURL)/"]
            .compactMap { URL(string: $0) }
        for url in candidates {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if (response as? HTTPURLResponse)?.statusCode == 200 { return true }
            } catch {
                continue
            }
        }
        return false
    }

    /// Fetch the OpenRouter model list for the picker; falls back to the
    /// hardcoded popular-models list if the fetch fails.
    func fetchOpenRouterModels() async {
        guard let key = openRouterAPIKey(), !key.isEmpty,
              let url = URL(string: OpenRouterProvider.modelsURL) else {
            openRouterModels = OpenRouterProvider.fallbackModels
            return
        }
        var request = URLRequest(url: url)
        for (header, value) in OpenRouterProvider.authHeaders(apiKey: key) {
            request.setValue(value, forHTTPHeaderField: header)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                openRouterModels = OpenRouterProvider.fallbackModels
                return
            }
            let models = OpenRouterProvider.parseModels(data)
            openRouterModels = models.isEmpty ? OpenRouterProvider.fallbackModels : models
        } catch {
            openRouterModels = OpenRouterProvider.fallbackModels
        }
    }

    private func checkHTTPEndpoint(urlString: String) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Model Management

    func fetchOllamaModels() async {
        guard let url = URL(string: "\(ollamaServerURL)/api/tags") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            struct TagsResponse: Decodable {
                struct Model: Decodable { let name: String }
                let models: [Model]?
            }
            let response = try JSONDecoder().decode(TagsResponse.self, from: data)
            ollamaModels = response.models?.map { $0.name } ?? []
            if !ollamaModels.contains(selectedOllamaModel), let first = ollamaModels.first {
                selectedOllamaModel = first
            }
            logger.info("Fetched \(self.ollamaModels.count) Ollama models")
        } catch {
            logger.error("Failed to fetch Ollama models: \(error.localizedDescription)")
        }
    }

    // MARK: - Connection Testing

    func testConnection(for backend: AIBackend) async -> ConnectionTestResult {
        let start = Date()
        var result = ConnectionTestResult(backend: backend)

        do {
            let testPrompt = "Reply with exactly: OK"
            _ = try await generate(prompt: testPrompt, using: backend, maxTokens: 10)
            result.responseTime = Date().timeIntervalSince(start)
            result.isSuccess = true
            result.message = String(format: "Connected (%.1fs)", result.responseTime ?? 0)
        } catch {
            result.responseTime = Date().timeIntervalSince(start)
            result.isSuccess = false
            result.message = error.localizedDescription
        }

        connectionTestResults[backend] = result
        return result
    }

    // MARK: - Background Monitoring

    func startBackgroundMonitoring(interval: TimeInterval = 60) {
        stopBackgroundMonitoring()
        monitoringTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { break }
                await refreshAllBackends()
            }
        }
    }

    func stopBackgroundMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    // MARK: - Keychain Helpers

    private static let keychainService = "com.jordankoch.JiraSummary"

    /// API key identifiers that must be stored in Keychain, not UserDefaults
    private static let apiKeyDefaults: [String] = [
        "AIBackend_OpenAI_Key",
        "AIBackend_GoogleCloud_Key",
        "AIBackend_Azure_Key",
        "AIBackend_Azure_Endpoint",
        "AIBackend_AWS_AccessKey",
        "AIBackend_AWS_SecretKey",
        "AIBackend_IBM_Key",
        "AIBackend_IBM_URL"
    ]

    private func saveToKeychain(key: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: Self.keychainService,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    private func loadFromKeychain(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: Self.keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteFromKeychain(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: Self.keychainService
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// One-time migration: move API keys from UserDefaults to Keychain, then delete from UserDefaults
    private func migrateKeysFromUserDefaults() {
        let defaults = UserDefaults.standard
        let migrationKey = "AIBackend_KeychainMigrationComplete"
        guard !defaults.bool(forKey: migrationKey) else { return }

        for key in Self.apiKeyDefaults {
            if let value = defaults.string(forKey: key), !value.isEmpty {
                saveToKeychain(key: key, value: value)
                defaults.removeObject(forKey: key)
                logger.info("Migrated \(key) from UserDefaults to Keychain")
            }
        }

        defaults.set(true, forKey: migrationKey)
        logger.info("API key migration from UserDefaults to Keychain complete")
    }

    // MARK: - Configuration Persistence

    func saveConfiguration() {
        let defaults = UserDefaults.standard

        // Non-sensitive settings stay in UserDefaults
        defaults.set(activeBackend.rawValue, forKey: "AIBackend_Active")
        defaults.set(isEnabled, forKey: "AIBackend_Enabled")
        defaults.set(selectedOllamaModel, forKey: "AIBackend_OllamaModel")
        defaults.set(ollamaServerURL, forKey: "AIBackend_OllamaURL")
        defaults.set(tinyLLMServerURL, forKey: "AIBackend_TinyLLMURL")
        defaults.set(tinyChatServerURL, forKey: "AIBackend_TinyChatURL")
        defaults.set(openWebUIServerURL, forKey: "AIBackend_OpenWebUIURL")
        defaults.set(novaGatewayURL, forKey: "AIBackend_NovaGatewayURL")
        defaults.set(selectedOpenRouterModel, forKey: "AIBackend_OpenRouterModel")
        defaults.set(useAllLocalModels, forKey: "AIBackend_UseAllLocalModels")
        defaults.set(enableAllFrontierModels, forKey: "AIBackend_EnableAllFrontierModels")
        defaults.set(useNovaGateway, forKey: "AIBackend_UseNovaGateway")
        defaults.set(awsRegion, forKey: "AIBackend_AWS_Region")
        defaults.set(temperature, forKey: "AIBackend_Temperature")
        defaults.set(maxTokens, forKey: "AIBackend_MaxTokens")

        if let statsData = try? JSONEncoder().encode(usageStats) {
            defaults.set(statsData, forKey: "AIBackend_UsageStats")
        }

        // API keys and secrets go to Keychain
        saveToKeychain(key: "AIBackend_OpenAI_Key", value: openAIKey)
        saveToKeychain(key: "AIBackend_GoogleCloud_Key", value: googleCloudKey)
        saveToKeychain(key: "AIBackend_Azure_Key", value: azureKey)
        saveToKeychain(key: "AIBackend_Azure_Endpoint", value: azureEndpoint)
        saveToKeychain(key: "AIBackend_AWS_AccessKey", value: awsAccessKey)
        saveToKeychain(key: "AIBackend_AWS_SecretKey", value: awsSecretKey)
        saveToKeychain(key: "AIBackend_IBM_Key", value: ibmKey)
        saveToKeychain(key: "AIBackend_IBM_URL", value: ibmURL)
    }

    func loadConfiguration() {
        let defaults = UserDefaults.standard

        // Migrate any keys still in UserDefaults to Keychain (one-time)
        migrateKeysFromUserDefaults()

        // Non-sensitive settings from UserDefaults
        if let raw = defaults.string(forKey: "AIBackend_Active"),
           let backend = AIBackend(rawValue: raw) {
            activeBackend = backend
        }
        isEnabled = defaults.bool(forKey: "AIBackend_Enabled")
        selectedOllamaModel = defaults.string(forKey: "AIBackend_OllamaModel") ?? "llama3"
        ollamaServerURL = defaults.string(forKey: "AIBackend_OllamaURL") ?? "http://localhost:11434"
        tinyLLMServerURL = defaults.string(forKey: "AIBackend_TinyLLMURL") ?? "http://localhost:8000"
        tinyChatServerURL = defaults.string(forKey: "AIBackend_TinyChatURL") ?? "http://localhost:8000"
        openWebUIServerURL = defaults.string(forKey: "AIBackend_OpenWebUIURL") ?? "http://localhost:8080"
        novaGatewayURL = defaults.string(forKey: "AIBackend_NovaGatewayURL") ?? ModelRegistry.novaGatewayDefaultURL
        selectedOpenRouterModel = defaults.string(forKey: "AIBackend_OpenRouterModel") ?? OpenRouterProvider.defaultModel
        useAllLocalModels = defaults.bool(forKey: "AIBackend_UseAllLocalModels")
        enableAllFrontierModels = defaults.bool(forKey: "AIBackend_EnableAllFrontierModels")
        useNovaGateway = defaults.bool(forKey: "AIBackend_UseNovaGateway")
        awsRegion = defaults.string(forKey: "AIBackend_AWS_Region") ?? "us-east-1"
        temperature = defaults.double(forKey: "AIBackend_Temperature")
        if temperature == 0 { temperature = 0.3 }
        maxTokens = defaults.integer(forKey: "AIBackend_MaxTokens")
        if maxTokens == 0 { maxTokens = 300 }

        if let statsData = defaults.data(forKey: "AIBackend_UsageStats"),
           let stats = try? JSONDecoder().decode(UsageStats.self, from: statsData) {
            usageStats = stats
        }

        // API keys and secrets from Keychain
        openAIKey = loadFromKeychain(key: "AIBackend_OpenAI_Key") ?? ""
        googleCloudKey = loadFromKeychain(key: "AIBackend_GoogleCloud_Key") ?? ""
        azureKey = loadFromKeychain(key: "AIBackend_Azure_Key") ?? ""
        azureEndpoint = loadFromKeychain(key: "AIBackend_Azure_Endpoint") ?? ""
        awsAccessKey = loadFromKeychain(key: "AIBackend_AWS_AccessKey") ?? ""
        awsSecretKey = loadFromKeychain(key: "AIBackend_AWS_SecretKey") ?? ""
        ibmKey = loadFromKeychain(key: "AIBackend_IBM_Key") ?? ""
        ibmURL = loadFromKeychain(key: "AIBackend_IBM_URL") ?? ""
    }
}

// MARK: - Supporting Types

struct UsageStats: Codable {
    var totalTokens: Int = 0
    var totalRequests: Int = 0
    var totalCost: Double = 0
    var averageResponseTime: Double = 0
    var lastUsed: Date?

    static func estimatedCostPerRequest(backend: AIBackend, tokens: Int) -> Double {
        let perMillionTokens: Double
        switch backend {
        case .openAI: perMillionTokens = 10.0
        case .googleCloud: perMillionTokens = 7.0
        case .azure: perMillionTokens = 10.0
        case .aws: perMillionTokens = 8.0
        case .ibmWatson: perMillionTokens = 12.0
        default: return 0 // Local backends are free
        }
        return Double(tokens) / 1_000_000 * perMillionTokens
    }
}

struct PerformanceMetrics {
    var averageLatency: TimeInterval = 0
    var successRate: Double = 1.0
    var totalAttempts: Int = 0
    var successfulAttempts: Int = 0
    var failedAttempts: Int = 0
    var lastResponseTime: TimeInterval?
    var lastSuccess: Date?
    var lastFailure: Date?
}

struct ConnectionTestResult {
    let backend: AIBackend
    var isSuccess: Bool = false
    var responseTime: TimeInterval?
    var message: String = "Not tested"
}

enum AIGenerationError: LocalizedError {
    case noBackendAvailable
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case noResponse
    case backendNotImplemented(String)
    case allBackendsFailed

    var errorDescription: String? {
        switch self {
        case .noBackendAvailable: return "No AI backend available"
        case .invalidURL: return "Invalid backend URL"
        case .invalidResponse: return "Invalid response from AI backend"
        case .httpError(let code): return "HTTP error \(code)"
        case .noResponse: return "No response from AI backend"
        case .backendNotImplemented(let name): return "\(name) backend not yet implemented"
        case .allBackendsFailed: return "All AI backends failed"
        }
    }
}
