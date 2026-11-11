# Turns the frames of a recorded KBSDemo tour into one GIF per scene.
#
#   python makegif.py <recording folder> <output folder> [--scale 0.85] [--pad 4] [--only 1,2] [--drop 3:18-25]
#                     [--names 1=one-name,2=another]
#
# --names gives the files other names than the default ones (no extension).
# --drop takes frames out of a scene (scene:first-last, several separated by
# commas): the frame before them stays on screen until the one after.
#
# Each scene is cropped to the board (its frame art included, found by
# walking out from the board's edges to the tour's plain dark ground), given
# one palette for all its frames, and written with the real time between
# frames: only what changes from one frame to the next is stored, so a
# pointer moving over a still board costs next to nothing. The last frame
# stays a while before the loop.
import json
import os
import sys

import numpy as np
from PIL import Image

NAMES = {
    1: "1-player-search",
    2: "2-character-filters",
    3: "3-role",
    4: "4-display-name",
    5: "5-hunt-search",
    6: "6-outdated-addons",
}
HOLD_LAST = 2.6            # seconds the last frame stays before the loop
MAX_GAP = 4.0              # no frame stays longer than this, whatever the recorder saw


def board_box(first, board, ppu, pad):
    """The board with its frame art: from the board's own rectangle, each side walks out while
    the line just outside still holds something else than the ground."""
    height, width = first.shape[:2]
    ground = first[2, 2].astype(np.int16)
    busy = np.abs(first.astype(np.int16) - ground).sum(axis=2) > 30
    if board:
        left, top, right, bottom = board
    else:
        ys, xs = np.nonzero(busy)
        left, top, right, bottom = xs.min(), ys.min(), xs.max(), ys.max()
    limit = int(round(30 * (ppu or 1.2)))
    for _ in range(limit):
        if left > 0 and busy[top:bottom + 1, left - 1].any():
            left -= 1
        if right < width - 1 and busy[top:bottom + 1, right + 1].any():
            right += 1
    for _ in range(limit):
        if top > 0 and busy[top - 1, left:right + 1].any():
            top -= 1
        if bottom < height - 1 and busy[bottom + 1, left:right + 1].any():
            bottom += 1
    return (max(0, left - pad), max(0, top - pad), min(width, right + 1 + pad), min(height, bottom + 1 + pad))


def scene_palette(sheet):
    """255 colours for a scene, in two parts. Median cut over everything gives the many dark
    browns of the board their smooth steps, but leaves nothing for colours that fill few pixels:
    class colours, icons. So a share of the palette is cut from the vivid pixels alone."""
    data = np.asarray(sheet).reshape(-1, 3)
    high = data.max(axis=1).astype(np.int16)
    spread = high - data.min(axis=1).astype(np.int16)
    keep = (spread > 60) & (high > 90)
    vivid = data[keep]
    entries = []
    if len(vivid) > 2000:
        # The board's gold is vivid too and is everywhere: the vivid pixels are taken hue by
        # hue, each hue and brightness giving at most a few hundred, so that a class colour
        # seen on one line of one frame weighs as much as the gold of every title.
        red, green, blue = (vivid[:, channel].astype(np.float32) for channel in range(3))
        top, gap = high[keep].astype(np.float32), spread[keep].astype(np.float32)
        hue = np.where(top == red, (green - blue) / gap % 6, np.where(top == green, (blue - red) / gap + 2, (red - green) / gap + 4))
        bins = (hue * 6).astype(np.int32) % 36 * 3 + np.digitize(top, (140, 200))
        rng = np.random.default_rng(7)
        chosen = []
        for value in np.unique(bins):
            members = np.nonzero(bins == value)[0]
            if len(members) >= 12:
                chosen.append(members if len(members) <= 400 else rng.choice(members, 400, replace=False))
        sample = vivid[np.concatenate(chosen)]
        width = 256
        rows = max(1, len(sample) // width)
        strip = Image.fromarray(np.ascontiguousarray(sample[: rows * width].reshape(rows, width, 3)))
        cut = strip.quantize(colors=80, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
        entries += cut.getpalette()[: 80 * 3]
    base = sheet.quantize(colors=255 - len(entries) // 3, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
    entries = base.getpalette()[: (255 - len(entries) // 3) * 3] + entries
    holder = Image.new("P", (1, 1))
    holder.putpalette(entries + [0] * (768 - len(entries)))
    return holder


def build(source, dest, scale, pad, only, drop=None, names=None):
    index = json.load(open(os.path.join(source, "index.json"), encoding="utf-8"))
    os.makedirs(dest, exist_ok=True)
    made = []
    for key in sorted(index["scenes"], key=int):
        scene = index["scenes"][key]
        number = int(key)
        if only and number not in only:
            continue
        frames = scene["frames"]
        for first, last in (drop or {}).get(number, []):
            frames = [frame for position, frame in enumerate(frames) if not first <= position <= last]
        if not frames:
            continue
        images = [Image.open(os.path.join(source, frame["file"])).convert("RGB") for frame in frames]
        box = board_box(np.asarray(images[0]), index.get("board"), index.get("ppu"), pad)
        images = [image.crop(box) for image in images]
        if scale != 1:
            size = (int(round(images[0].width * scale)), int(round(images[0].height * scale)))
            images = [image.resize(size, Image.LANCZOS) for image in images]
        # One palette for the scene, from a sheet of its frames: all of them
        # up to forty, the last one always (a scene can end on another tab,
        # with colours the rest of it never showed), at half size with no
        # blending so the colours stay the ones on screen.
        step = max(1, len(images) // 40)
        picks = images[::step]
        if picks[-1] is not images[-1]:
            picks.append(images[-1])
        half = (max(1, images[0].width // 2), max(1, images[0].height // 2))
        picks = [image.resize(half, Image.NEAREST) for image in picks]
        sheet = Image.new("RGB", (half[0], half[1] * len(picks)))
        for position, image in enumerate(picks):
            sheet.paste(image, (0, position * half[1]))
        palette = scene_palette(sheet)
        indexed = [image.quantize(palette=palette, dither=Image.Dither.NONE) for image in images]
        worst = 0.0
        for image, mapped in zip(images, indexed):
            diff = np.abs(np.asarray(image).astype(np.int16) - np.asarray(mapped.convert("RGB")).astype(np.int16)).sum(axis=2)
            worst = max(worst, float(np.percentile(diff, 99.5)))
        print("   palette: worst frame is within %d (sum of the three channels) for 99.5 %% of its pixels" % worst)
        times = [frame["t"] for frame in frames] + [max(scene["end"], frames[-1]["t"])]
        durations = []
        for position in range(len(frames)):
            gap = min(MAX_GAP, max(0.03, times[position + 1] - times[position]))
            durations.append(int(round(gap * 100)) * 10)
        durations[-1] = int(HOLD_LAST * 1000)
        name = (names or {}).get(number) or NAMES.get(number, "scene%d" % number)
        path = os.path.join(dest, name + ".gif")
        indexed[0].save(path, save_all=True, append_images=indexed[1:], duration=durations, loop=0, optimize=False, disposal=1)
        size_mb = os.path.getsize(path) / 1e6
        made.append((path, len(frames), sum(durations) / 1000, images[0].size, size_mb))
        print("%s: %d frames, %.1f s, %dx%d, %.2f MB" % (os.path.basename(path), len(frames), sum(durations) / 1000,
                                                       images[0].width, images[0].height, size_mb))
    return made


if __name__ == "__main__":
    arguments = sys.argv[1:]
    scale, pad, only, drop, names = 1.0, 4, None, {}, {}
    for flag in ("--scale", "--pad", "--only", "--drop", "--names"):
        if flag in arguments:
            position = arguments.index(flag)
            value = arguments[position + 1]
            del arguments[position:position + 2]
            if flag == "--scale":
                scale = float(value)
            elif flag == "--pad":
                pad = int(value)
            elif flag == "--drop":
                for part in value.split(","):
                    scene_number, span = part.split(":")
                    first, last = span.split("-")
                    drop.setdefault(int(scene_number), []).append((int(first), int(last)))
            elif flag == "--names":
                for part in value.split(","):
                    scene_number, name = part.split("=", 1)
                    names[int(scene_number)] = name
            else:
                only = {int(part) for part in value.split(",")}
    if len(arguments) < 2:
        print(__doc__)
        sys.exit(1)
    build(arguments[0], arguments[1], scale, pad, only, drop, names)
