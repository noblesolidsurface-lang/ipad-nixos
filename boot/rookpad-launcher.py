#!/usr/bin/env python3
"""RookPad: curses-based retro launcher for the iPad Air 2 running Linux.

Scans $ROOKPAD_ROMS (default ~/roms) for files; by extension picks a
RetroArch libretro core and launches `retroarch -L CORE ROM`. Runs on
the Linux VT console (framebuffer) or over SSH. Arrow keys navigate,
Enter launches, q quits.

Designed to be the init-less single app on tty1 after NixOS boot.
"""

import curses
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

LOGO = r"""
   ____             _    ____          _
  |  _ \ ___   ___ | | _|  _ \ __ _  __| |
  | |_) / _ \ / _ \| |/ / |_) / _` |/ _` |
  |  _ < (_) | (_) |   <|  __/ (_| | (_| |
  |_| \_\___/ \___/|_|\_\_|   \__,_|\__,_|

       Linux on the Apple A8X — v1.0
"""

# Extension -> (friendly name, libretro core base name).
# Nixpkgs' retroarch-cores puts cores at
# ${core}/lib/retroarch/cores/${core_libretro}.so (or .dylib on Darwin).
EXT_CORES = {
    ".nes": ("Nintendo NES", "fceumm_libretro"),
    ".sfc": ("Super Nintendo", "snes9x_libretro"),
    ".smc": ("Super Nintendo", "snes9x_libretro"),
    ".gb":  ("Game Boy", "gambatte_libretro"),
    ".gbc": ("Game Boy Color", "gambatte_libretro"),
    ".gba": ("Game Boy Advance", "mgba_libretro"),
    ".md":  ("Sega Genesis", "picodrive_libretro"),
    ".gen": ("Sega Genesis", "picodrive_libretro"),
    ".smd": ("Sega Genesis", "picodrive_libretro"),
    ".a26": ("Atari 2600", "stella2014_libretro"),
    ".zip": ("Arcade (MAME)", "mame2003_plus_libretro"),
    ".exe": ("DOS (DOSBox)", "dosbox_pure_libretro"),
    ".iso": ("DOS (DOSBox)", "dosbox_pure_libretro"),
}


def scan_roms(root: Path):
    """Return a sorted list of (display_name, path, core_name, platform)."""
    items = []
    if not root.exists():
        return items
    for p in sorted(root.rglob("*")):
        if not p.is_file():
            continue
        ext = p.suffix.lower()
        if ext not in EXT_CORES:
            continue
        platform, core = EXT_CORES[ext]
        items.append((p.stem, p, core, platform))
    return items


def find_core(core_name: str):
    """Find a libretro core .so on disk; return the path or None."""
    # Nix places cores under /run/current-system/sw/lib/retroarch/cores/
    # and in each core package's own output. Scan both.
    search_dirs = [
        Path("/run/current-system/sw/lib/retroarch/cores"),
        Path("/nix/var/nix/profiles/system/sw/lib/retroarch/cores"),
    ]
    for d in search_dirs:
        if d.exists():
            cand = d / f"{core_name}.so"
            if cand.exists():
                return cand
    # Fallback: find anywhere under /nix/store (slow, but foolproof).
    try:
        out = subprocess.check_output(
            ["find", "/nix/store", "-maxdepth", "5", "-name", f"{core_name}.so"],
            stderr=subprocess.DEVNULL, timeout=10,
        ).decode().splitlines()
        if out:
            return Path(out[0])
    except Exception:
        pass
    return None


def launch(stdscr, rom_path: Path, core_name: str, platform: str):
    """Suspend curses, run RetroArch, then come back to the menu."""
    core_so = find_core(core_name)
    curses.endwin()
    print(f"\nRookPad: launching {platform} — {rom_path.name}")
    if core_so is None:
        print(f"ERROR: libretro core '{core_name}' is not installed.")
        print("Press enter to return to RookPad.")
        try:
            input()
        except Exception:
            time.sleep(5)
        return
    retroarch = shutil.which("retroarch") or "/run/current-system/sw/bin/retroarch"
    cmd = [retroarch, "-L", str(core_so), str(rom_path),
           "--verbose", "--log-file=/tmp/rookpad-last.log"]
    print(f"$ {' '.join(cmd)}")
    try:
        subprocess.run(cmd, check=False)
    except Exception as e:
        print(f"RookPad: retroarch exited with error: {e}")
    print("\nRookPad: back to menu. Press enter.")
    try:
        input()
    except Exception:
        time.sleep(3)


def draw(stdscr, roms, idx, status=""):
    stdscr.clear()
    h, w = stdscr.getmaxyx()
    # Logo
    for i, line in enumerate(LOGO.splitlines()[:min(len(LOGO.splitlines()), h - 1)]):
        try:
            stdscr.addnstr(i, 0, line, w - 1, curses.A_BOLD)
        except curses.error:
            pass
    y = len(LOGO.splitlines()) + 1
    if y >= h - 1:
        return
    hint = "↑/↓ select  ·  Enter launch  ·  r rescan  ·  q quit"
    try:
        stdscr.addnstr(y, 0, hint, w - 1, curses.A_DIM)
    except curses.error:
        pass
    y += 2
    if not roms:
        msg = "No ROMs found in $ROOKPAD_ROMS. scp them to the iPad and press r."
        try:
            stdscr.addnstr(y, 0, msg, w - 1)
        except curses.error:
            pass
    else:
        rows = h - y - 2
        start = max(0, idx - rows // 2)
        end = min(len(roms), start + rows)
        for i in range(start, end):
            name, _, _, platform = roms[i]
            line = f"  {platform:16s}  {name}"
            attr = curses.A_REVERSE if i == idx else curses.A_NORMAL
            try:
                stdscr.addnstr(y + (i - start), 0, line[: w - 1], w - 1, attr)
            except curses.error:
                pass
    if status:
        try:
            stdscr.addnstr(h - 1, 0, status[: w - 1], w - 1, curses.A_DIM)
        except curses.error:
            pass
    stdscr.refresh()


def ui(stdscr):
    curses.curs_set(0)
    stdscr.keypad(True)
    try:
        curses.start_color()
        curses.use_default_colors()
    except curses.error:
        pass
    roms_root = Path(os.environ.get("ROOKPAD_ROMS", str(Path.home() / "roms")))
    roms = scan_roms(roms_root)
    idx = 0
    status = f"roms dir: {roms_root}  ·  {len(roms)} rom(s)"
    while True:
        draw(stdscr, roms, idx, status)
        try:
            key = stdscr.getch()
        except KeyboardInterrupt:
            break
        if key in (ord("q"), ord("Q")):
            break
        if key == ord("r"):
            roms = scan_roms(roms_root)
            idx = min(idx, max(0, len(roms) - 1))
            status = f"rescanned {roms_root} — {len(roms)} rom(s)"
            continue
        if not roms:
            continue
        if key in (curses.KEY_UP, ord("k")):
            idx = max(0, idx - 1)
        elif key in (curses.KEY_DOWN, ord("j")):
            idx = min(len(roms) - 1, idx + 1)
        elif key in (curses.KEY_PPAGE,):
            idx = max(0, idx - 10)
        elif key in (curses.KEY_NPAGE,):
            idx = min(len(roms) - 1, idx + 10)
        elif key in (curses.KEY_HOME,):
            idx = 0
        elif key in (curses.KEY_END,):
            idx = len(roms) - 1
        elif key in (10, 13, curses.KEY_ENTER):
            name, path, core, platform = roms[idx]
            launch(stdscr, path, core, platform)
            stdscr.clear()


def main():
    try:
        curses.wrapper(ui)
    except Exception as e:
        print(f"RookPad crashed: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
