# ConnTerm 官网与隐私协议设计

日期：2026-08-06  
状态：已确认方向，进入实现

## 目标

为 ConnTerm 提供一套可直接部署的纯静态官网，面向 App Store 审核、用户了解产品和隐私披露。官网不依赖后端、数据库、第三方分析或外部图片服务；部署到 Nginx、对象存储或静态托管即可。

## 视觉方向

采用 A「Quiet Infrastructure」：

- 深色基础设施底色（墨黑、钢蓝）；
- 荧光黄只作为运行状态、关键 CTA 和数据高亮；
- 以细网格、状态线、数据面板和终端符号建立专业气质；
- 大留白和清晰层级，避免营销夸张、赛博霓虹和装饰性噪点；
- 使用系统可用的高质量无衬线字体与等宽字体，确保中英文和移动端可读。

## 信息架构

- /：官网首页
  - Hero：产品定位、核心承诺、App Store CTA；
  - 能力面板：SSH、主机观测、终端与脚本、Docker、远程文件；
  - 工作流：连接 → 观测 → 处置；
  - 隐私承诺：本地优先、Keychain 保存私钥、无账号/无云端；
  - FAQ：支持系统、认证方式、数据去向、后台监控边界；
  - Footer：隐私政策、支持入口、语言切换；支持链接固定指向现有 GitHub Issues。
- /privacy/：隐私政策
  - 中文/英文切换；
  - 更新日期；
  - 数据处理、网络连接、Keychain、应用锁、权限、儿童与政策更新；
  - 明确不收集、不跟踪、不提供 ConnTerm 云服务；
  - 与 App Store Connect 隐私问卷保持一致。
- 不创建空的 `/support/` 占位页；支持入口固定为
  `https://github.com/crazyball666/Conn/issues`，首页 FAQ 通过锚点补充常见问题。

## 文案边界

严格依据当前 App：

- 不写账号系统、云同步、订阅、广告、分析 SDK、后台 24×7 告警；
- 不承诺远程主机由 ConnTerm 提供；
- 强调用户必须拥有或获授权访问目标主机；
- 危险命令和 Docker 操作由用户确认并承担风险；
- 隐私政策中的“无收集/无上传”与当前工程实现一致。

## 技术方案

- 纯静态 HTML、CSS、少量原生 JavaScript；
- 不引入构建工具或运行时依赖；
- 所有文案放在页面内的中英文数据对象中。语言状态优先级为 URL 查询参数
  `?lang=zh|en`，其次为 `localStorage`，最后跟随浏览器语言（仅 `zh-*` 选择中文，
  其余选择英文）。页面 hash 只用于页面锚点（如 `#faq`），语言切换不会覆盖或丢失
  当前 hash，切换后保留当前滚动位置；
- 默认语言跟随浏览器语言：中文浏览器显示中文，其他语言显示英文；
- 页面支持键盘导航、:focus-visible、减少动态效果偏好；
- 移动端断点优先，桌面端扩展为双栏/三栏网格；
- 无外链图片、字体或追踪脚本，离线打开仍能显示完整页面。

## 交付物

- docs/website/index.html
- docs/website/privacy/index.html
- docs/website/assets/site.css
- docs/website/assets/site.js
- docs/website/README.md（部署、域名、App Store Connect 填写说明）
- 与现有 `docs/app-store/PRIVACY_POLICY.md` 同步的中英文网页内容；该 Markdown 继续作为
  中文事实源，网页英文为等义翻译，并补充儿童隐私段落。更新隐私内容时必须同时更新
  Markdown 的“最后更新”日期与网页的发布日期。

## 验收标准

- 首页和隐私页可在无构建步骤下直接打开；
- 中英文切换不会丢失当前页面位置；
- 移动端宽度下没有横向滚动、裁切或遮挡；
- App Store Connect 只能填写部署后的公开 HTTPS 绝对 URL（例如
  `https://example.com/privacy/`），不能填写相对路径。README 必须说明站点根目录映射、
  `/privacy/` 到 `index.html` 的静态路由和 HTTPS 要求，并用 `curl -I` 检查首页、隐私页
  和支持入口均返回 200（支持入口检查 GitHub URL 可达）；
- App Store CTA 使用可配置的 `data-app-store-url`；上线前若尚未有商店链接，按钮必须降级
  为“即将上线/Coming soon”非链接状态，不能留下死链或 `#` 占位；
- 页面不请求外部服务，不包含模拟数据或虚构产品能力；
- git diff --check 通过，并用本地静态服务器检查首页/隐私页状态码和关键文案。
