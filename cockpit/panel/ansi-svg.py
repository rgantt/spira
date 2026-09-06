#!/usr/bin/env python3
"""ANSI text on stdin -> an SVG screenshot on stdout.

WHY THIS EXISTS. law-ui-changes-need-screenshots says any change to rendered output carries
before/after images, and this pane is rendered output — but it is a TUI on a box with no
image tooling (no PIL, no headless browser, no ImageMagick). A pasted block of text is not a
screenshot: it loses every colour, which is half of what "hard to read" was about. An SVG is
an image, it renders in a browser and in Obsidian on the phone, and it costs no dependency.

    tmux capture-pane -p -e -t <pane> | ./ansi-svg.py > shot.svg

Reads SGR escapes only, which is all the panel emits. Anything else is passed over.
"""
import re, sys, html

# xterm's palette. Index 0-7 normal, 8-15 bright.
PAL = ["#000000","#cd0000","#00cd00","#cdcd00","#0000ee","#cd00cd","#00cdcd","#e5e5e5",
       "#7f7f7f","#ff0000","#00ff00","#ffff00","#5c5cff","#ff00ff","#00ffff","#ffffff"]
DEF_FG, DEF_BG = "#d0d0d0", "#101010"
CW, CH, PAD, FS = 8.4, 17.0, 10.0, 14.0
SGR = re.compile(r"\x1b\[([0-9;]*)m")


def cells(line):
    """-> [(char, fg, bg, bold)]"""
    fg = bg = None
    bold = rev = False
    out, i = [], 0
    for m in SGR.finditer(line):
        for ch in line[i:m.start()]:
            f = PAL[15] if (bold and fg is None) else (fg or DEF_FG)
            b = bg or DEF_BG
            out.append((ch, b if rev else f, f if rev else b, bold))
        i = m.end()
        codes = [int(c or 0) for c in m.group(1).split(";")] or [0]
        k = 0
        while k < len(codes):
            c = codes[k]
            if c == 0:
                fg = bg = None; bold = rev = False
            elif c == 1: bold = True
            elif c in (21, 22): bold = False
            elif c == 7: rev = True
            elif c == 27: rev = False
            elif 30 <= c <= 37: fg = PAL[c - 30]
            elif c == 39: fg = None
            elif 40 <= c <= 47: bg = PAL[c - 40]
            elif c == 49: bg = None
            elif 90 <= c <= 97: fg = PAL[c - 90 + 8]
            elif 100 <= c <= 107: bg = PAL[c - 100 + 8]
            k += 1
    for ch in line[i:]:
        f = PAL[15] if (bold and fg is None) else (fg or DEF_FG)
        b = bg or DEF_BG
        out.append((ch, b if rev else f, f if rev else b, bold))
    return out


def main():
    rows = [cells(l) for l in sys.stdin.read().rstrip("\n").split("\n")]
    cols = max((len(r) for r in rows), default=0)
    w, h = PAD * 2 + cols * CW, PAD * 2 + len(rows) * CH
    o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w:.0f}" height="{h:.0f}" '
         f'viewBox="0 0 {w:.1f} {h:.1f}" font-family="DejaVu Sans Mono,Menlo,monospace" '
         f'font-size="{FS}">',
         f'<rect width="100%" height="100%" fill="{DEF_BG}"/>']
    # Backgrounds first, as runs, so the bands come out as solid bars rather than per-glyph
    # rectangles that hairline-crack between columns.
    for y, row in enumerate(rows):
        x = 0
        while x < len(row):
            bg = row[x][2]
            n = 1
            while x + n < len(row) and row[x + n][2] == bg:
                n += 1
            if bg != DEF_BG:
                o.append(f'<rect x="{PAD + x * CW:.1f}" y="{PAD + y * CH:.1f}" '
                         f'width="{n * CW + 0.5:.1f}" height="{CH:.1f}" fill="{bg}"/>')
            x += n
    for y, row in enumerate(rows):
        x = 0
        while x < len(row):
            fg, bold = row[x][1], row[x][3]
            n = 1
            while x + n < len(row) and (row[x + n][1], row[x + n][3]) == (fg, bold):
                n += 1
            text = "".join(c[0] for c in row[x:x + n])
            if text.strip():
                wt = ' font-weight="bold"' if bold else ""
                o.append(f'<text x="{PAD + x * CW:.1f}" y="{PAD + y * CH + FS * 0.8:.1f}" '
                         f'fill="{fg}"{wt} xml:space="preserve">{html.escape(text)}</text>')
            x += n
    o.append("</svg>")
    print("\n".join(o))


if __name__ == "__main__":
    main()
