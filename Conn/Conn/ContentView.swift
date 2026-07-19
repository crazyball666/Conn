import ConnKit
import ConnStore
import SwiftUI

/// 临时冒烟视图。Phase 1b 将替换为 `RootTabView`（5 Tab 悬浮 Dock 导航壳）。
struct ContentView: View {
    @State private var status = "正在初始化数据库…"

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Conn")
                .font(.largeTitle.bold())
            Text(status)
                .font(.footnote)
                .monospaced()
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
        .task { status = Self.smokeTest() }
    }

    /// 建库 → 写一台主机 → 读回，验证 ConnKit + ConnStore + GRDB 三者链接正常。
    private static func smokeTest() -> String {
        do {
            let database = try AppDatabase.inMemory()
            let store = HostStore(database: database)
            try store.save(Host(name: "web-01", address: "10.0.0.1", username: "root", tags: ["prod"]))

            let hosts = try store.allHosts()
            let first = hosts.first
            return """
            数据库就绪 · \(hosts.count) 台主机
            \(first?.displayAddress ?? "—")
            生产环境: \(first?.isProduction == true ? "是" : "否")
            """
        } catch {
            return "初始化失败：\(error.localizedDescription)"
        }
    }
}

#Preview {
    ContentView()
}
