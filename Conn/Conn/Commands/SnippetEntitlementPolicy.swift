import ConnEntitlement
import ConnKit

/// 将脚本执行入口映射到订阅权益，确保命令列表不会绕过功能闸门。
enum SnippetEntitlementPolicy {
    static func blockedFeature(
        for snippet: Snippet,
        hostCount: Int,
        mode: SnippetExecutionMode,
        gate: EntitlementGate
    ) -> PaywallContext? {
        if snippet.requiredCapabilities.contains(.docker),
           !gate.allowed(.dockerManagement) {
            return .dockerManagement
        }

        if mode == .silent,
           hostCount > 1,
           !gate.allowed(.batchExecution) {
            return .batchExecution
        }

        return nil
    }
}
