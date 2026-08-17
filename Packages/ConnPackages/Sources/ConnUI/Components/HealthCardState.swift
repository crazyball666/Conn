import SwiftUI

// 健康卡的**展示层状态枚举**。与视图分文件放，是因为 `HealthCard.swift` 已逼近
// `file_length` 上限；这些枚举本就是可独立测试的纯数据，与视图的渲染细节无关。

/// 主机健康状态的**展示层**表示。
///
/// 刻意与 `ConnKit.Host.HealthStatus` 分离：设计系统不依赖领域模型
/// （设计规范 §9「组件一律 stateless」），由 Feature 层负责映射。
public enum ConnHealthStatus: Sendable, CaseIterable {
    case ok, warn, crit, offline, unknown

    var pillSemantic: StatusPill.Semantic {
        switch self {
        case .ok: .good
        case .warn: .warn
        case .crit, .offline: .crit
        case .unknown: .off
        }
    }

    var label: String {
        switch self {
        case .ok: L("正常")
        case .warn: L("警告")
        case .crit: L("故障")
        case .offline: L("离线")
        case .unknown: L("未知")
        }
    }
}

/// SSH 连接层的展示状态，与指标采集完全正交。
///
/// Linux CPU 首个样本需要做基线计算时，主机已经连上，但健康值仍可能是
/// `.unknown`。单独建模连接态可以避免首页先闪「未知」，或把后台采集误报成
/// 「连接中」。
public enum ConnConnectionPhase: Sendable, CaseIterable {
    /// 首次进入首页，尚未完成 SSH 握手和首个采集结果。
    case connecting
    /// SSH 已建立；连接胶囊固定显示正常。
    case connected
    /// 已建立的会话失效，正在重新握手。
    case reconnecting
    /// 首次连接失败，连接胶囊显示离线。
    case failed

    var pillText: String {
        switch self {
        case .connecting:
            return L("连接中…")
        case .connected:
            return L("正常")
        case .reconnecting:
            return L("重连中")
        case .failed:
            return L("离线")
        }
    }

    var pillSemantic: StatusPill.Semantic {
        switch self {
        case .connecting, .reconnecting:
            return .info
        case .connected:
            return .good
        case .failed:
            return .crit
        }
    }

    var isBusy: Bool {
        switch self {
        case .connecting, .reconnecting: true
        case .connected, .failed: false
        }
    }
}

/// 采集阶段的**展示层**表示，与 `ConnMonitor.CollectPhase` 三态一一对应。
///
/// 刻意重新声明一份而非直接用领域枚举：ConnUI 零依赖（见 Package.swift 里
/// ConnUI target 的注释），映射由 Feature 层承担，与 `ConnHealthStatus` 同理。
///
/// **为什么是枚举而不是两个 Bool**：原先 `isBusy` / `isReconnecting` 两个独立
/// Bool 能表达 4 种组合，其中 `(isBusy: false, isReconnecting: true)`
/// ——「不转圈的重连中」——是无意义的，却拦不住调用方传进来。换成枚举后
/// 非法状态不可表示，派生的文字/语义色也随之变成可脱离 SwiftUI 单测的纯函数。
public enum ConnCollectPhase: Sendable, CaseIterable {
    /// 不在采集。
    case idle
    /// 本轮采集在飞行中，复用已有会话。
    case collecting
    /// 会话已被驱逐，本轮在重新握手。
    case reconnecting

    /// 胶囊文字。
    ///
    /// 重连中时盖掉状态文案——「重连中」比「正常/故障」更贴近此刻发生的事。
    /// 常规采集不改变健康状态文案；SSH 的「连接中…」/「重连中」由
    /// `ConnConnectionPhase` 决定，不能用 CPU/内存等指标是否完整来推断。
    func pillText(status: ConnHealthStatus) -> String {
        switch self {
        case .reconnecting:
            return L("重连中")
        case .collecting:
            return status.label
        case .idle:
            return status.label
        }
    }

    /// 胶囊语义色。重连中转蓝（`.info`）；常规采集保持健康状态自己的颜色。
    func pillSemantic(status: ConnHealthStatus) -> StatusPill.Semantic {
        switch self {
        case .reconnecting:
            return .info
        case .collecting:
            return status.pillSemantic
        case .idle:
            return status.pillSemantic
        }
    }
}
