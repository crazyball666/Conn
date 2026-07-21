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

        private let row1: [TerminalKey] = [.esc, .tab, .ctrl, .up, .down, .left, .right]
        private let row2: [TerminalKey] = [.pipe, .dash, .tilde, .sudo, .bangBang]

        var body: some View {
            VStack(spacing: 6) {
                keyRow(row1)
                keyRow(row2)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Color.connBar)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.connLine).frame(height: 1)
            }
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
