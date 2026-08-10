import Foundation
import Testing
@testable import Conn

@Suite("进程列表失败状态")
struct ProcessListFailureStateTests {
    @Test("连接失败时显示统一错误状态与重试按钮")
    func connectionFailureShowsBannerAndRetry() throws {
        let source = try source(named: "Conn/Hosts/ProcessListView.swift")

        #expect(source.contains("case let .failed(message):"))
        #expect(source.contains("ConnRetryState(message, retryTitle: L(\"重试\"))"))
        #expect(source.contains("await viewModel.retryProcesses()"))
    }

    @Test("进程页使用独立 ViewModel 并由工作台持有")
    func processPageUsesIndependentViewModel() throws {
        let listSource = try source(named: "Conn/Hosts/ProcessListView.swift")
        let detailSource = try source(named: "Conn/Hosts/ProcessDetailView.swift")
        let hostSource = try source(named: "Conn/Hosts/HostDetailView.swift")
        let overviewSource = try source(named: "Conn/Hosts/HostOverviewViewModel.swift")

        #expect(listSource.contains("let viewModel: ProcessListViewModel"))
        #expect(hostSource.contains("@State private var processVM: ProcessListViewModel"))
        #expect(hostSource.contains("ProcessListView(viewModel: processVM)"))
        #expect(detailSource.contains(".onAppear { viewModel.appear() }"))
        #expect(detailSource.contains(".onDisappear { viewModel.disappear() }"))
        #expect(!overviewSource.contains("setProcessSegmentActive"))
        #expect(!overviewSource.contains("retryProcesses"))
    }

    @Test("进程页展示平台能力降级而不是空白成功")
    func capabilityStateIsVisible() throws {
        let listSource = try source(named: "Conn/Hosts/ProcessListView.swift")
        let modelSource = try source(named: "Conn/Hosts/ProcessListViewModel.swift")

        #expect(modelSource.contains("var capabilityState: CapabilityState?"))
        #expect(modelSource.contains("var capabilityMessage: String?"))
        #expect(listSource.contains("viewModel.capabilityMessage"))
    }

    private func source(named relativePath: String) throws -> String {
        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: projectURL.appending(path: relativePath), encoding: .utf8)
    }
}
