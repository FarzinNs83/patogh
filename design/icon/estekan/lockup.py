# Hand-built monoline wordmarks (پاتوق / patogh) and lockups with the estekan mark.
# Letters are centreline strokes (width 12, round caps); baseline y=160.
from build import WALL, TEA, SAUCER, BUBBLE, INK, TEA_C, CREAM, TEA_D

W = 12
def dots(*pts, r=8): return "".join(f"M{x-r} {y}a{r} {r} 0 1 0 {2*r} 0a{r} {r} 0 1 0 {-2*r} 0Z" for x, y in pts)

FA_STROKE = " ".join([
    "M300 136V148A12 12 0 0 1 288 160H252A12 12 0 0 1 240 148V88",   # پ tooth + baseline + ا
    # ت tooth, baseline into و, loop round the head, then out of its bottom into the tail
    "M216 136V148A12 12 0 0 1 204 160H164A14 14 0 1 0 164 132A14 14 0 1 0 164 160Q164 198 126 202",
    "M88 146m-14 0a14 14 0 1 0 28 0a14 14 0 1 0 -28 0",              # ق head
    "M102 146V170A32 32 0 0 1 38 170V152",                           # ق bowl
])
FA_DOTS = dots((268, 182), (288, 182), (278, 202), (205, 116), (227, 116), (77, 112), (99, 112))
FA_BOX = (32, 82, 306, 210)

EN_STROKE = " ".join([
    "M20 116V200", "M42 138m-22 0a22 22 0 1 0 44 0a22 22 0 1 0 -44 0",      # p
    "M110 138m-22 0a22 22 0 1 0 44 0a22 22 0 1 0 -44 0", "M132 116V160",   # a
    "M168 100V160", "M156 116H180",                                         # t
    "M226 138m-22 0a22 22 0 1 0 44 0a22 22 0 1 0 -44 0",                    # o
    "M294 138m-22 0a22 22 0 1 0 44 0a22 22 0 1 0 -44 0", "M316 116V184A20 20 0 0 1 276 184",  # g
    "M340 92V160", "M340 138A22 22 0 0 1 384 138V160",                      # h
])
EN_BOX = (14, 86, 390, 210)

def text(stroke, dts, color, tf):
    s = f'<path d="{stroke}" fill="none" stroke="{color}" stroke-width="{W}" stroke-linecap="round" stroke-linejoin="round"/>'
    if dts: s += f'<path d="{dts}" fill="{color}"/>'
    return f'<g transform="{tf}">{s}</g>'

def mark(wall, tea, tf):
    return (f'<g transform="{tf}"><path fill="{wall}" fill-rule="evenodd" d="{WALL}"/><path fill="{tea}" d="{TEA}"/>'
            f'<path fill="{wall}" d="{SAUCER}"/><path fill="{wall}" d="{BUBBLE}"/></g>')

def svg(vb, body): return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vb}">{body}</svg>\n'

def lockups(ink, wall, tea, suffix):
    out = {}
    # English, mark left; x-height centre (138) aligned with glass centre (~150)
    gap = 40
    s = 1.0
    tx = 216 + gap - EN_BOX[0]*s
    out[f"lockup-en{suffix}.svg"] = svg(f"36 0 {tx + EN_BOX[2]*s + 20 - 36:.0f} 256", mark(wall, tea, "") + text(EN_STROKE, "", ink, f"translate({tx} {150 - 138*s}) scale({s})"))
    # Persian, mark right (RTL reading order)
    s = 1.05
    tx = 40 - FA_BOX[0]*s
    right = tx + FA_BOX[2]*s
    out[f"lockup-fa{suffix}.svg"] = svg(f"20 0 {right + gap + 176 + 20 - 20:.0f} 256", text(FA_STROKE, FA_DOTS, ink, f"translate({tx} {150 - 146*s}) scale({s})") + mark(wall, tea, f"translate({right + gap - 40} 0)"))
    # Stacked: mark, پاتوق, patogh
    fa_s, en_s = 0.9, 0.5
    fa_w, en_w = (FA_BOX[2]-FA_BOX[0])*fa_s, (EN_BOX[2]-EN_BOX[0])*en_s
    body = (mark(wall, tea, "translate(72 0)")
            + text(FA_STROKE, FA_DOTS, ink, f"translate({200 - fa_w/2 - FA_BOX[0]*fa_s} {262 - FA_BOX[1]*fa_s}) scale({fa_s})")
            + text(EN_STROKE, "", ink, f"translate({200 - en_w/2 - EN_BOX[0]*en_s} {400 - EN_BOX[1]*en_s}) scale({en_s})"))
    out[f"lockup-stacked{suffix}.svg"] = svg("20 0 360 480", body)
    return out

files = {**lockups(INK, INK, TEA_C, ""), **lockups(CREAM, CREAM, TEA_D, "-on-dark")}
files["wordmark-fa.svg"] = svg("26 76 286 140", text(FA_STROKE, FA_DOTS, INK, ""))
files["wordmark-en.svg"] = svg("8 80 388 136", text(EN_STROKE, "", INK, ""))
for n, s in files.items(): open(n, "w").write(s)
print("ok", len(files))
