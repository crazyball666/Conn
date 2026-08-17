import Foundation
import Testing
@testable import ConnUI

/// 覆盖 `ConnCollectPhase` 上的胶囊派生（文字 + 语义色）。
///
/// 这两项原是 `HealthCard` 里的私有计算属性，只能靠渲染截图间接核对；
/// 挪到枚举上后是纯函数，可以直接钉死「哪一态该显示什么」。
@Suite("HealthCard — 采集态的胶囊文字与语义色")
struct HealthCardPillTests {
    @Test("idle：文字与语义色完全跟随健康状态")
    func idleKeepsStatus() {
        for status in ConnHealthStatus.allCases {
            #expect(ConnCollectPhase.idle.pillText(status: status) == status.label)
            #expect(ConnCollectPhase.idle.pillSemantic(status: status) == status.pillSemantic)
        }
        // 具体钉一组，避免上面的循环退化成「拿实现和实现比」的同义反复。
        #expect(ConnCollectPhase.idle.pillText(status: .ok) == L("正常"))
        #expect(ConnCollectPhase.idle.pillSemantic(status: .ok) == .good)
        #expect(ConnCollectPhase.idle.pillSemantic(status: .crit) == .crit)
    }

    /// 已有读数的常规采集只转圈，**不改文案也不改配色**——每 30s 把「正常」换成
    /// 「连接中」会让状态区一直跳。连接状态由卡片的 loading / reconnecting
    /// 维度表达，不能因为 CPU 等待第二个差分样本就把健康未知误报成连接中。
    @Test("collecting：健康状态保持原样，未知状态仍显示未知")
    func collectingKeepsStatus() {
        for status in ConnHealthStatus.allCases {
            if case .unknown = status {
                #expect(ConnCollectPhase.collecting.pillText(status: status) == L("未知"))
                #expect(ConnCollectPhase.collecting.pillSemantic(status: status) == .off)
            } else {
                #expect(ConnCollectPhase.collecting.pillText(status: status) == status.label)
                #expect(ConnCollectPhase.collecting.pillSemantic(status: status) == status.pillSemantic)
            }
        }
        #expect(ConnCollectPhase.collecting.pillText(status: .warn) == L("警告"))
        #expect(ConnCollectPhase.collecting.pillSemantic(status: .warn) == .warn)
        #expect(ConnCollectPhase.collecting.pillText(status: .unknown) == L("未知"))
        #expect(ConnCollectPhase.collecting.pillSemantic(status: .unknown) == .off)
    }

    /// 只有重连态盖掉文案并转蓝（`.info`）——蓝色区别于「连接失败」的红，
    /// 传达的是「还在试，别急着当它挂了」。
    @Test("reconnecting：文字换成「重连中」并转蓝，覆盖任何底层状态")
    func reconnectingOverridesStatus() {
        for status in ConnHealthStatus.allCases {
            #expect(ConnCollectPhase.reconnecting.pillText(status: status) == L("重连中"))
            #expect(ConnCollectPhase.reconnecting.pillSemantic(status: status) == .info)
        }
        // 故障态下也必须被盖掉：重连是此刻更贴切的描述。
        #expect(ConnCollectPhase.reconnecting.pillSemantic(status: .crit) == .info)
    }

}

@Suite("HealthCard — SSH 连接态")
struct HealthCardConnectionPhaseTests {
    @Test("首次连接显示连接中，而不是健康未知")
    func connectingOverridesUnknown() {
        #expect(ConnConnectionPhase.connecting.pillText == L("连接中…"))
        #expect(ConnConnectionPhase.connecting.pillSemantic == .info)
        #expect(ConnConnectionPhase.connecting.isBusy)
    }

    @Test("已连接后固定显示正常，不受健康采样状态影响")
    func connectedIgnoresHealthStatus() {
        #expect(ConnConnectionPhase.connected.pillText == L("正常"))
        #expect(ConnConnectionPhase.connected.pillSemantic == .good)
        #expect(!ConnConnectionPhase.connected.isBusy)
    }

    @Test("重连和失败分别保留连接层语义")
    func reconnectAndFailureAreDistinct() {
        #expect(ConnConnectionPhase.reconnecting.pillText == L("重连中"))
        #expect(ConnConnectionPhase.reconnecting.pillSemantic == .info)
        #expect(ConnConnectionPhase.failed.pillText == L("离线"))
        #expect(ConnConnectionPhase.failed.pillSemantic == .crit)
    }
}
