//
//  AIBackendManager+Generation.swift
//  JiraSummary
//
//  Text generation implementations for each AI backend
//  Auto-fallback tries backends in priority order if primary fails
//  Created by Jordan Koch on 2026-02-17.
//

import Foundation
import os.log

extension AIBackendManager {

    // MARK: - Generate with Active Backend

    func generate(
        prompt: String,
        systemPrompt: String? = nil,
        using backend: AIBackend? = nil,
        temperature: Double? = nil,
        maxTokens: Int? = nil
    ) async throws -> String {
        let target = backend ?? activeBackend
        let temp = temperature ?? self.temperature
        let tokens = maxTokens ?? self.maxTokens

        guard isAvailable(target) else {
            throw AIGenerationError.noBackendAvailable
        }

        let start = Date()
        var result: String

        switch target {
        case .ollama:
            result = try await generateOllama(prompt: prompt, systemPrompt: systemPrompt, temperature: temp, maxTokens: tokens)
        case .tinyLLM:
            result = try await generateOpenAICompatible(url: tinyLLMServerURL, prompt: prompt, systemPrompt: systemPrompt, temperature: temp, maxTokens: tokens)
        case .tinyChat:
            result = try await generateTinyChat(prompt: prompt, systemPrompt: systemPrompt, temperature: temp, maxTokens: tokens)
        case .openWebUI:
            result = try await generateOpenAICompatible(url: openWebUIServerURL, prompt: prompt, systemPrompt: systemPrompt, temperature: temp, maxTokens: tokens)
        case .openAI:
            result = try await generateOpenAI(prompt: prompt, systemPrompt: systemPrompt, temperature: temp, maxTokens: tokens)
        case .mlx:
            result = try await generateMLX(prompt: prompt, maxTokens: tokens)
        case .openRouter:
            result = try await generateOpenRouter(prompt: prompt, systemPrompt: systemPrompt, temperature: temp, maxTokens: tokens)
        case .novaGateway:
            result = try await generateNovaGateway(prompt: prompt, systemPrompt: systemPrompt, temperature: temp, maxTokens: tokens)
        case .googleCloud, .azure, .aws, .ibmWatson:
            throw AIGenerationError.backendNotImplemented(target.rawValue)
        }

        // Track usage
        let elapsed = Date().timeIntervalSince(start)
        trackUsage(backend: target, tokens: tokens, responseTime: elapsed, success: true)

        return result
    }

    // MARK: - Generate with Auto-Fallback

    func generateWithFallback(
        prompt: String,
        systemPrompt: String? = nil,
        temperature: Double? = nil,
        maxTokens: Int? = nil
    ) async throws -> String {
        // Load-balanced mode: when any balancing toggle is on, fan the summary out
        // across the enabled pool (all local models / all frontier / Nova Gateway).
        // Falls through to the single-backend priority path when the pool is
        // empty or unreachable.
        if isBalancingEnabled {
            do {
                if let balanced = try await generateBalanced(prompt: prompt, systemPrompt: systemPrompt, temperature: temperature, maxTokens: maxTokens) {
                    return balanced
                }
            } catch {
                logger.warning("Balanced dispatch failed, falling back: \(error.localizedDescription)")
            }
        }

        // Priority order: Ollama → OpenAI → TinyChat → TinyLLM → OpenWebUI → MLX
        let priority: [AIBackend] = [.ollama, .openAI, .tinyChat, .tinyLLM, .openWebUI, .mlx]

        // Try active backend first
        if isAvailable(activeBackend) {
            do {
                return try await generate(prompt: prompt, systemPrompt: systemPrompt, using: activeBackend, temperature: temperature, maxTokens: maxTokens)
            } catch {
                logger.warning("Active backend \(self.activeBackend.rawValue) failed: \(error.localizedDescription)")
            }
        }

        // Try fallbacks
        for backend in priority where backend != activeBackend && isAvailable(backend) {
            do {
                let result = try await generate(prompt: prompt, systemPrompt: systemPrompt, using: backend, temperature: temperature, maxTokens: maxTokens)
                logger.info("Fallback to \(backend.rawValue) succeeded")
                return result
            } catch {
                logger.warning("Fallback \(backend.rawValue) failed: \(error.localizedDescription)")
                continue
            }
        }

        throw AIGenerationError.allBackendsFailed
    }

    // MARK: - Ollama

    private func generateOllama(prompt: String, systemPrompt: String?, temperature: Double, maxTokens: Int) async throws -> String {
        guard let url = URL(string: "\(ollamaServerURL)/api/generate") else {
            throw AIGenerationError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        var body: [String: Any] = [
            "model": selectedOllamaModel,
            "prompt": prompt,
            "stream": false,
            "options": [
                "temperature": temperature,
                "num_predict": maxTokens
            ]
        ]
        if let system = systemPrompt {
            body["system"] = system
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIGenerationError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        struct OllamaResponse: Decodable { let response: String }
        let decoded = try JSONDecoder().decode(OllamaResponse.self, from: data)
        return decoded.response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - OpenAI-Compatible (TinyLLM, OpenWebUI)

    private func generateOpenAICompatible(url: String, prompt: String, systemPrompt: String?, temperature: Double, maxTokens: Int) async throws -> String {
        guard let endpoint = URL(string: "\(url)/v1/chat/completions") else {
            throw AIGenerationError.invalidURL
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        var messages: [[String: String]] = []
        if let system = systemPrompt {
            messages.append(["role": "system", "content": system])
        }
        messages.append(["role": "user", "content": prompt])

        let body: [String: Any] = [
            "messages": messages,
            "temperature": temperature,
            "max_tokens": maxTokens
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIGenerationError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        struct ChatResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content else {
            throw AIGenerationError.noResponse
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - TinyChat

    private func generateTinyChat(prompt: String, systemPrompt: String?, temperature: Double, maxTokens: Int) async throws -> String {
        guard let url = URL(string: "\(tinyChatServerURL)/api/chat") else {
            throw AIGenerationError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        var messages: [[String: String]] = []
        if let system = systemPrompt {
            messages.append(["role": "system", "content": system])
        }
        messages.append(["role": "user", "content": prompt])

        let body: [String: Any] = [
            "messages": messages,
            "temperature": temperature,
            "max_tokens": maxTokens,
            "stream": false
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIGenerationError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        struct ChatResponse: Decodable {
            let message: String?
            let response: String?
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        let content = decoded.message ?? decoded.response ?? ""
        guard !content.isEmpty else { throw AIGenerationError.noResponse }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - OpenAI

    private func generateOpenAI(prompt: String, systemPrompt: String?, temperature: Double, maxTokens: Int) async throws -> String {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw AIGenerationError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(openAIKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60

        var messages: [[String: String]] = []
        if let system = systemPrompt {
            messages.append(["role": "system", "content": system])
        }
        messages.append(["role": "user", "content": prompt])

        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": messages,
            "temperature": temperature,
            "max_tokens": maxTokens
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIGenerationError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        struct ChatResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content else {
            throw AIGenerationError.noResponse
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - MLX

    func generateMLX(prompt: String, maxTokens: Int) async throws -> String {
        let mlxPath = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/mlx_lm")
            ? "/opt/homebrew/bin/mlx_lm"
            : "/usr/local/bin/mlx_lm"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: mlxPath)
        process.arguments = [
            "generate",
            "--model", "mlx-community/Llama-3.2-3B-Instruct-4bit",
            "--prompt", prompt,
            "--max-tokens", String(maxTokens)
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8), !output.isEmpty else {
            throw AIGenerationError.noResponse
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Usage Tracking

    private func trackUsage(backend: AIBackend, tokens: Int, responseTime: TimeInterval, success: Bool) {
        usageStats.totalRequests += 1
        usageStats.totalTokens += tokens
        usageStats.totalCost += UsageStats.estimatedCostPerRequest(backend: backend, tokens: tokens)
        usageStats.lastUsed = Date()

        let prevTotal = usageStats.averageResponseTime * Double(usageStats.totalRequests - 1)
        usageStats.averageResponseTime = (prevTotal + responseTime) / Double(usageStats.totalRequests)

        var metrics = performanceMetrics[backend] ?? PerformanceMetrics()
        metrics.totalAttempts += 1
        if success {
            metrics.successfulAttempts += 1
            metrics.lastSuccess = Date()
            metrics.lastResponseTime = responseTime
        } else {
            metrics.failedAttempts += 1
            metrics.lastFailure = Date()
        }
        metrics.successRate = Double(metrics.successfulAttempts) / Double(max(metrics.totalAttempts, 1))
        let prevLatency = metrics.averageLatency * Double(metrics.totalAttempts - 1)
        metrics.averageLatency = (prevLatency + responseTime) / Double(metrics.totalAttempts)
        performanceMetrics[backend] = metrics

        saveConfiguration()
    }
}
