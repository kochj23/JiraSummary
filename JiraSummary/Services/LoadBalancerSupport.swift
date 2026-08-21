//
//  LoadBalancerSupport.swift
//  JiraSummary
//
//  Supporting types for the shared multi-model LLM load balancer. These are the
//  dependency types referenced by the verbatim `ModelRegistry.swift`,
//  `OpenRouterProvider.swift` and `KeychainStore.swift` files carried over from
//  AIStudio's balanced-dispatch layer. They are namespaced separately from the
//  app's existing `AIBackend` enum so the copied files stay byte-for-byte
//  identical to AIStudio's while the existing multi-backend UI keeps using
//  `AIBackend`. The balanced-dispatch manager maps between the two.
//
//  Copied verbatim from AIStudio (LLMBackendType.swift, BackendConfiguration.swift,
//  ChatMessage.swift, LLMBackendManager.swift).
//  Copyright © 2026 Jordan Koch. All rights reserved.
//

import Foundation

// MARK: - LLM backend type (from AIStudio/Models/LLMBackendType.swift)

/// LLM backend type identifier
enum LLMBackendType: String, CaseIterable, Codable, Sendable {
    case ollama = "ollama"
    case mlx = "mlx"
    case tinyLLM = "tinyllm"
    case tinyChat = "tinychat"
    case openWebUI = "openwebui"
    case openRouter = "openrouter"
    case novaGateway = "novagateway"
    case auto = "auto"

    var displayName: String {
        switch self {
        case .ollama: return "Ollama"
        case .mlx: return "MLX Native"
        case .tinyLLM: return "TinyLLM"
        case .tinyChat: return "TinyChat"
        case .openWebUI: return "OpenWebUI"
        case .openRouter: return "OpenRouter (Frontier Models)"
        case .novaGateway: return "Nova Gateway"
        case .auto: return "Auto (Prefer Ollama)"
        }
    }

    var icon: String {
        switch self {
        case .ollama: return "network"
        case .mlx: return "cpu"
        case .tinyLLM: return "cube"
        case .tinyChat: return "bubble.left.and.bubble.right.fill"
        case .openWebUI: return "globe"
        case .openRouter: return "cloud"
        case .novaGateway: return "sparkle.magnifyingglass"
        case .auto: return "sparkles"
        }
    }

    var defaultURL: String {
        switch self {
        case .ollama: return "http://localhost:11434"
        case .mlx: return ""
        case .tinyLLM: return "http://localhost:8000"
        case .tinyChat: return "http://localhost:8000"
        case .openWebUI: return "http://localhost:8080"
        case .openRouter: return OpenRouterProvider.baseURL
        case .novaGateway: return ModelRegistry.novaGatewayDefaultURL
        case .auto: return ""
        }
    }

    var description: String {
        switch self {
        case .ollama: return "HTTP-based LLM API (localhost:11434)"
        case .mlx: return "Apple Silicon native inference via MLX"
        case .tinyLLM: return "TinyLLM lightweight server (localhost:8000)"
        case .tinyChat: return "TinyChat by Jason Cox (localhost:8000)"
        case .openWebUI: return "Self-hosted AI platform (localhost:8080)"
        case .openRouter: return "Frontier cloud models via OpenRouter (bring your own key)"
        case .novaGateway: return "Nova's gateway — OpenAI-compatible, inherits Nova's own routing (127.0.0.1:18792)"
        case .auto: return "Automatically choose best available backend"
        }
    }

    var attribution: String? {
        switch self {
        case .tinyLLM: return "TinyLLM by Jason Cox (https://github.com/jasonacox/TinyLLM)"
        case .tinyChat: return "TinyChat by Jason Cox (https://github.com/jasonacox/tinychat)"
        case .openWebUI: return "OpenWebUI Community Project (https://github.com/open-webui/open-webui)"
        default: return nil
        }
    }
}

/// Configuration for a single LLM backend
struct LLMBackendConfiguration: Identifiable, Sendable {
    let id: UUID
    let type: LLMBackendType
    var url: String
    var status: BackendStatus

    init(type: LLMBackendType, url: String? = nil) {
        self.id = UUID()
        self.type = type
        self.url = url ?? type.defaultURL
        self.status = .disconnected
    }
}

// MARK: - Backend status (from AIStudio/Models/BackendConfiguration.swift)

/// Connection status for a backend
enum BackendStatus: Sendable, Equatable {
    case connected
    case disconnected
    case checking
    case error(String)

    var displayText: String {
        switch self {
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        case .checking: return "Checking..."
        case .error(let msg): return "Error: \(msg)"
        }
    }

    var statusColor: String {
        switch self {
        case .connected: return "green"
        case .disconnected: return "gray"
        case .checking: return "yellow"
        case .error: return "red"
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

// MARK: - Chat message (from AIStudio/Models/ChatMessage.swift)

/// Role in a chat conversation
enum ChatRole: String, Codable, Sendable {
    case system
    case user
    case assistant
}

/// A single chat message
struct ChatMessage: Identifiable, Codable, Sendable {
    let id: UUID
    let role: ChatRole
    var content: String
    let timestamp: Date

    init(role: ChatRole, content: String) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
    }
}

// MARK: - LLM errors (from AIStudio/Services/LLMBackendManager.swift)

enum LLMError: LocalizedError, Sendable {
    case noBackendAvailable
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case noResponse
    case mlxNotAvailable

    var errorDescription: String? {
        switch self {
        case .noBackendAvailable:
            return "No LLM backend is available. Please start Ollama, TinyLLM, TinyChat, or OpenWebUI."
        case .invalidURL:
            return "Invalid backend URL configuration."
        case .invalidResponse:
            return "Received invalid response from LLM backend."
        case .httpError(let code):
            return "HTTP error \(code) from LLM backend."
        case .noResponse:
            return "No response received from LLM backend."
        case .mlxNotAvailable:
            return "MLX not available. Install: pip install mlx-lm"
        }
    }
}
