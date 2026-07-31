import Foundation

/// 进程页专用采集命令。只读取进程列表，不附带主机基础指标。
public enum ProcessCollectionScript {
    public enum Sentinel {
        public static let ps = "__CONN_PROCESS_PS__"
        public static let top = "__CONN_PROCESS_TOP__"
        public static let end = "__CONN_PROCESS_END__"
    }

    public static let command = [
        "echo \(Sentinel.ps)",
        "ps -eo pid,ppid,user,pcpu,pmem,rss,nlwp,stat,etimes,args --sort=-pcpu 2>/dev/null | head -n 500",
        "echo \(Sentinel.top)",
        "top -bn1 2>/dev/null | head -n 24",
        "echo \(Sentinel.end)"
    ].joined(separator: "; ")
}
