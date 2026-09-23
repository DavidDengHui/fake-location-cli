#!/usr/bin/env python3
"""
flc_ddi.py - offline Developer Disk Image (DDI) management.

The personalized DDI (about 15 MB) ships inside the package under ddi\\, so the
big first-run GitHub download never happens on an offline machine. The only
network step that cannot be removed is Apple's one-time, per-device TSS
personalization signature (a few KB) on the very first install to a device;
once installed the DDI persists on the iPhone and later runs are fully offline.

Usage:
    python flc_ddi.py sync                 copy bundled DDI into the local cache
    python flc_ddi.py status               show bundled/cached build id and device install state
    python flc_ddi.py install [udid]       personalize and install the DDI onto the device
"""
import asyncio
import plistlib
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CRYPTEX = "Xcode_iOS_DDI_Cryptex"
PERSONALIZED = "Xcode_iOS_DDI_Personalized"


def _build_id(path: Path):
    try:
        return plistlib.loads(path.read_bytes()).get("ProductBuildVersion")
    except Exception:
        return None


def bundled_id():
    return _build_id(ROOT / "assets" / "ddi" / CRYPTEX / "BuildManifest.plist")


def cache_ids():
    from pymobiledevice3.common import get_home_folder
    home = get_home_folder()
    return {
        name: _build_id(home / name / "BuildManifest.plist")
        for name in (PERSONALIZED, CRYPTEX)
    }


def cmd_sync():
    import flc_set
    flc_set.sync_local_ddi()
    ids = cache_ids()
    print(f"[flc] DDI cache ready. Cryptex build: {ids[CRYPTEX] or 'missing'}")


async def device_installed(rsd):
    """Return InstalledCryptex if the DDI cryptex is present, else None."""
    from pymobiledevice3.services.cryptexd import CryptexdService, DDI_CRYPTEX_IDENTIFIER
    installed = await CryptexdService(rsd).copy_installed()
    return next((c for c in installed if c.identifier == DDI_CRYPTEX_IDENTIFIER), None)


async def cmd_status(udid=None):
    print(f"[flc] Bundled DDI build : {bundled_id() or 'NOT PRESENT'}")
    try:
        ids = cache_ids()
        print(f"[flc] Cached cryptex     : {ids[CRYPTEX] or 'missing (run: flc ddi sync)'}")
        print(f"[flc] Cached personalized: {ids[PERSONALIZED] or 'missing'}")
    except Exception as ex:
        print(f"[flc] Could not read cache: {ex}")
        return
    # Optional device state (requires a connected device + tunnel).
    try:
        from pymobiledevice3.remote import userspace_tunnel
        rsd = await asyncio.wait_for(userspace_tunnel.establish_userspace_rsd(serial=udid), timeout=25)
        info = await device_installed(rsd)
        if info is not None:
            print(f"[flc] Device DDI         : INSTALLED ({info.version}) - fully offline from now on")
        else:
            print("[flc] Device DDI         : not installed (run: flc ddi install)")
    except asyncio.TimeoutError:
        print("[flc] Device DDI         : unknown (no device responded within 25s)")
    except Exception as ex:
        print(f"[flc] Device DDI         : unknown ({type(ex).__name__})")


async def cmd_install(udid=None):
    import flc_set
    flc_set.sync_local_ddi()
    from pymobiledevice3.remote import userspace_tunnel
    from pymobiledevice3.services.cryptexd import CryptexdService
    from pymobiledevice3.exceptions import AlreadyMountedError
    print("[flc] Connecting to the device (userspace tunnel)...")
    rsd = await userspace_tunnel.establish_userspace_rsd(serial=udid)
    try:
        info = await CryptexdService(rsd).auto_install_ddi()
        print(f"[flc] Developer disk image installed: {info.identifier} {info.version}")
    except AlreadyMountedError:
        print("[flc] Developer disk image is already installed on this device.")
    print("[flc] Done. Location commands now work and stay offline on this iPhone.")


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd = argv[1]
    udid = argv[2] if len(argv) > 2 else None
    if cmd in ("sync",):
        cmd_sync()
        return 0
    if cmd in ("status", "-s"):
        asyncio.run(cmd_status(udid))
        return 0
    if cmd in ("install", "-i"):
        try:
            asyncio.run(cmd_install(udid))
        except KeyboardInterrupt:
            pass
        return 0
    print(f"Unknown ddi action: {cmd}")
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
