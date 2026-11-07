"""Cuts a film-steps.sh recording into a contact sheet: one row per step, several frames per
step, so the effect of each command can be checked by eye.

    python3 camera/sheet.py OUTDIR [--crop W:H:X:Y] [--frames 4] [--hold 4]

The crop is the display's position in the 960 px wide video (default 180:180:358:135).
The video is lined up with the logged command times using the white sync flash: the first
frame whose display area turns bright marks the moment the flash command was sent.
"""
import argparse, subprocess, os

ap = argparse.ArgumentParser()
ap.add_argument("out")
ap.add_argument("--crop", default="180:180:358:135")
ap.add_argument("--frames", type=int, default=4)
ap.add_argument("--hold", type=float, default=4)
a = ap.parse_args()
os.chdir(a.out)

sync = dict(l.split() for l in open("sync.txt"))
record_start, flash_cmd = float(sync["record_start"]), float(sync["flash_cmd"])
steps = [l.rstrip("\n").split("|", 2) for l in open("steps.txt") if l.strip()]

# Mean brightness of the display area for every frame, to find the flash.
w, h, x, y = a.crop.split(":")
raw = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", "video.mov", "-vf",
                      f"crop={a.crop},scale=1:1", "-f", "rawvideo", "-pix_fmt", "gray", "-"],
                     capture_output=True, check=True).stdout
fps = 30.0
# Skip the camera's first second (auto exposure), then take the first jump from the black
# frame to the white one.
start = int(fps)
dark = min(raw[start:start + int(6 * fps)])
flash_frame = next((i for i in range(start + 5, min(len(raw), start + int(15 * fps)))
                    if raw[i] > dark + 60 and max(raw[i - 5:i]) < dark + 20), None)
if flash_frame is not None:
    offset = flash_frame / fps - flash_cmd  # video time = clock time + offset
    print(f"flash seen at video {flash_frame / fps:.2f} s")
else:
    # No visible flash (the screen was already bright). The camera's first frame arrives
    # about 1.4 s after ffmpeg starts (measured with the flash on this Mac).
    offset = -(record_start + 1.4)
    print("no flash found, using the recording start time (about 0.1 s less accurate)")

os.makedirs("frames", exist_ok=True)
names = []
for row, (t, label, args) in enumerate(steps):
    for k in range(a.frames):
        vt = float(t) + offset + 0.5 + k * (a.hold - 0.7) / max(1, a.frames - 1)
        vt = min(vt, len(raw) / fps - 0.2)
        name = f"frames/{row:03d}_{k}.jpg"
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-ss", f"{max(0, vt):.3f}", "-i", "video.mov",
                        "-vf", f"crop={a.crop},scale=120:-1", "-frames:v", "1", "-update", "1", "-y", name], check=True)
        names.append(name)
subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-pattern_type", "glob", "-i", "frames/*.jpg",
                "-vf", f"tile={a.frames}x{len(steps)}:padding=3", "-frames:v", "1", "-update", "1", "-y", "sheet.jpg"],
               check=True)
for row, (_, label, args) in enumerate(steps):
    print(f"row {row + 1}: {label}  ({args.strip()})")
print("wrote sheet.jpg")
