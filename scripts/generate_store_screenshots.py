#!/usr/bin/env python3
import html
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "store-assets" / "harmonyos" / "screenshots"
LOGO = ROOT / "clash" / "src" / "main" / "resources" / "base" / "media" / "app_logo.png"

W = 1920
H = 1080
FONT = "WenQuanYi Micro Hei, Open Sans, Helvetica, Arial, sans-serif"


def esc(value: str) -> str:
    return html.escape(value, quote=True)


def text(x: int, y: int, value: str, size: int, color: str = "#111827",
         weight: int = 400, anchor: str = "start", opacity: float = 1.0) -> str:
    return (
        f'<text x="{x}" y="{y}" font-family="{FONT}" font-size="{size}" '
        f'font-weight="{weight}" fill="{color}" text-anchor="{anchor}" '
        f'opacity="{opacity}">{esc(value)}</text>'
    )


def multiline(x: int, y: int, lines: list[str], size: int, color: str = "#4b5563",
              gap: int = 40, weight: int = 400) -> str:
    return "\n".join(text(x, y + i * gap, line, size, color, weight) for i, line in enumerate(lines))


def rounded(x: int, y: int, w: int, h: int, r: int, fill: str, stroke: str = "",
            sw: int = 0, opacity: float = 1.0) -> str:
    stroke_attr = f' stroke="{stroke}" stroke-width="{sw}"' if stroke else ""
    return f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill}"{stroke_attr} opacity="{opacity}"/>'


def pill(x: int, y: int, label: str, fill: str, color: str, width: int = 152) -> str:
    return rounded(x, y, width, 42, 21, fill) + text(x + width // 2, y + 28, label, 22, color, 700, "middle")


def phone_shell(inner: str) -> str:
    return f"""
    <g transform="translate(1110 80)">
      <rect x="0" y="0" width="520" height="900" rx="70" fill="#0f172a"/>
      <rect x="18" y="18" width="484" height="864" rx="52" fill="#f8fafc"/>
      <rect x="190" y="34" width="140" height="22" rx="11" fill="#111827" opacity=".85"/>
      <g transform="translate(42 78)">
        {inner}
      </g>
    </g>
    """


def app_header(title: str, subtitle: str = "") -> str:
    subtitle_svg = text(0, 60, subtitle, 24, "#64748b") if subtitle else ""
    return text(0, 28, title, 34, "#0f172a", 800) + subtitle_svg


def nav(active: str) -> str:
    items = [("首页", "Home"), ("代理", "Proxy"), ("订阅", "Sub"), ("设置", "Set")]
    cells = []
    for idx, (label, key) in enumerate(items):
        x = idx * 110 + 16
        active_fill = "#e0f2fe" if key == active else "transparent"
        color = "#0284c7" if key == active else "#64748b"
        cells.append(rounded(x, 0, 74, 54, 18, active_fill))
        cells.append(text(x + 37, 22, ["⌂", "≋", "⇅", "⚙"][idx], 24, color, 700, "middle"))
        cells.append(text(x + 37, 46, label, 16, color, 700, "middle"))
    return f'<g transform="translate(0 726)">{rounded(0, -12, 436, 82, 28, "#ffffff", "#e5e7eb", 1)}{"".join(cells)}</g>'


def home_screen() -> str:
    cards = [
        rounded(0, 95, 436, 190, 28, "#ffffff", "#e5e7eb", 1),
        text(34, 145, "当前节点", 22, "#64748b", 600),
        text(34, 190, "台湾 01", 34, "#0f172a", 800),
        pill(306, 132, "Rule", "#dbeafe", "#2563eb", 92),
        text(34, 244, "Trojan · Chrome TLS 指纹 · fake-ip DNS", 19, "#64748b"),
        '<circle cx="218" cy="420" r="122" fill="#0ea5e9"/>',
        '<circle cx="218" cy="420" r="94" fill="#38bdf8"/>',
        text(218, 408, "ON", 44, "#ffffff", 900, "middle"),
        text(218, 452, "已连接", 24, "#e0f2fe", 700, "middle"),
        rounded(0, 575, 206, 104, 24, "#ffffff", "#e5e7eb", 1),
        text(26, 618, "下载", 20, "#64748b", 600),
        text(26, 657, "42.8 MB", 31, "#0f172a", 800),
        rounded(230, 575, 206, 104, 24, "#ffffff", "#e5e7eb", 1),
        text(256, 618, "上传", 20, "#64748b", 600),
        text(256, 657, "6.4 MB", 31, "#0f172a", 800),
    ]
    return phone_shell(app_header("ClashHM", "稳定的 HarmonyOS NEXT 代理客户端") + "".join(cards) + nav("Home"))


def proxy_screen() -> str:
    rows = []
    data = [
        ("台湾 01", "Trojan", "86 ms", True),
        ("日本 02", "VLESS · h2", "112 ms", False),
        ("香港 03", "VMess · ws", "74 ms", False),
        ("新加坡 04", "Hysteria2", "128 ms", False),
        ("美国 05", "TUIC", "166 ms", False),
    ]
    for i, (name, proto, delay, selected) in enumerate(data):
        y = 116 + i * 108
        fill = "#e0f2fe" if selected else "#ffffff"
        stroke = "#38bdf8" if selected else "#e5e7eb"
        rows.append(rounded(0, y, 436, 88, 24, fill, stroke, 1))
        rows.append(text(28, y + 36, name, 26, "#0f172a", 800))
        rows.append(text(28, y + 66, proto, 18, "#64748b", 600))
        rows.append(text(392, y + 52, delay, 22, "#0284c7" if selected else "#16a34a", 800, "end"))
    return phone_shell(
        app_header("代理", "断开 VPN 也能选择节点和测速")
        + pill(0, 82, "Rule", "#dbeafe", "#2563eb", 90)
        + pill(106, 82, "Global", "#f1f5f9", "#475569", 116)
        + pill(240, 82, "Direct", "#f1f5f9", "#475569", 116)
        + "".join(rows)
        + nav("Proxy")
    )


def subscription_screen() -> str:
    cards = [
        rounded(0, 108, 436, 142, 26, "#ffffff", "#e5e7eb", 1),
        text(28, 154, "主订阅", 28, "#0f172a", 800),
        text(28, 194, "37 个节点 · 刚刚更新", 20, "#64748b", 600),
        pill(302, 146, "启用", "#dcfce7", "#16a34a", 92),
        rounded(0, 278, 436, 142, 26, "#ffffff", "#e5e7eb", 1),
        text(28, 324, "备用订阅", 28, "#0f172a", 800),
        text(28, 364, "自动解析 Clash YAML / 分享链接", 20, "#64748b", 600),
        rounded(0, 464, 436, 170, 28, "#eff6ff", "#bfdbfe", 1),
        text(28, 518, "兼容格式", 24, "#1d4ed8", 800),
        text(28, 564, "ss / vmess / vless / trojan / hy2 / tuic", 20, "#334155", 600),
        text(28, 604, "自动处理分组、规则和 DNS 配置", 20, "#334155", 600),
    ]
    return phone_shell(app_header("订阅", "添加、更新、切换配置更直接") + "".join(cards) + nav("Sub"))


def diagnostics_screen() -> str:
    logs = [
        "native status: running=true engine=shoes",
        "selectedProxy=台湾 01 tlsFingerprint=chrome",
        "routeDebug: chatgpt.com -> proxy",
        "traffic: up=6.4MB down=42.8MB",
        "dns: fake-ip enabled, IPv4 target forced",
    ]
    rows = []
    for i, line in enumerate(logs):
        y = 130 + i * 78
        rows.append(rounded(0, y, 436, 58, 16, "#0f172a"))
        rows.append(text(22, y + 38, line, 18, "#dbeafe", 600))
    return phone_shell(
        app_header("日志", "历史记录、诊断状态和一键复制")
        + pill(0, 82, "复制", "#dbeafe", "#2563eb", 90)
        + pill(108, 82, "清空", "#f1f5f9", "#475569", 90)
        + "".join(rows)
        + nav("Set")
    )


def settings_screen() -> str:
    items = [
        ("TLS 指纹", "Chrome / Rustls 可切换", "Chrome"),
        ("DNS 模式", "fake-ip，降低 DNS 泄露风险", "fake-ip"),
        ("连接模式", "Rule / Global / Direct", "Rule"),
        ("后台运行", "系统 VPN Extension 承载流量", "VPN"),
    ]
    rows = []
    for i, (title, sub, value) in enumerate(items):
        y = 112 + i * 118
        rows.append(rounded(0, y, 436, 92, 24, "#ffffff", "#e5e7eb", 1))
        rows.append(text(26, y + 38, title, 24, "#0f172a", 800))
        rows.append(text(26, y + 68, sub, 18, "#64748b", 600))
        rows.append(pill(304, y + 25, value, "#e0f2fe", "#0284c7", 92))
    return phone_shell(app_header("设置", "关键参数清晰可控") + "".join(rows) + nav("Set"))


def background(title: str, subtitle: list[str], badge: str, screen: str) -> str:
    logo_uri = LOGO.as_uri()
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#f8fafc"/>
      <stop offset=".48" stop-color="#e0f2fe"/>
      <stop offset="1" stop-color="#ecfeff"/>
    </linearGradient>
    <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="32" stdDeviation="32" flood-color="#0f172a" flood-opacity=".20"/>
    </filter>
  </defs>
  <rect width="{W}" height="{H}" fill="url(#bg)"/>
  <circle cx="1680" cy="130" r="210" fill="#bae6fd" opacity=".45"/>
  <circle cx="360" cy="930" r="250" fill="#99f6e4" opacity=".38"/>
  <g transform="translate(170 166)">
    <image href="{logo_uri}" x="0" y="0" width="96" height="96" rx="24"/>
    {text(124, 62, "ClashHM", 42, "#0f172a", 900)}
    {pill(0, 132, badge, "#0f172a", "#ffffff", 270)}
    {text(0, 270, title, 70, "#0f172a", 900)}
    {multiline(0, 338, subtitle, 32, "#334155", 48, 600)}
  </g>
  <g filter="url(#shadow)">
    {screen}
  </g>
</svg>"""


SLIDES = [
    ("01-home", "连接状态一屏掌握", ["当前节点、连接模式、上下行流量", "都在首页直接呈现"], "HarmonyOS NEXT VPN", home_screen()),
    ("02-proxy", "先选节点，再连接", ["断开状态也能浏览节点、切换分组", "并执行延迟测试"], "Proxy Selection", proxy_screen()),
    ("03-subscription", "订阅管理更省心", ["支持 Clash YAML 和多种分享链接", "自动解析节点、分组与规则"], "Subscription", subscription_screen()),
    ("04-diagnostics", "诊断信息可追踪", ["连接日志保留历史记录", "关键状态可一键复制排查"], "Diagnostics", diagnostics_screen()),
    ("05-settings", "核心参数可配置", ["Chrome TLS 指纹、fake-ip DNS", "Rule / Global / Direct 灵活切换"], "Native Core", settings_screen()),
]


def recommendation_horizontal() -> str:
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="396" height="223" viewBox="0 0 396 223">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#f8fafc"/>
      <stop offset=".58" stop-color="#dbeafe"/>
      <stop offset="1" stop-color="#ccfbf1"/>
    </linearGradient>
  </defs>
  <rect width="396" height="223" rx="22" fill="url(#bg)"/>
  <circle cx="344" cy="42" r="56" fill="#bae6fd" opacity=".65"/>
  <circle cx="64" cy="202" r="68" fill="#99f6e4" opacity=".58"/>
  <image href="{LOGO.as_uri()}" x="26" y="28" width="46" height="46"/>
  {text(84, 58, "ClashHM", 22, "#0f172a", 900)}
  {text(26, 112, "HarmonyOS NEXT", 20, "#0f172a", 900)}
  {text(26, 140, "原生 VPN 代理客户端", 22, "#0f172a", 900)}
  {text(26, 174, "订阅 · 节点 · DNS · TLS 指纹", 14, "#334155", 700)}
  <g transform="translate(260 48)">
    <rect x="0" y="0" width="94" height="156" rx="18" fill="#0f172a"/>
    <rect x="5" y="5" width="84" height="146" rx="14" fill="#f8fafc"/>
    <circle cx="47" cy="74" r="30" fill="#0ea5e9"/>
    {text(47, 68, "ON", 15, "#ffffff", 900, "middle")}
    {text(47, 87, "已连接", 8, "#dff7ff", 700, "middle")}
    <rect x="16" y="114" width="28" height="18" rx="5" fill="#e0f2fe"/>
    <rect x="50" y="114" width="28" height="18" rx="5" fill="#e0f2fe"/>
  </g>
</svg>"""


def recommendation_vertical() -> str:
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="414" height="573" viewBox="0 0 414 573">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#f8fafc"/>
      <stop offset=".55" stop-color="#e0f2fe"/>
      <stop offset="1" stop-color="#ecfeff"/>
    </linearGradient>
    <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="14" stdDeviation="14" flood-color="#0f172a" flood-opacity=".18"/>
    </filter>
  </defs>
  <rect width="414" height="573" rx="32" fill="url(#bg)"/>
  <circle cx="340" cy="82" r="86" fill="#bae6fd" opacity=".58"/>
  <circle cx="74" cy="500" r="110" fill="#99f6e4" opacity=".52"/>
  <image href="{LOGO.as_uri()}" x="40" y="42" width="70" height="70"/>
  {text(126, 82, "ClashHM", 28, "#0f172a", 900)}
  {text(40, 162, "HarmonyOS NEXT", 24, "#0f172a", 900)}
  {text(40, 198, "原生 VPN 代理客户端", 30, "#0f172a", 900)}
  {text(40, 236, "订阅、节点、规则和 DNS", 18, "#334155", 700)}
  {text(40, 262, "一屏掌握，稳定连接", 18, "#334155", 700)}
  <g transform="translate(114 302)" filter="url(#shadow)">
    <rect x="0" y="0" width="186" height="236" rx="28" fill="#0f172a"/>
    <rect x="8" y="8" width="170" height="220" rx="22" fill="#f8fafc"/>
    <rect x="68" y="18" width="50" height="8" rx="4" fill="#111827" opacity=".85"/>
    <text x="24" y="58" font-family="{FONT}" font-size="14" font-weight="900" fill="#0f172a">ClashHM</text>
    <text x="24" y="82" font-family="{FONT}" font-size="10" font-weight="700" fill="#64748b">台湾 01 · Rule</text>
    <circle cx="93" cy="124" r="44" fill="#0ea5e9"/>
    <text x="93" y="119" font-family="{FONT}" font-size="19" font-weight="900" fill="#ffffff" text-anchor="middle">ON</text>
    <text x="93" y="140" font-family="{FONT}" font-size="10" font-weight="700" fill="#dff7ff" text-anchor="middle">已连接</text>
    <rect x="24" y="180" width="62" height="30" rx="9" fill="#e0f2fe"/>
    <rect x="100" y="180" width="62" height="30" rx="9" fill="#e0f2fe"/>
  </g>
</svg>"""


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for slug, title, subtitle, badge, screen in SLIDES:
        svg = OUT / f"{slug}.svg"
        png = OUT / f"{slug}.png"
        svg.write_text(background(title, subtitle, badge, screen), encoding="utf-8")
        subprocess.run([
            "magick", str(svg), "-strip", "-quality", "92", str(png),
        ], check=True)
        svg.unlink()
    recommendations = [
        ("recommend-396x223", recommendation_horizontal()),
        ("recommend-414x573", recommendation_vertical()),
    ]
    for slug, svg_text in recommendations:
        svg = OUT / f"{slug}.svg"
        png = OUT / f"{slug}.png"
        svg.write_text(svg_text, encoding="utf-8")
        subprocess.run([
            "magick", str(svg), "-strip", "-quality", "92", str(png),
        ], check=True)
        svg.unlink()
    print(f"Generated {len(SLIDES)} screenshots and 2 recommendation images in {OUT}")


if __name__ == "__main__":
    main()
