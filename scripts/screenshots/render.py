#!/usr/bin/env python3
"""Render a `tmux capture-pane -p -e` dump (text + SGR escapes) as an SVG
terminal window. Every character sits in a fixed cell (textLength per run), and
box-drawing lines are drawn as strokes, so columns line up whatever font the
viewer has.

    render.py CAPTURE OUT.svg "window title"
"""
import html, re, sys

CW, LH, FS = 8.4, 18.0, 14.0          # cell width, line height, font size (px)
PAD_X, PAD_TOP, PAD_BOTTOM, BAR = 18, 14, 16, 34
BG, FG, BAR_BG, BORDER = "#0b0e0c", "#cfd8cf", "#151a16", "#243027"
BOLD_FG, DIM_FG = "#eef5ee", "#77847a"
# ANSI 0-15 onto the docs' dark terminal palette.
ANSI = ["#1b211d", "#ff7b72", "#7ee787", "#e3b341", "#6cc3f5", "#d2a8ff", "#6cc3f5", "#cfd8cf",
        "#77847a", "#ff7b72", "#7ee787", "#e3b341", "#6cc3f5", "#c488ff", "#6cc3f5", "#eef5ee"]
SEL_BG = "#1d2a21"                     # ANSI bg 0 / 8: fzf's current-line band
FONT = "ui-monospace, SFMono-Regular, Menlo, Consolas, 'DejaVu Sans Mono', 'Liberation Mono', monospace"


def xterm256(n):
    if n < 16:
        return ANSI[n]
    if n < 232:
        n -= 16
        steps = [0, 95, 135, 175, 215, 255]
        return "#%02x%02x%02x" % (steps[n // 36], steps[n // 6 % 6], steps[n % 6])
    v = 8 + (n - 232) * 10
    return "#%02x%02x%02x" % (v, v, v)


def parse(text):
    """-> rows of cells: (char, fg, bg, bold, dim)."""
    rows = []
    for line in text.rstrip("\n").split("\n"):
        st = dict(fg=None, bg=None, bold=False, dim=False, rev=False)
        cells = []
        for tok in re.split(r"(\x1b\[[0-9;:]*m)", line):
            if tok.startswith("\x1b["):
                codes = [int(c) if c else 0 for c in re.split("[;:]", tok[2:-1])] or [0]
                i = 0
                while i < len(codes):
                    c = codes[i]
                    if c == 0:
                        st = dict(fg=None, bg=None, bold=False, dim=False, rev=False)
                    elif c == 1: st["bold"] = True
                    elif c == 2: st["dim"] = True
                    elif c == 22: st["bold"] = st["dim"] = False
                    elif c == 7: st["rev"] = True
                    elif c == 27: st["rev"] = False
                    elif 30 <= c <= 37: st["fg"] = ANSI[c - 30]
                    elif 90 <= c <= 97: st["fg"] = ANSI[c - 82]
                    elif c == 39: st["fg"] = None
                    elif 40 <= c <= 47: st["bg"] = SEL_BG if c == 40 else ANSI[c - 40]
                    elif 100 <= c <= 107: st["bg"] = SEL_BG if c == 100 else ANSI[c - 92]
                    elif c == 49: st["bg"] = None
                    elif c in (38, 48) and i + 1 < len(codes):
                        key = "fg" if c == 38 else "bg"
                        if codes[i + 1] == 5:
                            n = codes[i + 2]
                            st[key] = SEL_BG if key == "bg" and n in (0, 8) else xterm256(n)
                            i += 2
                        elif codes[i + 1] == 2:
                            st[key] = "#%02x%02x%02x" % tuple(codes[i + 2:i + 5]); i += 4
                    i += 1
                continue
            for ch in tok:
                fg, bg = st["fg"], st["bg"]
                if st["rev"]:
                    fg, bg = (bg or BG), (fg or FG)
                if fg is None:
                    fg = DIM_FG if st["dim"] else (BOLD_FG if st["bold"] else FG)
                cells.append((ch, fg, bg, st["bold"], st["dim"]))
        rows.append(cells)
    return rows


VERT, HORIZ = set("│┃║"), set("─━═")
CORNERS = {"┌": (0, 1, 0, 1), "┐": (1, 0, 0, 1), "└": (0, 1, 1, 0), "┘": (1, 0, 1, 0),
           "├": (0, 1, 1, 1), "┤": (1, 0, 1, 1), "┬": (1, 1, 0, 1), "┴": (1, 1, 1, 0), "┼": (1, 1, 1, 1),
           "╭": (0, 1, 0, 1), "╮": (1, 0, 0, 1), "╰": (0, 1, 1, 0), "╯": (1, 0, 1, 0)}


def render(rows, title, cols=None):
    cols = cols or max((len(r) for r in rows), default=0)
    w = round(PAD_X * 2 + cols * CW)
    h = round(BAR + PAD_TOP + len(rows) * LH + PAD_BOTTOM)
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" '
           f'role="img" aria-label="{html.escape(title)}">',
           f'<title>{html.escape(title)}</title>',
           f'<rect x="0.5" y="0.5" width="{w - 1}" height="{h - 1}" rx="10" fill="{BG}" stroke="{BORDER}"/>',
           f'<path d="M0.5 {BAR} V10.5 a10 10 0 0 1 10 -10 H{w - 10.5} a10 10 0 0 1 10 10 V{BAR} Z" fill="{BAR_BG}"/>',
           f'<line x1="0.5" y1="{BAR}" x2="{w - 0.5}" y2="{BAR}" stroke="{BORDER}"/>']
    for i, c in enumerate(("#ff5f57", "#febc2e", "#28c840")):
        out.append(f'<circle cx="{20 + i * 20}" cy="{BAR / 2}" r="6" fill="{c}"/>')
    out.append(f'<text x="{w / 2}" y="{BAR / 2 + 4.5}" fill="{DIM_FG}" font-family="{FONT}" '
               f'font-size="13" text-anchor="middle">{html.escape(title)}</text>')
    top = BAR + PAD_TOP
    strokes, texts, fills = [], [], []
    for r, cells in enumerate(rows):
        y0 = top + r * LH
        # backgrounds, merged per run
        c = 0
        while c < len(cells):
            bg = cells[c][2]
            e = c
            while e < len(cells) and cells[e][2] == bg:
                e += 1
            if bg:
                fills.append(f'<rect x="{PAD_X + c * CW:.1f}" y="{y0:.1f}" width="{(e - c) * CW:.1f}" '
                             f'height="{LH}" fill="{bg}"/>')
            c = e
        # glyphs: box drawing as strokes, block as a rect, the rest as text runs
        c = 0
        while c < len(cells):
            ch, fg, _, bold, dim = cells[c]
            x0, xm, ym = PAD_X + c * CW, PAD_X + (c + 0.5) * CW, y0 + LH / 2
            if ch in VERT:
                strokes.append((fg, f"M{xm:.1f} {y0:.1f}V{y0 + LH:.1f}"))
            elif ch in HORIZ:
                strokes.append((fg, f"M{x0:.1f} {ym:.1f}H{x0 + CW:.1f}"))
            elif ch in CORNERS:
                left, right, up, down = CORNERS[ch]
                d = ""
                if left: d += f"M{x0:.1f} {ym:.1f}H{xm:.1f}"
                if right: d += f"M{xm:.1f} {ym:.1f}H{x0 + CW:.1f}"
                if up: d += f"M{xm:.1f} {y0:.1f}V{ym:.1f}"
                if down: d += f"M{xm:.1f} {ym:.1f}V{y0 + LH:.1f}"
                strokes.append((fg, d))
            elif ch == "▌":
                fills.append(f'<rect x="{x0:.1f}" y="{y0:.1f}" width="{CW / 2:.1f}" height="{LH}" fill="{fg}"/>')
            elif ch != " ":
                e = c
                while (e < len(cells) and cells[e][1:] == cells[c][1:]
                       and cells[e][0] not in VERT | HORIZ | set(CORNERS) | {"▌"}):
                    e += 1
                run = "".join(x[0] for x in cells[c:e]).rstrip()
                n = len(run)
                weight = ' font-weight="bold"' if bold else ""
                texts.append(f'<text x="{x0:.1f}" y="{y0 + LH * 0.72:.1f}" fill="{fg}"{weight} '
                             f'textLength="{n * CW:.1f}" lengthAdjust="spacingAndGlyphs">'
                             f'{html.escape(run)}</text>')
                c = e
                continue
            c += 1
    out += fills
    by_color = {}
    for color, d in strokes:
        by_color.setdefault(color, []).append(d)
    for color, ds in by_color.items():
        out.append(f'<path d="{"".join(ds)}" stroke="{color}" stroke-width="1.2" fill="none"/>')
    out.append(f'<g font-family="{FONT}" font-size="{FS}" xml:space="preserve">')
    out += texts
    out.append("</g></svg>")
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    src, dst, title = sys.argv[1:4]
    cols = int(sys.argv[4]) if len(sys.argv) > 4 else None
    with open(src, encoding="utf-8") as fh:
        rows = parse(fh.read())
    while rows and not "".join(c[0] for c in rows[-1]).strip():
        rows.pop()
    while rows and not "".join(c[0] for c in rows[0]).strip():
        rows.pop(0)
    with open(dst, "w", encoding="utf-8") as fh:
        fh.write(render(rows, title, cols))
