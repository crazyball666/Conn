import ConnOps
import ConnSSH
import Foundation
import Observation

@MainActor
final class DockerComposeRegistry {
    private var discovered: [DockerComposeProject] = []
    private var manualByName: [String: DockerComposeProject] = [:]

    var projects: [DockerComposeProject] {
        DockerComposeParser.mergeProjects(
            discovered: discovered,
            manual: Array(manualByName.values)
        )
    }

    func replaceDiscovered(_ projects: [DockerComposeProject]) {
        discovered = projects
    }

    func upsertManual(_ project: DockerComposeProject) {
        manualByName[project.name] = project
    }

    func removeManual(named name: String) {
        manualByName.removeValue(forKey: name)
    }
}

@Observable
@MainActor
final class DockerComposeModel {
    private(set) var items: [DockerComposeProject]
    private(set) var dialect: DockerComposeDialect?
    private(set) var isLoaded = false
    private(set) var errorMessage: String?

    private let context: DockerContext
    private let registry: DockerComposeRegistry

    init(context: DockerContext, registry: DockerComposeRegistry) {
        self.context = context
        self.registry = registry
        items = registry.projects
    }

    func loadIfNeeded() async {
        guard !isLoaded else { return }
        await load()
    }

    func load() async {
        guard context.isUsable else {
            errorMessage = L("Docker 当前不可用")
            items = registry.projects
            isLoaded = true
            return
        }
        do {
            let session = try await context.session()
            guard let detected = try await DockerService.composeDialect(
                on: session, sudo: context.sudo
            ) else {
                dialect = nil
                errorMessage = L("未检测到 Docker Compose")
                items = registry.projects
                isLoaded = true
                return
            }
            dialect = detected
            let projects = try await DockerService.listComposeProjects(
                dialect: detected, on: session, sudo: context.sudo
            )
            registry.replaceDiscovered(projects)
            items = registry.projects
            errorMessage = nil
        } catch {
            items = registry.projects
            errorMessage = error.friendlyDiagnosis
        }
        isLoaded = true
    }

    @discardableResult
    func addManualProject(_ draft: DockerComposeManualDraft) async -> Bool {
        guard let project = draft.project else {
            errorMessage = L("Compose 项目配置无效")
            return false
        }
        guard context.isUsable else {
            errorMessage = L("Docker 当前不可用")
            return false
        }
        do {
            let session = try await context.session()
            let detected: DockerComposeDialect
            if let dialect {
                detected = dialect
            } else if let probed = try await DockerService.composeDialect(
                on: session, sudo: context.sudo
            ) {
                detected = probed
                dialect = probed
            } else {
                errorMessage = L("未检测到 Docker Compose")
                return false
            }
            let services = try await DockerService.composeServices(
                project, dialect: detected, on: session, sudo: context.sudo
            )
            var validated = project
            validated.serviceCount = services.count
            validated.containerCount = services.reduce(0) { $0 + $1.containerCount }
            validated.runningContainerCount = services.reduce(0) {
                $0 + $1.runningContainerCount
            }
            validated.state = Self.state(
                containerCount: validated.containerCount,
                runningContainerCount: validated.runningContainerCount
            )
            registry.upsertManual(validated)
            items = registry.projects
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.friendlyDiagnosis
            return false
        }
    }

    func removeManualProject(_ project: DockerComposeProject) {
        guard project.source == .manual else { return }
        registry.removeManual(named: project.name)
        items = registry.projects
    }

    func services(for project: DockerComposeProject) async throws -> [DockerComposeService] {
        guard let dialect else {
            throw DockerComposeError.commandFailed(
                exitCode: 127,
                message: L("未检测到 Docker Compose")
            )
        }
        return try await DockerService.composeServices(
            project,
            dialect: dialect,
            on: context.session(),
            sudo: context.sudo
        )
    }

    private static func state(
        containerCount: Int,
        runningContainerCount: Int
    ) -> DockerComposeState {
        guard containerCount > 0 else { return .stopped }
        if runningContainerCount == containerCount { return .running }
        if runningContainerCount == 0 { return .stopped }
        return .partial
    }
}
