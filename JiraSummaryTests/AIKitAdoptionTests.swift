//
//  AIKitAdoptionTests.swift
//  JiraSummaryTests
//
//  JiraSummary's contract with NovaAIKit, grouped in the 7 test categories (security, performance, retry, unit,
//  integration, functional, frame/UI-state). In-memory settings and keys, a stub URLProtocol: nothing touches the
//  real Keychain or network. All people, systems and tickets here are synthetic.
//

import XCTest
import SwiftUI
import NovaAIKit
@testable import JiraSummary

// MARK: - Support

/// Answers every request from `handler`; records the requests. Default: refuse (connection failed).
final class AIStubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply { var status: Int; var body: String }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: ((URLRequest, Int) -> Reply?)?
    nonisolated(unsafe) private static var seen: [URLRequest] = []
    nonisolated(unsafe) private static var bodies: [String] = []

    static func reset(_ h: ((URLRequest, Int) -> Reply?)? = nil) {
        lock.lock(); handler = h; seen = []; bodies = []; lock.unlock()
    }
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return seen }
    static var requestBodies: [String] { lock.lock(); defer { lock.unlock() }; return bodies }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
            stream.close()
        }
        Self.lock.lock()
        Self.seen.append(request)
        Self.bodies.append(String(decoding: body, as: UTF8.self))
        let index = Self.seen.count
        let h = Self.handler
        Self.lock.unlock()
        guard let reply = h?(request, index) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// An Ollama /api/chat reply.
    static func ollama(_ text: String) -> Reply {
        let obj: [String: Any] = ["message": ["role": "assistant", "content": text], "done": true]
        return Reply(status: 200, body: String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self))
    }
}

@MainActor
private func makeAI(_ settings: NovaAISettings = NovaAISettings(backend: .ollama),
                    keys: NovaAIMemoryKeyStore = NovaAIMemoryKeyStore()) -> NovaAI {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [AIStubProtocol.self]
    return NovaAI(configuration: AppAI.configuration, storage: NovaAIMemoryStorage(settings), keyStore: keys,
                  session: URLSession(configuration: cfg), sleep: { _ in })
}

/// A synthetic person with activity.
private func sampleSummary(tickets: Int = 6) -> PersonSummary {
    var s = PersonSummary(personId: UUID(), systemId: UUID(), personName: "Test Person",
                          systemName: "Example Tracker", period: .weekly)
    s.totalTickets = tickets
    s.ticketsCompleted = tickets > 0 ? 3 : 0
    s.ticketsInProgress = tickets > 0 ? 2 : 0
    s.ticketsBlocked = tickets > 0 ? 1 : 0
    s.ticketsCreated = tickets > 0 ? 4 : 0
    if tickets > 0 {
        s.sprintName = "Sprint 7"
        s.committedPoints = 13
        s.completedPoints = 8
        var t = TicketActivity(systemId: s.systemId, personId: s.personId, ticketKey: "DEMO-1",
                               title: "Synthetic task", currentStatus: "Done")
        t.updatedDate = Date()
        s.recentTickets = [t]
    }
    return s
}

private let goodReply = "Test Person completed 3 of 6 tickets this week, with 2 in progress and 1 blocked. "
    + "Sprint 7 is at 8 of 13 points."

private func suite() -> UserDefaults {
    let name = "JiraSummaryTests.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

// MARK: - Security

final class AIKitSecurityTests: XCTestCase {
    func testKeychainServiceNames() {
        let c = AppAI.configuration
        XCTAssertEqual(c.appID, "jirasummary")
        XCTAssertEqual(c.keychainService(for: .openRouter), "com.jkoch.jirasummary.openrouter")
        XCTAssertEqual(c.keychainService(for: .openAI), "com.jkoch.jirasummary.openai")
    }

    @MainActor
    func testLegacyKeychainItemsMigrateAndObsoleteOnesAreDeleted() {
        let legacy = AppAI.legacyKeychainService
        let keys = NovaAIMemoryKeyStore([:])
        _ = keys.write("test-openai-value", service: legacy, account: "AIBackend_OpenAI_Key")
        _ = keys.write("test-google-value", service: legacy, account: "AIBackend_GoogleCloud_Key")
        _ = keys.write("test-aws-value", service: legacy, account: "AIBackend_AWS_SecretKey")
        _ = keys.write("test-openrouter-value", service: "com.jkoch.aistudio.openrouter", account: "apiKey")
        let ai = makeAI(keys: keys)
        AppAI.migrateLegacy(ai, defaults: suite())

        XCTAssertTrue(ai.hasAPIKey(for: .openAI))
        XCTAssertTrue(ai.hasAPIKey(for: .openRouter))
        XCTAssertNil(keys.read(service: legacy, account: "AIBackend_OpenAI_Key"), "old OpenAI item removed")
        XCTAssertNil(keys.read(service: legacy, account: "AIBackend_GoogleCloud_Key"), "removed backend secret deleted")
        XCTAssertNil(keys.read(service: legacy, account: "AIBackend_AWS_SecretKey"), "removed backend secret deleted")
        XCTAssertNotNil(keys.read(service: "com.jkoch.aistudio.openrouter", account: "apiKey"), "shared item kept")
    }

    @MainActor
    func testPlaintextDefaultsKeysLeaveUserDefaults() {
        let d = suite()
        d.set("test-openai-value", forKey: "AIBackend_OpenAI_Key")
        d.set("test-azure-value", forKey: "AIBackend_Azure_Key")
        let ai = makeAI()
        AppAI.migrateLegacy(ai, defaults: d)
        XCTAssertNil(d.object(forKey: "AIBackend_OpenAI_Key"))
        XCTAssertNil(d.object(forKey: "AIBackend_Azure_Key"))
        XCTAssertTrue(ai.hasAPIKey(for: .openAI))
    }

    @MainActor
    func testKeyNeverSentOverPlainHTTP() async {
        AIStubProtocol.reset { _, _ in AIStubProtocol.ollama(goodReply) }
        var s = NovaAISettings(backend: .openAI)
        s.setURL("http://example.invalid/v1", for: .openAI)
        let ai = makeAI(s)
        _ = ai.setAPIKey("test-openai-value", for: .openAI)
        let r = await AISummaryService.summarize(sampleSummary(), ai: ai)
        XCTAssertFalse(r.isAI)
        XCTAssertTrue(AIStubProtocol.requests.isEmpty, "nothing may leave with a key over http")
    }

    func testNoLegacyAIClientInSources() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("JiraSummary")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
                .replacingOccurrences(of: "migrateFromLegacyAIBackendManager", with: "")
            for banned in ["AIBackendManager", "OPENAI_API_KEY", "OpenRouterProvider", "ModelRegistry", "EthicalAIGuardian"] {
                XCTAssertFalse(text.contains(banned), "\(f.lastPathComponent) still references \(banned)")
            }
        }
    }
}

// MARK: - Performance

final class AIKitPerformanceTests: XCTestCase {
    func testBuiltInSummaryIsFast() {
        let s = sampleSummary()
        measure {
            for _ in 0..<2000 { _ = AISummaryService.fallbackSummary(for: s) }
        }
    }

    @MainActor
    func testOfflineFallbackDoesNotHang() async {
        AIStubProtocol.reset()                      // every request refused
        let ai = makeAI(NovaAISettings(backend: .auto))
        let start = Date()
        let r = await AISummaryService.summarize(sampleSummary(), ai: ai)
        XCTAssertFalse(r.isAI)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
}

// MARK: - Retry

final class AIKitRetryTests: XCTestCase {
    @MainActor
    func testTransientServerErrorIsRetried() async {
        AIStubProtocol.reset { _, n in n == 1 ? .init(status: 503, body: "{}") : AIStubProtocol.ollama(goodReply) }
        let r = await AISummaryService.summarize(sampleSummary(), ai: makeAI())
        XCTAssertTrue(r.isAI)
        XCTAssertEqual(AIStubProtocol.requests.count, 2)
    }

    @MainActor
    func testRejectedReplyIsAskedAgainOnce() async {
        let invented = "Test Person closed 42 tickets this week and finished 99 points of work in total."
        AIStubProtocol.reset { _, n in AIStubProtocol.ollama(n == 1 ? invented : goodReply) }
        let r = await AISummaryService.summarize(sampleSummary(), ai: makeAI())
        XCTAssertTrue(r.isAI)
        XCTAssertEqual(r.value, goodReply)
        XCTAssertEqual(AIStubProtocol.requests.count, 2)
        XCTAssertTrue(AIStubProtocol.requestBodies[1].contains("rejected"), "second ask carries the complaint")
    }

    @MainActor
    func testRejectedTwiceFallsBack() async {
        AIStubProtocol.reset { _, _ in AIStubProtocol.ollama("Test Person closed 42 tickets and 99 points this week.") }
        let s = sampleSummary()
        let r = await AISummaryService.summarize(s, ai: makeAI())
        XCTAssertFalse(r.isAI)
        XCTAssertEqual(r.value, AISummaryService.fallbackSummary(for: s))
    }
}

// MARK: - Unit

final class AIKitUnitTests: XCTestCase {
    func testFallbackSummaryUsesTheCounts() {
        let text = AISummaryService.fallbackSummary(for: sampleSummary())
        XCTAssertEqual(text, "Test Person touched 6 tickets in Example Tracker this week: 3 completed, 2 in progress, "
            + "1 blocked, 4 created. Sprint 7: 8 of 13 points completed. Most recent: DEMO-1 (Done).")
    }

    func testFallbackSummaryWithNoActivity() {
        XCTAssertEqual(AISummaryService.fallbackSummary(for: sampleSummary(tickets: 0)),
                       "Test Person had no tracked ticket activity in Example Tracker this week.")
    }

    func testFallbackIsGroundedInPrompt() {
        let s = sampleSummary()
        XCTAssertTrue(NovaAIText.grounded(AISummaryService.fallbackSummary(for: s), in: AISummaryService.buildPrompt(from: s)))
    }

    func testValidatorRejectsNonsense() {
        let v = AISummaryService.validator(source: AISummaryService.buildPrompt(from: sampleSummary()))
        XCTAssertThrowsError(try v("   \n "), "empty")
        XCTAssertThrowsError(try v("ok"), "too short")
        XCTAssertThrowsError(try v("Test Person closed 42 tickets this week."), "invented number")
        XCTAssertEqual(try v(goodReply), goodReply)
    }

    func testValidatorCapsLength() throws {
        let v = AISummaryService.validator(source: "")
        let long = String(repeating: "Steady progress on the synthetic work. ", count: 60)
        XCTAssertLessThanOrEqual(try v(long).count, AISummaryService.maxSummaryLength + 1)
    }

    func testPeriodPhrases() {
        XCTAssertEqual(SummaryPeriod.allCases.map(AISummaryService.periodPhrase),
                       ["today", "this week", "this sprint", "this month"])
    }
}

// MARK: - Integration

final class AIKitIntegrationTests: XCTestCase {
    @MainActor
    func testAISummaryFillsCardWithSourceLabel() async {
        AIStubProtocol.reset { _, _ in AIStubProtocol.ollama(goodReply) }
        let out = await AISummaryService.annotate(sampleSummary(), ai: makeAI())
        XCTAssertEqual(out.aiSummary, goodReply)
        XCTAssertEqual(out.aiSummarySource?.hasPrefix("AI · Ollama"), true)
        let req = AIStubProtocol.requests.first
        XCTAssertEqual(req?.url?.path, "/api/chat")
        let body = AIStubProtocol.requestBodies.first ?? ""
        XCTAssertTrue(body.contains("Test Person") && body.contains("engineering manager"))
    }

    @MainActor
    func testLegacySettingsMigrate() {
        let d = suite()
        d.set("Ollama", forKey: "AIBackend_Active")
        d.set("http://ollama.example.invalid:11434", forKey: "AIBackend_OllamaURL")
        d.set("synthetic-model:1b", forKey: "AIBackend_OllamaModel")
        d.set("http://gateway.example.invalid:18792", forKey: "AIBackend_NovaGatewayURL")
        d.set("vendor/synthetic-model", forKey: "AIBackend_OpenRouterModel")
        d.set(0.4, forKey: "AIBackend_Temperature")
        d.set(true, forKey: "AIBackend_UseNovaGateway")
        let ai = makeAI(NovaAISettings())
        AppAI.migrateLegacy(ai, defaults: d)
        XCTAssertEqual(ai.settings.backend, .ollama)
        XCTAssertEqual(ai.settings.url(for: .ollama), "http://ollama.example.invalid:11434")
        XCTAssertEqual(ai.settings.model(for: .ollama), "synthetic-model:1b")
        XCTAssertEqual(ai.settings.url(for: .novaGateway), "http://gateway.example.invalid:18792")
        XCTAssertEqual(ai.settings.model(for: .openRouter), "vendor/synthetic-model")
        for key in AppAI.obsoleteDefaultsKeys { XCTAssertNil(d.object(forKey: key), key) }
    }

    @MainActor
    func testMigrationIsIdempotent() {
        let d = suite()
        d.set("Ollama", forKey: "AIBackend_Active")
        let ai = makeAI(NovaAISettings())
        AppAI.migrateLegacy(ai, defaults: d)
        ai.settings.backend = .tinyLLM                     // user changes it afterwards
        AppAI.migrateLegacy(ai, defaults: d)
        XCTAssertEqual(ai.settings.backend, .tinyLLM, "second launch must not re-import")
    }
}

// MARK: - Functional

final class AIKitFunctionalTests: XCTestCase {
    @MainActor
    func testEveryFeatureWorksWithAIOff() async {
        AIStubProtocol.reset { _, _ in AIStubProtocol.ollama(goodReply) }
        let s = sampleSummary()
        let out = await AISummaryService.annotate(s, ai: makeAI(NovaAISettings(enabled: false)))
        XCTAssertEqual(out.aiSummary, AISummaryService.fallbackSummary(for: s))
        XCTAssertEqual(out.aiSummarySource, "Built-in")
        XCTAssertTrue(AIStubProtocol.requests.isEmpty, "AI off: nothing sent")
    }

    @MainActor
    func testEveryFeatureFallsBackWhenOffline() async {
        AIStubProtocol.reset()
        let s = sampleSummary()
        let r = await AISummaryService.summarize(s, ai: makeAI(NovaAISettings(backend: .auto)))
        XCTAssertFalse(r.isAI)
        XCTAssertEqual(r.value, AISummaryService.fallbackSummary(for: s))
    }

    @MainActor
    func testNoActivityNeedsNoAI() async {
        AIStubProtocol.reset { _, _ in AIStubProtocol.ollama(goodReply) }
        let r = await AISummaryService.summarize(sampleSummary(tickets: 0), ai: makeAI())
        XCTAssertFalse(r.isAI)
        XCTAssertTrue(AIStubProtocol.requests.isEmpty)
    }

    @MainActor
    func testCloudBackendWithoutKeySendsNothing() async {
        AIStubProtocol.reset { _, _ in AIStubProtocol.ollama(goodReply) }
        let r = await AISummaryService.summarize(sampleSummary(), ai: makeAI(NovaAISettings(backend: .openRouter)))
        XCTAssertFalse(r.isAI)
        XCTAssertTrue(AIStubProtocol.requests.isEmpty)
    }
}

// MARK: - Frame / UI state

final class AIKitFrameTests: XCTestCase {
    @MainActor
    func testStatusReflectsOnOff() {
        let ai = makeAI(NovaAISettings(enabled: false))
        XCTAssertEqual(ai.status.state, .off)
        ai.settings.enabled = true
        XCTAssertEqual(ai.status.state, .unknown)
        XCTAssertEqual(NovaAIStatusIndicator.color(.online), .green)
        XCTAssertEqual(NovaAIStatusIndicator.color(.offline), .orange)
    }

    @MainActor
    func testStatusGoesOfflineThenOnline() async {
        AIStubProtocol.reset()
        let ai = makeAI()
        _ = await AISummaryService.summarize(sampleSummary(), ai: ai)
        XCTAssertEqual(ai.status.state, .offline)
        AIStubProtocol.reset { _, _ in AIStubProtocol.ollama(goodReply) }
        ai.health.reset()
        _ = await AISummaryService.summarize(sampleSummary(), ai: ai)
        XCTAssertEqual(ai.status.state, .online)
        XCTAssertEqual(ai.status.lastSource?.isAI, true)
    }

    @MainActor
    func testSettingsAndCardsRender() {
        for view in [AnyView(SummaryCardView(summary: sampleSummary())),
                     AnyView(NovaAISettingsView(ai: makeAI(), footer: "test"))] {
            let host = NSHostingView(rootView: view.frame(width: 600, height: 800))
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.width, 0)
        }
    }

    func testSourceLabelPersistsAndOldDataStillDecodes() throws {
        var s = sampleSummary()
        s.aiSummary = "Synthetic summary."
        s.aiSummarySource = "Built-in"
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(PersonSummary.self, from: data).aiSummarySource, "Built-in")

        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "aiSummarySource")
        let old = try JSONSerialization.data(withJSONObject: obj)
        XCTAssertNil(try JSONDecoder().decode(PersonSummary.self, from: old).aiSummarySource)
    }
}
