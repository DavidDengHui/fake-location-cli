# Fake Location CLI - flc (Windows, portable)

**English** | [中文](README-CN.md)

The repository is named **Fake Location CLI**; the program itself is written and
invoked as **`flc`** throughout this document.

A small, self-contained command-line tool that simulates the GPS location of a
connected iPhone. It is built on top of [pymobiledevice3](https://github.com/doronz88/pymobiledevice3)
and ships with its own portable Python, so **nothing has to be installed first**
(except the iPhone USB driver, which is bundled offline).

Everything is inside one folder. Copy the folder to any Windows PC and it runs.

---

## 1. What is inside

```
flc\
  flc.cmd                              Launcher (run this / the "flc" command)
  flc-main.ps1                          All program logic (engine, launched by flc.cmd)
  flc_set.py                            Persistent location holder (keepalive + auto-reconnect)
  flc_route.py                          Build GPX routes from text/CSV or line by line
  flc_ddi.py                            Offline Developer Disk Image (DDI) management
  requirements.txt                      Exact pinned Python packages (for building)
  assets\                               All runtime dependencies live in this one folder
    python\                             Trimmed portable Python 3.12 + pymobiledevice3
    drivers\
      AppleMobileDeviceSupport64.msi    Offline Apple USB driver
    ddi\                                Offline Developer Disk Image (~32 MB)
    dist\                               Build materials (only after "flc configure")
      python-3.12.10.nupkg              Official NuGet python package
      wheels\                           All pinned wheels (offline install cache)
  data\                                 Generated routes & data (created automatically)
    example-route.gpx / .txt            Bundled samples for the route replay
  logs\                                 Log files (created automatically)
  README.md
  README-CN.md
```

All third-party runtime pieces are kept under `assets\` so the program folder
stays tidy. The shipped portable package already contains `assets\python`,
`assets\drivers` and `assets\ddi`, so it runs without any download. `assets\dist`
only appears if you run `flc configure` to (re)build the runtime from sources.

The `wintun` tunnel driver is already bundled inside the pymobiledevice3 package
(amd64/arm64/x86/arm) — no separate tunnel driver is needed.

### Requirements

- Windows 10 / 11 (64-bit).
- An iPhone on **iOS 17 or newer** (tested on iOS 17–27).
- A USB data cable (USB connection is the supported path).
- Administrator rights only for: installing the driver, and starting/stopping
  the Apple service. Setting a location itself does **not** need administrator.

---

## 2. Quick start

### A) Using the portable package (recommended)

The shipped `flc` folder already contains the portable Python, the driver and
the DDI. Open a command window **in this folder** (`Shift+Right-click` →
*Open in Terminal/PowerShell here*), then:

1. **Prepare the PC** (one time). Recommended:
   ```
   flc make install
   ```
   This adds the folder to your user PATH **and** automatically installs the USB
   driver (one UAC prompt — click **Yes**), caches the offline DDI, and, if an
   iPhone is already connected, prepares the DDI on it. Then open a **new**
   command window and you can type `flc` from any folder.

   If you prefer not to change the PATH, run just the driver step instead:
   `flc drivers install` (administrator). The DDI is prepared on the first `flc set`.

2. **Connect the iPhone** with USB, unlock it, then:
   ```
   flc devices connect
   ```
   Approve UAC, and **on the iPhone tap "Trust" and enter the passcode**.

3. **Enable Developer Mode** (iOS 16+ and the DVT location feature require it):
   on the iPhone go to **Settings → Privacy & Security → Developer Mode → ON**,
   then restart the phone when asked. (The Developer Mode menu appears after the
   first developer connection.)

4. **Set a location** (no administrator needed). Just give the two numbers —
   latitude then longitude. The window stays open and **holds** the location.
   ```
   flc set 23.137106 113.331353
   ```
   With no numbers you are prompted for them one by one. The required Developer
   Disk Image is **bundled offline** in `assets\ddi\` and prepared automatically,
   so the first `set` does not download the big image. When it finishes the iPhone
   reports the new location in Maps and other apps.

5. **Return to the real location**: click into the running window and press
   **Ctrl+C** (the tool clears the simulation and restores real GPS), or run:
   ```
   flc set own
   ```
   If you close the window without Ctrl+C and the fake spot remains, run
   `flc set own` once.

### B) Starting from source only (GitHub / a source zip)

A source-only folder has no `assets\` and cannot run until the runtime is built.
On a PC with internet access:

```
flc configure
flc make
```

`flc configure` downloads, from official sources, the portable Python NuGet
package, all pinned Python wheels, the Apple driver `.msi` and the offline DDI
into `assets\` (items already present are skipped). Then `flc make` builds the
trimmed portable Python offline into `assets\python` (no compiler needed). After
that, continue with steps 1–5 above.

---

## 3. Command reference

All commands work with short aliases (e.g. `flc -c`).

### configure — download every runtime dependency

| Command | Alias | Meaning |
|---|---|---|
| `flc configure` | `-c` | Download all runtime dependencies from official sources into `assets\` (the NuGet Python package, pinned wheels, the Apple driver `.msi`, and the offline DDI). Items already present and complete are skipped. Safe to run repeatedly. |

Downloaded build materials are kept under `assets\dist\`; the driver and DDI go
to `assets\drivers\` and `assets\ddi\`. Internet is required. The shipped
portable package never needs this command.

### make — build the runtime, install/uninstall the command

| Command | Alias | Meaning |
|---|---|---|
| `flc make` | — | Build the trimmed portable Python from `assets\dist` into `assets\python` (fully offline, no compiler). Run after `flc configure`. |
| `flc make install` | `-i` | Add this folder to your **user PATH**, then automatically install the USB driver (one UAC prompt), cache the offline DDI, prepare the DDI on a connected phone, and finally print a full `flc server status` summary. |
| `flc make -i --prefix=PATH` | `--p=PATH` | Copy the whole program (including `assets\`) to PATH and add **that** folder to the user PATH. `-i` is the short install flag and `--p=` the short prefix flag. Example: `flc make -i --p="C:\flc"` (same as `flc make install --prefix="C:\flc"`). |
| `flc make uninstall` | `-u` | Remove the folder from the user PATH, then ask whether to delete the whole program folder. Add `-y` to answer yes. |
| `flc make clean` | `-c` | Delete the whole `assets\` folder (built Python, driver, DDI and build materials), leaving only the program sources. Rebuild later with `flc configure` then `flc make`. Asks for `YES`; add `-y` to skip. |

After `flc make install`, open a **new** command window and type `flc help`.

`--prefix` also accepts `--prefix PATH` (space form). The folder itself still
works by running `flc.cmd` directly even if it is not on the PATH.

### server — background pieces

| Command | Alias | Meaning |
|---|---|---|
| `flc server status` | `-s` | Show portable Python, pymobiledevice3 version, the Apple service, the tunneld port, the offline driver/DDI, and connected devices. |
| `flc server kill` | `-k` | Stop conflicting background processes (anything holding tunneld port 49151, and stray `pymobiledevice3 tunneld` / `simulate-location` processes). Administrator. |

### drivers — the iPhone USB driver

| Command | Alias | Meaning |
|---|---|---|
| `flc drivers list` | `-l` | List required drivers and whether an offline installer is bundled. |
| `flc drivers status` | `-s` | Show whether the driver is installed, the service state, and live USB nodes. |
| `flc drivers install` | `-i` | Install the driver silently (offline `.msi` if present, otherwise download it). Administrator. |
| `flc drivers uninstall` | `-u` | Uninstall Apple Mobile Device Support. Administrator. |

### devices — connected iPhones

| Command | Alias | Meaning |
|---|---|---|
| `flc devices list` | `-l` | List connected Apple devices (name, model, iOS, UDID, USB/Network). |
| `flc devices connect` | `-c` | Start the Apple service and send a pairing request (tap Trust on the iPhone). Administrator. |
| `flc devices disconnect` | `-d` | Stop the Apple service, releasing all iPhone connections. Administrator. |
| `flc devices reconnect` | `-r` | Restart the Apple service and re-list devices (handy after a glitch). Administrator. |

### ddi — offline Developer Disk Image

iOS 17+ location services require the Developer Disk Image (DDI) to be present on
the device. The image itself (~32 MB) is **bundled offline** in `assets\ddi\`, so
flc never performs the big GitHub download. It is copied into the local cache
automatically before the first `set`.

| Command | Alias | Meaning |
|---|---|---|
| `flc ddi status` | `-s` | Show the bundled and cached DDI build id, and whether the connected iPhone already has it installed. |
| `flc ddi sync` | — | Copy the bundled offline DDI into the local cache (also done automatically on first `set`). |
| `flc ddi install` | `-i` | Personalize and install the DDI on the connected iPhone (normally automatic on the first `set`). |

The **only** online step that cannot be pre-bundled is Apple's one-time
personalization signature (a few KB) on the very first install to *each* iPhone;
after that the DDI persists on the phone and every later run is fully offline.

### location

| Command | Meaning |
|---|---|
| `flc set <lat> <lng>` | Set and **hold** a location using two plain numbers (latitude then longitude). Example: `flc set 23.137106 113.331353` |
| `flc set` | No coordinates given — you are prompted to type latitude and longitude one by one (example shown: `23.137106 113.331353`). |
| `flc set -Lat <lat> -Lng <lng>` | The named form still works, equivalent to the plain two-number form. |
| `flc set gpx <file>` | Replay a route (`.gpx`, or a `.txt`/`.csv` auto-converted to GPX), then hold the last point. See [GPX replay](#gpx-replay). |
| `flc set gpx new` | Build a route **line by line** (time + latitude + longitude), then replay it. See [Building a route](#building-a-route). |
| `flc set own` or `flc set -o` | Clear the simulation and restore the real location. |
| `flc help` / `flc -h` | Show the help. |

Coordinates are decimal **latitude then longitude**. Negative numbers are fine
(the tool inserts the `--` separator for you), e.g. New York:
`flc set 40.690008 -74.045843`.

> **Coordinate system note:** the phone location service uses **WGS-84**.
> Coordinates copied from Chinese maps (Gaode/AMap, Tencent, Baidu) are GCJ-02 or
> BD-09 and can be off by a few hundred metres in mainland China. For exact
> results in China, convert the map coordinate to WGS-84 first. Outside mainland
> China (and for most testing) the two agree closely enough.

---

## 4. How the location is held (and why it does not revert)

`flc set` runs the DVT location service in the **userspace tunnel** mode
(`--userspace`), a pure-Python network stack that needs **no administrator and no
background tunneld**. The holding script (`flc_set.py`) does more than send the
spot once:

- It re-applies the location **every 15 seconds** on the same connection, so the
  phone keeps reporting the fake spot instead of drifting back to real GPS.
- If the USB/network tunnel drops, it **automatically rebuilds the tunnel** and
  resumes holding.
- On **Ctrl+C** (or termination) it opens a fresh connection and sends a
  **clear**, so the phone returns to its real location.

The running window prints lines like:

```
[flc] Simulated location set: 23.137106, 113.331353
[flc] Holding location (re-applied every 15s). Keep this window open.
[flc] 03:14:50  location re-applied  (23.137106, 113.331353)
```

- **Keep the window open** to keep the fake location.
- Press **Ctrl+C** in that window for a clean stop that restores real GPS.
- If you close the window directly (or the fake spot persists), run
  `flc set own` once.

### GPX replay

`flc set gpx <route.gpx>` replays a recorded **track** so the phone moves along
it:

- Each track point is sent in order. If points carry timestamps, the tool waits
  for the real time gap between them, reproducing the recorded speed.
- When the track ends it **holds the last point** with the same 15-second
  keepalive.
- A working sample is included: `flc set gpx data\example-route.gpx`.

Export a route from Strava, Komoot, AllTrails, a GPS watch, or a route planner as
**GPX 1.1 track** (`<trk>`). Files containing only `<rte>` routes or waypoints
are not replayed by the underlying library — convert them to a track first.

### Building a route

You do not need to hand-write GPX. flc can build a track from plain text or by
typing points one per line.

**A) Replay a plain-text / CSV route** — `.txt` or `.csv` is converted to GPX
automatically, then replayed. One point per line, separators may be spaces,
commas, tabs, `;` or `|`. The time is optional:

```
0 23.137106 113.331353
10 23.138000 113.332000
25.5 23.139000 113.333000
```

Each line is `[time] latitude longitude`. Time is seconds from the start
(`0`, `10`, `25.5`) or a clock value `HH:MM:SS` / `MM:SS`. If you omit time,
points are automatically spaced 10 seconds apart. Lines starting with `#` are
comments. Then:

```
flc set gpx my-walk.txt
```

The converted GPX is saved under `data\` and replayed.

**B) Build a route interactively** — run `flc set gpx new` (or `flc set gpx`
with no file and type `new`). You are prompted for each point; press **Enter on
an empty line** to finish. The route is saved to `data\route-<timestamp>.gpx`
and then replayed.

```
point 1> 0 23.137106 113.331353
point 2> 10 23.138000 113.332000
point 3> 23.139000 113.333000
point 4>
```

A `data\example-route.txt` is included alongside the `.gpx` sample.

---

## 5. Move it to another PC

The whole folder is portable.

1. Copy the entire **`flc`** folder to the other PC (a USB stick or network
   copy). Any location is fine, e.g. `C:\flc`, `C:\Program Files\flc`, or a
   portable drive.
2. On that PC, run `flc make install` once: it installs the USB driver (one UAC
   prompt), caches the offline DDI, and adds the folder to your user PATH. To put
   it in a fixed location, use `flc make install --prefix="C:\flc"`. If you would
   rather not touch the PATH, run `flc drivers install` (administrator) instead.
4. No Python, pip, or other software has to be installed. The bundled
   `assets\python` folder is self-contained.

Do not copy only `flc.cmd` — the `assets\` folder must travel with it. The
bundled DDI means the new PC needs no large download either.

To publish the tool on a repository without shipping large third-party binaries,
copy the folder, run `flc make clean` to leave sources only, and push that. A
recipient then runs `flc configure` and `flc make` once on an internet-connected
PC to rebuild the portable runtime.

---

## 6. Troubleshooting

- **Every command just prints the help / nothing runs** — make sure you invoke
  the launcher `flc.cmd` (or the `flc` command after `make install`); the engine
  is `flc-main.ps1` and is not meant to be run by name. If you upgraded from an
  older build, open a **new** command window so Windows resolves `flc` to
  `flc.cmd` again. Running `flc devices list` must print `Connected Apple devices:`.
- **`'flc' is not recognized`** — either run `flc.cmd` from inside the folder,
  or run `flc make install` once and open a new command window.
- **A source-only folder says the runtime is missing** — run `flc configure`
  then `flc make` (internet needed) to build `assets\python`, or use the shipped
  portable package.
- **`ConnectionRefusedError [WinError 1225]` / no device found** — the Apple
  Mobile Device Service is stopped or the driver is missing. Run
  `flc drivers status`, then `flc devices connect` (approve UAC) and
  `flc devices reconnect`. Also try a different USB cable / USB port (data, not
  charge-only).
- **UAC appears** — driver install, service control and `server kill` need
  administrator; click **Yes** (the account is already an administrator, so no
  password is normally required).
- **Trust prompt does not appear** — run `flc devices connect` again, or
  `flc devices reconnect`; unplug and replug the iPhone; make sure it is unlocked.
- **Developer Mode / Developer Disk Image errors** — enable Developer Mode
  (section 2). The disk image is bundled offline; run `flc ddi status` to check
  it and `flc ddi install` to install it on the phone. The very first install to
  a new iPhone needs a small, one-time Apple personalization handshake; after
  that it works offline.
- **A newer iOS says the DDI build is wrong** — each iOS beta/release can need a
  matching DDI. Update pymobiledevice3 (or replace the `assets\ddi\` folder) so
  the bundled build id matches, then run `flc ddi sync`.
- **Location is wrong / does not move / reverts to real GPS** — the holding
  window must stay open; it re-applies the spot every 15 seconds and rebuilds the
  tunnel if it drops. If the spot still reverts, run `flc set own`, then `set`
  again. Some apps cache location; reopen them.
- **GPX track does not move** — the file must contain a `<trk>` track (not only
  `<rte>`/waypoints); see [GPX replay](#gpx-replay). Use the bundled
  `data\example-route.gpx` to confirm the feature works.
- **Port 49151 already in use** — another tunneld is running. Run
  `flc server kill`.
- **Logs** — see `logs\flc.log` and `logs\amds-install.log`.

---

## 7. Uninstall

- Remove the command from PATH and optionally delete the folder:
  `flc make uninstall` (it removes the PATH entry, then asks before deleting;
  `-y` deletes immediately).
- Remove the iPhone driver (optional): `flc devices disconnect` then
  `flc drivers uninstall`.

Uninstalling the driver only removes the Apple USB support on this PC; it does
not affect the iPhone.

---

## 8. Notes

- This tool wraps the official `pymobiledevice3` command line; it does not modify
  the iPhone or install anything on it.
- Simulating a location is a developer feature for testing, development, and
  personal use. Use it lawfully and in line with the rules of any app you use.
- A fake location is reported by the phone to apps and is not a real GPS change.
- Official download sources used by `flc configure`: the Python NuGet package
  (`nuget.org/packages/python`), Python wheels from PyPI (with a Tsinghua mirror
  fallback), the Apple Mobile Device Support `.msi` from `swcdn.apple.com`
  (SHA-256 verified), and the DDI from the
  [DeveloperDiskImage](https://github.com/doronz88/DeveloperDiskImage) mirrors.
