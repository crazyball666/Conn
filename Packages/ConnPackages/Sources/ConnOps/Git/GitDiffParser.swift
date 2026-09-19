import Foundation

/// 解析 `git diff` 输出为结构化的 `GitFileDiff`。
///
/// 遵循 Unified Diff 格式：
/// ```diff
/// diff --git a/file.swift b/file.swift
/// index 1234567..89abcdef 100644
/// --- a/file.swift
/// +++ b/file.swift
/// @@ -10,4 +10,6 @@ func test() {
///  context line
/// -old line
/// +new line 1
/// +new line 2
/// ```
public enum GitDiffParser {
    public static func parse(rawDiff: String, filePath: String) -> GitFileDiff {
        let lines = rawDiff.components(separatedBy: .newlines)
        var hunks: [GitDiffHunk] = []
        var currentHunkHeader: String?
        var currentHunkLines: [GitDiffLine] = []
        var additions = 0
        var deletions = 0

        var oldLine = 0
        var newLine = 0
        var lineID = 0

        func finishHunk() {
            guard let header = currentHunkHeader else { return }
            hunks.append(GitDiffHunk(header: header, lines: currentHunkLines))
            currentHunkHeader = nil
            currentHunkLines.removeAll()
        }

        for rawLine in lines {
            if rawLine.hasPrefix("@@") {
                finishHunk()
                currentHunkHeader = rawLine
                let (o, n) = parseHunkHeader(rawLine)
                oldLine = o
                newLine = n
                continue
            }

            guard currentHunkHeader != nil else {
                // @@ 出现前的 diff header 忽略
                continue
            }

            guard let firstChar = rawLine.first else {
                // 空行按上下文处理
                currentHunkLines.append(GitDiffLine(
                    id: lineID,
                    type: .context,
                    text: "",
                    oldLineNumber: oldLine,
                    newLineNumber: newLine
                ))
                lineID += 1
                oldLine += 1
                newLine += 1
                continue
            }

            let text = String(rawLine.dropFirst())

            switch firstChar {
            case "+":
                additions += 1
                currentHunkLines.append(GitDiffLine(
                    id: lineID,
                    type: .addition,
                    text: text,
                    oldLineNumber: nil,
                    newLineNumber: newLine
                ))
                lineID += 1
                newLine += 1
            case "-":
                deletions += 1
                currentHunkLines.append(GitDiffLine(
                    id: lineID,
                    type: .deletion,
                    text: text,
                    oldLineNumber: oldLine,
                    newLineNumber: nil
                ))
                lineID += 1
                oldLine += 1
            case " ":
                currentHunkLines.append(GitDiffLine(
                    id: lineID,
                    type: .context,
                    text: text,
                    oldLineNumber: oldLine,
                    newLineNumber: newLine
                ))
                lineID += 1
                oldLine += 1
                newLine += 1
            case "\\":
                // e.g. "\ No newline at end of file"
                currentHunkLines.append(GitDiffLine(
                    id: lineID,
                    type: .header,
                    text: rawLine,
                    oldLineNumber: nil,
                    newLineNumber: nil
                ))
                lineID += 1
            default:
                break
            }
        }

        finishHunk()

        return GitFileDiff(
            filePath: filePath,
            hunks: hunks,
            additions: additions,
            deletions: deletions
        )
    }

    /// 解析 `@@ -10,4 +12,6 @@` 提取初始行号
    private static func parseHunkHeader(_ header: String) -> (oldStart: Int, newStart: Int) {
        let parts = header.components(separatedBy: " ")
        var oldStart = 1
        var newStart = 1

        for part in parts {
            if part.hasPrefix("-") {
                let rangeStr = String(part.dropFirst())
                let nums = rangeStr.components(separatedBy: ",")
                if let s = Int(nums[0]) { oldStart = s }
            } else if part.hasPrefix("+") {
                let rangeStr = String(part.dropFirst())
                let nums = rangeStr.components(separatedBy: ",")
                if let s = Int(nums[0]) { newStart = s }
            }
        }

        return (oldStart, newStart)
    }
}
