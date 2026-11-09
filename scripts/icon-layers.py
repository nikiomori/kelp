"""Resources/AppIcon.svg → Resources/AppIcon.icon, the same drawing as an Icon Composer document cut into layers (water,
light rays, three planes of kelp, bubbles), so macOS 26 draws it in each icon style of System Settings › Appearance:
Default is the drawing itself; Dark keeps the composition in dark water with the plants lit from the front; Clear and
Tinted (the "tinted" appearance) draw the plants white over the system's glass, nearest the most opaque.
Run by scripts/icon.sh; the result opens in Icon Composer.  python3 scripts/icon-layers.py <AppIcon.svg> <AppIcon.icon>"""
import json, os, re, shutil, sys

src, out = sys.argv[1], sys.argv[2]
svg = open(src).read()
planes = {}
for fill, body in re.findall(r'<g fill="(#[0-9A-F]{6})"(?: opacity="[^"]*")?>(.*?)</g>', svg):
    planes[fill] = planes.get(fill, "") + body   # a plane's plants, then its floats
rays = re.search(r'<g fill="url\(#kf-ray\)">(.*?)</g>', svg).group(1)
sea_gradient = re.search(r'<linearGradient id="kf-bg".*?</linearGradient>', svg).group(0)
ray_gradient = re.search(r'<linearGradient id="kf-ray".*?</linearGradient>', svg).group(0)

# The SVG's tile is Apple's 824 pt template at (100, 100); an Icon Composer layer fills the whole 1024 pt canvas.
K = 1024 / 824
TILE = f'transform="translate({-100 * K:.3f},{-100 * K:.3f}) scale({K:.5f})"'


def layer(body, defs=""):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">'
            f'<defs>{defs}</defs><g {TILE}>{body}</g></svg>')


def srgb(hex_):
    r, g, b = (int(hex_[i:i + 2], 16) / 255 for i in (1, 3, 5))
    return f"srgb:{r:.5f},{g:.5f},{b:.5f},1.00000"


DARK = {"far": "#1D5960", "mid": "#2C8790", "near": "#6CD3CA", "top": "#1A4C55", "bottom": "#03141A"}
ASSETS = {
    "sea.svg": layer('<rect x="0" y="0" width="1124" height="1124" fill="url(#kf-bg)"/>', sea_gradient),
    "rays.svg": layer(f'<g fill="url(#kf-ray)">{rays}</g>', ray_gradient),
    "far.svg": layer(f'<g fill="#3F9AA3">{planes["#3F9AA3"]}</g>'),
    "mid.svg": layer(f'<g fill="#17636E">{planes["#17636E"]}</g>'),
    "near.svg": layer(f'<g fill="#0A3440">{planes["#0A3440"]}</g>'),
    "bubbles.svg": layer(f'<g fill="#FFFFFF" opacity=".55">{planes["#FFFFFF"]}</g>'),
}


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


# No glass effects of its own: Default draws as the flat drawing does.
FLAT = {"shadow": {"kind": "none", "opacity": 0.5}, "translucency": {"enabled": False, "value": 0.5},
        "specular": False, "lighting": "combined"}
DOC = {
    "fill-specializations": [
        {"value": {"linear-gradient": [srgb("#8FE5DB"), srgb("#0A4353")]}},
        {"appearance": "dark", "value": {"linear-gradient": [srgb(DARK["top"]), srgb(DARK["bottom"])]}},
    ],
    "groups": [
        {"name": "Front", "layers": [image("bubbles.svg", mono=.8), image("near.svg", DARK["near"], mono=1)], **FLAT},
        {"name": "Middle", "layers": [image("mid.svg", DARK["mid"], mono=.55)], **FLAT},
        {"name": "Back", "layers": [image("far.svg", DARK["far"], mono=.3)], **FLAT},
        {"name": "Water", "layers": [image("rays.svg", dark_opacity=.35, mono=.6, mono_white=False),
                                     image("sea.svg", hidden=("dark", "tinted"))], **FLAT},
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
