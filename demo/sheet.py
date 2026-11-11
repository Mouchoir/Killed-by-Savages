# Contact sheets of a recording: a few frames of each scene side by side,
# to look at what was captured before making the GIFs.
#   python sheet.py <recording folder> <scene> [count] [scale] [columns]
import json
import os
import sys

from PIL import Image, ImageDraw

source, scene = sys.argv[1], sys.argv[2]
count = int(sys.argv[3]) if len(sys.argv) > 3 else 6
scale = float(sys.argv[4]) if len(sys.argv) > 4 else 0.5
columns = int(sys.argv[5]) if len(sys.argv) > 5 else 2
index = json.load(open(os.path.join(source, "index.json"), encoding="utf-8"))
frames = index["scenes"][scene]["frames"]
if count >= len(frames):
    picks = list(range(len(frames)))
else:
    picks = sorted({round(position * (len(frames) - 1) / (count - 1)) for position in range(count)})
images = []
for pick in picks:
    image = Image.open(os.path.join(source, frames[pick]["file"])).convert("RGB")
    image = image.resize((int(image.width * scale), int(image.height * scale)), Image.LANCZOS)
    ImageDraw.Draw(image).text((6, 4), "#%d  t=%.2fs" % (pick, frames[pick]["t"]), fill=(255, 255, 0))
    images.append(image)
rows = (len(images) + columns - 1) // columns
sheet = Image.new("RGB", (images[0].width * columns, images[0].height * rows), (0, 0, 0))
for position, image in enumerate(images):
    sheet.paste(image, ((position % columns) * image.width, (position // columns) * image.height))
path = os.path.join(source, "sheet-scene%s.png" % scene)
sheet.save(path)
print(path, sheet.size, "frames", picks)
print("times:", " ".join("%.2f" % frame["t"] for frame in frames))
