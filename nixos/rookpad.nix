# RookPad: NixOS module that layers a retro-emulator launcher on top of
# the base ipad-air2-ram system. Imported by nixosConfigurations.rookpad.
#
# What this adds:
#   - RetroArch with a bundle of 2D-friendly libretro cores (NES, SNES,
#     Game Boy, GBA, Genesis, Atari, Arcade/MAME, DOSBox).
#   - PS5 DualSense works via USB-HID (any Lightning→USB-A/C adapter).
#   - The RookPad TUI launcher runs on tty1 (replaces the dashboard) and
#     is also what SSH users land in.
#   - A user `rookpad` to own ~/roms, with sudo access for admin.
#   - Framebuffer font bumped up for readability on the iPad's 2048×1536.
{ config, lib, pkgs, ... }:
let
  rookpadLauncher = pkgs.runCommand "rookpad-launcher" {
    buildInputs = [ pkgs.python3 pkgs.findutils ];
  } ''
    mkdir -p $out/bin
    install -m755 ${../boot/rookpad-launcher.py} $out/bin/rookpad
    # Make sure the shebang finds python at a stable path.
    sed -i '1s|.*|#!${pkgs.python3}/bin/python3|' $out/bin/rookpad
  '';

  # Core libretro set — chosen to fit comfortably in a ~500 MB squashfs
  # and only include things that run acceptably without GPU acceleration.
  cores = with pkgs.libretro; [
    fceumm            # NES
    snes9x            # SNES
    gambatte          # Game Boy / GBC
    mgba              # GBA
    picodrive         # Sega Genesis / 32X
    stella2014        # Atari 2600
    mame2003-plus     # Arcade
    dosbox-pure       # DOS
  ];

  retroarch = pkgs.wrapRetroArch { cores = cores; };
in
{
  imports = [ ./ipad-air2-ram.nix ];

  # Allow the few unfree bits (if any core happens to be unfree).
  nixpkgs.config.allowUnfreePredicate = pkg:
    builtins.elem (lib.getName pkg) [ "mame2003-plus" ];

  # Larger console font — the iPad's native framebuffer is 2048×1536,
  # so the default 8×16 is pin-dot-tiny.
  console = {
    enable = true;
    font = "ter-v32n";
    packages = [ pkgs.terminus_font ];
  };

  # The rookpad user owns ~/roms and runs the launcher.
  users.users.rookpad = {
    isNormalUser = true;
    uid = 1000;
    group = "rookpad";
    extraGroups = [ "wheel" "input" "video" "audio" ];
    home = "/home/rookpad";
    createHome = true;
    initialHashedPassword = ""; # passwordless local login (USB only)
    shell = pkgs.bash;
    openssh.authorizedKeys.keyFiles = [ ../boot/ssh/authorized_keys ];
  };
  users.groups.rookpad = { gid = 1000; };

  # wheel without password: SSH is already key-only; the only path in is
  # physical USB, which is a trust boundary of its own.
  security.sudo = {
    enable = true;
    wheelNeedsPassword = false;
  };

  # Replace the dashboard on tty1 with RookPad.
  systemd.services.tablet-dashboard.enable = lib.mkForce false;
  systemd.services.rookpad = {
    description = "RookPad retro launcher on the iPad screen";
    wantedBy = [ "multi-user.target" ];
    path = [
      retroarch
      pkgs.python3
      pkgs.findutils
      pkgs.coreutils
      pkgs.util-linux
    ];
    environment = {
      HOME = "/home/rookpad";
      ROOKPAD_ROMS = "/home/rookpad/roms";
      TERM = "linux";
    };
    serviceConfig = {
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /home/rookpad/roms";
      ExecStart = "${rookpadLauncher}/bin/rookpad";
      StandardInput = "tty";
      StandardOutput = "tty";
      StandardError = "journal";
      TTYPath = "/dev/tty1";
      TTYReset = "yes";
      TTYVHangup = "yes";
      User = "rookpad";
      Group = "rookpad";
      Restart = "always";
      RestartSec = 2;
    };
  };

  # SSH shell lands straight into RookPad (not bash), so `ssh rookpad@…`
  # drops the user into the launcher. Bash is still available via
  # `ssh -t rookpad@… bash` for maintenance.
  programs.bash.shellInit = ''
    if [ -n "$SSH_CONNECTION" ] && [ "$(tty)" != "/dev/tty1" ] && [ -z "$ROOKPAD_SKIP" ]; then
      exec ${rookpadLauncher}/bin/rookpad
    fi
  '';

  environment.systemPackages = [
    retroarch
    rookpadLauncher
    pkgs.python3
  ];

  # Message of the Day for the SSH recovery shell.
  users.motd = ''

    ╔═══════════════════════════════════════════════════╗
    ║                     RookPad                       ║
    ║      Linux on an abandoned iPad Air 2 (A8X)       ║
    ║                                                   ║
    ║    rookpad: launcher    ·    SSH key-only         ║
    ║    scp roms to ~rookpad/roms, launcher auto-lists ║
    ║                                                   ║
    ║    run `ROOKPAD_SKIP=1 bash` to escape to a shell ║
    ╚═══════════════════════════════════════════════════╝

  '';
}
