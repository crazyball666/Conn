import Combine
import ConnKit
import ConnSSH
import ConnTerminal
import ConnUI
import Foundation
import PhotosUI
import SwiftUI
import UIKit

private actor TerminalAttachmentSerialGate {
    static let shared = TerminalAttachmentSerialGate()

    private var activeHosts: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(hostID: String) async {
        if activeHosts.insert(hostID).inserted {
            return
        }
        await withCheckedContinuation { continuation in
            waiters[hostID, default: []].append(continuation)
        }
    }

    func release(hostID: String) {
        if var hostWaiters = waiters[hostID], !hostWaiters.isEmpty {
            let next = hostWaiters.removeFirst()
            waiters[hostID] = hostWaiters.isEmpty ? nil : hostWaiters
            next.resume()
        } else {
            activeHosts.remove(hostID)
        }
    }
}

@MainActor
final class TerminalAttachmentCoordinator: ObservableObject {
    struct LocalResource: Sendable {
        let url: URL
        let originalName: String
        let deleteAfterUse: Bool
    }

    private struct UploadRequest: Sendable {
        let resources: [LocalResource]
        let providerWorkingDirectory: String?
        let insertionContext: TerminalTextInsertionContext
        var nextIndex: Int
        var completed: [RemoteUploadedResource]
    }

    @Published private(set) var panelState: TerminalAttachmentPanelState = .idle

    private let host: Host
    private let connectionManager: ConnectionManager
    private let uploadService: RemoteUploadService
    private weak var insertionMailbox: TerminalTextInsertionMailbox?
    private var fileSystem: (any RemoteFileSystem)?
    private var transferTask: Task<Void, Never>?
    private var retryRequest: UploadRequest?
    private var completedReceipts: [RemoteUploadedResource] = []

    init(
        host: Host,
        connectionManager: ConnectionManager,
        uploadService: RemoteUploadService = RemoteUploadService()
    ) {
        self.host = host
        self.connectionManager = connectionManager
        self.uploadService = uploadService
    }

    deinit {
        transferTask?.cancel()
        let resources = retryRequest?.resources ?? []
        Self.removeStagedResources(resources)
        if let fileSystem {
            Task { await fileSystem.close() }
        }
    }

    func retry() {
        guard let retryRequest, let insertionMailbox else { return }
        start(retryRequest, insertionMailbox: insertionMailbox)
    }

    func insertCompletedPaths() {
        guard !completedReceipts.isEmpty,
              let insertionMailbox,
              let context = insertionMailbox.currentContext,
              let text = try? TerminalPathInsertionRenderer.render(
                  completedReceipts.map(\.terminalReferencePath)
              )
        else { return }
        insertionMailbox.enqueue(text, expectedContext: context)
        completedReceipts.removeAll()
        panelState = .idle
    }

    func cancel(cleanup: Bool = true) {
        transferTask?.cancel()
        transferTask = nil
        if cleanup, let retryRequest {
            Self.removeStagedResources(retryRequest.resources)
            self.retryRequest = nil
        }
        panelState = .idle
    }

    private func begin(
        resources: [LocalResource],
        providerWorkingDirectory: String?,
        insertionContext: TerminalTextInsertionContext?,
        insertionMailbox: TerminalTextInsertionMailbox
    ) {
        guard !resources.isEmpty else { return }
        guard let insertionContext else {
            Self.removeStagedResources(resources)
            panelState = .init(phase: .notice(message: L("当前终端尚未准备好，请稍后重试。")))
            return
        }
        cancel(cleanup: true)
        self.insertionMailbox = insertionMailbox
        let request = UploadRequest(
            resources: resources,
            providerWorkingDirectory: providerWorkingDirectory,
            insertionContext: insertionContext,
            nextIndex: 0,
            completed: []
        )
        retryRequest = request
        start(request, insertionMailbox: insertionMailbox)
    }

    private func start(
        _ request: UploadRequest,
        insertionMailbox: TerminalTextInsertionMailbox
    ) {
        transferTask?.cancel()
        retryRequest = request
        let hostID = host.id
        transferTask = Task { [weak self, weak insertionMailbox] in
            guard let self, let insertionMailbox else { return }
            await TerminalAttachmentSerialGate.shared.acquire(hostID: hostID)
            defer {
                Task { await TerminalAttachmentSerialGate.shared.release(hostID: hostID) }
            }
            do {
                try Task.checkCancellation()
                var mutableRequest = request
                let fs = try await filesystem()
                let home = try await fs.realPath(".")
                let destination = try TerminalAttachmentDestinationResolver.resolve(
                    providerWorkingDirectory: request.providerWorkingDirectory,
                    accountHome: home
                )
                while mutableRequest.nextIndex < mutableRequest.resources.count {
                    try Task.checkCancellation()
                    let index = mutableRequest.nextIndex
                    let resource = mutableRequest.resources[index]
                    panelState = .init(phase: .uploading(name: resource.originalName, progress: 0))
                    let receipt = try await uploadWithOneChannelRetry(
                        resource,
                        destination: destination,
                        itemIndex: index,
                        totalCount: mutableRequest.resources.count
                    )
                    mutableRequest.completed.append(receipt)
                    mutableRequest.nextIndex += 1
                    retryRequest = mutableRequest
                }

                try finish(mutableRequest, insertionMailbox: insertionMailbox)
            } catch is CancellationError {
                panelState = .idle
            } catch {
                panelState = .init(phase: .failed(message: failureMessage(for: error, request: request)))
            }
        }
    }

    private func finish(
        _ request: UploadRequest,
        insertionMailbox: TerminalTextInsertionMailbox
    ) throws {
        completedReceipts = request.completed
        retryRequest = nil
        Self.removeStagedResources(request.resources)
        let text = try TerminalPathInsertionRenderer.render(
            completedReceipts.map(\.terminalReferencePath)
        )
        let canInsert = insertionMailbox.currentContext == request.insertionContext
        if canInsert {
            insertionMailbox.enqueue(text, expectedContext: request.insertionContext)
        }
        panelState = .init(
            phase: .completed(
                count: completedReceipts.count,
                requiresManualInsertion: !canInsert
            )
        )
    }

    private func failureMessage(for error: Error, request: UploadRequest) -> String {
        let completedCount = retryRequest?.completed.count ?? request.completed.count
        guard completedCount > 0 else {
            return String(format: L("附件上传失败：%@"), error.friendlyDiagnosis)
        }
        return String(
            format: L("已上传 %d 个附件，其余附件上传失败：%@"),
            completedCount,
            error.friendlyDiagnosis
        )
    }

    private func uploadWithOneChannelRetry(
        _ resource: LocalResource,
        destination: String,
        itemIndex: Int,
        totalCount: Int
    ) async throws -> RemoteUploadedResource {
        var lastError: Error?
        for attempt in 0 ... 1 {
            do {
                let fs = try await filesystem()
                return try await uploadService.upload(
                    localURL: resource.url,
                    originalName: resource.originalName,
                    to: destination,
                    using: fs,
                    onProgress: { [weak self] progress in
                        await self?.updateProgress(
                            name: resource.originalName,
                            progress: (Double(itemIndex) + progress) / Double(max(totalCount, 1))
                        )
                    }
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                guard attempt == 0 else { break }
                await discardFileSystem()
            }
        }
        throw lastError ?? TerminalAttachmentPreparationError.uploadUnavailable
    }

    private func filesystem() async throws -> any RemoteFileSystem {
        if let fileSystem {
            return fileSystem
        }
        let session = try await connectionManager.session(for: host)
        let created = try await session.sftp()
        fileSystem = created
        return created
    }

    private func updateProgress(name: String, progress: Double) {
        panelState = .init(phase: .uploading(name: name, progress: progress))
    }

    private func discardFileSystem() async {
        guard let fileSystem else { return }
        self.fileSystem = nil
        await fileSystem.close()
    }

    private static func stageImage(_ image: UIImage, baseName: String) throws -> LocalResource {
        let data: Data
        let fileExtension: String
        if let jpeg = image.jpegData(compressionQuality: 0.92) {
            data = jpeg
            fileExtension = "jpg"
        } else if let png = image.pngData() {
            data = png
            fileExtension = "png"
        } else {
            throw TerminalAttachmentPreparationError.unsupportedImage
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("conn-terminal-attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(baseName)-\(UUID().uuidString.prefix(8)).\(fileExtension)"
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return .init(url: url, originalName: name, deleteAfterUse: true)
    }

    private nonisolated static func removeStagedResources(_ resources: [LocalResource]) {
        for resource in resources where resource.deleteAfterUse {
            try? FileManager.default.removeItem(at: resource.url)
        }
    }
}

extension TerminalAttachmentCoordinator {
    func uploadFiles(
        _ urls: [URL],
        providerWorkingDirectory: String?,
        insertionContext: TerminalTextInsertionContext?,
        insertionMailbox: TerminalTextInsertionMailbox
    ) {
        let resources = urls.map {
            LocalResource(url: $0, originalName: $0.lastPathComponent, deleteAfterUse: false)
        }
        begin(
            resources: resources,
            providerWorkingDirectory: providerWorkingDirectory,
            insertionContext: insertionContext,
            insertionMailbox: insertionMailbox
        )
    }

    func uploadPhotos(
        _ items: [PhotosPickerItem],
        providerWorkingDirectory: String?,
        insertionContext: TerminalTextInsertionContext?,
        insertionMailbox: TerminalTextInsertionMailbox
    ) {
        guard !items.isEmpty else { return }
        cancel(cleanup: true)
        panelState = .init(phase: .preparing)
        transferTask = Task { [weak self] in
            guard let self else { return }
            var resources: [LocalResource] = []
            do {
                for (index, item) in items.enumerated() {
                    try Task.checkCancellation()
                    guard let data = try await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data)
                    else {
                        throw TerminalAttachmentPreparationError.unsupportedImage
                    }
                    let resource = try Self.stageImage(
                        image,
                        baseName: String(format: "image-%02d", index + 1)
                    )
                    resources.append(resource)
                }
                begin(
                    resources: resources,
                    providerWorkingDirectory: providerWorkingDirectory,
                    insertionContext: insertionContext,
                    insertionMailbox: insertionMailbox
                )
            } catch is CancellationError {
                Self.removeStagedResources(resources)
                panelState = .idle
            } catch {
                Self.removeStagedResources(resources)
                panelState = .init(phase: .notice(message: error.friendlyDiagnosis))
            }
        }
    }

    func uploadClipboard(
        providerWorkingDirectory: String?,
        insertionContext: TerminalTextInsertionContext?,
        insertionMailbox: TerminalTextInsertionMailbox
    ) {
        #if DEBUG
            if ProcessInfo.processInfo.environment["CONN_SMOKE_TERMINAL_ATTACHMENTS_FAILURE"] != nil {
                panelState = .init(phase: .failed(message: L("无法建立附件上传通道。")))
                return
            }
            if ProcessInfo.processInfo.environment["CONN_SMOKE_TERMINAL_ATTACHMENTS"] != nil {
                let renderer = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24))
                let image = renderer.image { context in
                    UIColor.systemPurple.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
                }
                do {
                    let resource = try Self.stageImage(image, baseName: "ConnUploadSmoke")
                    begin(
                        resources: [resource],
                        providerWorkingDirectory: providerWorkingDirectory,
                        insertionContext: insertionContext,
                        insertionMailbox: insertionMailbox
                    )
                } catch {
                    panelState = .init(phase: .failed(message: error.friendlyDiagnosis))
                }
                return
            }
        #endif
        if let urls = UIPasteboard.general.urls, !urls.isEmpty {
            uploadFiles(
                urls,
                providerWorkingDirectory: providerWorkingDirectory,
                insertionContext: insertionContext,
                insertionMailbox: insertionMailbox
            )
            return
        }
        guard let image = UIPasteboard.general.image else {
            panelState = .init(phase: .notice(message: L("剪贴板中没有可上传的图片或文件。")))
            return
        }
        do {
            let resource = try Self.stageImage(image, baseName: "clipboard-image")
            begin(
                resources: [resource],
                providerWorkingDirectory: providerWorkingDirectory,
                insertionContext: insertionContext,
                insertionMailbox: insertionMailbox
            )
        } catch {
            panelState = .init(phase: .failed(message: error.friendlyDiagnosis))
        }
    }
}

private enum TerminalAttachmentPreparationError: LocalizedError {
    case unsupportedImage
    case uploadUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedImage: L("无法处理所选图片格式。")
        case .uploadUnavailable: L("无法建立附件上传通道。")
        }
    }
}
