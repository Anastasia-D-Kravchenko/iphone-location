"""Draws the 1024x1024 app icon (blue gradient with a white location pin)."""
import json
from pathlib import Path

from PIL import Image, ImageDraw

S = 1024
out = Path(__file__).parent / "LocationRemote/Assets.xcassets/AppIcon.appiconset"
out.mkdir(parents=True, exist_ok=True)

img = Image.new("RGB", (S, S))
d = ImageDraw.Draw(img)
for y in range(S):
    t = y / S
    d.line([(0, y), (S, y)], fill=(int(30 + 20 * t), int(140 - 60 * t), int(255 - 40 * t)))

# Pin: a circle head with a triangle tail and a hole.
cx, cy, r = S // 2, 420, 230
d.ellipse([cx - r, cy - r, cx + r, cy + r], fill="white")
d.polygon([(cx - 200, cy + 120), (cx + 200, cy + 120), (cx, 860)], fill="white")
hr = 95
d.ellipse([cx - hr, cy - hr, cx + hr, cy + hr], fill=(40, 110, 240))

img.save(out / "icon.png")
(out / "Contents.json").write_text(json.dumps({
    "images": [{"filename": "icon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
    "info": {"author": "xcode", "version": 1},
}, indent=2))
(out.parent / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2))
print("icon written")
