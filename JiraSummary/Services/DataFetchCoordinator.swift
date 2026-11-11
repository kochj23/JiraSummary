//
//  DataFetchCoordinator.swift
//  JiraSummary
//
//  Parallel multi-system data fetch using withTaskGroup
//  Created by Jordan Koch on 2026-02-17.
//

import Foundation
import os.log

@MainActor
@Observable
final class DataFetchCoordinator {
    static let shared = DataFetchCoordinator()

    var isFetching = false
    var fetchProgress: String = ""
    var fetchErrors: [String] = []

    private let logger = Logger(subsystem: "com.jordankoch.JiraSummary", category: "DataFetch")
    private let dataStore = DataStore.shared
    private let summaryEngine = SummaryEngine.shared

    private init() {}

    // MARK: - Fetch All

    func fetchAll(period: SummaryPeriod = .weekly) async {
        guard !isFetching else { return }
        isFetching = true
        fetchErrors = []
        fetchProgress = "Starting data fetch..."

        let connections = dataStore.connections.filter { $0.isAuthenticated }
        let people = dataStore.trackedPeople

        guard !connections.isEmpty else {
            fetchProgress = "No authenticated systems"
            isFetching = false
            return
        }

        guard !people.isEmpty else {
            fetchProgress = "No people to track"
            isFetching = false
            return
        }

        // Parallel fetch across systems
        await withTaskGroup(of: Void.self) { group in
            for connection in connections {
                let connectionPeople = people.filter { $0.systemId == connection.id }
                guard !connectionPeople.isEmpty else { continue }

                group.addTask { [weak self] in
                    guard let self else { return }
                    await self.fetchForSystem(connection: connection, people: connectionPeople, period: period)
                }
            }
        }

        // Generate summaries
        fetchProgress = "Generating summaries..."
        for person in people {
            if let connection = connections.first(where: { $0.id == person.systemId }) {
                let activities = dataStore.activities(for: person.id)
                let sprints = dataStore.sprints(for: person.systemId)
                let summary = summaryEngine.generateSummary(
                    for: person,
                    systemName: connection.name,
                    activities: activities,
                    sprints: sprints,
                    period: period
                )
                dataStore.updateSummary(summary)
            }
        }

        // Natural-language summaries (NovaAIKit; built-in text when AI is off or unavailable)
        fetchProgress = "Writing summaries..."
        for person in people {
            if let summary = dataStore.personSummaries.first(where: {
                $0.personId == person.id && $0.systemId == person.systemId && $0.period == period
            }) {
                dataStore.updateSummary(await AISummaryService.annotate(summary))
            }
        }

        dataStore.saveLastRefreshDate()
        WidgetDataSyncService.shared.syncFromDataStore()
        fetchProgress = "Done"
        isFetching = false
        logger.info("Fetch complete for \(connections.count) systems, \(people.count) people")
    }

    // MARK: - Per-System Fetch

    private func fetchForSystem(connection: SystemConnection, people: [TrackedPerson], period: SummaryPeriod) async {
        await MainActor.run { fetchProgress = "Fetching from \(connection.name)..." }

        let sinceDate = Calendar.current.date(byAdding: .day, value: -period.days, to: Date()) ?? Date()

        switch connection.type {
        case .jiraCloud:
            await fetchJiraCloud(connection: connection, people: people, since: sinceDate)
        case .jiraServer:
            await fetchJiraServer(connection: connection, people: people, since: sinceDate)
        case .azureDevOps:
            await fetchAzureDevOps(connection: connection, people: people, since: sinceDate)
        }

        // Fetch sprint data
        await fetchSprintData(for: connection)
    }

    // MARK: - Jira Cloud

    private func fetchJiraCloud(connection: SystemConnection, people: [TrackedPerson], since: Date) async {
        let service = JiraCloudService(baseURL: connection.baseURL, systemId: connection.id)

        for person in people {
            do {
                let issues = try await service.fetchIssuesForUser(accountId: person.systemUserId, since: since)
                let activities = issues.map { convertJiraIssue($0, systemId: connection.id, personId: person.id) }
                await MainActor.run {
                    dataStore.updateTicketActivities(activities, for: person.id, systemId: connection.id)
                }
                logger.info("Fetched \(issues.count) issues for \(person.displayName) from \(connection.name)")
            } catch {
                let errorMsg = "[\(connection.name)] \(person.displayName): \(error.localizedDescription)"
                logger.error("\(errorMsg)")
                await MainActor.run { fetchErrors.append(errorMsg) }
            }
        }
    }

    // MARK: - Jira Server

    private func fetchJiraServer(connection: SystemConnection, people: [TrackedPerson], since: Date) async {
        let service = JiraServerService(baseURL: connection.baseURL, systemId: connection.id)

        for person in people {
            do {
                let issues = try await service.fetchIssuesForUser(username: person.systemUserId, since: since)
                let activities = issues.map { convertJiraIssue($0, systemId: connection.id, personId: person.id) }
                await MainActor.run {
                    dataStore.updateTicketActivities(activities, for: person.id, systemId: connection.id)
                }
                logger.info("Fetched \(issues.count) issues for \(person.displayName) from \(connection.name)")
            } catch {
                let errorMsg = "[\(connection.name)] \(person.displayName): \(error.localizedDescription)"
                logger.error("\(errorMsg)")
                await MainActor.run { fetchErrors.append(errorMsg) }
            }
        }
    }

    // MARK: - Azure DevOps

    private func fetchAzureDevOps(connection: SystemConnection, people: [TrackedPerson], since: Date) async {
        let service = AzureDevOpsService(baseURL: connection.baseURL, systemId: connection.id)

        for person in people {
            do {
                let workItems = try await service.fetchWorkItemsForUser(uniqueName: person.systemUserId, since: since)
                var activities: [TicketActivity] = []

                for item in workItems {
                    var activity = convertAzDOWorkItem(item, systemId: connection.id, personId: person.id)

                    // Fetch status transitions
                    let updates = try await service.fetchWorkItemUpdates(workItemId: item.id)
                    activity.transitions = updates.compactMap { update -> StatusTransition? in
                        guard let stateChange = update.fields?.state,
                              let newValue = stateChange.newValue else { return nil }
                        let dateFormatter = ISO8601DateFormatter()
                        let date = update.revisedDate.flatMap { dateFormatter.date(from: $0) } ?? Date()
                        return StatusTransition(
                            fromStatus: stateChange.oldValue,
                            toStatus: newValue,
                            transitionDate: date,
                            author: update.revisedBy?.displayName
                        )
                    }

                    activities.append(activity)
                }

                await MainActor.run {
                    dataStore.updateTicketActivities(activities, for: person.id, systemId: connection.id)
                }
                logger.info("Fetched \(workItems.count) work items for \(person.displayName) from \(connection.name)")
            } catch {
                let errorMsg = "[\(connection.name)] \(person.displayName): \(error.localizedDescription)"
                logger.error("\(errorMsg)")
                await MainActor.run { fetchErrors.append(errorMsg) }
            }
        }
    }

    // MARK: - Sprint Data

    private func fetchSprintData(for connection: SystemConnection) async {
        guard !connection.boardIds.isEmpty else { return }

        switch connection.type {
        case .jiraCloud:
            let service = JiraCloudService(baseURL: connection.baseURL, systemId: connection.id)
            for boardId in connection.boardIds {
                do {
                    let sprints = try await service.fetchSprints(boardId: boardId)
                    let sprintDataList = sprints.map { convertJiraSprint($0, systemId: connection.id) }
                    await MainActor.run {
                        dataStore.updateSprintData(sprintDataList, for: connection.id)
                    }
                } catch {
                    logger.error("Sprint fetch failed for board \(boardId): \(error.localizedDescription)")
                }
            }

        case .jiraServer:
            let service = JiraServerService(baseURL: connection.baseURL, systemId: connection.id)
            for boardId in connection.boardIds {
                do {
                    let sprints = try await service.fetchSprints(boardId: boardId)
                    let sprintDataList = sprints.map { convertJiraSprint($0, systemId: connection.id) }
                    await MainActor.run {
                        dataStore.updateSprintData(sprintDataList, for: connection.id)
                    }
                } catch {
                    logger.error("Sprint fetch failed for board \(boardId): \(error.localizedDescription)")
                }
            }

        case .azureDevOps:
            break // Iterations handled differently for AzDO
        }
    }

    // MARK: - Converters

    private func convertJiraIssue(_ issue: JiraIssue, systemId: UUID, personId: UUID) -> TicketActivity {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

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

        if let created = issue.fields.created { activity.createdDate = dateFormatter.date(from: created) ?? Date() }
        if let updated = issue.fields.updated { activity.updatedDate = dateFormatter.date(from: updated) ?? Date() }
        if let resolved = issue.fields.resolutiondate { activity.resolvedDate = dateFormatter.date(from: resolved) }

        // Convert changelog to transitions
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

    private func convertAzDOWorkItem(_ item: AzDOWorkItem, systemId: UUID, personId: UUID) -> TicketActivity {
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

        let dateFormatter = ISO8601DateFormatter()
        if let created = item.fields?.createdDate { activity.createdDate = dateFormatter.date(from: created) ?? Date() }
        if let changed = item.fields?.changedDate { activity.updatedDate = dateFormatter.date(from: changed) ?? Date() }
        if let closed = item.fields?.closedDate { activity.resolvedDate = dateFormatter.date(from: closed) }

        return activity
    }

    private func convertJiraSprint(_ sprint: JiraSprint, systemId: UUID) -> SprintData {
        let state: SprintState
        switch sprint.state?.lowercased() {
        case "active": state = .active
        case "closed": state = .closed
        default: state = .future
        }

        var data = SprintData(systemId: systemId, sprintName: sprint.name, state: state)
        data.goal = sprint.goal

        let dateFormatter = ISO8601DateFormatter()
        if let start = sprint.startDate { data.startDate = dateFormatter.date(from: start) }
        if let end = sprint.endDate { data.endDate = dateFormatter.date(from: end) }

        return data
    }
}
