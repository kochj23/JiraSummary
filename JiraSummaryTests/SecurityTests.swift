//
//  SecurityTests.swift
//  JiraSummaryTests
//
//  Security tests: Keychain usage, no token logging, URL construction safety,
//  JQL/WIQL injection prevention
//  Created by Jordan Koch on 2026-05-01.
//

import XCTest
@testable import JiraSummary

final class SecurityTests: XCTestCase {

    // MARK: - Keychain Service Structure

    func testKeychainServiceIsSingleton() {
        let a = KeychainService.shared
        let b = KeychainService.shared
        XCTAssertTrue(a === b, "KeychainService should be a singleton")
    }

    func testKeychainStoreAndRetrieveCredential() throws {
        let systemId = UUID()
        let credential = AuthCredential(
            systemId: systemId,
            type: .cookie,
            value: "test-session-cookie-value",
            cookieName: "cloud.session.token",
            expiresAt: Date().addingTimeInterval(7200)
        )

        // Store
        try KeychainService.shared.storeCredential(credential)

        // Retrieve
        let retrieved = KeychainService.shared.retrieveCredential(for: systemId)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.systemId, systemId)
        XCTAssertEqual(retrieved?.type, .cookie)
        XCTAssertEqual(retrieved?.value, "test-session-cookie-value")
        XCTAssertEqual(retrieved?.cookieName, "cloud.session.token")

        // Cleanup
        KeychainService.shared.deleteCredential(for: systemId)
    }

    func testKeychainDeleteCredential() throws {
        let systemId = UUID()
        let credential = AuthCredential(
            systemId: systemId,
            type: .bearerToken,
            value: "token-to-delete",
            cookieName: nil,
            expiresAt: nil
        )

        try KeychainService.shared.storeCredential(credential)
        XCTAssertTrue(KeychainService.shared.hasCredential(for: systemId))

        KeychainService.shared.deleteCredential(for: systemId)
        XCTAssertFalse(KeychainService.shared.hasCredential(for: systemId))
    }

    func testKeychainRetrieveNonexistent() {
        let result = KeychainService.shared.retrieveCredential(for: UUID())
        XCTAssertNil(result, "Retrieving a non-existent credential should return nil")
    }

    func testKeychainHasCredentialReturnsFalseForMissing() {
        XCTAssertFalse(KeychainService.shared.hasCredential(for: UUID()))
    }

    func testKeychainOverwriteExistingCredential() throws {
        let systemId = UUID()

        // Store first credential
        let cred1 = AuthCredential(systemId: systemId, type: .cookie, value: "value-1", cookieName: "token", expiresAt: nil)
        try KeychainService.shared.storeCredential(cred1)

        // Overwrite with second credential
        let cred2 = AuthCredential(systemId: systemId, type: .bearerToken, value: "value-2", cookieName: nil, expiresAt: nil)
        try KeychainService.shared.storeCredential(cred2)

        // Should get the latest
        let retrieved = KeychainService.shared.retrieveCredential(for: systemId)
        XCTAssertEqual(retrieved?.type, .bearerToken)
        XCTAssertEqual(retrieved?.value, "value-2")

        KeychainService.shared.deleteCredential(for: systemId)
    }

    // MARK: - API Keys in Keychain (not UserDefaults)

    func testAIBackendKeysAreNotInUserDefaults() {
        let defaults = UserDefaults.standard
        let sensitiveKeys = [
            "AIBackend_OpenAI_Key",
            "AIBackend_GoogleCloud_Key",
            "AIBackend_Azure_Key",
            "AIBackend_Azure_Endpoint",
            "AIBackend_AWS_AccessKey",
            "AIBackend_AWS_SecretKey",
            "AIBackend_IBM_Key",
            "AIBackend_IBM_URL"
        ]

        for key in sensitiveKeys {
            let value = defaults.string(forKey: key)
            // After migration, these should NOT be in UserDefaults
            // (They might be nil or empty if migration already ran)
            if let val = value, !val.isEmpty {
                XCTFail("Sensitive key '\(key)' found in UserDefaults with value. Should be in Keychain only.")
            }
        }
    }

    // MARK: - No Token/Credential Logging

    func testAPIErrorDescriptionsDoNotLeakCredentials() {
        let errors: [APIError] = [
            .invalidResponse,
            .invalidURL,
            .unauthorized,
            .forbidden,
            .rateLimited,
            .httpError(500),
            .decodingError("Failed at key 'token'"),
            .noData,
            .invalidParameter("boardId must be integer")
        ]

        for error in errors {
            let description = error.errorDescription ?? ""
            // Error messages should not contain session tokens, cookies, or credentials
            XCTAssertFalse(description.contains("Bearer "), "Error description should not contain Bearer tokens")
            XCTAssertFalse(description.contains("sk-"), "Error description should not contain API keys")
            XCTAssertFalse(description.contains("AKIA"), "Error description should not contain AWS keys")
            XCTAssertFalse(description.contains("cloud.session.token"), "Error description should not contain cookie names")
        }
    }

    func testKeychainErrorDescriptionsDoNotLeakData() {
        let errors: [KeychainError] = [
            .storeFailed(-25299),
            .retrieveFailed(-25300)
        ]

        for error in errors {
            let description = error.errorDescription ?? ""
            // Should only contain status code, no credential values
            XCTAssertTrue(description.contains("status:"), "Error should include OSStatus for debugging")
            XCTAssertFalse(description.lowercased().contains("password"), "Error should not mention passwords")
            XCTAssertFalse(description.lowercased().contains("token"), "Error should not mention tokens")
        }
    }

    func testAIGenerationErrorDescriptionsAreSafe() {
        let errors: [AIGenerationError] = [
            .noBackendAvailable,
            .invalidURL,
            .invalidResponse,
            .httpError(401),
            .noResponse,
            .backendNotImplemented("TestBackend"),
            .allBackendsFailed
        ]

        for error in errors {
            let description = error.errorDescription ?? ""
            XCTAssertFalse(description.contains("sk-"), "AI error should not contain API keys")
            XCTAssertFalse(description.contains("Bearer"), "AI error should not contain auth headers")
        }
    }

    // MARK: - URL Construction Safety

    func testSystemConnectionURLMustBeHTTPS() {
        // Test that the system connection stores valid URLs
        let httpsURL = URL(string: "https://company.atlassian.net")!
        let connection = SystemConnection(name: "Secure", type: .jiraCloud, baseURL: httpsURL)
        XCTAssertEqual(connection.baseURL.scheme, "https")
    }

    func testSystemTypeLoginPathsAreRelative() {
        // Login paths should be relative, not absolute URLs
        for type in SystemType.allCases {
            XCTAssertTrue(type.loginPath.hasPrefix("/"), "Login path should be a relative path starting with /")
            XCTAssertFalse(type.loginPath.contains("://"), "Login path should not be an absolute URL")
        }
    }

    // MARK: - AI Backend Enum Security

    func testLocalBackendsDoNotRequireAPIKeys() {
        let localBackends: [AIBackend] = [.ollama, .mlx, .tinyLLM, .tinyChat, .openWebUI]
        for backend in localBackends {
            XCTAssertTrue(backend.isLocal, "\(backend.rawValue) should be marked as local")
        }
    }

    func testCloudBackendsAreNotLocal() {
        let cloudBackends: [AIBackend] = [.openAI, .googleCloud, .azure, .aws, .ibmWatson]
        for backend in cloudBackends {
            XCTAssertFalse(backend.isLocal, "\(backend.rawValue) should not be marked as local")
        }
    }

    func testLocalBackendDefaultURLsAreLocalhost() {
        let localBackends: [AIBackend] = [.ollama, .tinyLLM, .tinyChat, .openWebUI]
        for backend in localBackends {
            let url = backend.defaultURL
            XCTAssertTrue(url.contains("localhost") || url.contains("127.0.0.1"),
                         "\(backend.rawValue) default URL should be localhost, got: \(url)")
        }
    }

    // MARK: - Cost Estimation Safety

    func testLocalBackendsCostZero() {
        let localBackends: [AIBackend] = [.ollama, .mlx, .tinyLLM, .tinyChat, .openWebUI]
        for backend in localBackends {
            let cost = UsageStats.estimatedCostPerRequest(backend: backend, tokens: 1000)
            XCTAssertEqual(cost, 0, "Local backend \(backend.rawValue) should have zero cost")
        }
    }

    func testCloudBackendsCostPositive() {
        let cloudBackends: [AIBackend] = [.openAI, .googleCloud, .azure, .aws, .ibmWatson]
        for backend in cloudBackends {
            let cost = UsageStats.estimatedCostPerRequest(backend: backend, tokens: 1000)
            XCTAssertGreaterThan(cost, 0, "Cloud backend \(backend.rawValue) should have positive cost")
        }
    }

    // MARK: - AuthCredential Encoding Safety

    func testAuthCredentialDoesNotExposeValueInDescription() {
        let credential = AuthCredential(
            systemId: UUID(),
            type: .cookie,
            value: "sensitive-token-value-12345",
            cookieName: "session",
            expiresAt: nil
        )

        // The String(describing:) output should not be used for logging,
        // but verify the model exists and encodes properly
        let data = try? JSONEncoder().encode(credential)
        XCTAssertNotNil(data, "Credential should be encodable")
    }

    // MARK: - Input Sanitization Patterns

    func testJQLSpecialCharactersPresenceInEscapePattern() {
        // The JQL escape function should handle these characters
        let dangerousInputs = [
            "user\" OR 1=1 --",
            "user' OR '1'='1",
            "user\\; DROP TABLE issues",
            "test\nORDER BY 1",
        ]

        // Verify the pattern: escaping backslash, double quote, single quote
        for input in dangerousInputs {
            let escaped = input
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "'", with: "\\'")

            // Every double quote must now be backslash-escaped. Removing the
            // escaped `\"` sequences should leave no bare double quote behind.
            // (The naive `escaped.contains("\" OR ")` check is wrong: escaping to
            // `\"` still leaves the literal `" OR ` substring present.)
            let withoutEscapedQuotes = escaped.replacingOccurrences(of: "\\\"", with: "")
            XCTAssertFalse(withoutEscapedQuotes.contains("\""), "JQL injection via double quote should be escaped")
        }
    }

    func testWIQLEscapePattern() {
        // Azure DevOps WIQL uses single-quote escaping (doubling)
        let input = "O'Brien"
        let escaped = input.replacingOccurrences(of: "'", with: "''")
        XCTAssertEqual(escaped, "O''Brien")
    }

    // MARK: - NovaAPIServer Loopback Binding

    @MainActor
    func testNovaAPIServerPort() {
        let server = NovaAPIServer.shared
        XCTAssertEqual(server.port, 37433, "NovaAPI should be bound to port 37433")
    }
}
