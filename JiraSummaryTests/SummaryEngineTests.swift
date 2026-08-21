//
//  SummaryEngineTests.swift
//  JiraSummaryTests
//
//  Functional tests for SummaryEngine data aggregation
//  Created by Jordan Koch on 2026-05-01.
//

import XCTest
@testable import JiraSummary

final class SummaryEngineTests: XCTestCase {

    let engine = SummaryEngine.shared

    // MARK: - Helpers

    private func makeActivity(
        systemId: UUID,
        personId: UUID,
        key: String,
        status: String,
        storyPoints: Double? = nil,
        createdDaysAgo: Int = 0,
        updatedDaysAgo: Int = 0,
        sprintName: String? = nil
    ) -> TicketActivity {
        var activity = TicketActivity(
            systemId: systemId,
            personId: personId,
            ticketKey: key,
            title: "Ticket \(key)",
            currentStatus: status
        )
        activity.storyPoints = storyPoints
        activity.sprintName = sprintName
        activity.createdDate = Calendar.current.date(byAdding: .day, value: -createdDaysAgo, to: Date()) ?? Date()
        activity.updatedDate = Calendar.current.date(byAdding: .day, value: -updatedDaysAgo, to: Date()) ?? Date()
        return activity
    }

    private func makePerson(systemId: UUID) -> TrackedPerson {
        TrackedPerson(systemId: systemId, displayName: "Test Person", systemUserId: "test-user")
    }

    // MARK: - Basic Summary Generation

    func testGenerateSummaryWithNoActivities() {
        let systemId = UUID()
        let person = makePerson(systemId: systemId)

        let summary = engine.generateSummary(
            for: person,
            systemName: "Test System",
            activities: [],
            sprints: [],
            period: .weekly
        )

        XCTAssertEqual(summary.personId, person.id)
        XCTAssertEqual(summary.systemId, person.systemId)
        XCTAssertEqual(summary.personName, "Test Person")
        XCTAssertEqual(summary.systemName, "Test System")
        XCTAssertEqual(summary.period, .weekly)
        XCTAssertEqual(summary.totalTickets, 0)
        XCTAssertEqual(summary.ticketsCompleted, 0)
        XCTAssertEqual(summary.ticketsInProgress, 0)
        XCTAssertEqual(summary.ticketsBlocked, 0)
        XCTAssertEqual(summary.ticketsCreated, 0)
    }

    func testGenerateSummaryCountsStatuses() {
        let systemId = UUID()
        let person = makePerson(systemId: systemId)

        let activities = [
            makeActivity(systemId: systemId, personId: person.id, key: "A-1", status: "Done", updatedDaysAgo: 1),
            makeActivity(systemId: systemId, personId: person.id, key: "A-2", status: "Done", updatedDaysAgo: 2),
            makeActivity(systemId: systemId, personId: person.id, key: "A-3", status: "In Progress", updatedDaysAgo: 1),
            makeActivity(systemId: systemId, personId: person.id, key: "A-4", status: "Blocked", updatedDaysAgo: 0),
            makeActivity(systemId: systemId, personId: person.id, key: "A-5", status: "To Do", updatedDaysAgo: 3),
        ]

        let summary = engine.generateSummary(
            for: person,
            systemName: "Jira",
            activities: activities,
            sprints: [],
            period: .weekly
        )

        XCTAssertEqual(summary.totalTickets, 5)
        XCTAssertEqual(summary.ticketsCompleted, 2, "Done status should count as completed")
        XCTAssertEqual(summary.ticketsInProgress, 1, "In Progress should count")
        XCTAssertEqual(summary.ticketsBlocked, 1, "Blocked should count")
    }

    func testGenerateSummaryRecognizesDoneStatuses() {
        let systemId = UUID()
        let person = makePerson(systemId: systemId)

        let doneStatuses = ["done", "closed", "resolved", "completed"]
        let activities = doneStatuses.enumerated().map { index, status in
            makeActivity(systemId: systemId, personId: person.id, key: "D-\(index)", status: status, updatedDaysAgo: 1)
        }

        let summary = engine.generateSummary(
            for: person,
            systemName: "Test",
            activities: activities,
            sprints: [],
            period: .weekly
        )

        XCTAssertEqual(summary.ticketsCompleted, 4, "All done variants should be recognized")
    }

    func testGenerateSummaryRecognizesProgressStatuses() {
        let systemId = UUID()
        let person = makePerson(systemId: systemId)

        let progressStatuses = ["in progress", "active", "doing", "in review", "code review", "testing"]
        let activities = progressStatuses.enumerated().map { index, status in
            makeActivity(systemId: systemId, personId: person.id, key: "P-\(index)", status: status, updatedDaysAgo: 1)
        }

        let summary = engine.generateSummary(
            for: person,
            systemName: "Test",
            activities: activities,
            sprints: [],
            period: .weekly
        )

        XCTAssertEqual(summary.ticketsInProgress, 6, "All progress variants should be recognized")
    }

    // MARK: - Period Filtering

    func testFilterByDailyPeriod() {
        let systemId = UUID()
        let person = makePerson(systemId: systemId)

        let activities = [
            makeActivity(systemId: systemId, personId: person.id, key: "T-1", status: "Open", updatedDaysAgo: 0),
            makeActivity(systemId: systemId, personId: person.id, key: "T-2", status: "Open", updatedDaysAgo: 2), // outside daily
        ]

        let summary = engine.generateSummary(
            for: person,
            systemName: "Test",
            activities: activities,
            sprints: [],
            period: .daily
        )

        XCTAssertEqual(summary.totalTickets, 1, "Daily period should only include today's tickets")
    }

    func testFilterByMonthlyPeriod() {
        let systemId = UUID()
        let person = makePerson(systemId: systemId)

        let activities = [
            makeActivity(systemId: systemId, personId: person.id, key: "M-1", status: "Done", updatedDaysAgo: 5),
            makeActivity(systemId: systemId, personId: person.id, key: "M-2", status: "Done", updatedDaysAgo: 15),
            makeActivity(systemId: systemId, personId: person.id, key: "M-3", status: "Done", updatedDaysAgo: 25),
            makeActivity(systemId: systemId, personId: person.id, key: "M-4", status: "Done", updatedDaysAgo: 35), // outside monthly
        ]

        let summary = engine.generateSummary(
            for: person,
            systemName: "Test",
            activities: activities,
            sprints: [],
            period: .monthly
        )

        XCTAssertEqual(summary.totalTickets, 3, "Monthly should include last 30 days only")
    }

    // MARK: - Story Points / Velocity

    func testStoryPointsCalculationWithoutSprints() {
        let systemId = UUID()
        let person = makePerson(systemId: systemId)

        let activities = [
            makeActivity(systemId: systemId, personId: person.id, key: "SP-1", status: "Done", storyPoints: 3, updatedDaysAgo: 1),
            makeActivity(systemId: systemId, personId: person.id, key: "SP-2", status: "Done", storyPoints: 5, updatedDaysAgo: 2),
            makeActivity(systemId: systemId, personId: person.id, key: "SP-3", status: "In Progress", storyPoints: 8, updatedDaysAgo: 1),
            makeActivity(systemId: systemId, personId: person.id, key: "SP-4", status: "Open", storyPoints: nil, updatedDaysAgo: 3),
        ]

        let summary = engine.generateSummary(
            for: person,
            systemName: "Test",
            activities: activities,
            sprints: [],
            period: .weekly
        )

        // Without active sprint, committedPoints = sum of all story points
        XCTAssertEqual(summary.committedPoints, 16, accuracy: 0.01) // 3 + 5 + 8
        // completedPoints = sum of done tickets' story points
        XCTAssertEqual(summary.completedPoints, 8, accuracy: 0.01)  // 3 + 5
    }

    func testSprintVelocityFromActiveSprintBreakdown() {
        let systemId = UUID()
        let person = makePerson(systemId: systemId)

        var breakdown = PersonSprintBreakdown(personId: person.id, personName: "Test Person")
        breakdown.committedPoints = 20
        breakdown.completedPoints = 15

        var sprint = SprintData(systemId: systemId, sprintName: "Sprint 5", state: .active)
        sprint.personBreakdowns = [breakdown]

        let activities = [
            makeActivity(systemId: systemId, personId: person.id, key: "S-1", status: "Done", storyPoints: 5, updatedDaysAgo: 1),
        ]

        let summary = engine.generateSummary(
            for: person,
            systemName: "Test",
            activities: activities,
            sprints: [sprint],
            period: .weekly
        )

        XCTAssertEqual(summary.sprintName, "Sprint 5")
        XCTAssertEqual(summary.committedPoints, 20, "Should use sprint breakdown when available")
        XCTAssertEqual(summary.completedPoints, 15, "Should use sprint breakdown when available")
    }

    // MARK: - Recent Activity Limits

    func testRecentTicketsLimitedToTen() {
        let systemId = UUID()
        let person = makePerson(systemId: systemId)

        let activities = (0..<20).map { i in
            makeActivity(systemId: systemId, personId: person.id, key: "R-\(i)", status: "Open", updatedDaysAgo: 0)
        }

        let summary = engine.generateSummary(
            for: person,
            systemName: "Test",
            activities: activities,
            sprints: [],
            period: .weekly
        )

        XCTAssertEqual(summary.recentTickets.count, 10, "Should be limited to 10 most recent tickets")
    }

    func testRecentTransitionsLimitedToTwenty() {
        let systemId = UUID()
        let person = makePerson(systemId: systemId)

        let activities = (0..<15).map { i -> TicketActivity in
            var activity = makeActivity(systemId: systemId, personId: person.id, key: "TR-\(i)", status: "Done", updatedDaysAgo: 0)
            activity.transitions = [
                StatusTransition(fromStatus: "Open", toStatus: "In Progress", transitionDate: Date(), author: "Dev"),
                StatusTransition(fromStatus: "In Progress", toStatus: "Done", transitionDate: Date(), author: "Dev")
            ]
            return activity
        }

        let summary = engine.generateSummary(
            for: person,
            systemName: "Test",
            activities: activities,
            sprints: [],
            period: .weekly
        )

        XCTAssertEqual(summary.recentTransitions.count, 20, "Should be limited to 20 most recent transitions")
    }

    // MARK: - Tickets Created Count

    func testTicketsCreatedCountsOnlyWithinPeriod() {
        let systemId = UUID()
        let person = makePerson(systemId: systemId)

        let activities = [
            makeActivity(systemId: systemId, personId: person.id, key: "C-1", status: "Open", createdDaysAgo: 2, updatedDaysAgo: 1),
            makeActivity(systemId: systemId, personId: person.id, key: "C-2", status: "Open", createdDaysAgo: 10, updatedDaysAgo: 3),
        ]

        let summary = engine.generateSummary(
            for: person,
            systemName: "Test",
            activities: activities,
            sprints: [],
            period: .weekly
        )

        // C-1 was created 2 days ago (within the 7-day weekly window); C-2 was
        // created 10 days ago (outside it), so only C-1 counts.
        XCTAssertEqual(summary.ticketsCreated, 1, "Only the ticket created within the weekly range counts")
    }

    // MARK: - Case Insensitive Status Matching

    func testCaseInsensitiveStatusMatching() {
        let systemId = UUID()
        let person = makePerson(systemId: systemId)

        let activities = [
            makeActivity(systemId: systemId, personId: person.id, key: "CI-1", status: "DONE", updatedDaysAgo: 1),
            makeActivity(systemId: systemId, personId: person.id, key: "CI-2", status: "Done", updatedDaysAgo: 1),
            makeActivity(systemId: systemId, personId: person.id, key: "CI-3", status: "IN PROGRESS", updatedDaysAgo: 1),
            makeActivity(systemId: systemId, personId: person.id, key: "CI-4", status: "BLOCKED", updatedDaysAgo: 1),
        ]

        let summary = engine.generateSummary(
            for: person,
            systemName: "Test",
            activities: activities,
            sprints: [],
            period: .weekly
        )

        XCTAssertEqual(summary.ticketsCompleted, 2, "Status matching should be case-insensitive")
        XCTAssertEqual(summary.ticketsInProgress, 1)
        XCTAssertEqual(summary.ticketsBlocked, 1)
    }
}
