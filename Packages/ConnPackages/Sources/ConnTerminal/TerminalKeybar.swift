#if canImport(UIKit)
    import ConnUI
    import SwiftUI

    /// 终端加速键条（原型 S4 / 技术方案 §4.2）。
    ///
    /// 两行键，挂在系统键盘上方（`inputAccessoryView`）。Ctrl 为粘滞键，点亮后
    /// 下一击组合。设计规范 §6：键盘触发动作**不动画**（高频）。
    struct TerminalKeybar: View {
        let ctrlActive: Bool
        let onKey: (TerminalKey) -> Void

        /// 键位取舍：`sudo` / `!!` / `-` 移除——它们只是省几个字符，而系统键盘上本来就有；
        /// 换成 `^C`（终端最高频操作，原先要「Ctrl 再 C」两次点击）、`/`（路径分隔，
        /// iOS 键盘上要切符号面）、`Home` / `End`（系统键盘根本没有）。
        private let row1: [TerminalKey] = [.esc, .tab, .ctrl, .ctrlC, .slash]
        private let row2: [TerminalKey] = [.pipe, .tilde, .home, .end]

        /// 触感的触发源。每次按键自增一次，`sensoryFeedback` 只认「值变了」。
        ///
        /// 用计数器而不是「最后按下的键」：连按同一个键时后者的值不变，触感就不会响。
        @State private var pressCount = 0

        /// 摇杆边长 = 两行键帽 + 行距，正好跨满整个键条高度。
        private static let padSide: CGFloat = 34 * 2 + 6

        var body: some View {
            // 摇杆放右侧：原先四个方向键就在右边，右手拇指够得到；
            // 它跨两行做成方块，拖动行程比单行键帽充裕得多。
            HStack(spacing: 6) {
                VStack(spacing: 6) {
                    keyRow(row1)
                    keyRow(row2)
                }
                TerminalDirectionPad(onKey: onKey)
                    .frame(width: Self.padSide, height: Self.padSide)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Color.connBar)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.connLine).frame(height: 1)
            }
            // 键帽按下给一记轻敲，与系统键盘的击键反馈同量级。
            // 不用 UIImpactFeedbackGenerator：那是 UIKit-only，而本文件虽在
            // `#if canImport(UIKit)` 内，声明式写法与仓库其它处（GroupFilterBar）一致。
            .sensoryFeedback(.impact(weight: .light), trigger: pressCount)
        }

        private func keyRow(_ keys: [TerminalKey]) -> some View {
            HStack(spacing: 6) {
                ForEach(keys) { key in
                    keyCap(key)
                }
            }
        }

        private func keyCap(_ key: TerminalKey) -> some View {
            let isLit = key.isSticky && ctrlActive
            return Button {
                pressCount &+= 1
                onKey(key)
            } label: {
                Text(key.label)
                    .font(.connData(.footnote))
                    .foregroundStyle(isLit ? Color.connAccent : .connInk)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(
                        isLit ? Color.connAccentFill : Color.connKey,
                        in: .rect(cornerRadius: ConnRadius.key, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: ConnRadius.key, style: .continuous)
                            .strokeBorder(isLit ? Color.connAccent : Color.connKeyline, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
    }
#endif
