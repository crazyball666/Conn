#!/usr/bin/env python3
"""Convert a Conn doc markdown file to a self-contained styled HTML file.
Usage: build_doc_html.py <input.md> <page-title>"""
import sys
from pathlib import Path

import markdown
from markdown.extensions.toc import TocExtension, slugify_unicode

SRC = Path(sys.argv[1])
TITLE = sys.argv[2]
DST = SRC.with_suffix(".html")

text = SRC.read_text(encoding="utf-8")
md = markdown.Markdown(
    extensions=["extra", TocExtension(slugify=slugify_unicode, toc_depth="2-3", title=None)],
    output_format="html5",
)
body = md.convert(text)
toc = md.toc
body = body.replace("<table>", '<div class="tw"><table>').replace("</table>", "</table></div>")

CSS = """
:root {
  --bg: #F5F6FB; --panel: #ffffff; --ink: #191D2B; --muted: #5D6478;
  --accent: #4F58E3; --accent-ink: #4F58E3; --accent-soft: #E9EBFB;
  --line: #E3E6F0; --code-bg: #EEF0F8; --shadow: 0 1px 3px rgba(25, 29, 43, .06);
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #0A0C14; --panel: #131624; --ink: #DFE2EE; --muted: #8E95AC;
    --accent: #8B93FF; --accent-ink: #A0A7FF; --accent-soft: #1E2340;
    --line: #262C42; --code-bg: #12151F; --shadow: none;
  }
}
* { box-sizing: border-box; }
html { color-scheme: light dark; }
body { margin: 0; background: var(--bg); color: var(--ink);
  font: 16px/1.75 "PingFang SC", "Hiragino Sans GB", -apple-system, "Helvetica Neue", "Microsoft YaHei", sans-serif;
  -webkit-font-smoothing: antialiased; }
.page { max-width: 920px; margin: 0 auto; padding: 0 28px 96px; }
.brandbar { display: flex; align-items: baseline; gap: 12px;
  padding: 20px 0 14px; border-bottom: 1px solid var(--line); margin-bottom: 40px; }
.brandbar .mark { font-family: "SF Mono", ui-monospace, Menlo, monospace;
  font-weight: 700; font-size: 20px; letter-spacing: .02em; color: var(--accent-ink); }
.brandbar .mark::before { content: "▸ "; color: var(--muted); font-weight: 400; }
.brandbar .kicker { font-family: "SF Mono", ui-monospace, Menlo, monospace;
  font-size: 11px; letter-spacing: .18em; color: var(--muted); text-transform: uppercase; }
h1 { font-family: "Songti SC", "STSong", "PingFang SC", serif;
  font-size: 34px; line-height: 1.35; font-weight: 900; letter-spacing: .01em; margin: 8px 0 24px; text-wrap: balance; }
h2 { font-size: 23px; font-weight: 700; margin: 64px 0 18px;
  padding: 6px 0 10px 14px; border-left: 4px solid var(--accent); border-bottom: 1px solid var(--line); }
h3 { font-size: 18px; font-weight: 700; margin: 40px 0 12px; }
h4 { font-size: 15.5px; font-weight: 700; margin: 30px 0 8px; color: var(--accent-ink); }
p { margin: 12px 0; }
a { color: var(--accent-ink); text-decoration: none; border-bottom: 1px solid transparent; }
a:hover { border-bottom-color: var(--accent-ink); }
hr { border: 0; border-top: 1px solid var(--line); margin: 56px 0; }
ul, ol { padding-left: 26px; } li { margin: 6px 0; }
blockquote { margin: 18px 0; padding: 12px 18px; border-left: 3px solid var(--accent);
  background: var(--accent-soft); border-radius: 0 8px 8px 0; }
blockquote p { margin: 4px 0; }
code { font-family: "SF Mono", ui-monospace, Menlo, monospace; font-size: .86em;
  background: var(--code-bg); border: 1px solid var(--line); border-radius: 4px; padding: 1px 5px; }
pre { background: var(--code-bg); border: 1px solid var(--line); border-radius: 10px;
  padding: 16px 18px; overflow-x: auto; line-height: 1.5; }
pre code { background: none; border: 0; padding: 0; font-size: 12.5px; }
.tw { overflow-x: auto; margin: 18px 0; border: 1px solid var(--line); border-radius: 10px; box-shadow: var(--shadow); }
table { border-collapse: collapse; width: 100%; font-size: 13.5px; line-height: 1.55; font-variant-numeric: tabular-nums; }
thead th { font-family: "SF Mono", ui-monospace, Menlo, monospace; font-size: 12px;
  text-align: left; color: var(--muted); letter-spacing: .04em; background: var(--code-bg);
  border-bottom: 1.5px solid var(--line); padding: 9px 12px; white-space: nowrap; }
tbody td { padding: 8px 12px; border-bottom: 1px solid var(--line); vertical-align: top; background: var(--panel); }
tbody tr:last-child td { border-bottom: 0; }
tbody tr:nth-child(even) td { background: color-mix(in srgb, var(--panel) 60%, var(--bg)); }
td:first-child { font-weight: 600; }
.toc-card { background: var(--panel); border: 1px solid var(--line); border-radius: 12px;
  padding: 18px 26px; margin: 0 0 48px; box-shadow: var(--shadow); }
.toc-card > .toc-title { font-family: "SF Mono", ui-monospace, Menlo, monospace; font-size: 11px;
  letter-spacing: .18em; color: var(--muted); margin-bottom: 8px; }
.toc-card ul { list-style: none; padding-left: 0; margin: 0; column-count: 2; column-gap: 40px; }
.toc-card ul ul { column-count: 1; padding-left: 16px; margin-top: 2px; }
.toc-card li { margin: 3px 0; break-inside: avoid; font-size: 13.5px; }
.footer-note { margin-top: 80px; padding-top: 16px; border-top: 1px solid var(--line);
  font-family: "SF Mono", ui-monospace, Menlo, monospace; font-size: 11px; color: var(--muted); }
@media (max-width: 640px) { .page { padding: 0 16px 64px; } h1 { font-size: 27px; } .toc-card ul { column-count: 1; } }
@media print { :root { --bg: #fff; --panel: #fff; --shadow: none; } body { font-size: 12px; }
  h2 { break-after: avoid; margin-top: 32px; } .tw { border: 0; overflow: visible; }
  table { font-size: 10.5px; } pre { white-space: pre-wrap; } }
"""

html = f"""<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>{TITLE}</title>
<style>{CSS}</style>
</head>
<body>
<div class="page">
  <div class="brandbar"><span class="mark">Conn</span><span class="kicker">{TITLE}</span></div>
  <nav class="toc-card"><div class="toc-title">目录 · Contents</div>{toc}</nav>
  {body}
  <div class="footer-note">Conn · {TITLE} · 2026-07-19 · 本地自包含 HTML，无外部依赖，可直接分享或打印</div>
</div>
</body>
</html>
"""
DST.write_text(html, encoding="utf-8")
print(f"written: {DST} ({DST.stat().st_size} bytes)")
