//
//  AIBackendTests.swift
//  JiraSummaryTests
//
//  Unit tests for AIBackend enum and supporting types
//  Created by Jordan Koch on 2026-05-01.
//

import XCTest
@testable import JiraSummary

final class AIBackendTests: XCTestCase {

    // MARK: - AIBackend Enum

    func testAllBackendsCovered() {
        XCTAssertEqual(AIBackend.allCases.count, 12, "Should have 12 AI backends (incl. OpenRouter + Nova Gateway)")
    }

    func testBackendRawValues() {
        XCTAssertEqual(AIBackend.ollama.rawValue, "Ollama")
        XCTAssertEqual(AIBackend.mlx.rawValue, "MLX")
        XCTAssertEqual(AIBackend.tinyLLM.rawValue, "TinyLLM")
        XCTAssertEqual(AIBackend.tinyChat.rawValue, "TinyChat")
        XCTAssertEqual(AIBackend.openWebUI.rawValue, "OpenWebUI")
        XCTAssertEqual(AIBackend.openAI.rawValue, "OpenAI")
        XCTAssertEqual(AIBackend.googleCloud.rawValue, "Google Cloud")
        XCTAssertEqual(AIBackend.azure.rawValue, "Azure")
        XCTAssertEqual(AIBackend.aws.rawValue, "AWS")
        XCTAssertEqual(AIBackend.ibmWatson.rawValue, "IBM Watson")
        XCTAssertEqual(AIBackend.openRouter.rawValue, "OpenRouter")
        XCTAssertEqual(AIBackend.novaGateway.rawValue, "Nova Gateway")
    }

    func testBackendIsLocal() {
        XCTAssertTrue(AIBackend.ollama.isLocal)
        XCTAssertTrue(AIBackend.mlx.isLocal)
        XCTAssertTrue(AIBackend.tinyLLM.isLocal)
        XCTAssertTrue(AIBackend.tinyChat.isLocal)
        XCTAssertTrue(AIBackend.openWebUI.isLocal)
        // Nova Gateway runs on the local machine (127.0.0.1).
        XCTAssertTrue(AIBackend.novaGateway.isLocal)

        XCTAssertFalse(AIBackend.openAI.isLocal)
        XCTAssertFalse(AIBackend.googleCloud.isLocal)
        XCTAssertFalse(AIBackend.azure.isLocal)
        XCTAssertFalse(AIBackend.aws.isLocal)
        XCTAssertFalse(AIBackend.ibmWatson.isLocal)
        XCTAssertFalse(AIBackend.openRouter.isLocal)
    }

    func testBackendIconsAreNonEmpty() {
        for backend in AIBackend.allCases {
            XCTAssertFalse(backend.icon.isEmpty, "\(backend.rawValue) should have an icon")
        }
    }

    func testBackendIdentifiable() {
        for backend in AIBackend.allCases {
            XCTAssertEqual(backend.id, backend.rawValue)
        }
    }

    func testBackendCodable() throws {
        for backend in AIBackend.allCases {
            let data = try JSONEncoder().encode(backend)
            let decoded = try JSONDecoder().decode(AIBackend.self, from: data)
            XCTAssertEqual(decoded, backend)
        }
    }

    // MARK: - UsageStats

    func testUsageStatsDefaults() {
        let stats = UsageStats()
        XCTAssertEqual(stats.totalTokens, 0)
        XCTAssertEqual(stats.totalRequests, 0)
        XCTAssertEqual(stats.totalCost, 0)
        XCTAssertEqual(stats.averageResponseTime, 0)
        XCTAssertNil(stats.lastUsed)
    }

    func testUsageStatsCodable() throws {
        var stats = UsageStats()
        stats.totalTokens = 5000
        stats.totalRequests = 10
        stats.totalCost = 0.05
        stats.averageResponseTime = 1.5
        stats.lastUsed = Date()

        let data = try JSONEncoder().encode(stats)
        let decoded = try JSONDecoder().decode(UsageStats.self, from: data)

        XCTAssertEqual(decoded.totalTokens, 5000)
        XCTAssertEqual(decoded.totalRequests, 10)
        XCTAssertEqual(decoded.totalCost, 0.05, accuracy: 0.001)
        XCTAssertEqual(decoded.averageResponseTime, 1.5, accuracy: 0.001)
        XCTAssertNotNil(decoded.lastUsed)
    }

    func testEstimatedCostCalculation() {
        // OpenAI: $10 per million tokens
        let openAICost = UsageStats.estimatedCostPerRequest(backend: .openAI, tokens: 1000)
        XCTAssertEqual(openAICost, 0.01, accuracy: 0.001) // 1000/1M * $10

        // Google: $7 per million tokens
        let googleCost = UsageStats.estimatedCostPerRequest(backend: .googleCloud, tokens: 1000)
        XCTAssertEqual(googleCost, 0.007, accuracy: 0.001)

        // AWS: $8 per million tokens
        let awsCost = UsageStats.estimatedCostPerRequest(backend: .aws, tokens: 500)
        XCTAssertEqual(awsCost, 0.004, accuracy: 0.001) // 500/1M * $8

        // IBM Watson: $12 per million tokens
        let ibmCost = UsageStats.estimatedCostPerRequest(backend: .ibmWatson, tokens: 2000)
        XCTAssertEqual(ibmCost, 0.024, accuracy: 0.001)

        // Local should be free
        XCTAssertEqual(UsageStats.estimatedCostPerRequest(backend: .ollama, tokens: 100000), 0)
    }

    func testEstimatedCostZeroTokens() {
        let cost = UsageStats.estimatedCostPerRequest(backend: .openAI, tokens: 0)
        XCTAssertEqual(cost, 0)
    }

    // MARK: - PerformanceMetrics

    func testPerformanceMetricsDefaults() {
        let metrics = PerformanceMetrics()
        XCTAssertEqual(metrics.averageLatency, 0)
        XCTAssertEqual(metrics.successRate, 1.0)
        XCTAssertEqual(metrics.totalAttempts, 0)
        XCTAssertEqual(metrics.successfulAttempts, 0)
        XCTAssertEqual(metrics.failedAttempts, 0)
        XCTAssertNil(metrics.lastResponseTime)
        XCTAssertNil(metrics.lastSuccess)
        XCTAssertNil(metrics.lastFailure)
    }

    // MARK: - ConnectionTestResult

    func testConnectionTestResultDefaults() {
        let result = ConnectionTestResult(backend: .ollama)
        XCTAssertEqual(result.backend, .ollama)
        XCTAssertFalse(result.isSuccess)
        XCTAssertNil(result.responseTime)
        XCTAssertEqual(result.message, "Not tested")
    }

    // MARK: - AIGenerationError

    func testAIGenerationErrorDescriptions() {
        XCTAssertNotNil(AIGenerationError.noBackendAvailable.errorDescription)
        XCTAssertNotNil(AIGenerationError.invalidURL.errorDescription)
        XCTAssertNotNil(AIGenerationError.invalidResponse.errorDescription)
        XCTAssertNotNil(AIGenerationError.httpError(500).errorDescription)
        XCTAssertNotNil(AIGenerationError.noResponse.errorDescription)
        XCTAssertNotNil(AIGenerationError.backendNotImplemented("Test").errorDescription)
        XCTAssertNotNil(AIGenerationError.allBackendsFailed.errorDescription)

        XCTAssertTrue(AIGenerationError.httpError(500).errorDescription?.contains("500") ?? false)
        XCTAssertTrue(AIGenerationError.backendNotImplemented("Azure").errorDescription?.contains("Azure") ?? false)
    }
}
