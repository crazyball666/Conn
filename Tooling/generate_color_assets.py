#!/usr/bin/env python3
"""从单一令牌表生成 ConnUI 的 Assets.xcassets 色板。

令牌真值来源：docs/prototypes/index.html 的 CSS 变量（设计规范 §0 裁决规则：
原型 CSS 实际值 > 规范文字表述），外加 v1.3 补齐的结构性/终端/填充令牌。

用法：
    python3 Tooling/generate_color_assets.py

输出：Packages/ConnPackages/Sources/ConnUI/Resources/Media.xcassets/
"""

import json
import os
import shutil

# (令牌名, 深色, 浅色) —— 浅色为 None 表示两主题恒定
TOKENS = [
    # —— 基础色板（原型 CSS L10-L26）——
    ("connBg",          "#0A0C14", "#F2F3F8"),
    ("connSurface",     "#141826", "#FFFFFF"),
    ("connElevated",    "#1A1F33", "#FFFFFF"),
    ("connLine",        "#1F2437", "#E6E8F1"),
    ("connInk",         "#EDEFF7", "#17181F"),
    ("connMuted",       "#8E95AC", "#6B7183"),
    ("connAccent",      "#8B93FF", "#4F58E3"),
    ("connAccentDeep",  "#5A63F2", "#4046C8"),
    ("connGood",        "#32D74B", "#1FA24A"),
    ("connWarn",        "#FFD60A", "#B58500"),
    ("connCrit",        "#FF5C5C", "#E5484D"),
    ("connInfo",        "#5CD9FF", "#0087C8"),
    ("connDisk",        "#F7A45C", "#D97B2A"),
    # 终端画布两主题恒为深色（行业惯例，设计规范 §2）
    ("connTermBg",      "#07090F", None),

    # —— 结构性令牌（设计规范 v1.3 补；原型 L15 原为自引用循环）——
    ("connBar",         "#151A2B", "#ECEEF5"),
    ("connKey",         "#1E2438", "#FFFFFF"),
    ("connKeyline",     "#2C3350", "#D5D9E6"),
    ("connTrack",       "#232942", "#E4E7F0"),
    ("connDim",         "#5C6379", "#9AA1B5"),

    # —— 终端与日志专属色（恒定，因终端画布恒为深色）——
    ("connTermFg",      "#C6CCE0", None),
    ("connTermDim",     "#6A7288", None),
    ("connLogFg",       "#B6BDD0", None),
    ("connLogErrFg",    "#FFB4AE", None),
    ("connLogWarnFg",   "#F2DF8E", None),
    ("connCodeLineNo",  "#4A5170", None),
    ("connCodeComment", "#5E6680", None),
]

# (令牌名, 基色, alpha) —— 状态半透明填充，两主题同值
# 注意基色与状态色令牌不同：原型用的是 iOS 系统色，此处如实还原
FILLS = [
    ("connGoodFill",   "#30D158", 0.14),
    ("connWarnFill",   "#FFD60A", 0.14),
    ("connCritFill",   "#FF453A", 0.16),
    ("connInfoFill",   "#64D2FF", 0.14),
    ("connAccentFill", "#8B93FF", 0.15),
    ("connOffFill",    "#8CA096", 0.14),
]

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(
    ROOT, "Packages/ConnPackages/Sources/ConnUI/Resources/Media.xcassets"
)


def components(hex_value: str, alpha: float = 1.0) -> dict:
    """把 #RRGGBB 转成 Asset Catalog 的 sRGB 分量表示。"""
    raw = hex_value.lstrip("#")
    return {
        "alpha": f"{alpha:.3f}",
        "red": f"0x{raw[0:2].upper()}",
        "green": f"0x{raw[2:4].upper()}",
        "blue": f"0x{raw[4:6].upper()}",
    }


def color_entry(hex_value: str, alpha: float = 1.0, appearance: str = None) -> dict:
    entry = {
        "idiom": "universal",
        "color": {
            "color-space": "srgb",
            "components": components(hex_value, alpha),
        },
    }
    if appearance:
        entry["appearances"] = [
            {"appearance": "luminosity", "value": appearance}
        ]
    return entry


def write_colorset(name: str, dark: str, light: str | None, alpha: float = 1.0):
    path = os.path.join(ASSETS, f"{name}.colorset")
    os.makedirs(path, exist_ok=True)

    if light is None:
        # 两主题恒定：只出一档 universal
        colors = [color_entry(dark, alpha)]
    else:
        # 第一档为 Any（浅色作为基准），第二档标记 dark
        colors = [
            color_entry(light, alpha),
            color_entry(dark, alpha, appearance="dark"),
        ]

    contents = {
        "colors": colors,
        "info": {"author": "xcode", "version": 1},
    }
    with open(os.path.join(path, "Contents.json"), "w") as handle:
        json.dump(contents, handle, indent=2)
        handle.write("\n")


def main():
    if os.path.exists(ASSETS):
        shutil.rmtree(ASSETS)
    os.makedirs(ASSETS)

    with open(os.path.join(ASSETS, "Contents.json"), "w") as handle:
        json.dump({"info": {"author": "xcode", "version": 1}}, handle, indent=2)
        handle.write("\n")

    for name, dark, light in TOKENS:
        write_colorset(name, dark, light)
    for name, base, alpha in FILLS:
        write_colorset(name, base, None, alpha)

    total = len(TOKENS) + len(FILLS)
    print(f"已生成 {total} 个 Color Set → {ASSETS}")
    print("  基础与结构令牌:", len(TOKENS))
    print("  状态填充令牌:", len(FILLS))


if __name__ == "__main__":
    main()
