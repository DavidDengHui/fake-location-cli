#!/usr/bin/env python3
"""
flc_route.py - build a GPX track from simple text/CSV, or create one interactively.

The iPhone location replay (pymobiledevice3 play_gpx_file) only walks
<track>/<segment>/<point> and paces between two points that both carry a
timestamp. This helper turns plain text lines into a valid GPX 1.1 track.

Line format (separators can be spaces, commas, tabs, ';' or '|'):
    [time] latitude longitude

  * time is optional.
      - seconds from the start, e.g. 0, 10, 25.5
      - or a clock value HH:MM:SS / MM:SS, e.g. 08:00:10
    If a line has no time, points are auto-spaced --step seconds apart.
  * lines starting with '#' and blank lines are ignored (in a file).

Examples:
    0 23.137106 113.331353
    10 23.138000 113.332000
    25.5 23.139000 113.333000
    23.137106 113.331353            # auto-timed

Usage:
    python flc_route.py convert  <input.txt|.csv> <output.gpx> [--step 10]
    python flc_route.py interactive <output.gpx> [--step 10]
"""
import sys
import re
import os
import datetime

DEFAULT_STEP = 10.0
# A fixed UTC base; only the *differences* between points matter for replay.
BASE = datetime.datetime(2026, 1, 1, 0, 0, 0, tzinfo=datetime.timezone.utc)

SEP_RE = re.compile(r"[\s,;|]+")


def parse_time(token):
    """Parse a relative-seconds number or HH:MM:SS / MM:SS clock -> seconds(float)."""
    token = token.strip()
    if ":" in token:
        parts = [float(p) for p in token.split(":") if p != ""]
        if len(parts) == 3:
            h, m, s = parts
        elif len(parts) == 2:
            h, m, s = 0.0, parts[0], parts[1]
        else:
            h, m, s = 0.0, 0.0, parts[0]
        return h * 3600.0 + m * 60.0 + s
    return float(token)


def parse_lines(lines, step=DEFAULT_STEP):
    """Return [(seconds, lat, lng), ...] strictly increasing in time."""
    points = []
    auto_t = 0.0
    prev_t = None
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        # strip a possible leading index/numbering like "1) ..." is left as-is
        toks = [t for t in SEP_RE.split(line) if t != ""]
        if len(toks) < 2:
            raise ValueError(f"cannot parse line (need lat lng at least): {line!r}")
        try:
            if len(toks) >= 3:
                t = parse_time(toks[0])
                lat = float(toks[-2].replace(",", "."))
                lng = float(toks[-1].replace(",", "."))
            else:
                lat = float(toks[0].replace(",", "."))
                lng = float(toks[1].replace(",", "."))
                t = auto_t
                auto_t += step
        except ValueError:
            raise ValueError(f"invalid numeric value in line: {line!r}")
        if not (-90.0 <= lat <= 90.0) or not (-180.0 <= lng <= 180.0):
            raise ValueError(f"coordinates out of range in line: {line!r}")
        # ensure strictly increasing timestamps
        if prev_t is not None and t <= prev_t:
            t = prev_t + step
        if len(toks) < 3:
            auto_t = t + step  # keep auto sequence in sync after clamping
        prev_t = t
        points.append((float(t), lat, lng))
    if not points:
        raise ValueError("no route points found")
    return points


def iso_time(seconds):
    dt = BASE + datetime.timedelta(seconds=float(seconds))
    # isoformat gives e.g. 2026-01-01T00:00:10.500000+00:00 -> use Z suffix
    return dt.isoformat().replace("+00:00", "Z")


def build_gpx(points, name="flc route"):
    out = []
    out.append('<?xml version="1.0" encoding="UTF-8"?>')
    out.append('<gpx version="1.1" creator="flc" xmlns="http://www.topografix.com/GPX/1/1">')
    out.append('  <metadata><name>%s</name></metadata>' % name)
    out.append('  <trk>')
    out.append('    <name>%s</name>' % name)
    out.append('    <trkseg>')
    for t, lat, lng in points:
        out.append('      <trkpt lat="%.7f" lon="%.7f"><time>%s</time></trkpt>'
                   % (lat, lng, iso_time(t)))
    out.append('    </trkseg>')
    out.append('  </trk>')
    out.append('</gpx>')
    return "\n".join(out) + "\n"


def write_gpx(points, out_path, name="flc route"):
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(build_gpx(points, name))


def summarize(points):
    total = points[-1][0] - points[0][0]
    return len(points), total, points[0], points[-1]


def run_convert(input_path, out_path, step):
    with open(input_path, "r", encoding="utf-8-sig") as f:
        lines = f.readlines()
    points = parse_lines(lines, step)
    write_gpx(points, out_path, name=os.path.splitext(os.path.basename(input_path))[0])
    n, total, first, last = summarize(points)
    print(f"[flc] Converted: {input_path}")
    print(f"[flc] {n} points, duration {total:.0f}s -> {out_path}")
    print(f"[flc] start {first[1]},{first[2]}  end {last[1]},{last[2]}")
    return 0


def run_interactive(out_path, step):
    print("Create a route line by line.")
    print("Each line:  [time] latitude longitude")
    print("  - time optional: seconds from start (0, 10, 25.5) or HH:MM:SS")
    print(f"  - without time, points are spaced {step:g}s apart")
    print("  - example:  0 23.137106 113.331353")
    print("  - example:  10 23.138000 113.332000")
    print("Press ENTER on an empty line to finish.\n")
    raw_lines = []
    n = 0
    while True:
        try:
            line = input("point %d> " % (n + 1))
        except EOFError:
            break
        if line.strip() == "":
            break
        if line.strip().startswith("#"):
            continue
        try:
            pts = parse_lines(raw_lines + [line], step)
            t, lat, lng = pts[-1]
            raw_lines.append(line)
            n = len(raw_lines)
            print("    added #%d at t=%gs  %.7f, %.7f" % (n, t, lat, lng))
        except ValueError as ex:
            print("    skipped: %s" % ex)
    if not raw_lines:
        print("[flc] No points entered; nothing saved.")
        return 1
    points = parse_lines(raw_lines, step)
    write_gpx(points, out_path, name="interactive route")
    cnt, total, first, last = summarize(points)
    print("")
    print(f"[flc] Saved route: {out_path}")
    print(f"[flc] {cnt} points, duration {total:.0f}s")
    print(f"[flc] start {first[1]},{first[2]}  end {last[1]},{last[2]}")
    return 0


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    mode = argv[1]
    step = DEFAULT_STEP
    positional = []
    i = 2
    while i < len(argv):
        if argv[i] == "--step" and i + 1 < len(argv):
            try:
                step = float(argv[i + 1])
            except ValueError:
                print("Invalid --step value.")
                return 2
            i += 2
        else:
            positional.append(argv[i])
            i += 1
    if mode in ("convert", "c"):
        if len(positional) < 2:
            print("Usage: flc_route.py convert <input.txt|.csv> <output.gpx> [--step 10]")
            return 2
        if not os.path.isfile(positional[0]):
            print(f"Input file not found: {positional[0]}")
            return 2
        try:
            return run_convert(positional[0], positional[1], step)
        except ValueError as ex:
            print(f"[flc] {ex}")
            return 2
    elif mode in ("interactive", "i", "new"):
        return run_interactive(positional[0], step)
    else:
        print(__doc__)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
