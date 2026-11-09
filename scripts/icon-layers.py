"""Resources/AppIcon(Dev).svg → AppIcon(Dev).icon, the same drawing as an Icon Composer document cut into layers (water,
light rays, Dev's grid, three planes of kelp, bubbles), so macOS 26 draws it in each icon style of System Settings ›
Appearance: Default is the drawing itself; Dark keeps the composition in dark water; Clear and Tinted (the "tinted"
appearance) draw the plants white over the system's glass, nearest the most opaque.
Run by scripts/icon.sh; the result opens in Icon Composer.  python3 scripts/icon-layers.py <AppIcon.svg> <AppIcon.icon>"""
import json, os, re, shutil, sys

src, out = sys.argv[1], sys.argv[2]
svg = open(src).read()
sea_gradient = re.search(r'<linearGradient id="kf-bg".*?</linearGradient>', svg).group(0)
ray_gradient = re.search(r'<linearGradient id="kf-ray".*?</linearGradient>', svg).group(0)
inside = re.search(r'<g clip-path="url\(#kf-c\)">(.*)</g><path', svg).group(1)
groups = []   # (opening tag, body); a plane's plants and then its floats share a tag, so they become one layer
for tag, body in re.findall(r'(<g [^>]*>)(.*?)</g>', inside):
    if groups and groups[-1][0] == tag:
        groups[-1] = (tag, groups[-1][1] + body)
    else:
        groups.append((tag, body))
grid = [g for g in groups if 'd="M100,0 V1024' in g[1]]
rays = [g for g in groups if "url(#kf-ray)" in g[0]]
bubbles = [g for g in groups if "<circle" in g[1]]
planes = [g for g in groups if g not in grid + rays + bubbles]
assert len(rays) == 1 and len(bubbles) == 1 and len(planes) == 3, [g[0] for g in groups]
outlined = 'fill="none"' in planes[0][0]   # Dev's blueprint: white outlines, which read on dark water as they are

# The SVG's tile is Apple's 824 pt template at (100, 100); an Icon Composer layer fills the whole 1024 pt canvas.
K = 1024 / 824
TILE = f'transform="translate({-100 * K:.3f},{-100 * K:.3f}) scale({K:.5f})"'


def layer(group, defs=""):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">'
            f'<defs>{defs}</defs><g {TILE}>{group[0]}{group[1]}</g></g></svg>')


def srgb(hex_):
    r, g, b = (int(hex_[i:i + 2], 16) / 255 for i in (1, 3, 5))
    return f"srgb:{r:.5f},{g:.5f},{b:.5f},1.00000"


stops = re.findall(r'stop-color="(#[0-9A-Fa-f]{6})"', sea_gradient)
# Dark water: Kelp's teal or Dev's blueprint blue at night. Kelp's plants are dark silhouettes, so in the dark they're
# lit from the front instead (far to near); Dev's are white outlines already.
DARK_SEA = {"#8FE5DB": ("#1A4C55", "#03141A"), "#3A7BDA": ("#16305E", "#050E22")}[stops[0].upper()]
DARK_PLANES = [None] * 3 if outlined else ["#1D5960", "#2C8790", "#6CD3CA"]
ASSETS = {"sea.svg": layer(('<g>', '<rect x="0" y="0" width="1124" height="1124" fill="url(#kf-bg)"/>'), sea_gradient),
          "rays.svg": layer(rays[0], ray_gradient), "far.svg": layer(planes[0]), "mid.svg": layer(planes[1]),
          "near.svg": layer(planes[2]), "bubbles.svg": layer(bubbles[0])}
if grid:
    ASSETS["grid.svg"] = layer(grid[0])


def image(name, dark=None, dark_opacity=None, mono=None, mono_white=True, hidden=()):
    """dark: its colour in Dark; mono: its opacity in Clear and Tinted, drawn white unless mono_white is off."""
    layer = {"image-name": name, "name": name.removesuffix(".svg")}
    fills = [{"appearance": "dark", "value": {"solid": srgb(dark)}}] if dark else []
    if mono is not None and mono_white:
        fills.append({"appearance": "tinted", "value": {"solid": srgb("#FFFFFF")}})
    opacities = [{"appearance": "dark", "value": dark_opacity}] if dark_opacity is not None else []
    if mono is not None:
        opacities.append({"appearance": "tinted", "value": mono})
    if fills:
        layer["fill-specializations"] = fills
    if opacities:
        layer["opacity-specializations"] = [{"value": 1}] + opacities
    if hidden:
        layer["hidden-specializations"] = [{"value": False}] + [{"appearance": a, "value": True} for a in hidden]
    return layer


# Outlines carry their own opacity per plane; filled planes get it in Clear and Tinted.
MONO = [1, 1, 1] if outlined else [.3, .55, 1]
water = [image("rays.svg", dark_opacity=.35, mono=.6, mono_white=False)]
water += [image("grid.svg", mono=1)] if grid else []
water += [image("sea.svg", hidden=("dark", "tinted"))]
# No glass effects of its own: Default draws as the flat drawing does.
FLAT = {"shadow": {"kind": "none", "opacity": 0.5}, "translucency": {"enabled": False, "value": 0.5},
        "specular": False, "lighting": "combined"}
DOC = {
    "fill-specializations": [
        {"value": {"linear-gradient": [srgb(stops[0]), srgb(stops[-1])]}},
        {"appearance": "dark", "value": {"linear-gradient": [srgb(DARK_SEA[0]), srgb(DARK_SEA[1])]}},
    ],
    "groups": [
        {"name": "Front", "layers": [image("bubbles.svg", mono=.8), image("near.svg", DARK_PLANES[2], mono=MONO[2])],
         **FLAT},
        {"name": "Middle", "layers": [image("mid.svg", DARK_PLANES[1], mono=MONO[1])], **FLAT},
        {"name": "Back", "layers": [image("far.svg", DARK_PLANES[0], mono=MONO[0])], **FLAT},
        {"name": "Water", "layers": water, **FLAT},
    ],
    "supported-platforms": {"squares": ["macOS"]},
}

shutil.rmtree(out, ignore_errors=True)
os.makedirs(os.path.join(out, "Assets"))
for name, text in ASSETS.items():
    with open(os.path.join(out, "Assets", name), "w") as f:
        f.write(text)
with open(os.path.join(out, "icon.json"), "w") as f:
    json.dump(DOC, f, indent=2)
    f.write("\n")
print(f"wrote {out}")
