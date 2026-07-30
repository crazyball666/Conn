/// 将一个值编码为恰好一个 POSIX shell 参数。
///
/// 远端命令仍由 shell 执行，因此动态值必须逐个编码；不能接受或拼接整段 shell 命令。
public enum ShellArgument {
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
