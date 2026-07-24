// 仅 DEBUG：并排展示健康卡的三种加载态（已加载 / 加载中 / 失败），供截图核对。
#if DEBUG
import ConnUI
import SwiftUI

struct CardStatesSmokeView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: ConnSpacing.stackGap) {
                HealthCard(.init(
                    id: "1", name: "38.147.173.228", address: "root@38.147.173.228:62256",
                    status: .ok, cpu: 8, memory: 38, disk: 68,
                    coresText: "2 核", memTotalText: "3.6 G", diskTotalText: "30 G",
                    net: .init(upRate: "3.1 K", upTotal: "548 M", downRate: "1.5 K", downTotal: "7.2 G"),
                    io: .init(upRate: "0 B", upTotal: "29.3 G", downRate: "0 B", downTotal: "940 M"),
                    uptimeText: "15 天", loadText: "0.09", note: "hk"
                )) {}
                HealthCard(.init(
                    id: "2", name: "web-01", address: "root@10.0.0.1",
                    status: .unknown, loadState: .loading, note: "加载中示例"
                )) {}
                HealthCard(.init(
                    id: "3", name: "db-master", address: "root@10.0.0.2",
                    status: .offline, loadState: .failed("连接超时：22 端口无响应"), note: "生产主库"
                )) {}
            }
            .padding(ConnSpacing.page)
        }
        .background(Color.connBg.ignoresSafeArea())
    }
}
#endif
