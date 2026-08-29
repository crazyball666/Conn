import ConnUI
import SwiftUI

/// 第三方依赖许可声明。内容随 App 一起发布，避免用户必须联网才能查看许可文本。
struct OpenSourceLicensesView: View {
    var body: some View {
        ScrollView {
            Text(licenseText)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(ConnSpacing.page)
        }
        .background(Color.connBg.ignoresSafeArea())
        .navigationTitle(L("开源许可"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private let licenseText = """
Conn includes the following open-source software:

GRDB.swift 7.11.1 — MIT
https://github.com/groue/GRDB.swift
Citadel 0.12.1 — MIT
https://github.com/orlandos-nl/Citadel
SwiftTerm 1.19.0 — MIT
https://github.com/migueldeicaza/SwiftTerm
Highlightr 2.3.0 — MIT
https://github.com/raspu/Highlightr
BigInt 5.7.0 — MIT
https://github.com/attaswift/BigInt

swift-crypto 3.15.1, swift-nio 2.101.3, swift-nio-ssh 0.3.6,
swift-atomics 1.3.1, swift-collections 1.6.0, swift-log 1.14.0,
swift-system 1.7.4, swift-asn1 1.7.1, and swift-argument-parser 1.8.2
are distributed under the Apache License, Version 2.0.
https://www.apache.org/licenses/LICENSE-2.0

MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

Apache License, Version 2.0

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
"""
