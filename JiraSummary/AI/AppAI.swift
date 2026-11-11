//
//  AppAI.swift
//  JiraSummary
//
//  The app's one AI object (NovaAIKit). Settings persist in UserDefaults (no secrets); keys live in the Keychain
//  under com.jkoch.jirasummary.<backend>.
//

import Foundation
import NovaAIKit

@MainActor
enum AppAI {
    static let appID = "jirasummary"
    static let appName = "JiraSummary"

    static let configuration = NovaAIConfiguration(appID: appID, appName: appName)

    static let shared: NovaAI = {
        let ai = NovaAI(configuration: configuration)
        AppAI.migrateLegacy(ai)
        return ai
    }()
}

extension AppAI {
    /// Keychain service the pre-NovaAIKit AI layer used. Its accounts were named after the old
    /// UserDefaults keys (`AIBackend_OpenAI_Key`, `AIBackend_GoogleCloud_Key`, ...).
    static let legacyKeychainService = "com.jordankoch.JiraSummary"

    /// Accounts in `legacyKeychainService` that held secrets of the removed Google/Azure/AWS/IBM backends.
    static let obsoleteLegacyAccounts = [
        "AIBackend_GoogleCloud_Key", "AIBackend_Azure_Key", "AIBackend_Azure_Endpoint",
        "AIBackend_AWS_AccessKey", "AIBackend_AWS_SecretKey", "AIBackend_IBM_Key", "AIBackend_IBM_URL",
    ] + NovaAIKeys.obsoleteLegacyAccounts

    /// JiraSummary-only UserDefaults keys of the old AI layer (load balancer / generation tuning). They have no
    /// NovaAIKit successor except the OpenRouter model, which is imported before they are removed.
    static let obsoleteDefaultsKeys = [
        "AIBackend_OpenRouterModel", "AIBackend_Temperature", "AIBackend_MaxTokens", "AIBackend_UseAllLocalModels",
        "AIBackend_EnableAllFrontierModels", "AIBackend_UseNovaGateway", "AIBackend_KeychainMigrationComplete",
    ]

    /// One-time, idempotent migration of the old AI settings and keys. Never reads a key out except to copy it
    /// into the new Keychain item (done inside NovaAIKit), never logs one.
    static func migrateLegacy(_ ai: NovaAI, defaults: UserDefaults = .standard) {
        // Old AI-layer UserDefaults: URLs (incl. Nova Gateway), backend, Ollama model, on/off; plaintext
        // OpenAI key → Keychain; Google/Azure/AWS/IBM secrets and usage stats deleted.
        ai.migrateFromLegacyAIBackendManager(defaults: defaults)

        if let model = defaults.string(forKey: "AIBackend_OpenRouterModel"), !model.isEmpty,
           ai.settings.models[NovaAIBackend.openRouter.rawValue] == nil {
            ai.settings.setModel(model, for: .openRouter)
        }
        for key in obsoleteDefaultsKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
        }

        // Old Keychain items → com.jkoch.jirasummary.<backend>.
        ai.migrateLegacyKey(service: legacyKeychainService, account: "AIBackend_OpenAI_Key", to: .openAI, deleteLegacy: true)
        ai.migrateLegacyKey(service: legacyKeychainService, account: "openAIAPIKey", to: .openAI, deleteLegacy: true)
        // Shared with AIStudio: copy, keep the original.
        ai.migrateLegacyKey(service: "com.jkoch.aistudio.openrouter", account: "apiKey", to: .openRouter)
        // Secrets of the removed backends (deletes only).
        ai.keys.deleteObsoleteLegacyItems(service: legacyKeychainService, accounts: obsoleteLegacyAccounts)
    }
}
