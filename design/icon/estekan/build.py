# Generates the Patogh estekan mark: glass wall ring, tea, saucer, steam bubble.
def side(o):
    # right half of the glass as cubic segments, inset by o; mirrored for the left
    rim, waist, belly, base = 46 - o, 29 - o * .9, 38 - o, 26 - o * .7
    top, bot = 84 + o, 220 - o
    return [((rim, top), (rim - 3, 132), (waist, 140), (waist, 162)),
            ((waist, 162), (waist, 176), (belly, 178), (belly, 198)),
            ((belly, 198), (belly, 212), (base + 12, bot), (base, bot))]

def lerp(a, b, t): return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)

def split(seg, t):
    p0, p1, p2, p3 = seg
    a, b, c = lerp(p0, p1, t), lerp(p1, p2, t), lerp(p2, p3, t)
    d, e = lerp(a, b, t), lerp(b, c, t)
    f = lerp(d, e, t)
    return (f, e, c, p3)  # second half

def cut_top(segs, y):
    seg = segs[0]; lo, hi = 0.0, 1.0
    for _ in range(50):
        m = (lo + hi) / 2
        p = split(seg, m)[0]
        lo, hi = (m, hi) if p[1] < y else (lo, m)
    return [split(seg, lo)] + segs[1:]

def f(v): return f"{v:.1f}".rstrip('0').rstrip('.')
def X(x, s): return f(128 + s * x)

def path(segs):
    # right side top->bottom, base across, left side bottom->top
    s = segs[0][0]
    d = f"M{X(-s[0], 1)} {f(s[1])}H{X(s[0], 1)}"
    for _, c1, c2, p in segs:
        d += f"C{X(c1[0],1)} {f(c1[1])} {X(c2[0],1)} {f(c2[1])} {X(p[0],1)} {f(p[1])}"
    d += f"H{X(-segs[-1][3][0], 1)}"
    for p0, c1, c2, _ in reversed(segs):
        d += f"C{X(-c2[0],1)} {f(c2[1])} {X(-c1[0],1)} {f(c1[1])} {X(-p0[0],1)} {f(p0[1])}"
    return d + "Z"

WALL = path(side(0)) + path(side(9))       # evenodd ring
TEA = path(cut_top(side(16), 110))
SOLID = path(side(0))
SAUCER = "M62 220H194Q188 236 170 236H86Q68 236 62 220Z"
BUBBLE = "M152 16A25 25 0 1 1 152 66A25 25 0 1 1 152 16Z M137 58Q135 70 124 79Q143 79 151 64Z"

def svg(body, bg=None, size=256):
    rect = f'<rect width="256" height="256" rx="56" fill="{bg}"/>' if bg else ""
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256">{rect}{body}</svg>\n'

def mark(wall, tea, shift=""):
    g = (f'<path fill="{wall}" fill-rule="evenodd" d="{WALL}"/><path fill="{tea}" d="{TEA}"/>'
         f'<path fill="{wall}" d="{SAUCER}"/><path fill="{wall}" d="{BUBBLE}"/>')
    return f'<g{shift}>{g}</g>' if shift else g

INK, TEA_C, CREAM, TEA_D, TILE = "#2B1810", "#C2451E", "#FFF3E0", "#E8692F", "#2B1810"
inset = ' transform="translate(25.6 25.6) scale(.8)"'
files = {
    "estekan-black.svg": svg(mark("#000", "#000")),
    "estekan-color.svg": svg(mark(INK, TEA_C)),
    "estekan-on-dark.svg": svg(mark(CREAM, TEA_D)),
    "estekan-white.svg": svg(mark("#fff", "#fff")),
    "app-icon.svg": svg(mark(CREAM, TEA_D, inset), bg=TILE),
    # small-size cut: solid glass, tea shown as a darker band is lost at 16px anyway
    "estekan-small.svg": svg(f'<path fill="{INK}" d="{SOLID}"/><path fill="{INK}" d="{SAUCER}"/><path fill="{INK}" d="{BUBBLE}"/>'),
    "app-icon-small.svg": svg(f'<g{inset}><path fill="{TEA_D}" d="{SOLID}"/><path fill="{CREAM}" d="{SAUCER}"/><path fill="{CREAM}" d="{BUBBLE}"/></g>', bg=TILE),
    # full-bleed tiles: iOS rounds apple-touch itself; maskable keeps the mark in the 80% safe zone
    "app-icon-square.svg": svg(f'<rect width="256" height="256" fill="{TILE}"/>' + mark(CREAM, TEA_D, inset)),
    "maskable.svg": svg(f'<rect width="256" height="256" fill="{TILE}"/>' + mark(CREAM, TEA_D, ' transform="translate(44.8 44.8) scale(.65)"')),
}
# macOS: Apple's grid puts the tile at 824/1024 of the canvas, centred, with transparent margin
mac = ' transform="translate(25 25) scale(.8047)"'
files["app-icon-mac.svg"] = svg(f'<g{mac}>' + files["app-icon.svg"].split('">', 1)[1].rsplit("</svg>", 1)[0] + '</g>')
files["app-icon-mac-small.svg"] = svg(f'<g{mac}>' + files["app-icon-small.svg"].split('">', 1)[1].rsplit("</svg>", 1)[0] + '</g>')
# tray: small cut, one colour, cropped tight so the glass fills the tiny tray slot
TRAY = f'<path d="{SOLID}"/><path d="{SAUCER}"/><path d="{BUBBLE}"/>'
files["tray.svg"] = f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="40 12 176 228" fill="{TEA_D}">{TRAY}</svg>\n'
files["tray-template.svg"] = f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="40 12 176 228" fill="#000">{TRAY}</svg>\n'
for name, s in files.items():
    open(name, "w").write(s)
print("ok", len(files))
