#!/usr/bin/env python3
"""
flc_set.py - persistent fake location holder (userspace tunnel, no admin needed).

The plain `pymobiledevice3 simulate-location set` sends the location once and then
blocks on input. On Windows the pure-Python userspace tunnel can silently drop and
the iPhone then reverts to its real location. This script:

  * sets the simulated location (a fixed point) OR replays a GPX route,
  * RE-SENDS the location every KEEPALIVE seconds on the same connection,
  * fully rebuilds the tunnel if the connection is lost,
  * restores the real location on Ctrl+C / window close.

Usage:
    python flc_set.py <latitude> <longitude> [udid] [--keep <seconds>]
    python flc_set.py point <latitude> <longitude> [udid] [--keep <seconds>]
    python flc_set.py gpx <route.gpx> [udid] [--keep <seconds>]

The --keep (or -k) flag overrides the default 15-second re-apply interval
(allowed range 1-3600 seconds).
"""
import asyncio
import sys
import time
import signal
import logging

from pymobiledevice3.remote import userspace_tunnel
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation

# Keep general pymobiledevice3 logs quiet but show GPX per-point progress.
logging.basicConfig(level=logging.WARNING, format="[pmd3] %(message)s")
logging.getLogger("LocationSimulation").setLevel(logging.INFO)

KEEPALIVE = 15.0          # default re-apply interval (seconds); override with flc set ... --keep <sec>
RECONNECT_DELAY = 3.0     # wait before rebuilding a dropped tunnel

_DDI_CHECKED = False


def stamp():
    return time.strftime("%H:%M:%S")


def sync_local_ddi():
    """Copy the bundled offline DDI into pymobiledevice3's home cache.

    Avoids the first-run image download from GitHub. Idempotent: only copies when the cache is
    missing or its build id differs from the bundled one.
    """
    try:
        import shutil
        import plistlib
        from pathlib import Path
        from pymobiledevice3.common import get_home_folder

        bundled = Path(__file__).resolve().parent / "assets" / "ddi"
        if not bundled.is_dir():
            return
        home = get_home_folder()
        for name in ("Xcode_iOS_DDI_Personalized", "Xcode_iOS_DDI_Cryptex"):
            src = bundled / name
            if not src.is_dir():
                continue
            dst = home / name
            src_manifest = src / "BuildManifest.plist"
            need = True
            if (dst / "BuildManifest.plist").exists():
                try:
                    have = plistlib.loads((dst / "BuildManifest.plist").read_bytes()).get("ProductBuildVersion")
                    ship = plistlib.loads(src_manifest.read_bytes()).get("ProductBuildVersion")
                    need = have != ship
                except Exception:
                    need = True
            if need:
                if dst.exists():
                    shutil.rmtree(dst, ignore_errors=True)
                shutil.copytree(src, dst)
                print(f"[flc] Offline developer disk image ready ({name}).")
    except Exception as ex:
        print(f"[flc] Offline DDI prepare skipped: {ex}")


async def ensure_ddi(rsd):
    """Best-effort: make sure the Developer Disk Image is installed on the device.

    Already installed (the normal case after first use) returns offline and instantly via an
    AlreadyMountedError. On a brand-new device this personalizes and installs it, which needs a
    one-time small Apple TSS request (the big image is already local thanks to sync_local_ddi).
    Never blocks DVT: any failure is reported and the DVT connection is attempted regardless.
    """
    global _DDI_CHECKED
    if _DDI_CHECKED:
        return
    try:
        from pymobiledevice3.services.cryptexd import CryptexdService
        from pymobiledevice3.exceptions import AlreadyMountedError
        try:
            info = await CryptexdService(rsd).auto_install_ddi()
            print(f"[flc] Developer disk image installed on device ({info.version}).")
        except AlreadyMountedError:
            pass
        _DDI_CHECKED = True
    except Exception as ex:
        print(f"[flc] DDI auto-check: {type(ex).__name__}: {ex}")
        print("[flc] (continuing - if location commands fail, run 'flc ddi install' once)")


def gpx_last_point(path):
    """Return the last track/route point in a GPX file (or None)."""
    try:
        import gpxpy
        with open(path, "r", encoding="utf-8") as f:
            gpx = gpxpy.parse(f)
        points = list(gpx.walk(only_points=True))
        return points[-1] if points else None
    except Exception:
        return None


def parse_args(argv):
    """Return (mode, target, udid, interval). mode is 'point' (target=(lat,lng)) or 'gpx' (target=path).

    interval (seconds) comes from --keep/-k; None means use the default.
    """
    argv = list(argv)
    interval = None
    clean = []
    i = 0
    while i < len(argv):
        if argv[i] in ('--keep', '-k'):
            if i + 1 >= len(argv):
                print("Missing value for --keep. Example: flc set 23.137106 113.331353 --keep 5")
                return None
            try:
                interval = float(argv[i + 1])
            except ValueError:
                print(f"Invalid keep value: {argv[i + 1]}. Use seconds, e.g. --keep 5")
                return None
            i += 2
        else:
            clean.append(argv[i])
            i += 1
    argv = clean
    if interval is not None:
        if interval < 1 or interval > 3600:
            print("Keep interval must be between 1 and 3600 seconds.")
            return None
        if interval < 3:
            print("[flc] Warning: an interval below 3s adds no benefit and may cause message backlog on the tunnel.")
    if len(argv) < 2:
        print("Usage:")
        print("  flc_set.py <latitude> <longitude> [udid] [--keep <seconds>]")
        print("  flc_set.py gpx <route.gpx> [udid] [--keep <seconds>]")
        return None
    first = argv[1]
    if first in ("gpx", "--gpx"):
        if len(argv) < 3:
            print("GPX mode requires a file path: flc set gpx route.gpx")
            return None
        path = argv[2]
        udid = argv[3] if len(argv) > 3 else None
        return ("gpx", path, udid, interval)
    if first in ("point", "--point"):
        if len(argv) < 4:
            print("Point mode requires latitude and longitude.")
            return None
        try:
            lat = float(argv[2]); lng = float(argv[3])
        except ValueError:
            print("Invalid coordinates. Use decimal numbers, e.g. 23.137106 113.331353")
            return None
        udid = argv[4] if len(argv) > 4 else None
        return ("point", (lat, lng), udid, interval)
    # bare coordinates: <lat> <lng>
    if len(argv) < 3:
        print("Please provide both latitude and longitude.")
        return None
    try:
        lat = float(argv[1].replace(",", "."))
        lng = float(argv[2].replace(",", "."))
    except ValueError:
        print("Invalid coordinates. Use decimal numbers, e.g. 23.137106 113.331353")
        return None
    udid = argv[3] if len(argv) > 3 else None
    return ("point", (lat, lng), udid, interval)


async def hold_point(lat, lng, udid, stop_event, interval):
    """Establish the userspace tunnel once and hold a fixed point."""
    rsd = await userspace_tunnel.establish_userspace_rsd(serial=udid)
    await ensure_ddi(rsd)
    async with DvtProvider(rsd) as dvt, LocationSimulation(dvt) as loc:
        await loc.set(lat, lng)
        print(f"[flc] Simulated location set: {lat}, {lng}")
        print(f"[flc] Holding location (re-applied every {int(interval)}s). Keep this window open.")
        print("[flc] Press Ctrl+C, or close the window, to STOP and restore the real location.")
        print()
        while not stop_event.is_set():
            try:
                await asyncio.wait_for(stop_event.wait(), timeout=interval)
            except asyncio.TimeoutError:
                pass
            if stop_event.is_set():
                break
            try:
                await loc.set(lat, lng)
                print(f"[flc] {stamp()}  location re-applied  ({lat}, {lng})")
            except Exception as ex:
                print(f"[flc] {stamp()}  keepalive failed ({ex}); rebuilding tunnel...")
                raise


async def hold_gpx(path, udid, stop_event, played, interval):
    """Play a GPX route once, then hold its last point with keepalives."""
    rsd = await userspace_tunnel.establish_userspace_rsd(serial=udid)
    await ensure_ddi(rsd)
    async with DvtProvider(rsd) as dvt, LocationSimulation(dvt) as loc:
        if not played["done"]:
            print(f"[flc] Playing GPX route: {path}")
            await loc.play_gpx_file(path)
            played["done"] = True
            print("[flc] Route replay finished.")
        last = gpx_last_point(path)
        if last is None:
            print("[flc] No track points found in the GPX file.")
            return
        await loc.set(last.latitude, last.longitude)
        print(f"[flc] Holding end point: {last.latitude}, {last.longitude}")
        print(f"[flc] Holding location (re-applied every {int(interval)}s). Keep this window open.")
        print("[flc] Press Ctrl+C, or close the window, to STOP and restore the real location.")
        print()
        while not stop_event.is_set():
            try:
                await asyncio.wait_for(stop_event.wait(), timeout=interval)
            except asyncio.TimeoutError:
                pass
            if stop_event.is_set():
                break
            try:
                await loc.set(last.latitude, last.longitude)
                print(f"[flc] {stamp()}  end point re-applied  ({last.latitude}, {last.longitude})")
            except Exception as ex:
                print(f"[flc] {stamp()}  keepalive failed ({ex}); rebuilding tunnel...")
                raise


async def restore_real_location(udid):
    """Best-effort one-shot clear using a fresh connection."""
    try:
        rsd = await userspace_tunnel.establish_userspace_rsd(serial=udid)
        await ensure_ddi(rsd)
        async with DvtProvider(rsd) as dvt, LocationSimulation(dvt) as loc:
            await loc.clear()
        print("[flc] Real location restored.")
        return True
    except Exception as ex:
        print(f"[flc] Automatic restore failed: {ex}")
        print("[flc] If the phone still shows the fake location, run: flc set own")
        return False


async def run(mode, target, udid, interval):
    loop = asyncio.get_running_loop()
    stop_event = asyncio.Event()

    def request_stop():
        stop_event.set()

    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, request_stop)
        except (NotImplementedError, AttributeError, ValueError):
            try:
                signal.signal(sig, lambda s, f: request_stop())
            except Exception:
                pass

    played = {"done": False}

    while not stop_event.is_set():
        try:
            if mode == "gpx":
                await hold_gpx(target, udid, stop_event, played, interval)
            else:
                lat, lng = target
                await hold_point(lat, lng, udid, stop_event, interval)
        except asyncio.CancelledError:
            stop_event.set()
        except Exception as ex:
            if stop_event.is_set():
                break
            print(f"[flc] {stamp()}  tunnel lost: {ex}")
            print(f"[flc] reconnecting in {int(RECONNECT_DELAY)}s... (make sure the iPhone is connected and unlocked)")
            try:
                await asyncio.wait_for(stop_event.wait(), timeout=RECONNECT_DELAY)
            except asyncio.TimeoutError:
                pass

    print("[flc] Stopping, restoring the real location...")
    await restore_real_location(udid)


def main():
    parsed = parse_args(sys.argv)
    if parsed is None:
        return 2
    mode, target, udid, interval = parsed
    if interval is None:
        interval = KEEPALIVE
    sync_local_ddi()
    if mode == "point":
        lat, lng = target
        if not (-90.0 <= lat <= 90.0 and -180.0 <= lng <= 180.0):
            print("Coordinates out of range.")
            return 2
    else:
        import os
        if not os.path.isfile(target):
            print(f"GPX file not found: {target}")
            return 2
    try:
        asyncio.run(run(mode, target, udid, interval))
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
