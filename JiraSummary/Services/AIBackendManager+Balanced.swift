//
//  AIBackendManager+Balanced.swift
//  JiraSummary
//
//  Shared multi-model LLM load balancer, integrated with the existing
//  multi-backend layer. Mirrors AIStudio's `LLMBackendManager` balanced-dispatch:
//  the daily-summary generation can fan out across ALL enabled local models
//  (Ollama + MLX), ALL OpenRouter frontier models, and the optional Nova Gateway,
//  spread by the pure `LoadBalancer` over a health-gated pool.
//
//  Nova Gateway is ALWAYS optional — a failed health check simply drops it from
//  the pool; it is never a hard dependency.
//
//  Created by Jordan Koch on 2026-02-17.
//

import Foundation

extension AIBackendManager {

    // MARK: - Balanced entry point

    /// Fan the prompt out across the enabled balancer pool. Returns nil when no
    /// balancing toggle is on or the pool has no reachable model, so the caller
    /// can fall back to the existing single-backend / priority path.
    func generateBalanced(
        prompt: String,
        systemPrompt: String? = nil,
        temperature: Double? = nil,
        maxTokens: Int? = nil
    ) async throws -> String? {
        guard isBalancingEnabled else { return nil }

        let temp = Float(temperature ?? self.temperature)
        let tokens = maxTokens ?? self.maxTokens

        let pool = await discoverEnabledPool()
        guard !pool.isEmpty else { return nil }

        let health = await healthMap(for: pool)
        var remaining = pool
        var lastError: Error?

        // Try balancer-selected models, falling through on failure.
        while let choice = balancer.next(pool: remaining, health: health, policy: balancerPolicy) {
            balancer.checkOut(choice.id)
            do {
                let result = try await dispatchBalanced(model: choice, prompt: prompt, systemPrompt: systemPrompt, temperature: temp, maxTokens: tokens)
                balancer.checkIn(choice.id)
                return result
            } catch {
                balancer.checkIn(choice.id)
                lastError = error
                remaining.removeAll { $0.id == choice.id }
                continue
            }
        }

        // Nothing healthy in the pool — let the caller fall back cleanly.
        if let lastError = lastError { throw lastError }
        return nil
    }

    // MARK: - Pool discovery + health gating

    /// Discover the enabled balancer pool honoring the three toggles. Resilient:
    /// any unreachable source contributes zero models.
    func discoverEnabledPool() async -> [DiscoveredModel] {
        var ollama: [DiscoveredModel] = []
        var mlx: [DiscoveredModel] = []
        var frontier: [DiscoveredModel] = []

        if useAllLocalModels {
            ollama = await ModelRegistry.discoverOllama(baseURL: ollamaServerURL)
            mlx = ModelRegistry.discoverMLX()
        }
        if enableAllFrontierModels {
            frontier = ModelRegistry.frontierModels(from: openRouterModels)
        }
        let nova = useNovaGateway ? ModelRegistry.novaGatewayModel(url: novaGatewayURL) : nil

        let pool = ModelRegistry.assemblePool(
            ollama: ollama,
            mlx: mlx,
            frontier: frontier,
            novaGateway: nova,
            useAllLocalModels: useAllLocalModels,
            enableAllFrontierModels: enableAllFrontierModels,
            useNovaGateway: useNovaGateway
        )
        discoveredModels = pool
        return pool
    }

    /// Build a `[modelId: Bool]` health map for `pool` by probing each distinct
    /// backend once (health-gating for the load balancer).
    private func healthMap(for pool: [DiscoveredModel]) async -> [String: Bool] {
        var backendHealth: [LLMBackendType: Bool] = [:]
        for backend in Set(pool.map { $0.backend }) {
            backendHealth[backend] = await checkAvailability(backend)
        }
        var map: [String: Bool] = [:]
        for model in pool {
            map[model.id] = backendHealth[model.backend] ?? false
        }
        return map
    }

    /// Quick availability probe for a load-balancer backend type, reusing the
    /// existing `AIBackend` availability where they correspond.
    private func checkAvailability(_ type: LLMBackendType) async -> Bool {
        switch type {
        case .ollama: return isAvailable(.ollama)
        case .mlx: return isAvailable(.mlx)
        case .openRouter: return isAvailable(.openRouter)
        case .novaGateway: return isAvailable(.novaGateway)
        case .tinyLLM: return isAvailable(.tinyLLM)
        case .tinyChat: return isAvailable(.tinyChat)
        case .openWebUI: return isAvailable(.openWebUI)
        case .auto: return false
        }
    }

    // MARK: - Balanced dispatch

    /// Route a single balancer-selected model through the appropriate backend
    /// implementation (all OpenAI-compatible backends ride the generic path).
    private func dispatchBalanced(
        model: DiscoveredModel,
        prompt: String,
        systemPrompt: String?,
        temperature: Float,
        maxTokens: Int
    ) async throws -> String {
        switch model.backend {
        case .ollama:
            return try await generateOllamaChat(model: model.modelName, prompt: prompt, systemPrompt: systemPrompt, temperature: temperature, maxTokens: maxTokens)
        case .mlx:
            return try await generateMLX(prompt: prompt, maxTokens: maxTokens)
        case .openRouter:
            guard let key = openRouterAPIKey(), !key.isEmpty else { throw LLMError.noBackendAvailable }
            return try await generateOpenAICompatibleEndpoint(endpoint: model.endpoint, model: model.modelName, headers: OpenRouterProvider.authHeaders(apiKey: key), prompt: prompt, systemPrompt: systemPrompt, temperature: temperature, maxTokens: maxTokens)
        case .novaGateway:
            return try await generateOpenAICompatibleEndpoint(endpoint: model.endpoint, model: model.modelName, headers: [:], prompt: prompt, systemPrompt: systemPrompt, temperature: temperature, maxTokens: maxTokens)
        default:
            throw LLMError.noBackendAvailable
        }
    }

    // MARK: - Backend request implementations

    /// Ollama `/api/chat` generation against a specific model (balanced path).
    func generateOllamaChat(
        model: String,
        prompt: String,
        systemPrompt: String?,
        temperature: Float,
        maxTokens: Int
    ) async throws -> String {
        guard let url = URL(string: "\(ollamaServerURL)/api/chat") else { throw LLMError.invalidURL }

        var apiMessages: [[String: String]] = []
        if let system = systemPrompt, !system.isEmpty {
            apiMessages.append(["role": "system", "content": system])
        }
        apiMessages.append(["role": "user", "content": prompt])

        let body: [String: Any] = [
            "model": model,
            "messages": apiMessages,
            "stream": false,
            "options": ["temperature": temperature, "num_predict": maxTokens]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw LLMError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.noResponse
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Non-streaming generation against a full OpenAI-compatible endpoint URL.
    /// Shared by OpenRouter and Nova Gateway, using the copied
    /// `OpenAICompatibleRequest` builder.
    func generateOpenAICompatibleEndpoint(
        endpoint: String,
        model: String,
        headers: [String: String],
        prompt: String,
        systemPrompt: String?,
        temperature: Float,
        maxTokens: Int
    ) async throws -> String {
        let apiMessages = OpenAICompatibleRequest.chatMessages(prompt: prompt, systemPrompt: systemPrompt, history: [])
        var request = try OpenAICompatibleRequest.build(
            endpoint: endpoint,
            model: model,
            messages: apiMessages,
            temperature: temperature,
            maxTokens: maxTokens,
            stream: false,
            headers: headers
        )
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw LLMError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        struct OpenAIResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }
        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content else { throw LLMError.noResponse }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Single-backend OpenRouter / Nova (used by the AIBackend switch)

    /// OpenRouter frontier-model generation for the selected model.
    func generateOpenRouter(prompt: String, systemPrompt: String?, temperature: Double, maxTokens: Int) async throws -> String {
        guard let key = openRouterAPIKey(), !key.isEmpty else { throw AIGenerationError.noBackendAvailable }
        return try await generateOpenAICompatibleEndpoint(
            endpoint: OpenRouterProvider.chatCompletionsURL,
            model: selectedOpenRouterModel,
            headers: OpenRouterProvider.authHeaders(apiKey: key),
            prompt: prompt,
            systemPrompt: systemPrompt,
            temperature: Float(temperature),
            maxTokens: maxTokens
        )
    }

    /// Nova Gateway generation (OpenAI-compatible; inherits Nova's own routing).
    func generateNovaGateway(prompt: String, systemPrompt: String?, temperature: Double, maxTokens: Int) async throws -> String {
        return try await generateOpenAICompatibleEndpoint(
            endpoint: "\(novaGatewayURL)/v1/chat/completions",
            model: "nova",
            headers: [:],
            prompt: prompt,
            systemPrompt: systemPrompt,
            temperature: Float(temperature),
            maxTokens: maxTokens
        )
    }
}
