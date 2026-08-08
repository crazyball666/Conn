# ConnTerm 官网与隐私政策

这是 ConnTerm 的纯静态官网，不需要 Node、构建工具、数据库或后端服务。目录可以直接部署到 Nginx、对象存储或任意静态托管：

```text
docs/website/
├── index.html
├── privacy/index.html
├── support/index.html
└── assets/site.css + site.js
```

## 本地预览

在仓库根目录执行：

```bash
cd docs/website
python3 -m http.server 8080
```

然后打开 `http://127.0.0.1:8080/`。隐私页地址是 `http://127.0.0.1:8080/privacy/`，支持页地址是 `http://127.0.0.1:8080/support/`。

语言选择顺序是 `?lang=zh|en` → 浏览器本地存储 → 浏览器语言。只有 `zh-*` 浏览器默认中文，其他语言默认英文；语言切换不会覆盖页面锚点或当前滚动位置。

## 部署与 App Store Connect

将 `docs/website` 的内容作为站点根目录部署，并确保静态服务器将 `/privacy/` 和 `/support/` 映射到各自的 `index.html`。App Store Connect 的隐私政策和支持字段必须填写部署后可公开访问的 HTTPS 绝对地址，例如：

```text
https://your-domain.example/privacy/
https://your-domain.example/support/
```

请将示例域名替换为你实际控制的域名，并配置有效 TLS 证书。部署后检查：

```bash
curl -I https://your-domain.example/
curl -I https://your-domain.example/privacy/
curl -I https://your-domain.example/support/
curl -I https://your-domain.example/assets/site.css
```

公开部署前，必须在 `support/index.html` 中替换所有 `REPLACE_WITH_*` 联系信息；未替换的支持页不符合 App Store 提交要求。若尚未拥有 App Store 上的产品 URL，首页 CTA 会保持“即将上线/Coming soon”状态，不会产生死链；获得正式链接后，在 `index.html` 的 `data-app-store-url` 填入 `https://apps.apple.com/...`，无需改动脚本。

## 更新隐私政策

`docs/app-store/PRIVACY_POLICY.md` 是中文事实源。修改收集范围、网络行为或安全说明时，必须同步更新该 Markdown 和 `privacy/index.html` 的中英文内容，并同步更新两处“最后更新”日期。网页内容必须与 App Store Connect 隐私问卷和实际工程行为一致。

网站不加载外部字体、图片、分析脚本或追踪服务，便于审核和离线检查。
