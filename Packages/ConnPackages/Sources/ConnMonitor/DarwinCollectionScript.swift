import Foundation

/// macOS 单趟指标采集脚本。所有命令均为系统自带、只读命令；缺失字段由解析器结构化降级。
public enum DarwinCollectionScript {
    public enum Sentinel {
        public static let top = "__CONN_DARWIN_TOP__"
        public static let cores = "__CONN_DARWIN_CORES__"
        public static let memsize = "__CONN_DARWIN_MEMSIZE__"
        public static let vmstat = "__CONN_DARWIN_VMSTAT__"
        public static let swap = "__CONN_DARWIN_SWAP__"
        public static let load = "__CONN_DARWIN_LOAD__"
        public static let disk = "__CONN_DARWIN_DISK__"
        public static let net = "__CONN_DARWIN_NET__"
        public static let primaryInterface = "__CONN_DARWIN_PRIMARY_INTERFACE__"
        public static let ifconfig = "__CONN_DARWIN_IFCONFIG__"
        public static let tcp = "__CONN_DARWIN_TCP__"
        public static let ioreg = "__CONN_DARWIN_IOREG__"
        public static let uptime = "__CONN_DARWIN_UPTIME__"
        public static let os = "__CONN_DARWIN_OS__"
        public static let cpuinfo = "__CONN_DARWIN_CPUINFO__"
        public static let end = "__CONN_DARWIN_END__"

        static let all: Set<String> = [
            top, cores, memsize, vmstat, swap, load, disk, net, primaryInterface, ifconfig,
            tcp, ioreg, uptime, os, cpuinfo, end,
        ]
    }

    public static func command(includeExtended: Bool = true) -> String {
        var parts = [
            "export LC_ALL=C LANG=C",
            "echo \(Sentinel.top)", "top -l 1 -n 0 2>/dev/null | grep 'CPU usage'",
            "echo \(Sentinel.cores)", "sysctl -n hw.logicalcpu 2>/dev/null",
            "echo \(Sentinel.memsize)", "sysctl -n hw.memsize 2>/dev/null",
            "echo \(Sentinel.vmstat)", "vm_stat 2>/dev/null",
            "echo \(Sentinel.swap)", "sysctl -n vm.swapusage 2>/dev/null",
            "echo \(Sentinel.load)", "uptime 2>/dev/null",
            "echo \(Sentinel.disk)", "df -P -k 2>/dev/null",
            "echo \(Sentinel.net)", "netstat -ibdn 2>/dev/null",
            "echo \(Sentinel.primaryInterface)",
            "/sbin/route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}'",
            "echo \(Sentinel.ioreg)", "ioreg -r -c IOBlockStorageDriver -l 2>/dev/null",
            "echo \(Sentinel.uptime)",
            uptimeCommand(),
        ]
        if includeExtended {
            parts += [
                "echo \(Sentinel.ifconfig)", "ifconfig 2>/dev/null",
                "echo \(Sentinel.tcp)", "netstat -s -p tcp 2>/dev/null",
                "echo \(Sentinel.os)", "sw_vers 2>/dev/null",
                "echo \(Sentinel.cpuinfo)",
                "sysctl -n machdep.cpu.brand_string 2>/dev/null || sysctl -n hw.model 2>/dev/null",
            ]
        }
        parts.append("echo \(Sentinel.end)")
        return parts.joined(separator: "; ")
    }

    /// `kern.boottime` 的标准输出同时包含 `sec` 与 `usec`。提取表达式必须从
    /// 行首的 `{ sec = …` 锚定，否则贪婪匹配会把 `usec` 误当作启动时间戳。
    static func uptimeCommand(
        bootTimeSource: String = "sysctl -n kern.boottime 2>/dev/null",
        nowSource: String = "date +%s"
    ) -> String {
        "boot=$(\(bootTimeSource) | "
            + "sed -E 's/^\\{[[:space:]]*sec[[:space:]]*=[[:space:]]*([0-9]+).*/\\1/'); "
            + "now=$(\(nowSource)); "
            + "case \"$boot:$now\" in *[!0-9:]*|:*|*:) ;; *) "
            + "[ \"$now\" -ge \"$boot\" ] && echo $((now - boot)) ;; esac"
    }
}
