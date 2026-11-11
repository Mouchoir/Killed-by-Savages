# Records the KBSDemo tour of the Killed by Savages board, scene by scene.
#
#   python record.py <output folder> [minutes to wait for the tour]
#   python record.py --selftest
#
# Windows only; needs Pillow and numpy. It waits for the game window, then
# for the tour's marker in the top left corner of the game: four squares,
# [magenta][phase][scene][cyan]. Nothing is captured before the player
# starts the tour with /kbsdemo. While the phase is "armed" it finds the
# board by the two markers in its corners; during a scene it copies the
# board's rectangle about 15 times a second and keeps every frame that
# differs from the one before, as a PNG, with its time. It ends when the
# marker says the tour is over. Only the board's rectangle is ever written
# to disk: nothing else of the screen.
import ctypes
import json
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from ctypes import wintypes

import numpy as np
from PIL import Image

SQUARE_UNITS = 16          # the marker's squares, in UI units
MARGIN_UNITS = 36          # kept around the board, inside the tour's dark ground
RATE = 15                  # frames a second during a scene
PHASES = {"W": "armed", "B": "idle", "R": "scene", "K": "done"}
SCENES = "RGBYWK"
CODES = {
    (1, 0, 1): "M", (0, 1, 1): "C", (1, 0, 0): "R", (0, 1, 0): "G",
    (0, 0, 1): "B", (1, 1, 0): "Y", (1, 1, 1): "W", (0, 0, 0): "K",
}


def log(*parts):
    print(time.strftime("%H:%M:%S"), *parts, flush=True)


# --- the game window and the screen ------------------------------------------

def dpi_aware():
    user32 = ctypes.windll.user32
    try:
        user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
    except Exception:
        user32.SetProcessDPIAware()


def process_path(pid):
    kernel32 = ctypes.windll.kernel32
    handle = kernel32.OpenProcess(0x1000, False, pid)
    if not handle:
        return ""
    try:
        size = wintypes.DWORD(1024)
        buffer = ctypes.create_unicode_buffer(1024)
        if kernel32.QueryFullProcessImageNameW(handle, 0, buffer, ctypes.byref(size)):
            return buffer.value
        return ""
    finally:
        kernel32.CloseHandle(handle)


def find_wow():
    user32 = ctypes.windll.user32
    found = []
    proc = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)

    def each(hwnd, _):
        if not user32.IsWindowVisible(hwnd):
            return True
        if user32.GetWindowTextLengthW(hwnd) == 0:
            return True
        pid = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        name = process_path(pid.value).replace("/", "\\").split("\\")[-1].lower()
        if name.startswith("wow") and name.endswith(".exe"):
            found.append(hwnd)
        return True

    user32.EnumWindows(proc(each), 0)
    return found[0] if found else None


def client_rect(hwnd):
    user32 = ctypes.windll.user32
    rect = wintypes.RECT()
    user32.GetClientRect(hwnd, ctypes.byref(rect))
    origin = wintypes.POINT(0, 0)
    user32.ClientToScreen(hwnd, ctypes.byref(origin))
    return origin.x, origin.y, rect.right - rect.left, rect.bottom - rect.top


class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [
        ("biSize", wintypes.DWORD), ("biWidth", wintypes.LONG), ("biHeight", wintypes.LONG),
        ("biPlanes", wintypes.WORD), ("biBitCount", wintypes.WORD), ("biCompression", wintypes.DWORD),
        ("biSizeImage", wintypes.DWORD), ("biXPelsPerMeter", wintypes.LONG), ("biYPelsPerMeter", wintypes.LONG),
        ("biClrUsed", wintypes.DWORD), ("biClrImportant", wintypes.DWORD),
    ]


class Grabber:
    """Copies one rectangle of the screen into memory: a single BitBlt of that rectangle.
    (Pillow's ImageGrab copies the whole desktop and crops, a few frames a second at best.)"""

    def __init__(self, width, height):
        user32, gdi32 = ctypes.windll.user32, ctypes.windll.gdi32
        pointer = ctypes.c_void_p
        user32.GetDC.restype = pointer
        user32.GetDC.argtypes = [pointer]
        gdi32.CreateCompatibleDC.restype = pointer
        gdi32.CreateCompatibleDC.argtypes = [pointer]
        gdi32.CreateDIBSection.restype = pointer
        gdi32.CreateDIBSection.argtypes = [pointer, pointer, ctypes.c_uint, ctypes.POINTER(pointer), pointer, ctypes.c_uint]
        gdi32.SelectObject.restype = pointer
        gdi32.SelectObject.argtypes = [pointer, pointer]
        gdi32.BitBlt.argtypes = [pointer, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, pointer,
                                 ctypes.c_int, ctypes.c_int, ctypes.c_uint]
        self.gdi32 = gdi32
        self.width, self.height = width, height
        self.screen = user32.GetDC(None)
        self.memory = gdi32.CreateCompatibleDC(self.screen)
        header = BITMAPINFOHEADER()
        header.biSize = ctypes.sizeof(BITMAPINFOHEADER)
        header.biWidth, header.biHeight = width, -height        # top row first
        header.biPlanes, header.biBitCount, header.biCompression = 1, 32, 0
        bits = pointer()
        self.bitmap = gdi32.CreateDIBSection(self.screen, ctypes.byref(header), 0, ctypes.byref(bits), None, 0)
        if not self.bitmap or not bits.value:
            raise OSError("could not create a %dx%d bitmap" % (width, height))
        gdi32.SelectObject(self.memory, self.bitmap)
        buffer = (ctypes.c_ubyte * (width * height * 4)).from_address(bits.value)
        self.view = np.frombuffer(buffer, dtype=np.uint8).reshape(height, width, 4)

    def grab(self, left, top):
        """The rectangle whose top left corner is at (left, top) on the desktop, as RGB."""
        self.gdi32.BitBlt(self.memory, 0, 0, self.width, self.height, self.screen, left, top, 0x00CC0020)
        self.gdi32.GdiFlush()
        return np.ascontiguousarray(self.view[:, :, 2::-1])


# --- reading the markers (plain functions of pixel arrays, testable) ---------

def classify(pixel):
    bits = []
    for channel in pixel:
        if channel > 170:
            bits.append(1)
        elif channel < 85:
            bits.append(0)
        else:
            return None
    return CODES.get(tuple(bits))


def read_marker(strip):
    """strip: the top left of the game, a few rows high. Returns (phase, scene, square size in px) or None."""
    row = strip[min(5, strip.shape[0] - 1)]
    codes = [classify(pixel) for pixel in row]
    start = next((index for index in range(min(8, len(codes))) if codes[index] == "M"), None)
    if start is None:
        return None
    end = start
    while end < len(codes) and codes[end] == "M":
        end += 1
    size = end - start
    if size < 5:
        return None

    def at(square):
        index = int(start + (square + 0.5) * size)
        return codes[index] if index < len(codes) else None

    if at(3) != "C":
        return None
    phase = PHASES.get(at(1))
    if phase is None:
        return None
    scene = SCENES.index(at(2)) + 1 if at(2) is not None and at(2) in SCENES else 0
    return phase, scene, size


def find_board(image, square):
    """image: the whole game. The board's corners carry [magenta][yellow] at its top left and
    [yellow][magenta] at its bottom right. Returns (left, top, right, bottom), inclusive, or None."""
    data = image.astype(np.int16)
    red, green, blue = data[..., 0], data[..., 1], data[..., 2]
    magenta = (red > 200) & (green < 70) & (blue > 200)
    yellow = (red > 200) & (green > 200) & (blue < 70)
    magenta[: square * 2, : square * 6] = False      # the tour's own status marker
    step = 3

    def moved(mask, offset):
        out = np.zeros_like(mask)
        if offset > 0:
            out[:, offset:] = mask[:, :-offset]
        elif offset < 0:
            out[:, :offset] = mask[:, -offset:]
        else:
            out[:] = mask
        return out

    # x is the last magenta column before yellow starts (one blended column allowed between).
    top_left = magenta & moved(magenta, step) & moved(yellow, -2) & moved(yellow, -(2 + step))
    bottom_right = yellow & moved(yellow, step) & moved(magenta, -2) & moved(magenta, -(2 + step))
    ys, xs = np.nonzero(top_left)
    ys2, xs2 = np.nonzero(bottom_right)
    if len(ys) == 0 or len(ys2) == 0:
        return None
    top = int(ys.min())
    x = int(xs[ys == top].min())
    while x > 0 and magenta[top, x - 1]:
        x -= 1
    left = x
    bottom = int(ys2.max())
    x = int(xs2[ys2 == bottom].max()) + 2
    while x + 1 < magenta.shape[1] and magenta[bottom, x + 1]:
        x += 1
    right = x
    if right - left < 300 or bottom - top < 200:
        return None
    return left, top, right, bottom


# --- the recording -----------------------------------------------------------

def record(out_dir, wait_minutes):
    dpi_aware()
    os.makedirs(out_dir, exist_ok=True)
    deadline = time.time() + wait_minutes * 60
    hwnd, rect, board, ppu = None, None, None, None
    scenes, current, started, last = {}, 0, None, None
    absent_since, saw_marker = None, False
    result = "timeout"
    strip, frame_grabber = Grabber(420, 12), None
    writer = ThreadPoolExecutor(max_workers=2)

    def save(frame, path):
        Image.fromarray(frame).save(path, compress_level=1)

    log("waiting for the game and the tour, up to", wait_minutes, "minutes")
    while True:
        tick = time.perf_counter()
        if hwnd is None or not ctypes.windll.user32.IsWindow(hwnd):
            hwnd = find_wow()
            if hwnd is None:
                if time.time() > deadline:
                    break
                time.sleep(2)
                continue
            log("game window found")
        cx, cy, cw, ch = client_rect(hwnd)
        if cw < 420 or ch < 300:
            if time.time() > deadline:
                break
            time.sleep(1)
            continue
        marker = read_marker(strip.grab(cx, cy))
        now = time.perf_counter()
        if marker is None:
            if saw_marker:
                absent_since = absent_since or now
                if now - absent_since > 8:
                    result = "the marker went away"
                    break
            elif time.time() > deadline:
                break
            time.sleep(0.05 if saw_marker else 0.15)
            continue
        absent_since = None
        phase, scene, size = marker
        if not saw_marker:
            saw_marker = True
            log("tour marker seen, square of", size, "px")
        ppu = size / SQUARE_UNITS
        if phase == "armed" and rect is None:
            found = find_board(Grabber(cw, ch).grab(cx, cy), size)
            if found:
                margin = int(round(MARGIN_UNITS * ppu))
                left, top = max(0, found[0] - margin), max(0, found[1] - margin)
                right, bottom = min(cw - 1, found[2] + margin), min(ch - 1, found[3] + margin)
                rect = (left, top, right - left + 1, bottom - top + 1)
                board = (found[0] - left, found[1] - top, found[2] - left, found[3] - top)
                log("board found at", found, "captured rectangle", rect)
        if phase == "scene" and scene > 0:
            if rect is None:
                # No corner markers seen: the tour centres the board, so take the middle.
                width, height = int(900 * ppu) + 2 * int(60 * ppu), int(640 * ppu) + 2 * int(60 * ppu)
                width, height = min(width, cw), min(height, ch)
                rect = ((cw - width) // 2, (ch - height) // 2, width, height)
                log("no corner markers were seen: capturing the middle of the game,", rect)
            if frame_grabber is None:
                frame_grabber = Grabber(rect[2], rect[3])
            if scene != current:
                current, started, last = scene, now, None
                scenes[scene] = {"frames": [], "end": 0}
                os.makedirs(os.path.join(out_dir, "scene%d" % scene), exist_ok=True)
                log("scene", scene, "started")
            frame = frame_grabber.grab(cx + rect[0], cy + rect[1])
            stamp = time.perf_counter() - started
            if last is None or not np.array_equal(frame, last):
                name = "scene%d/f%04d.png" % (scene, len(scenes[scene]["frames"]))
                writer.submit(save, frame, os.path.join(out_dir, name))
                scenes[scene]["frames"].append({"t": round(stamp, 3), "file": name})
                last = frame
            scenes[scene]["end"] = round(time.perf_counter() - started, 3)
        elif current:
            log("scene", current, "ended:", len(scenes[current]["frames"]), "frames in", scenes[current]["end"], "s")
            current = 0
        if phase == "done":
            result = "ok"
            break
        spent = time.perf_counter() - tick
        time.sleep(max(0.0, 1 / RATE - spent) if phase == "scene" else 0.04)
    if current:
        log("scene", current, "cut short:", len(scenes[current]["frames"]), "frames")
    writer.shutdown(wait=True)
    index = {"result": result, "rect": rect, "board": board, "ppu": ppu, "scenes": scenes}
    with open(os.path.join(out_dir, "index.json"), "w", encoding="utf-8") as handle:
        json.dump(index, handle, indent=1)
    log("finished:", result, "| scenes recorded:", sorted(scenes))
    return 0 if result == "ok" else 2


# --- self test: the marker readers against a drawn screen, and the grabber ----

def selftest():
    rng = np.random.default_rng(3)
    colors = {"M": (255, 0, 255), "C": (0, 255, 255), "R": (255, 0, 0), "G": (0, 255, 0), "B": (0, 0, 255),
              "Y": (255, 255, 0), "W": (255, 255, 255), "K": (0, 0, 0)}
    failures = 0
    for ppu in (0.8, 1.0, 1.177, 1.5, 2.0):
        scale = 4
        width, height = 2560, 1440
        big = Image.fromarray(rng.integers(20, 120, (height, width, 3), dtype=np.uint8)).resize((width * scale, height * scale), Image.NEAREST)
        canvas = np.asarray(big).copy()

        def fill(x0, y0, x1, y1, code):
            canvas[int(y0 * scale):int(y1 * scale), int(x0 * scale):int(x1 * scale)] = colors[code]

        square = SQUARE_UNITS * ppu
        # The tour centres the board; a fraction of a pixel off, as on a real screen.
        left, top = (width - 820 * ppu) / 2 + 0.3, (height - 560 * ppu) / 2 + 0.6
        right, bottom = left + 820 * ppu, top + 560 * ppu
        corner = 12 * ppu
        fill(left, top, left + corner, top + corner, "M")
        fill(left + corner, top, left + 2 * corner, top + corner, "Y")
        fill(right - 2 * corner, bottom - corner, right - corner, bottom, "Y")
        fill(right - corner, bottom - corner, right, bottom, "M")
        for phase, scene in (("W", "K"), ("B", "K"), ("R", "R"), ("R", "Y"), ("R", "K"), ("K", "K")):
            for index, code in enumerate(("M", phase, scene, "C")):
                fill(index * square, 0, (index + 1) * square, square, code)
            screen = np.asarray(Image.fromarray(canvas).resize((width, height), Image.BOX))
            got = read_marker(screen[:12, :420])
            want = (PHASES[phase], SCENES.index(scene) + 1)
            if got is None or got[:2] != want or abs(got[2] - square) > 2:
                failures += 1
                print("marker FAIL ppu", ppu, phase, scene, "->", got)
        found = find_board(screen, int(round(square)))
        want = (left, top, right - 1, bottom - 1)
        if found is None or any(abs(a - b) > 2 for a, b in zip(found, want)):
            failures += 1
            print("board FAIL ppu", ppu, "->", found, "wanted", tuple(round(v) for v in want))
        else:
            print("ppu", ppu, "ok: marker square", got[2], "px, board", found)
    if read_marker(rng.integers(0, 255, (12, 420, 3), dtype=np.uint8)) is not None:
        failures += 1
        print("marker FAIL: noise read as a marker")
    # The grabber: a corner of this desktop, in memory only, and how long a copy takes.
    dpi_aware()
    grabber = Grabber(1000, 700)
    began = time.perf_counter()
    for _ in range(30):
        frame = grabber.grab(0, 0)
    each = (time.perf_counter() - began) / 30 * 1000
    if frame.shape != (700, 1000, 3) or int(frame.max()) == int(frame.min()):
        failures += 1
        print("grab FAIL: shape", frame.shape, "values", frame.min(), frame.max())
    else:
        print("grab ok: 1000x700 in %.1f ms" % each)
    print("selftest:", "ok" if failures == 0 else "%d failure(s)" % failures)
    return 1 if failures else 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--selftest":
        sys.exit(selftest())
    if len(sys.argv) < 2:
        print("usage: record.py <output folder> [minutes to wait]   |   record.py --selftest")
        sys.exit(1)
    sys.exit(record(sys.argv[1], float(sys.argv[2]) if len(sys.argv) > 2 else 120))
