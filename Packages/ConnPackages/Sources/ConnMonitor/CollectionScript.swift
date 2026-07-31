import Foundation

/// 单趟采集脚本（技术实现方案 §4.3）。
///
/// 一次 `exec` 把所有指标读齐，段间用 sentinel 分隔，避免多次往返。核心指标
/// （CPU/内存/负载/磁盘/网络）全部读 `/proc` + `df`，这些在 GNU 与 BusyBox/Alpine
/// 上都具备，无需能力探测。进程列表由 `ProcessCollectionScript` 独立采集。
public enum CollectionScript {
    /// 段分隔标记。选用不可能出现在正常输出里的形态。
    public enum Sentinel {
        public static let stat = "__CONN_STAT__"
        public static let mem = "__CONN_MEM__"
        public static let load = "__CONN_LOAD__"
        public static let disk = "__CONN_DISK__"
        public static let net = "__CONN_NET__"
        public static let snmp = "__CONN_SNMP__"
        public static let ipaddr = "__CONN_IPADDR__"
        public static let io = "__CONN_IO__"
        public static let uptime = "__CONN_UPTIME__"
        public static let os = "__CONN_OS__"
        public static let cpuinfo = "__CONN_CPUINFO__"
        public static let end = "__CONN_END__"
    }

    /// 采集命令——按调用方所需**只取该取的段**，省掉不显示的查询与解析。所有子命令都
    /// `2>/dev/null`，缺失的段落留空由解析器容忍。段间用 sentinel 分隔，解析器按标记定位、与顺序无关。
    ///
    /// - 核心段（恒取）：CPU/内存/负载/磁盘/网络/IO/开机时长——仪表盘卡片、状态胶囊、概览图都要。
    /// - `includeExtended`：概览专属的详情段——系统名（os-release）、CPU 型号（cpuinfo）、
    ///   TCP 重传（snmp）、各网卡（ip addr）。仪表盘/其它段不显示，去掉省 4 条命令 + 解析。
    public static func command(includeExtended: Bool = true) -> String {
        var parts = [
            "echo \(Sentinel.stat)", "cat /proc/stat 2>/dev/null",
            "echo \(Sentinel.mem)", "cat /proc/meminfo 2>/dev/null",
            "echo \(Sentinel.load)", "cat /proc/loadavg 2>/dev/null",
            "echo \(Sentinel.disk)", "df -P -k 2>/dev/null",
            "echo \(Sentinel.net)", "cat /proc/net/dev 2>/dev/null",
            "echo \(Sentinel.io)", "cat /proc/diskstats 2>/dev/null",
            "echo \(Sentinel.uptime)", "cat /proc/uptime 2>/dev/null"
        ]
        if includeExtended {
            parts += [
                "echo \(Sentinel.snmp)", "cat /proc/net/snmp 2>/dev/null",
                "echo \(Sentinel.ipaddr)", "ip -o -4 addr show 2>/dev/null",
                "echo \(Sentinel.os)", "cat /etc/os-release 2>/dev/null",
                "echo \(Sentinel.cpuinfo)", "grep -m1 'model name' /proc/cpuinfo 2>/dev/null"
            ]
        }
        parts.append("echo \(Sentinel.end)")
        return parts.joined(separator: "; ")
    }
}
