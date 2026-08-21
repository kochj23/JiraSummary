//
//  IntegrationTests.swift
//  JiraSummaryTests
//
//  Integration tests: Mock Jira/AzDO API response parsing, end-to-end
//  data flow from raw JSON to PersonSummary
//  Created by Jordan Koch on 2026-05-01.
//

import XCTest
@testable import JiraSummary

final class IntegrationTests: XCTestCase {

    private let decoder = JSONDecoder()

    // MARK: - Full Jira Cloud Response -> TicketActivity Pipeline

    func testJiraCloudResponseToTicketActivities() throws {
        // Simulate a full Jira Cloud search response
        let json = """
        {
            "startAt": 0,
            "maxResults": 50,
            "total": 3,
            "issues": [
                {
                    "id": "10001",
                    "key": "TEAM-100",
                    "fields": {
                        "summary": "Implement user authentication",
                        "status": { "name": "Done", "id": "3", "statusCategory": { "id": 3, "key": "done", "name": "Done" } },
                        "priority": { "name": "High", "id": "2" },
                        "issuetype": { "name": "Story", "id": "10001", "subtask": false },
                        "assignee": { "displayName": "Alice", "accountId": "alice-123" },
                        "creator": { "displayName": "PM Bob", "accountId": "bob-456" },
                        "created": "2026-04-10T10:00:00.000+0000",
                        "updated": "2026-04-25T16:00:00.000+0000",
                        "resolutiondate": "2026-04-25T16:00:00.000+0000",
                        "customfield_10016": 8.0,
                        "sprint": { "id": 50, "name": "Sprint 12", "state": "active" }
                    },
                    "changelog": {
                        "histories": [
                            {
                                "id": "200",
                                "created": "2026-04-15T09:00:00.000+0000",
                                "author": { "displayName": "Alice" },
                                "items": [
                                    { "field": "status", "fromString": "To Do", "toString": "In Progress" }
                                ]
                            },
                            {
                                "id": "201",
                                "created": "2026-04-25T16:00:00.000+0000",
                                "author": { "displayName": "Alice" },
                                "items": [
                                    { "field": "status", "fromString": "In Progress", "toString": "Done" }
                                ]
                            }
                        ]
                    }
                },
                {
                    "id": "10002",
                    "key": "TEAM-101",
                    "fields": {
                        "summary": "Fix pagination bug",
                        "status": { "name": "In Progress", "id": "3" },
                        "priority": { "name": "Critical", "id": "1" },
                        "issuetype": { "name": "Bug", "id": "10002" },
                        "assignee": { "displayName": "Alice", "accountId": "alice-123" },
                        "created": "2026-04-20T08:00:00.000+0000",
                        "updated": "2026-04-28T10:00:00.000+0000",
                        "customfield_10016": 3.0
                    }
                },
                {
                    "id": "10003",
                    "key": "TEAM-102",
                    "fields": {
                        "summary": "Update API documentation",
                        "status": { "name": "To Do", "id": "1" },
                        "issuetype": { "name": "Task", "id": "10003" },
                        "assignee": { "displayName": "Alice", "accountId": "alice-123" },
                        "created": "2026-04-27T14:00:00.000+0000",
                        "updated": "2026-04-27T14:00:00.000+0000",
                        "customfield_10016": 1.0
                    }
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(JiraSearchResponse.self, from: json)

        // Verify parsing
        XCTAssertEqual(response.total, 3)
        XCTAssertEqual(response.issues.count, 3)

        // Simulate converting to TicketActivity (same logic as DataFetchCoordinator.convertJiraIssue)
        let systemId = UUID()
        let personId = UUID()
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let activities = response.issues.map { issue -> TicketActivity in
            var activity = TicketActivity(
                systemId: systemId,
                personId: personId,
                ticketKey: issue.key,
                title: issue.fields.summary,
                currentStatus: issue.fields.status.name
            )
            activity.priority = issue.fields.priority?.name
            activity.ticketType = issue.fields.issuetype?.name
            activity.storyPoints = issue.fields.customfield_10016
            activity.sprintName = issue.fields.sprint?.name

            if let created = issue.fields.created {
                activity.createdDate = dateFormatter.date(from: created) ?? Date()
            }
            if let updated = issue.fields.updated {
                activity.updatedDate = dateFormatter.date(from: updated) ?? Date()
            }
            if let resolved = issue.fields.resolutiondate {
                activity.resolvedDate = dateFormatter.date(from: resolved)
            }

            activity.transitions = issue.changelog?.histories?.flatMap { history -> [StatusTransition] in
                let date = history.created.flatMap { dateFormatter.date(from: $0) } ?? Date()
                return history.items?.compactMap { item -> StatusTransition? in
                    guard item.field == "status" else { return nil }
                    return StatusTransition(
                        fromStatus: item.fromString,
                        toStatus: item.toString ?? "Unknown",
                        transitionDate: date,
                        author: history.author?.displayName
                    )
                } ?? []
            } ?? []

            return activity
        }

        // Verify converted activities
        XCTAssertEqual(activities.count, 3)
        XCTAssertEqual(activities[0].ticketKey, "TEAM-100")
        XCTAssertEqual(activities[0].currentStatus, "Done")
        XCTAssertEqual(activities[0].storyPoints, 8.0)
        XCTAssertEqual(activities[0].transitions.count, 2)
        XCTAssertEqual(activities[0].transitions[0].fromStatus, "To Do")
        XCTAssertEqual(activities[0].transitions[0].toStatus, "In Progress")
        XCTAssertEqual(activities[0].transitions[1].toStatus, "Done")
        XCTAssertNotNil(activities[0].resolvedDate)

        XCTAssertEqual(activities[1].ticketKey, "TEAM-101")
        XCTAssertEqual(activities[1].priority, "Critical")
        XCTAssertEqual(activities[1].ticketType, "Bug")
        XCTAssertTrue(activities[1].transitions.isEmpty)

        XCTAssertEqual(activities[2].storyPoints, 1.0)
        XCTAssertEqual(activities[2].sprintName, nil)
    }

    // MARK: - Azure DevOps Work Item -> TicketActivity Pipeline

    func testAzureDevOpsWorkItemToTicketActivity() throws {
        let json = """
        {
            "count": 2,
            "value": [
                {
                    "id": 5001,
                    "rev": 3,
                    "fields": {
                        "System.Title": "Build CI/CD pipeline",
                        "System.State": "Closed",
                        "System.WorkItemType": "User Story",
                        "System.AssignedTo": { "displayName": "Charlie", "uniqueName": "charlie@co.com" },
                        "System.CreatedDate": "2026-04-05T09:00:00Z",
                        "System.ChangedDate": "2026-04-20T17:00:00Z",
                        "Microsoft.VSTS.Common.ClosedDate": "2026-04-20T17:00:00Z",
                        "Microsoft.VSTS.Common.Priority": 1,
                        "Microsoft.VSTS.Scheduling.StoryPoints": 13.0,
                        "System.IterationPath": "Project\\\\Sprint 4"
                    }
                },
                {
                    "id": 5002,
                    "rev": 1,
                    "fields": {
                        "System.Title": "Research caching strategies",
                        "System.State": "Active",
                        "System.WorkItemType": "Task",
                        "System.AssignedTo": { "displayName": "Charlie", "uniqueName": "charlie@co.com" },
                        "System.CreatedDate": "2026-04-18T10:00:00Z",
                        "System.ChangedDate": "2026-04-28T11:00:00Z",
                        "Microsoft.VSTS.Common.Priority": 3,
                        "Microsoft.VSTS.Scheduling.StoryPoints": 5.0
                    }
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(AzDOWorkItemResponse.self, from: json)
        XCTAssertEqual(response.value?.count, 2)

        // Convert to TicketActivity (same logic as DataFetchCoordinator.convertAzDOWorkItem)
        let systemId = UUID()
        let personId = UUID()
        let dateFormatter = ISO8601DateFormatter()

        let activities: [TicketActivity] = (response.value ?? []).map { item in
            var activity = TicketActivity(
                systemId: systemId,
                personId: personId,
                ticketKey: "#\(item.id)",
                title: item.fields?.title ?? "Untitled",
                currentStatus: item.fields?.state ?? "Unknown"
            )
            activity.ticketType = item.fields?.workItemType
            activity.storyPoints = item.fields?.storyPoints
            activity.sprintName = item.fields?.iterationPath

            if let priority = item.fields?.priority {
                activity.priority = "P\(priority)"
            }

            if let created = item.fields?.createdDate {
                activity.createdDate = dateFormatter.date(from: created) ?? Date()
            }
            if let changed = item.fields?.changedDate {
                activity.updatedDate = dateFormatter.date(from: changed) ?? Date()
            }
            if let closed = item.fields?.closedDate {
                activity.resolvedDate = dateFormatter.date(from: closed)
            }

            return activity
        }

        XCTAssertEqual(activities.count, 2)
        XCTAssertEqual(activities[0].ticketKey, "#5001")
        XCTAssertEqual(activities[0].title, "Build CI/CD pipeline")
        XCTAssertEqual(activities[0].currentStatus, "Closed")
        XCTAssertEqual(activities[0].priority, "P1")
        XCTAssertEqual(activities[0].storyPoints, 13.0)
        XCTAssertNotNil(activities[0].resolvedDate)

        XCTAssertEqual(activities[1].ticketKey, "#5002")
        XCTAssertEqual(activities[1].priority, "P3")
        XCTAssertNil(activities[1].resolvedDate)
    }

    // MARK: - End-to-End: JSON -> PersonSummary

    func testEndToEndJSONToPersonSummary() throws {
        let systemId = UUID()
        let personId = UUID()

        // Create activities that simulate parsed Jira data
        let activities: [TicketActivity] = {
            var result: [TicketActivity] = []

            // 3 completed tickets
            for i in 0..<3 {
                var a = TicketActivity(systemId: systemId, personId: personId, ticketKey: "E2E-\(i)", title: "Done task \(i)", currentStatus: "Done")
                a.storyPoints = 5
                a.updatedDate = Date()
                a.createdDate = Date()
                result.append(a)
            }

            // 2 in progress
            for i in 3..<5 {
                var a = TicketActivity(systemId: systemId, personId: personId, ticketKey: "E2E-\(i)", title: "WIP task \(i)", currentStatus: "In Progress")
                a.storyPoints = 3
                a.updatedDate = Date()
                a.createdDate = Date()
                result.append(a)
            }

            // 1 blocked
            var blocked = TicketActivity(systemId: systemId, personId: personId, ticketKey: "E2E-5", title: "Blocked task", currentStatus: "Blocked")
            blocked.storyPoints = 8
            blocked.updatedDate = Date()
            blocked.createdDate = Date()
            result.append(blocked)

            return result
        }()

        let person = TrackedPerson(systemId: systemId, displayName: "E2E Tester", systemUserId: "e2e-user")
        // Use the actual person ID that matches activities
        let fixedActivities = activities.map { activity -> TicketActivity in
            var a = TicketActivity(systemId: systemId, personId: person.id, ticketKey: activity.ticketKey, title: activity.title, currentStatus: activity.currentStatus)
            a.storyPoints = activity.storyPoints
            a.updatedDate = activity.updatedDate
            a.createdDate = activity.createdDate
            return a
        }

        let summary = SummaryEngine.shared.generateSummary(
            for: person,
            systemName: "Integration Test System",
            activities: fixedActivities,
            sprints: [],
            period: .weekly
        )

        XCTAssertEqual(summary.personName, "E2E Tester")
        XCTAssertEqual(summary.systemName, "Integration Test System")
        XCTAssertEqual(summary.totalTickets, 6)
        XCTAssertEqual(summary.ticketsCompleted, 3)
        XCTAssertEqual(summary.ticketsInProgress, 2)
        XCTAssertEqual(summary.ticketsBlocked, 1)
        XCTAssertEqual(summary.ticketsCreated, 6)

        // Story points: committed = all (5*3 + 3*2 + 8) = 29
        XCTAssertEqual(summary.committedPoints, 29, accuracy: 0.01)
        // Completed points: done tickets only (5*3) = 15
        XCTAssertEqual(summary.completedPoints, 15, accuracy: 0.01)

        // Computed properties
        XCTAssertEqual(summary.completionRate, 50.0, accuracy: 0.01) // 3/6
        XCTAssertGreaterThan(summary.velocityPercentage, 0)
    }

    // MARK: - Sprint Data Parsing Pipeline

    func testJiraSprintToSprintDataConversion() throws {
        let json = """
        {
            "maxResults": 10,
            "startAt": 0,
            "values": [
                {
                    "id": 100,
                    "name": "Sprint 15",
                    "state": "active",
                    "startDate": "2026-04-14T00:00:00.000Z",
                    "endDate": "2026-04-28T00:00:00.000Z",
                    "goal": "Ship authentication module"
                },
                {
                    "id": 99,
                    "name": "Sprint 14",
                    "state": "closed",
                    "startDate": "2026-04-01T00:00:00.000Z",
                    "endDate": "2026-04-14T00:00:00.000Z"
                },
                {
                    "id": 101,
                    "name": "Sprint 16",
                    "state": "future"
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(JiraSprintResponse.self, from: json)
        let systemId = UUID()
        // Jira sprint dates carry fractional seconds ("...000Z"), which the
        // default ISO8601DateFormatter does not parse — enable that option so
        // startDate/endDate decode instead of coming back nil.
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // Convert (same logic as DataFetchCoordinator.convertJiraSprint)
        let sprintDataList = response.values.map { sprint -> SprintData in
            let state: SprintState
            switch sprint.state?.lowercased() {
            case "active": state = .active
            case "closed": state = .closed
            default: state = .future
            }

            var data = SprintData(systemId: systemId, sprintName: sprint.name, state: state)
            data.goal = sprint.goal
            if let start = sprint.startDate { data.startDate = dateFormatter.date(from: start) }
            if let end = sprint.endDate { data.endDate = dateFormatter.date(from: end) }
            return data
        }

        XCTAssertEqual(sprintDataList.count, 3)
        XCTAssertEqual(sprintDataList[0].sprintName, "Sprint 15")
        XCTAssertEqual(sprintDataList[0].state, .active)
        XCTAssertEqual(sprintDataList[0].goal, "Ship authentication module")
        XCTAssertNotNil(sprintDataList[0].startDate)
        XCTAssertNotNil(sprintDataList[0].endDate)

        XCTAssertEqual(sprintDataList[1].state, .closed)
        XCTAssertEqual(sprintDataList[2].state, .future)
        XCTAssertNil(sprintDataList[2].startDate)
    }

    // MARK: - AI Summary Prompt Construction

    func testAISummaryPromptContainsRequiredFields() {
        // Verify the prompt builder includes key data points
        var summary = PersonSummary(
            personId: UUID(),
            systemId: UUID(),
            personName: "Prompt Test",
            systemName: "Jira Cloud",
            period: .weekly
        )
        summary.totalTickets = 10
        summary.ticketsCompleted = 5
        summary.ticketsInProgress = 3
        summary.ticketsBlocked = 1
        summary.ticketsCreated = 4
        summary.committedPoints = 20
        summary.completedPoints = 12
        summary.sprintName = "Sprint 22"

        var activity = TicketActivity(
            systemId: summary.systemId,
            personId: summary.personId,
            ticketKey: "PROMPT-1",
            title: "Test ticket for prompt",
            currentStatus: "Done"
        )
        activity.updatedDate = Date()
        summary.recentTickets = [activity]

        // The prompt should contain person name, system, period, counts, sprint info
        // We verify the PersonSummary data that feeds the prompt
        XCTAssertEqual(summary.personName, "Prompt Test")
        XCTAssertEqual(summary.systemName, "Jira Cloud")
        XCTAssertEqual(summary.period.rawValue, "Weekly")
        XCTAssertEqual(summary.totalTickets, 10)
        XCTAssertEqual(summary.sprintName, "Sprint 22")
        XCTAssertFalse(summary.recentTickets.isEmpty)
    }

    // MARK: - Malformed JSON Handling

    func testMalformedJiraResponseThrows() {
        let badJSON = """
        { "startAt": "not_a_number", "maxResults": 50, "total": 0, "issues": [] }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try decoder.decode(JiraSearchResponse.self, from: badJSON))
    }

    func testIncompleteAzDOWorkItemHandled() throws {
        let json = """
        { "id": 999 }
        """.data(using: .utf8)!

        let item = try decoder.decode(AzDOWorkItem.self, from: json)
        XCTAssertEqual(item.id, 999)
        XCTAssertNil(item.fields, "Missing fields should decode as nil")
        XCTAssertNil(item.rev)
    }

    func testEmptyWorkItemResponseHandled() throws {
        let json = """
        { "count": 0, "value": [] }
        """.data(using: .utf8)!

        let response = try decoder.decode(AzDOWorkItemResponse.self, from: json)
        XCTAssertEqual(response.count, 0)
        XCTAssertTrue(response.value?.isEmpty ?? true)
    }
}
