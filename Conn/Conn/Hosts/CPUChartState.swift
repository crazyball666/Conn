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
    private var samples: [CPUChartMetric: [Double]] = [:]

    subscript(metric: CPUChartMetric) -> [Double] {
        samples[metric] ?? []
    }

    mutating func append(_ value: CPUBreakdown, limit: Int) {
        append(value.user, to: .user, limit: limit)
        append(value.system, to: .system, limit: limit)
        append(value.iowait, to: .iowait, limit: limit)
        append(value.idle, to: .idle, limit: limit)
        append(value.nice, to: .nice, limit: limit)
        append(value.irq, to: .irq, limit: limit)
        append(value.softirq, to: .softirq, limit: limit)
        append(value.steal, to: .steal, limit: limit)
    }

    private mutating func append(_ value: Double, to metric: CPUChartMetric, limit: Int) {
        guard limit > 0 else {
            samples[metric] = []
            return
        }
        var history = samples[metric] ?? []
        history.append(value)
        if history.count > limit {
            history.removeFirst(history.count - limit)
        }
        samples[metric] = history
    }
}
