import ConnMonitor
import Foundation

/// CPU 趋势图支持独立显示/隐藏的八类时间占比。
enum CPUChartMetric: String, CaseIterable, Hashable, Sendable {
    case user
    case system
    case iowait
    case idle
    case nice
    case irq
    case softirq
    case steal
}

/// 页面内临时可见性；每次进入详情默认显示全部指标。
struct CPUChartVisibility: Equatable, Sendable {
    private(set) var visible = Set(CPUChartMetric.allCases)

    func contains(_ metric: CPUChartMetric) -> Bool {
        visible.contains(metric)
    }

    mutating func toggle(_ metric: CPUChartMetric) {
        if visible.contains(metric) {
            visible.remove(metric)
        } else {
            visible.insert(metric)
        }
    }
}

/// 八类 CPU 指标的滚动历史，避免把低占比但有诊断价值的指标合并丢失。
struct CPUCategoryHistory: Equatable, Sendable {
    private var history: [CPUChartMetric: [TrendSample]] = [:]

    subscript(metric: CPUChartMetric) -> [Double] {
        history[metric, default: []].map(\.value)
    }

    mutating func append(_ value: CPUBreakdown, limit: Int) {
        let nextSequence = history.values.flatMap { $0 }.map(\.sequence).max().map { $0 + 1 } ?? 0
        append(value, sequence: nextSequence, limit: limit)
    }

    mutating func append(_ value: CPUBreakdown, sequence: Int, limit: Int) {
        append(value.user, to: .user, sequence: sequence, limit: limit)
        append(value.system, to: .system, sequence: sequence, limit: limit)
        append(value.iowait, to: .iowait, sequence: sequence, limit: limit)
        append(value.idle, to: .idle, sequence: sequence, limit: limit)
        append(value.nice, to: .nice, sequence: sequence, limit: limit)
        append(value.irq, to: .irq, sequence: sequence, limit: limit)
        append(value.softirq, to: .softirq, sequence: sequence, limit: limit)
        append(value.steal, to: .steal, sequence: sequence, limit: limit)
    }

    func samples(for metric: CPUChartMetric) -> [TrendSample] {
        history[metric] ?? []
    }

    private mutating func append(_ value: Double, to metric: CPUChartMetric, sequence: Int, limit: Int) {
        guard limit > 0 else {
            history[metric] = []
            return
        }
        var metricHistory = history[metric] ?? []
        metricHistory.append(TrendSample(sequence: sequence, value: value))
        if metricHistory.count > limit {
            metricHistory.removeFirst(metricHistory.count - limit)
        }
        history[metric] = metricHistory
    }
}
