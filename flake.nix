{
  description = "iPad NixOS - Linux on iPad via checkm8/pongoOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Separately pinned, newer nixpkgs used only for the macOS Linux-builder
    # VM package (darwin.linux-builder-vz) -- the main `nixpkgs` input above
    # predates that package's addition to nixpkgs. Kept independent so
    # bumping it can't disturb the kernel/initramfs build pins above.
    nixpkgsBuilder.url = "github:NixOS/nixpkgs/34ab99075ac4f7e40cf037eef32cb1c360bb85e9";
    devenv = {
      url = "github:cachix/devenv";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    linuxApple519 = {
      url = "github:konradybcio/linux-apple/a907b05f09bfea50511ea0e82dc14f70d999ba37";
      flake = false;
    };
    linuxAppleResources = {
      url = "github:SoMainline/linux-apple-resources/30780ec0fecdab849bb812e1dde52b87e614f45b";
      flake = false;
    };
    hoolockDocs = {
      url = "github:HoolockLinux/docs/23ebe1fbc375599221553a7e1815e5de182a6b42";
      flake = false;
    };
    # Newer-kernel candidate researched after Round 8 (see
    # research/t7001-usb-next.md's "Decision, 2026-09-07"): tracks mainline
    # Linux 7.3-rc1, restores real dwc2 DMA hardware-capability detection
    # instead of the historical fork's hardcoded PIO fallback, and already
    # has a t7001-j81.dts for this exact board. Pinned to the same commit
    # verified against the live repository during that research.
    hoolockLinux = {
      url = "github:HoolockLinux/linux/6831bc701a6ce059e71e5aaa9488c9195bea6927";
      flake = false;
    };
    # Separate, isolated pin for research/j81-long-term-subsystems.md's
    # internal-storage check: Hoolock's own `ans1` branch (ANS1/ASP storage
    # controller support), 27 commits ahead of the hoolockLinux pin above.
    # Deliberately its own input rather than a rebase of hoolockLinux, so
    # this compile-only check can never disturb the known-good battery/
    # touch payload -- see kernel/hoolock-ans1-check.nix, which builds this
    # source with none of this project's own patches applied (a direct
    # "does Hoolock's own community code compile under our toolchain"
    # question, not "do our patches also apply on top of a divergent
    # tree", which is a different, later question). Not wired into
    # m1n1-hoolock-control at all.
    hoolockLinuxAns1 = {
      url = "github:HoolockLinux/linux/ed8528f482a526371e59711645794c91fafb2b42";
      flake = false;
    };
    # Fetched as a proper flake input (resolved on the Mac, which has real
    # internet access) rather than via pkgs.fetchzip inside the package body
    # -- that fetch used to run on the offline cross-compilation builder,
    # which cannot resolve nightly.link/tarballs.nixos.org. Same class of fix
    # already applied to linuxApple519/linuxAppleResources above.
    hoolockM1n1 = {
      url = "https://nightly.link/hoolocklinux/m1n1/actions/runs/33380676898/m1n1.zip";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, nixpkgsBuilder, devenv, ... }@inputs:
    let
      linuxBuildSystem = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${linuxBuildSystem};
      darwinPkgs = import nixpkgs {
        system = "aarch64-darwin";
        overlays = [
          # libplist's ostep2 test currently crashes on this Darwin host;
          # it is only a build-time check for the irecovery dependency.
          (_final: prev: {
            libplist = prev.libplist.overrideAttrs (_: { doCheck = false; });
          })
        ];
      };
      darwinGaster = darwinPkgs.callPackage ./boot/gaster.nix {};

      # Cross-compilation: build on x86_64, target aarch64 (iPad ARM64)
      # glibc variant — used for the kernel build (buildLinux handles cross internally)
      pkgsCross = import nixpkgs {
        localSystem.system = linuxBuildSystem;
        crossSystem.system = "aarch64-linux";
      };

      # musl variant — for the initramfs.
      # musl gives fully self-contained binaries: no glibc version skew,
      # simpler static linking.  aarch64-unknown-linux-musl is the triple.
      pkgsCrossMusl = import nixpkgs {
        localSystem.system = linuxBuildSystem;
        crossSystem = {
          config = "aarch64-unknown-linux-musl";
          # The 4 KiB page size is a kernel concern, not a userspace concern.
          # musl and busybox do not need a special page-size override here.
        };
      };

      # Explicitly opt in to including a local *public* SSH key.  Keeping this
      # environment-derived makes ordinary builds key-free and reproducible.
      authorizedKeysFile =
        let keyPath = builtins.getEnv "IPAD_AUTHORIZED_KEYS";
        in if keyPath == "" then null else builtins.path {
          path = builtins.toPath keyPath;
          name = "ipad-authorized-keys";
        };
    in
    {
      # Dev shell (x86_64 tools for RE, flashing, serial, etc.)
      devShells.${linuxBuildSystem}.default = devenv.lib.mkShell {
        inherit inputs pkgs;
        modules = [ ./devenv.nix ];
      };

      devShells.aarch64-darwin.default = darwinPkgs.mkShell {
        packages = [
          darwinGaster
          darwinPkgs.libirecovery
          darwinPkgs.python3
          darwinPkgs.python3Packages.pyusb
          darwinPkgs.xz
        ];
      };

      # Cross-compiled packages for iPad (aarch64, 4 KiB pages on A7-A8X)
      packages.${linuxBuildSystem} =
        let
          # example.config sets CONFIG_USB_ETH_EEM=y, which makes the g_ether
          # gadget present CDC-EEM instead of CDC-ECM as its non-Windows USB
          # configuration (drivers/usb/gadget/legacy/Kconfig: "If you say y
          # here, the Ethernet gadget driver will use the EEM protocol
          # rather than ECM"). Confirmed on real hardware, 2026-09-07: once
          # Linux boots and g_ether binds, the Mac's ioreg shows the device
          # matched+active but stuck on configuration 1 (class 0x02/subclass
          # 0x0c/proto 0x07 -- CDC-EEM) with configuration 2 being RNDIS
          # (class 0x02/subclass 0x02/proto 0xff, Microsoft's ACM+vendor
          # encoding) -- no CDC-ECM (subclass 0x06) offered at all, and
          # macOS has no in-box driver for either EEM or RNDIS, only ECM.
          # USB_ETH always `select`s USB_F_ECM regardless of this flag, so
          # disabling USB_ETH_EEM is enough to make g_ether fall back to
          # ECM without touching anything else.
          patchedHistoricalConfig = pkgs.runCommand "ipad-t7001-defconfig-usb-ecm" {} ''
            sed 's/^CONFIG_USB_ETH_EEM=y$/# CONFIG_USB_ETH_EEM is not set/' \
              ${inputs.linuxAppleResources}/example.config > "$out"
          '';
          historicalKernel = pkgsCross.callPackage ./kernel/historical.nix {
            source = inputs.linuxApple519;
            historicalConfig = patchedHistoricalConfig;
          };
          modernKernel = pkgsCross.callPackage ./kernel {};

          # config_16k defaults to 16K pages (A9-A11/T2); Hoolock's own setup
          # guide says to swap in CONFIG_ARM64_4K_PAGES for A7-A8X instead --
          # confirmed directly from that guide's text during the Round 8
          # follow-up research, not inferred from the filename. Same
          # sed-on-a-derivation technique as patchedHistoricalConfig above.
          #
          # CONFIG_BACKLIGHT_APPLE_PMIC stays enabled (config_16k's default):
          # its build failure under this project's GCC cross-toolchain
          # (drivers/video/backlight/apple_pmic_bl.c, missing default case
          # in a switch, -Werror=return-type) is now fixed properly at the
          # source in kernel/hoolock.nix's configuredSource, rather than
          # worked around by disabling the driver -- see that file's
          # comment. This DTB already has a matching, enabled DT node for
          # it (i2c@20a110000/pmic@3c/backlight@600), same as the RTC
          # (CONFIG_RTC_DRV_APPLE_PMIC, already =y here, untouched).
          patchedHoolockConfig = pkgs.runCommand "ipad-t7001-hoolock-defconfig-4k" {} ''
            sed \
              -e 's/^# CONFIG_ARM64_4K_PAGES is not set$/CONFIG_ARM64_4K_PAGES=y/' \
              -e 's/^CONFIG_ARM64_16K_PAGES=y$/# CONFIG_ARM64_16K_PAGES is not set/' \
              -e 's/^# CONFIG_I2C_CHARDEV is not set$/CONFIG_I2C_CHARDEV=y/' \
              -e 's/^CONFIG_DEBUG_INFO=y$/# CONFIG_DEBUG_INFO is not set/' \
              -e 's/^CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT=y$/# CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT is not set/' \
              -e 's/^CONFIG_DEBUG_INFO_COMPRESSED_NONE=y$/# CONFIG_DEBUG_INFO_COMPRESSED_NONE is not set/' \
              -e 's/^# CONFIG_INPUT_TOUCHSCREEN is not set$/CONFIG_INPUT_TOUCHSCREEN=y/' \
              ${inputs.hoolockDocs}/config_16k > "$out"

            # Not needed for this project's goal (booting Linux on the iPad,
            # not kernel-level debugging with gdb/kgdb) -- and DWARF debug
            # sections in every temporary vmlinux copy during the final
            # kallsyms/link pass are what exhausted the builder VM's disk
            # at that exact step, 2026-09-10, twice, even with 40GB and a
            # freshly garbage-collected store. Also shrinks the final
            # payload, relevant given this project's known m1n1/PongoOS
            # payload-size sensitivity (see docs/software-only-control.md).

            # BAT-1/BAT-2 (docs/plans/2026-09-08-j81-bluetooth-battery-adt.md,
            # research/j81-battery-hdq.md): CONFIG_BATTERY_BQ27XXX_HDQ_UART
            # is a symbol this project's own kernel patches add (see
            # kernel/patches/0004-add-bq27xxx-hdq-uart-frontend.patch) --
            # it can't exist in the pinned upstream config_16k yet, so
            # there's no existing line for sed to flip; append it instead.
            # CONFIG_BATTERY_BQ27XXX, CONFIG_SERIAL_DEV_BUS and
            # CONFIG_SERIAL_DEV_CTRL_TTYPORT (its real dependencies) are
            # already =y in the base config -- checked, not assumed.
            echo 'CONFIG_BATTERY_BQ27XXX_HDQ_UART=y' >> "$out"

            # CHG-1: the J81 D2207 child only reports verified PMIC charger
            # settings. It has no write callback; safe charging control stays
            # gated on a physical meter and a later explicit test.
            echo 'CONFIG_CHARGER_J81_D2207=y' >> "$out"

            # TOUCH-2 groundwork: CONFIG_TOUCHSCREEN_APPLE_Z2 doesn't exist in
            # the pinned upstream config_16k (a brand-new symbol, same as
            # CONFIG_BATTERY_BQ27XXX_HDQ_UART above -- append, don't sed).
            # Its own Kconfig depends on SPI (already =y) and ARCH_APPLE
            # (already =y) -- checked directly, not assumed. Built in now so
            # the whole chain (config + kernel/patches/0011's new
            # apple,j81-touchscreen compatible) compile-verifies together,
            # matching TOUCH-1's rigor -- but no touch child DT node exists
            # yet for it to bind to (see docs/plans/2026-09-09-j81-touch-spi3.md
            # for why: firmware-name and touchscreen-size-x/y are still
            # unresolved, and guessing them is exactly what this project's
            # process avoids).
            echo 'CONFIG_TOUCHSCREEN_APPLE_Z2=y' >> "$out"
          '';
          hoolockKernel = pkgsCross.callPackage ./kernel/hoolock.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockConfig;
          };

          # Compile-only T7000 PCIe host groundwork. The driver patch is inert
          # and this kernel is not consumed by any payload.
          patchedHoolockPcieCheckConfig = pkgs.runCommand "ipad-t7001-pcie-check-defconfig-4k" {} ''
            sed \
              -e 's/^# CONFIG_ARM64_4K_PAGES is not set$/CONFIG_ARM64_4K_PAGES=y/' \
              -e 's/^CONFIG_ARM64_16K_PAGES=y$/# CONFIG_ARM64_16K_PAGES is not set/' \
              -e 's/^CONFIG_DEBUG_INFO=y$/# CONFIG_DEBUG_INFO is not set/' \
              -e 's/^CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT=y$/# CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT is not set/' \
              -e 's/^CONFIG_DEBUG_INFO_COMPRESSED_NONE=y$/# CONFIG_DEBUG_INFO_COMPRESSED_NONE is not set/' \
              ${inputs.hoolockDocs}/config_16k > "$out"
            echo 'CONFIG_PCIE_APPLE_T7000=y' >> "$out"
          '';
          hoolockPcieCheckKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-check.nix {
            source = inputs.hoolockLinux;
            pcieConfig = patchedHoolockPcieCheckConfig;
          };

          # research/j81-long-term-subsystems.md's "Internal NAND storage"
          # ecosystem check, 2026-09-13: same 4K-pages/debug-info base fixes
          # as patchedHoolockConfig above (about our hardware/toolchain, not
          # about our own drivers), but none of our own driver symbols --
          # this config is for ans1's unpatched source tree, which doesn't
          # have them. CONFIG_APPLE_ASP is ans1's own new symbol for the
          # ANS1 storage driver; its real dependencies (APPLE_RTKIT,
          # ARCH_APPLE) are already =y in the base config -- checked, not
          # assumed.
          patchedAns1Config = pkgs.runCommand "ipad-t7001-ans1-check-defconfig-4k" {} ''
            sed \
              -e 's/^# CONFIG_ARM64_4K_PAGES is not set$/CONFIG_ARM64_4K_PAGES=y/' \
              -e 's/^CONFIG_ARM64_16K_PAGES=y$/# CONFIG_ARM64_16K_PAGES is not set/' \
              -e 's/^CONFIG_DEBUG_INFO=y$/# CONFIG_DEBUG_INFO is not set/' \
              -e 's/^CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT=y$/# CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT is not set/' \
              -e 's/^CONFIG_DEBUG_INFO_COMPRESSED_NONE=y$/# CONFIG_DEBUG_INFO_COMPRESSED_NONE is not set/' \
              ${inputs.hoolockDocs}/config_16k > "$out"
            echo 'CONFIG_APPLE_ASP=y' >> "$out"
          '';
          hoolockAns1CheckKernel = pkgsCross.callPackage ./kernel/hoolock-ans1-check.nix {
            source = inputs.hoolockLinuxAns1;
            ansConfig = patchedAns1Config;
          };

          # docs/plans/2026-09-13-j81-ans1-observation-only.md's combined,
          # bootable test kernel: everything patchedHoolockConfig already
          # has, plus CONFIG_APPLE_ASP for the (observation-only-hardened)
          # ANS1 storage driver kernel/hoolock-ans1-test.nix adds. Built
          # from patchedHoolockConfig's own output rather than duplicating
          # its sed chain, so it can never drift from the real payload's
          # base config.
          patchedHoolockAns1TestConfig = pkgs.runCommand "ipad-t7001-hoolock-ans1-test-defconfig-4k" {} ''
            cat ${patchedHoolockConfig} > "$out"
            echo 'CONFIG_APPLE_ASP=y' >> "$out"
          '';
          hoolockAns1TestKernel = pkgsCross.callPackage ./kernel/hoolock-ans1-test.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockAns1TestConfig;
          };

          # Charging Stage 2 (docs/plans/2026-09-13-pmic-pcie-execution.md):
          # a writable input_current_limit property on the D2207 charger
          # driver. No new CONFIG needed -- CONFIG_CHARGER_J81_D2207 is
          # already =y in patchedHoolockConfig for CHG-1's read-only
          # driver, and this only adds functions to that same file -- so
          # this reuses patchedHoolockConfig directly rather than
          # deriving a new one.
          hoolockChargingWritableTestKernel = pkgsCross.callPackage ./kernel/hoolock-charging-writable-test.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockConfig;
          };

          # Touch SPI experiment (research/j81-touch-spi-experiment-design.md):
          # patchedHoolockConfig plus CONFIG_SPI_SPIDEV for the spidev test
          # child that kernel/hoolock-touch-spi-test.nix adds under SPI3.
          patchedHoolockTouchSpiTestConfig = pkgs.runCommand "ipad-t7001-hoolock-touch-spi-test-defconfig-4k" {} ''
            cat ${patchedHoolockConfig} > "$out"
            echo 'CONFIG_SPI_SPIDEV=y' >> "$out"
          '';
          hoolockTouchSpiTestKernel = pkgsCross.callPackage ./kernel/hoolock-touch-spi-test.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockTouchSpiTestConfig;
          };

          # docs/plans/2026-09-13-j81-wifi-pcie.md's link/enumeration-test
          # kernel, per the approved plan
          # (an internal plan file (not part of the repository)):
          # everything patchedHoolockConfig already has, plus
          # CONFIG_PCIE_APPLE_T7000 for the real (but strictly bounded)
          # PCIe driver kernel/hoolock-pcie-test.nix adds. Built from
          # patchedHoolockConfig's own output, same reasoning as
          # patchedHoolockAns1TestConfig above.
          patchedHoolockPcieTestConfig = pkgs.runCommand "ipad-t7001-hoolock-pcie-test-defconfig-4k" {} ''
            cat ${patchedHoolockConfig} > "$out"
            echo 'CONFIG_PCIE_APPLE_T7000=y' >> "$out"
          '';
          hoolockPcieTestKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-test.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieTestConfig;
          };

          # docs/plans/2026-09-13-j81-wifi-pcie.md's "Post-attempt
          # implementation review": the corrected, genuinely minimal next
          # diagnostic after 0018's two inconclusive hardware attempts.
          # Same CONFIG_PCIE_APPLE_T7000=y as patchedHoolockPcieTestConfig
          # (the driver still needs to be built in to match against the DT
          # node), but kernel/hoolock-pcie-pmgr-test.nix applies patch 0019
          # instead of 0018 -- a probe() that maps no MMIO and calls no
          # PCI/ECAM/DART code at all.
          patchedHoolockPciePmgrTestConfig = pkgs.runCommand "ipad-t7001-hoolock-pcie-pmgr-test-defconfig-4k" {} ''
            cat ${patchedHoolockConfig} > "$out"
            echo 'CONFIG_PCIE_APPLE_T7000=y' >> "$out"
          '';
          hoolockPciePmgrTestKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-pmgr-test.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPciePmgrTestConfig;
          };

          # docs/plans/2026-09-13-j81-wifi-pcie.md's "PMGR-only test:
          # hardware-verified clean" section: the next diagnostic step
          # after 0019 (above) proved the DT status flip and power-domain
          # attachment don't hang the boot on their own. Same
          # CONFIG_PCIE_APPLE_T7000=y, but kernel/hoolock-pcie-shared-read-
          # test.nix applies patch 0020 instead -- a bare shared-window
          # devm_ioremap_resource() + single readl(), still no ECAM/PCI
          # core/DART.
          patchedHoolockPcieSharedReadTestConfig = pkgs.runCommand "ipad-t7001-hoolock-pcie-shared-read-test-defconfig-4k" {} ''
            cat ${patchedHoolockConfig} > "$out"
            echo 'CONFIG_PCIE_APPLE_T7000=y' >> "$out"
          '';
          hoolockPcieSharedReadTestKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-shared-read-test.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieSharedReadTestConfig;
          };

          # docs/plans/2026-09-13-j81-wifi-pcie.md's "Bounded shared-window
          # read test: hardware-verified clean" section: the next
          # diagnostic step after 0020 (above) proved the shared window is
          # safely readable. Same CONFIG_PCIE_APPLE_T7000=y, but
          # kernel/hoolock-pcie-ecam-read-test.nix applies patch 0021
          # instead -- a bare ECAM-window devm_ioremap_resource() + single
          # readl(), still no pci_ecam_create()/pci_host_probe()/DART.
          patchedHoolockPcieEcamReadTestConfig = pkgs.runCommand "ipad-t7001-hoolock-pcie-ecam-read-test-defconfig-4k" {} ''
            cat ${patchedHoolockConfig} > "$out"
            echo 'CONFIG_PCIE_APPLE_T7000=y' >> "$out"
          '';
          hoolockPcieEcamReadTestKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-ecam-read-test.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieEcamReadTestConfig;
          };

          # docs/plans/2026-09-13-j81-wifi-pcie.md's "Bounded ECAM-window
          # read test: hardware-verified clean" section: the next
          # diagnostic step after 0021 (above) proved a single ECAM read
          # at offset 0 is safe. Same CONFIG_PCIE_APPLE_T7000=y, but
          # kernel/hoolock-pcie-ecam-multi-test.nix applies patch 0022
          # instead -- three bounded reads at bus 0/1/4, still no
          # pci_ecam_create()/pci_host_probe()/DART.
          patchedHoolockPcieEcamMultiTestConfig = pkgs.runCommand "ipad-t7001-hoolock-pcie-ecam-multi-test-defconfig-4k" {} ''
            cat ${patchedHoolockConfig} > "$out"
            echo 'CONFIG_PCIE_APPLE_T7000=y' >> "$out"
          '';
          hoolockPcieEcamMultiTestKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-ecam-multi-test.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieEcamMultiTestConfig;
          };

          # docs/plans/2026-09-13-j81-wifi-pcie.md's "Multi-offset ECAM
          # read test: hardware-verified clean" section: the final
          # diagnostic step -- every raw MMIO read tried anywhere on this
          # controller is now safe, so this tests the one remaining
          # untested code path: pci_host_common_init() itself, in complete
          # isolation from everything else 0018 also did. Same
          # CONFIG_PCIE_APPLE_T7000=y, but
          # kernel/hoolock-pcie-hostcommon-test.nix applies patch 0023
          # instead -- a bare pci_host_common_init() call and nothing else.
          patchedHoolockPcieHostcommonTestConfig = pkgs.runCommand "ipad-t7001-hoolock-pcie-hostcommon-test-defconfig-4k" {} ''
            cat ${patchedHoolockConfig} > "$out"
            echo 'CONFIG_PCIE_APPLE_T7000=y' >> "$out"
          '';
          hoolockPcieHostcommonTestKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-hostcommon-test.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieHostcommonTestConfig;
          };

          # docs/plans/2026-09-13-j81-wifi-pcie.md's "Next evidence gate"
          # section: step 1 of the corrected four-step DART/controller
          # plan -- close the last passive-read gap (0020 only re-checked
          # the LTSSM register, not the other four registers the earlier
          # "read-only" 0018 driver also read) before DART itself becomes
          # the next thing tested in isolation. Same
          # CONFIG_PCIE_APPLE_T7000=y, but
          # kernel/hoolock-pcie-shared-remaining-test.nix applies patch
          # 0024 instead -- four bounded reads of port 1's
          # REFCLK_EN/PERST_INTERNAL/0x10c/LINK_ENABLE, still no
          # ECAM/PCI-core/DART.
          patchedHoolockPcieSharedRemainingTestConfig = pkgs.runCommand "ipad-t7001-hoolock-pcie-shared-remaining-test-defconfig-4k" {} ''
            cat ${patchedHoolockConfig} > "$out"
            echo 'CONFIG_PCIE_APPLE_T7000=y' >> "$out"
          '';
          hoolockPcieSharedRemainingTestKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-shared-remaining-test.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieSharedRemainingTestConfig;
          };

          # docs/plans/2026-09-13-j81-wifi-pcie.md's DART evidence gate,
          # test 1 of 2: the PMGR-only PCIe probe (same inert driver as
          # 0019) with dart_apcie1 also enabled and no iommu-map -- the
          # stock apple-dart driver's own probe/reset/IRQ path in
          # isolation. Same CONFIG_PCIE_APPLE_T7000=y as every other PCIe
          # test config (CONFIG_APPLE_DART is already =y in the base
          # config, no change needed there).
          patchedHoolockPcieDartNoIommuTestConfig = pkgs.runCommand "ipad-t7001-hoolock-pcie-dart-noiommu-test-defconfig-4k" {} ''
            cat ${patchedHoolockConfig} > "$out"
            echo 'CONFIG_PCIE_APPLE_T7000=y' >> "$out"
          '';
          hoolockPcieDartNoIommuTestKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-dart-noiommu-test.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieDartNoIommuTestConfig;
          };

          # docs/plans/2026-09-13-j81-wifi-pcie.md's DART evidence gate,
          # test 2 of 2: same as above but with pcie's iommu-map restored
          # -- run only once test 1 hardware-verifies clean.
          patchedHoolockPcieDartIommuMapTestConfig = pkgs.runCommand "ipad-t7001-hoolock-pcie-dart-iommu-map-test-defconfig-4k" {} ''
            cat ${patchedHoolockConfig} > "$out"
            echo 'CONFIG_PCIE_APPLE_T7000=y' >> "$out"
          '';
          hoolockPcieDartIommuMapTestKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-dart-iommu-map-test.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieDartIommuMapTestConfig;
          };

          # DART recovery-write evidence gate
          # (docs/plans/2026-09-13-j81-wifi-pcie.md,
          # research/t7000-pcie-hardware-findings.md): test 1 (0025) hung
          # on real hardware with the stock apple-dart driver bound.
          # Offline Ghidra tracing found Apple's own DART writes +0x24
          # before restoring configuration, while Linux's driver instead
          # begins with a read of +0x00. This config enables the new,
          # dedicated recovery-write test driver (CONFIG_
          # APPLE_DART_T7000_RECOVERY_TEST, patch 0027) in addition to the
          # same CONFIG_PCIE_APPLE_T7000=y every PCIe test config has.
          patchedHoolockPcieDartRecoveryTestConfig = pkgs.runCommand "ipad-t7001-hoolock-pcie-dart-recovery-test-defconfig-4k" {} ''
            cat ${patchedHoolockConfig} > "$out"
            echo 'CONFIG_PCIE_APPLE_T7000=y' >> "$out"
            echo 'CONFIG_APPLE_DART_T7000_RECOVERY_TEST=y' >> "$out"
          '';
          hoolockPcieDartRecoveryTestKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-dart-recovery-test.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieDartRecoveryTestConfig;
          };

          # DART recovery-write test, ps_pcie direct-attach variant
          # (docs/plans/2026-09-13-j81-wifi-pcie.md,
          # research/t7000-pcie-hardware-findings.md): 0027 hung, ruling
          # out read-before-write ordering. First step of the ordered
          # domain-gate plan -- same CONFIG_APPLE_DART_T7000_RECOVERY_TEST
          # driver as 0027, patch 0028 only adds power-domains = <&ps_pcie>
          # to dart_apcie1 itself.
          patchedHoolockPcieDartRecoveryPspcieTestConfig = pkgs.runCommand "ipad-t7001-hoolock-pcie-dart-recovery-pspcie-test-defconfig-4k" {} ''
            cat ${patchedHoolockConfig} > "$out"
            echo 'CONFIG_PCIE_APPLE_T7000=y' >> "$out"
            echo 'CONFIG_APPLE_DART_T7000_RECOVERY_TEST=y' >> "$out"
          '';
          hoolockPcieDartRecoveryPspcieTestKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-dart-recovery-pspcie-test.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieDartRecoveryPspcieTestConfig;
          };

          # DART sibling power-domain isolation tests
          # (docs/plans/2026-09-13-j81-wifi-pcie.md,
          # research/t7000-pcie-hardware-findings.md's "Required test order
          # if hardware work resumes" section): no-MMIO logging driver
          # (CONFIG_APPLE_DART_T7000_NOMMIO_TEST) bound to dart_apcie1 with
          # ps_pcie_aux or ps_pcie_ref, never both -- confirms merely
          # powering that sibling domain is safe before it is ever paired
          # with a real MMIO-touching DART test. Only run if
          # hoolock-pcie-dart-recovery-pspcie-test also hangs.
          patchedHoolockPcieDartNommioPspcieauxTestConfig = pkgs.runCommand "ipad-t7001-hoolock-pcie-dart-nommio-pspcieaux-test-defconfig-4k" {} ''
            cat ${patchedHoolockConfig} > "$out"
            echo 'CONFIG_PCIE_APPLE_T7000=y' >> "$out"
            echo 'CONFIG_APPLE_DART_T7000_NOMMIO_TEST=y' >> "$out"
          '';
          hoolockPcieDartNommioPspcieauxTestKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-dart-nommio-pspcieaux-test.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieDartNommioPspcieauxTestConfig;
          };

          patchedHoolockPcieDartNommioPspcierefTestConfig = pkgs.runCommand "ipad-t7001-hoolock-pcie-dart-nommio-pspcieref-test-defconfig-4k" {} ''
            cat ${patchedHoolockConfig} > "$out"
            echo 'CONFIG_PCIE_APPLE_T7000=y' >> "$out"
            echo 'CONFIG_APPLE_DART_T7000_NOMMIO_TEST=y' >> "$out"
          '';
          hoolockPcieDartNommioPspcierefTestKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-dart-nommio-pspcieref-test.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieDartNommioPspcierefTestConfig;
          };

          # DART power-domains fix, real driver
          # (docs/plans/2026-09-13-j81-wifi-pcie.md,
          # research/t7000-pcie-hardware-findings.md): Test A (0028)
          # hardware-verified the fix -- dart_apcie1 given its own
          # power-domains = <&ps_pcie> reference. This config repeats 0025
          # (the real stock apple-dart driver, no iommu-map) with that fix
          # applied. CONFIG_APPLE_DART is already =y in the base config.
          patchedHoolockPcieDartPspcieFixTestConfig = pkgs.runCommand "ipad-t7001-hoolock-pcie-dart-pspcie-fix-test-defconfig-4k" {} ''
            cat ${patchedHoolockConfig} > "$out"
            echo 'CONFIG_PCIE_APPLE_T7000=y' >> "$out"
          '';
          hoolockPcieDartPspcieFixTestKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-dart-pspcie-fix-test.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieDartPspcieFixTestConfig;
          };

          # DART power-domains fix, iommu-map restored
          # (docs/plans/2026-09-13-j81-wifi-pcie.md,
          # research/t7000-pcie-hardware-findings.md): `0031`
          # hardware-verified the real apple-dart driver with the
          # power-domains fix. This config restores pcie's iommu-map
          # (0026's original scope) with that fix carried over.
          patchedHoolockPcieDartPspcieFixIommuMapTestConfig = pkgs.runCommand "ipad-t7001-hoolock-pcie-dart-pspcie-fix-iommu-map-test-defconfig-4k" {} ''
            cat ${patchedHoolockConfig} > "$out"
            echo 'CONFIG_PCIE_APPLE_T7000=y' >> "$out"
          '';
          hoolockPcieDartPspcieFixIommuMapTestKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-dart-pspcie-fix-iommu-map-test.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieDartPspcieFixIommuMapTestConfig;
          };

          # Stage 1 of the real PCIe host-controller implementation
          # (docs/plans/2026-09-13-j81-wifi-pcie.md,
          # research/t7000-pcie-hardware-findings.md): the recovered
          # AppleT7000PCIe::_enablePortHardware shared-window write
          # sequence for board port 1. No PERST, no per-port window, no
          # link start, no enumeration.
          patchedHoolockPcieEnableSequenceTestConfig = pkgs.runCommand "ipad-t7001-hoolock-pcie-enable-sequence-test-defconfig-4k" {} ''
            cat ${patchedHoolockConfig} > "$out"
            echo 'CONFIG_PCIE_APPLE_T7000=y' >> "$out"
          '';
          hoolockPcieEnableSequenceTestKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-enable-sequence-test.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieEnableSequenceTestConfig;
          };

          # Stage 2 of the real PCIe host-controller implementation
          # (docs/plans/2026-09-13-j81-wifi-pcie.md,
          # research/t7000-pcie-hardware-findings.md): Stage 1's enable
          # sequence combined with the kernel's generic
          # pci_host_common_init()/ECAM bus scan -- still no PERST, so
          # the scan is expected to find nothing. No per-port window, no
          # link-start bit.
          patchedHoolockPcieEnableEnumerationTestConfig = pkgs.runCommand "ipad-t7001-hoolock-pcie-enable-enumeration-test-defconfig-4k" {} ''
            cat ${patchedHoolockConfig} > "$out"
            echo 'CONFIG_PCIE_APPLE_T7000=y' >> "$out"
          '';
          hoolockPcieEnableEnumerationTestKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-enable-enumeration-test.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieEnableEnumerationTestConfig;
          };

          # Stage 3 of the real PCIe host-controller implementation
          # (docs/plans/2026-09-13-j81-wifi-pcie.md,
          # research/t7000-pcie-hardware-findings.md): Stage 2's enable
          # sequence + generic ECAM enumeration, now with PERST#
          # deasserted via a pci@0,0/reset-gpios DT child node. No
          # per-port window, no link-start bit.
          patchedHoolockPcieEnableEnumerationPerstTestConfig = pkgs.runCommand "ipad-t7001-hoolock-pcie-enable-enumeration-perst-test-defconfig-4k" {} ''
            cat ${patchedHoolockConfig} > "$out"
            echo 'CONFIG_PCIE_APPLE_T7000=y' >> "$out"
          '';
          hoolockPcieEnableEnumerationPerstTestKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-enable-enumeration-perst-test.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieEnableEnumerationPerstTestConfig;
          };

          # Stage 4a of the real PCIe host-controller implementation
          # (docs/plans/2026-09-13-j81-wifi-pcie.md,
          # research/t7000-pcie-hardware-findings.md): Stage 3 plus one
          # bounded read from the per-port controller window (ADT index
          # 3 for port 1) -- never touched by any prior test. No write
          # to that window yet; the link-start bit write is a later,
          # separately gated stage.
          patchedHoolockPciePortControllerWindowReadTestConfig = pkgs.runCommand "ipad-t7001-hoolock-pcie-port-controller-window-read-test-defconfig-4k" {} ''
            cat ${patchedHoolockConfig} > "$out"
            echo 'CONFIG_PCIE_APPLE_T7000=y' >> "$out"
          '';
          hoolockPciePortControllerWindowReadTestKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-port-controller-window-read-test.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPciePortControllerWindowReadTestConfig;
          };

          # Stage 4a v2 (docs/plans/2026-09-13-j81-wifi-pcie.md,
          # research/t7000-pcie-hardware-findings.md): the same bounded
          # per-port controller window read as 0036, but mapped
          # non-exclusively after the first attempt was hardware-tested
          # and hit a real -EBUSY (the window overlaps dart_apcie1's
          # own already-claimed MMIO region). No new CONFIG needed,
          # reuses the same defconfig-plus-CONFIG_PCIE_APPLE_T7000
          # pattern.
          patchedHoolockPciePortControllerWindowReadTestV2Config = pkgs.runCommand "ipad-t7001-hoolock-pcie-port-controller-window-read-test-v2-defconfig-4k" {} ''
            cat ${patchedHoolockConfig} > "$out"
            echo 'CONFIG_PCIE_APPLE_T7000=y' >> "$out"
          '';
          hoolockPciePortControllerWindowReadTestV2Kernel = pkgsCross.callPackage ./kernel/hoolock-pcie-port-controller-window-read-test-v2.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPciePortControllerWindowReadTestV2Config;
          };

          # Stage 4b of the real PCIe host-controller implementation
          # (docs/plans/2026-09-13-j81-wifi-pcie.md,
          # research/t7000-pcie-hardware-findings.md): Stage 4a plus the
          # per-port controller window's own link-start bit write --
          # the final piece of Apple's recovered order. Built ahead of
          # Stage 4a's own hardware result; see
          # kernel/hoolock-pcie-link-start-write-test.nix's own header
          # comment -- do not test on hardware before that read comes
          # back clean.
          patchedHoolockPcieLinkStartWriteTestConfig = pkgs.runCommand "ipad-t7001-hoolock-pcie-link-start-write-test-defconfig-4k" {} ''
            cat ${patchedHoolockConfig} > "$out"
            echo 'CONFIG_PCIE_APPLE_T7000=y' >> "$out"
          '';
          hoolockPcieLinkStartWriteTestKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-link-start-write-test.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieLinkStartWriteTestConfig;
          };

          # Stage 4b v2 (docs/plans/2026-09-13-j81-wifi-pcie.md,
          # research/t7000-pcie-hardware-findings.md): the same
          # link-start write as 0037, mapped non-exclusively to match
          # Stage 4a v2 (0038)'s hardware-confirmed fix for the same
          # per-port window.
          patchedHoolockPcieLinkStartWriteTestV2Config = pkgs.runCommand "ipad-t7001-hoolock-pcie-link-start-write-test-v2-defconfig-4k" {} ''
            cat ${patchedHoolockConfig} > "$out"
            echo 'CONFIG_PCIE_APPLE_T7000=y' >> "$out"
          '';
          hoolockPcieLinkStartWriteTestV2Kernel = pkgsCross.callPackage ./kernel/hoolock-pcie-link-start-write-test-v2.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieLinkStartWriteTestV2Config;
          };

          # Stage 5A (docs/plans/2026-09-13-j81-wifi-pcie.md,
          # research/t7000-pcie-hardware-findings.md): the full
          # recovered enable sequence plus a read-only baseline capture
          # of the seven ADT-selected controller-tuning/DBI offsets --
          # no new writes.
          patchedHoolockPcieTuningBaselineTestConfig = pkgs.runCommand "ipad-t7001-hoolock-pcie-tuning-baseline-test-defconfig-4k" {} ''
            cat ${patchedHoolockConfig} > "$out"
            echo 'CONFIG_PCIE_APPLE_T7000=y' >> "$out"
          '';
          hoolockPcieTuningBaselineTestKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-tuning-baseline-test.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieTuningBaselineTestConfig;
          };

          # Stage 5B mapping gate: one read through the already-mapped ECAM
          # window at Apple's recovered DBI-control address. No new writes.
          patchedHoolockPcieDbiEcamReadTestConfig = pkgs.runCommand "ipad-t7001-hoolock-pcie-dbi-ecam-read-test-defconfig-4k" {} ''
            cat ${patchedHoolockConfig} > "$out"
            echo 'CONFIG_PCIE_APPLE_T7000=y' >> "$out"
          '';
          hoolockPcieDbiEcamReadTestKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-dbi-ecam-read-test.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieDbiEcamReadTestConfig;
          };

          # Stage 5C: the actual gated RMW -- dbi-overrides through the ECAM
          # window (gate set/restore around the three records), then
          # apcie-config-tunables through the direct port-controller window.
          patchedHoolockPcieDbiTunablesWriteTestConfig = pkgs.runCommand "ipad-t7001-hoolock-pcie-dbi-tunables-write-test-defconfig-4k" {} ''
            cat ${patchedHoolockConfig} > "$out"
            echo 'CONFIG_PCIE_APPLE_T7000=y' >> "$out"
          '';
          hoolockPcieDbiTunablesWriteTestKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-dbi-tunables-write-test.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieDbiTunablesWriteTestConfig;
          };

          # Stage 5D: read-only link-state probe. No new writes -- logs
          # +0x88/+0x8c/+0x100/+0x104/+0x114 and two DesignWare DBI
          # corroboration candidates at t+0/10/100/1000ms.
          patchedHoolockPcieLinkStateProbeTestConfig = pkgs.runCommand "ipad-t7001-hoolock-pcie-link-state-probe-test-defconfig-4k" {} ''
            cat ${patchedHoolockConfig} > "$out"
            echo 'CONFIG_PCIE_APPLE_T7000=y' >> "$out"
          '';
          hoolockPcieLinkStateProbeTestKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-link-state-probe-test.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieLinkStateProbeTestConfig;
          };

          # Stage 5E: enableGated()'s full recovered tail, reordered to
          # match Apple exactly -- DBI/tunables, port-tail writes, MSI
          # registers, PERST# deassertion, link-start last, then a bounded
          # poll of the link-up register instead of a fixed delay.
          patchedHoolockPcieLinkWaitWriteTestConfig = pkgs.runCommand "ipad-t7001-hoolock-pcie-link-wait-write-test-defconfig-4k" {} ''
            cat ${patchedHoolockConfig} > "$out"
            echo 'CONFIG_PCIE_APPLE_T7000=y' >> "$out"
          '';
          hoolockPcieLinkWaitWriteTestKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-link-wait-write-test.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieLinkWaitWriteTestConfig;
          };

          # Stage 5F: J81's maximum-link-speed=1 ADT property, applied via
          # a standard PCIe capability RMW on the root port itself (Link
          # Control 2's low nibble set to 1/Gen1, after confirming Gen1 is
          # in the supported-speeds vector). Generic PCIe, not an
          # Apple-specific register.
          patchedHoolockPcieLinkSpeedWriteTestConfig = pkgs.runCommand "ipad-t7001-hoolock-pcie-link-speed-write-test-defconfig-4k" {} ''
            cat ${patchedHoolockConfig} > "$out"
            echo 'CONFIG_PCIE_APPLE_T7000=y' >> "$out"
          '';
          hoolockPcieLinkSpeedWriteTestKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-link-speed-write-test.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieLinkSpeedWriteTestConfig;
          };

          # REG_ON test stage: Stage 5F plus an early BCM4350 REG_ON assert via
          # the D2207 PMU (GPIO 3, register 0x0403), per Apple's order.
          patchedHoolockPcieRegOnTestConfig = pkgs.runCommand "ipad-t7001-hoolock-pcie-reg-on-test-defconfig-4k" {} ''
            cat ${patchedHoolockConfig} > "$out"
            echo 'CONFIG_PCIE_APPLE_T7000=y' >> "$out"
          '';
          hoolockPcieRegOnTestKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-reg-on-test.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieRegOnTestConfig;
          };

          # Board-bound follow-up to the hardware-proven REG_ON test:
          # J81's PCIe node explicitly names the D2207 PMIC. The driver
          # asserts and verifies only BCM4350 Wi-Fi GPIO3 before PCIe; it
          # does not look up an arbitrary PMIC or describe Bluetooth GPIO2.
          patchedHoolockPcieJ81RegOnConfig = pkgs.runCommand "ipad-t7001-hoolock-pcie-j81-reg-on-defconfig-4k" {} ''
            cat ${patchedHoolockConfig} > "$out"
            echo 'CONFIG_PCIE_APPLE_T7000=y' >> "$out"
          '';
          hoolockPcieJ81RegOnKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-j81-reg-on.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieJ81RegOnConfig;
          };

          # 0052 plus 0053 (DLLLA link wait). Same config as the 0052 variant.
          hoolockPcieJ81DllaKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-j81-dllla.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieJ81RegOnConfig;
          };

          # 0052 + 0053 + 0054 (behaviour-neutral clean-up of the host driver).
          hoolockPcieJ81CleanKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-j81-clean.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieJ81RegOnConfig;
          };

          # ... plus 0055 (per-controller MSI doorbell reservation in the Apple DART).
          hoolockPcieJ81DoorbellKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-j81-doorbell.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieJ81RegOnConfig;
          };

          # Head of the MSI series: ... plus 0056 (derive the MSI port register values).
          hoolockPcieJ81MsiKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-j81-msi.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieJ81RegOnConfig;
          };

          # TEST ONLY: Wi-Fi H1B base = MSI series + DMA model A + brcmfmac PCIe (no firmware in the store).
          patchedHoolockPcieJ81WifiH1bConfig = pkgs.runCommand "ipad-t7001-hoolock-pcie-j81-wifi-h1b-defconfig-4k" {} ''
            cat ${patchedHoolockPcieJ81RegOnConfig} > "$out"
            echo 'CONFIG_WIRELESS=y' >> "$out"
            echo 'CONFIG_CFG80211=y' >> "$out"
            echo 'CONFIG_CFG80211_REQUIRE_SIGNED_REGDB=n' >> "$out"
            echo 'CONFIG_WLAN=y' >> "$out"
            echo 'CONFIG_WLAN_VENDOR_BROADCOM=y' >> "$out"
            echo 'CONFIG_BRCMUTIL=y' >> "$out"
            echo 'CONFIG_BRCMFMAC=y' >> "$out"
            echo 'CONFIG_BRCMFMAC_PCIE=y' >> "$out"
            echo 'CONFIG_BRCMDBG=y' >> "$out"
            echo 'CONFIG_BRCMFMAC_PCIE_H1B_DIAG=y' >> "$out"
            echo 'CONFIG_APPLE_DART_H1B_DIAG=y' >> "$out"
            echo 'CONFIG_PCIE_APPLE_T7000_DEBUGFS_DIAG=y' >> "$out"
            echo 'CONFIG_PCIE_APPLE_T7000_DEVICE_WAKE_TEST=y' >> "$out"
            echo 'CONFIG_FW_LOADER_USER_HELPER_FALLBACK=n' >> "$out"
            echo 'CONFIG_FW_LOADER_USER_HELPER=n' >> "$out"
          '';
          # PRODUCTION Wi-Fi kernel config: the same patches as the H1B test kernel (the DMA/DART/MAC fixes of 0089/0090 are device-tree driven), but the
          # diagnostic code (CONFIG_*_DIAG: ring/DART/console diagnostics, debugfs register dumps, query interface) is compiled out. CONFIG_PCIE_APPLE_T7000_DEVICE_WAKE_TEST
          # stays: it carries the device_wake=1 boot argument the Wi-Fi payload uses (research/2026-10-10-wifi-bringup-root-cause-and-permanent-fix.md section 4).
          patchedHoolockWifiConfig = pkgs.runCommand "ipad-t7001-hoolock-wifi-defconfig-4k" {} ''
            cat ${patchedHoolockPcieJ81RegOnConfig} > "$out"
            echo 'CONFIG_WIRELESS=y' >> "$out"
            echo 'CONFIG_CFG80211=y' >> "$out"
            echo 'CONFIG_CFG80211_REQUIRE_SIGNED_REGDB=n' >> "$out"
            echo 'CONFIG_WLAN=y' >> "$out"
            echo 'CONFIG_WLAN_VENDOR_BROADCOM=y' >> "$out"
            echo 'CONFIG_BRCMUTIL=y' >> "$out"
            echo 'CONFIG_BRCMFMAC=y' >> "$out"
            echo 'CONFIG_BRCMFMAC_PCIE=y' >> "$out"
            echo 'CONFIG_BRCMDBG=y' >> "$out"
            echo 'CONFIG_PCIE_APPLE_T7000_DEVICE_WAKE_TEST=y' >> "$out"
            # 16x32 console font (selected with fbcon=font:TER16x32): the 1536x2048 screen is unreadable at the default 8x16.
            echo 'CONFIG_FONTS=y' >> "$out"
            echo 'CONFIG_FONT_TER16x32=y' >> "$out"
            echo 'CONFIG_FW_LOADER_USER_HELPER_FALLBACK=n' >> "$out"
            echo 'CONFIG_FW_LOADER_USER_HELPER=n' >> "$out"
            # NixOS-in-RAM (docs/plans/2026-10-11-nixos-in-ram.md) and the touch spidev experiment.
            echo 'CONFIG_SQUASHFS=y' >> "$out"
            echo 'CONFIG_SQUASHFS_ZSTD=y' >> "$out"
            echo 'CONFIG_SQUASHFS_XZ=y' >> "$out"
            echo 'CONFIG_OVERLAY_FS=y' >> "$out"
            echo 'CONFIG_EROFS_FS=y' >> "$out"
            echo 'CONFIG_CGROUP_BPF=y' >> "$out"
            echo 'CONFIG_FUSE_FS=y' >> "$out"
            echo 'CONFIG_SPI_SPIDEV=y' >> "$out"
          '';
          # Model B keeps the configuration it was built with (before the 0067 toggles); same derivation name and content.
          patchedHoolockPcieJ81WifiH1bRawConfig = pkgs.runCommand "ipad-t7001-hoolock-pcie-j81-wifi-h1b-defconfig-4k" {} ''
            cat ${patchedHoolockPcieJ81RegOnConfig} > "$out"
            echo 'CONFIG_WIRELESS=y' >> "$out"
            echo 'CONFIG_CFG80211=y' >> "$out"
            echo 'CONFIG_CFG80211_REQUIRE_SIGNED_REGDB=n' >> "$out"
            echo 'CONFIG_WLAN=y' >> "$out"
            echo 'CONFIG_WLAN_VENDOR_BROADCOM=y' >> "$out"
            echo 'CONFIG_BRCMUTIL=y' >> "$out"
            echo 'CONFIG_BRCMFMAC=y' >> "$out"
            echo 'CONFIG_BRCMFMAC_PCIE=y' >> "$out"
            echo 'CONFIG_BRCMDBG=y' >> "$out"
            echo 'CONFIG_BRCMFMAC_PCIE_H1B_DIAG=y' >> "$out"
            echo 'CONFIG_APPLE_DART_H1B_DIAG=y' >> "$out"
            echo 'CONFIG_PCIE_APPLE_T7000_DEBUGFS_DIAG=y' >> "$out"
            echo 'CONFIG_FW_LOADER_USER_HELPER_FALLBACK=n' >> "$out"
            echo 'CONFIG_FW_LOADER_USER_HELPER=n' >> "$out"
          '';
          hoolockPcieJ81WifiH1bKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-j81-wifi-h1b.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieJ81WifiH1bConfig;
          };
          hoolockWifiKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-j81-wifi-h1b.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockWifiConfig;
          };
          # Same, DMA model B (raw PTE indexing): no 0064.
          hoolockPcieJ81WifiH1bRawKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-j81-wifi-h1b-raw.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieJ81WifiH1bRawConfig;
          };

          # TEST ONLY: DMA models for plan phase 2/3 (0063 window; 0064 selects Apple's rebase).
          hoolockPcieJ81DmaRebaseKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-j81-dma-rebase.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieJ81RegOnConfig;
          };
          hoolockPcieJ81DmaRawKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-j81-dma-raw.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieJ81RegOnConfig;
          };

          # TEST ONLY, PRIVATE DATA: 0052-0057 plus 0061 and 0062 (BCM4350 OTP shadow capture).
          patchedHoolockPcieJ81BcmShadowConfig = pkgs.runCommand "ipad-t7001-hoolock-pcie-j81-bcm-shadow-defconfig-4k" {} ''
            cat ${patchedHoolockPcieJ81RegOnConfig} > "$out"
            echo 'CONFIG_PCIE_APPLE_T7000_BCM_PROBE=y' >> "$out"
            echo 'CONFIG_PCIE_APPLE_T7000_BCM_PROBE_SHADOW=y' >> "$out"
          '';
          hoolockPcieJ81BcmShadowKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-j81-bcm-shadow.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieJ81BcmShadowConfig;
          };

          # TEST ONLY: 0052-0057 plus 0061 (BCM4350 metadata observation probe).
          patchedHoolockPcieJ81BcmProbeConfig = pkgs.runCommand "ipad-t7001-hoolock-pcie-j81-bcm-probe-defconfig-4k" {} ''
            cat ${patchedHoolockPcieJ81RegOnConfig} > "$out"
            echo 'CONFIG_PCIE_APPLE_T7000_BCM_PROBE=y' >> "$out"
          '';
          hoolockPcieJ81BcmProbeKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-j81-bcm-probe.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieJ81BcmProbeConfig;
          };

          # PROPOSAL: 0052-0057 plus 0060 (per-controller IOVA window in the Apple DART).
          hoolockPcieJ81IovaKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-j81-iova.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieJ81RegOnConfig;
          };

          # TEST ONLY: 0052-0057 plus 0059 (read-only +0x168 dump).
          patchedHoolockPcieJ81MsiDiagConfig = pkgs.runCommand "ipad-t7001-hoolock-pcie-j81-msi-diag-defconfig-4k" {} ''
            cat ${patchedHoolockPcieJ81RegOnConfig} > "$out"
            echo 'CONFIG_PCIE_APPLE_T7000_DIAG_MSIADDR=y' >> "$out"
          '';
          hoolockPcieJ81MsiDiagKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-j81-msi-diag.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieJ81MsiDiagConfig;
          };

          # TEST ONLY: 0052-0057 plus 0058 (MSI allocation self-test) and IRQ debugfs.
          patchedHoolockPcieJ81MsiSelftestConfig = pkgs.runCommand "ipad-t7001-hoolock-pcie-j81-msi-selftest-defconfig-4k" {} ''
            cat ${patchedHoolockPcieJ81RegOnConfig} > "$out"
            echo 'CONFIG_PCIE_APPLE_T7000_MSI_SELFTEST=y' >> "$out"
            echo 'CONFIG_GENERIC_IRQ_DEBUGFS=y' >> "$out"
          '';
          hoolockPcieJ81MsiSelftestKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-j81-msi-selftest.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieJ81MsiSelftestConfig;
          };

          # Stage 5G: isolated PMGR gate test -- explicitly attaches
          # ps_pcie_aux/ps_pcie_ref alongside the already-automatic
          # ps_pcie, no register-level changes.
          patchedHoolockPcieGateAuxRefTestConfig = pkgs.runCommand "ipad-t7001-hoolock-pcie-gate-aux-ref-test-defconfig-4k" {} ''
            cat ${patchedHoolockConfig} > "$out"
            echo 'CONFIG_PCIE_APPLE_T7000=y' >> "$out"
          '';
          hoolockPcieGateAuxRefTestKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-gate-aux-ref-test.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieGateAuxRefTestConfig;
          };

          # Stage 5H: isolated early gate-register delta -- replays
          # Apple's +0x6d0 hook (clear shared 0x180 bit0, set 0x198 bit0
          # for port 1) before the existing enable sequence. Built on
          # Stage 5F, not 5G, to stay separable from the AUX/REF test.
          patchedHoolockPcieGateRegisterTestConfig = pkgs.runCommand "ipad-t7001-hoolock-pcie-gate-register-test-defconfig-4k" {} ''
            cat ${patchedHoolockConfig} > "$out"
            echo 'CONFIG_PCIE_APPLE_T7000=y' >> "$out"
          '';
          hoolockPcieGateRegisterTestKernel = pkgsCross.callPackage ./kernel/hoolock-pcie-gate-register-test.nix {
            source = inputs.hoolockLinux;
            hoolockConfig = patchedHoolockPcieGateRegisterTestConfig;
          };

          # BT-1 (docs/plans/2026-09-08-j81-bluetooth-battery-adt.md):
          # The transport-only UART3 DT patch deliberately has no Bluetooth
          # child. This userspace tool attaches the raw HCI UART independently;
          # see boot/btattach.nix for why it is a minimal source build rather
          # than the full BlueZ package.
          btattachPkg = pkgsCrossMusl.callPackage ./boot/btattach.nix {
            stdenvCross = pkgsCrossMusl.stdenv;
            bluezSrc = pkgsCrossMusl.bluez.src;
            bluezVersion = pkgsCrossMusl.bluez.version;
          };

          # BT-3 (docs/plans/2026-09-08-j81-bluetooth-battery-adt.md): m1n1's
          # own USB proxy mode doesn't enumerate on this hardware (tried
          # repeatedly, 2026-09-08), so the PMU GPIO2 register scan runs
          # from Linux instead, over the same pmic@3c I2C chip RTC/backlight
          # already prove works. i2c-tools is small and dependency-free
          # (unlike bluez, no glib/dbus-style chain to route around), so the
          # real package cross-compiles directly -- no from-scratch minimal
          # build needed here. Static for the same reason as btattach: the
          # debug initramfs's musl is a separate build from Nix's own, and
          # the stock package's dynamic linking against Nix's musl produced
          # a real "not found" failure on hardware (the ELF interpreter
          # path doesn't exist there) before this override was added.
          # lib/Module.mk documents its own static-build variables
          # (BUILD_DYNAMIC_LIB/BUILD_STATIC_LIB/USE_STATIC_LIB) -- disabling
          # the shared libi2c.so build entirely avoids it fighting a global
          # -static (which broke with "cannot find -lgcc_s" when the
          # Makefile's own `-shared` link line picked it up too).
          i2cToolsPkg = pkgsCrossMusl.i2c-tools.overrideAttrs (old: {
            # LDFLAGS=-static (a plain make variable the Makefile's own
            # $(CC) $(LDFLAGS) link line picks up directly), not
            # NIX_LDFLAGS -- that route left the tools/Module.mk link step
            # still pulling in shared libgcc_s ("cannot find -lgcc_s", no
            # static libgcc_s.a exists in this musl cross toolchain),
            # because it doesn't reach gcc's own driver-level "this is a
            # static link, use libgcc.a" detection the same way.
            makeFlags = old.makeFlags ++ [
              "BUILD_DYNAMIC_LIB=0"
              "BUILD_STATIC_LIB=1"
              "USE_STATIC_LIB=1"
              "LDFLAGS=-static"
            ];
          });

          # Wi-Fi userland for the J81 BCM4350 (docs/plans/2026-10-10-j81-wifi-userland.md): static iw and wpa_supplicant (musl, aarch64). Public and
          # generic; the network name and passphrase never enter the Nix store or Git, they are supplied only by the private payload assembler
          # (boot/assemble_private_wifi_payload.py --wifi-userland ...). busybox in the debug initramfs already provides udhcpc, ifconfig, route, ping.
          wifiUserlandPkg = pkgs.runCommand "ipad-air2-wifi-userland" {} ''
            mkdir -p "$out/bin"
            cp ${pkgsCrossMusl.pkgsStatic.wpa_supplicant}/bin/wpa_supplicant "$out/bin/wpa_supplicant"
            cp ${pkgsCrossMusl.pkgsStatic.wpa_supplicant}/bin/wpa_cli "$out/bin/wpa_cli"
            cp ${pkgsCrossMusl.pkgsStatic.iw}/bin/iw "$out/bin/iw"
          '';

          # pinpoke: read any pin's pad register and drive ONE allow-listed pin (AP GPIO 164, BT_WAKE) through /dev/mem; run-time bring-up tool only (boot/pinpoke.c).
          pinpokePkg = pkgsCrossMusl.stdenv.mkDerivation {
            name = "pinpoke";
            dontUnpack = true;
            buildPhase = "$CC -static -O2 -Wall -o pinpoke ${./boot/pinpoke.c}";
            installPhase = "mkdir -p $out/bin && cp pinpoke $out/bin/pinpoke";
          };

          # uartpoke: read/write ONLY the three baud registers of the Bluetooth UART3 (boot/uartpoke.c); run-time tool for the Apple baud-register study.
          uartpokePkg = pkgsCrossMusl.stdenv.mkDerivation {
            name = "uartpoke";
            dontUnpack = true;
            buildPhase = "$CC -static -O2 -Wall -o uartpoke ${./boot/uartpoke.c}";
            installPhase = "mkdir -p $out/bin && cp uartpoke $out/bin/uartpoke";
          };

          # touch-diag (boot/touch-diag.c, with the firmware-upload experiment mode), pushed to the running iPad at run time.
          touchDiagStaticPkg = pkgsCrossMusl.stdenv.mkDerivation {
            name = "touch-diag";
            dontUnpack = true;
            buildPhase = "$CC -static -O2 -Wall -Wextra -Werror -o touch-diag ${./boot/touch-diag.c}";
            installPhase = "mkdir -p $out/bin && cp touch-diag $out/bin/touch-diag";
          };

          # uartpeek: READ-ONLY dump of UART3/UART5 registers 0x00..0x3c (boot/uartpeek.c) for the Bluetooth baud-register investigation; run-time tool only.
          uartpeekPkg = pkgsCrossMusl.stdenv.mkDerivation {
            name = "uartpeek";
            dontUnpack = true;
            buildPhase = "$CC -static -O2 -Wall -o uartpeek ${./boot/uartpeek.c}";
            installPhase = "mkdir -p $out/bin && cp uartpeek $out/bin/uartpeek";
          };

          # Bluetooth bring-up tools, pushed to the iPad at run time (never part of a payload): static btattach and i2c-tools (docs/plans/2026-10-08-j81-bluetooth-battery-adt.md).
          btUserlandPkg = pkgs.runCommand "ipad-air2-bt-userland" {} ''
            mkdir -p "$out/bin"
            cp ${btattachPkg}/bin/btattach "$out/bin/btattach"
            for f in ${i2cToolsPkg}/bin/*; do cp "$f" "$out/bin/"; done
          '';

          # J81 BASE PAYLOAD (docs/plans/2026-10-08-j81-base-package.md). Every payload that is meant to be run on the iPad
          # should be built through this function, so these stay in every build without copy-paste drift:
          #   1. charging: the kernel must carry patch 0017 (writable input_current_limit; enforced by
          #      kernel/test_j81_base_contract.py) and /usr/bin/charging-policy is started by the boot hook;
          #   2. telnet (recovery, 172.16.42.1:23) + key-only Dropbear SSH (172.16.42.1:22) over the USB ECM link;
          #   3. the debug console: console=tty0, ignore_loglevel and the postmarketOS debug-shell flow;
          #   4. the tablet tools /usr/bin/tablet-status and /usr/bin/tablet-dashboard;
          #   5. the universal probe (stage B of the plan; its userland helper is added here once the kernel framework exists).
          # No Bluetooth userland and no I2C tools are included (the Wi-Fi payload rules forbid them; charging uses sysfs only).
          mkJ81BasePayload = { name, kernel, bootargsExtra ? "", wifi ? false, dashboard ? false, btWakeHog ? false, touchSpidev ? false, touchGpioCs ? false, nixosHandoff ? false }:
            let
              dropbearPkg = pkgsCrossMusl.dropbear;
              dropbearClosure = pkgs.closureInfo { rootPaths = [ dropbearPkg ]; };
            in pkgs.runCommand "ipad-air2-${name}" {
              nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio pkgs.findutils ];
            } ''
              mkdir -p "$out" overlay/etc/postmarketos-mkinitfs/hooks overlay/usr/bin
              cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
              cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
              gzip -n -c ${kernel}/Image > "$out/Image.gz"

              dtc -I dtb -O dts ${kernel}/dtbs/apple/t7001-j81.dtb \
                | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
                | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"
              ${if touchSpidev then ''
              # TEST ONLY (research/2026-10-11-touch-upload notes): turn on the disabled spidev child on SPI3 (patch 0095) for the touch experiment.
              fdtput -t s "$out/t7001-j81.dtb" /soc/spi@20a08c000/touch-diag@0 status okay
              ${if touchGpioCs then ''
              # TEST ONLY: chip select of SPI3 driven as a GPIO (AP pin 51, active low) like Apple's driver does, instead of the pad's SPI function. The pad's SPI pinmux is
              # dropped (the pin is strictly owned by one user), which is done by renaming the pinctrl state so "default" no longer exists.
              pinctrl_ph=$(fdtget "$out/t7001-j81.dtb" /soc/pinctrl@20e300000 phandle)
              fdtput -t x "$out/t7001-j81.dtb" /soc/spi@20a08c000 cs-gpios "$(printf %x "$pinctrl_ph")" 0x33 0x1
              fdtput -t s "$out/t7001-j81.dtb" /soc/spi@20a08c000 pinctrl-names sleep
              '' else ""}
              '' else ""}
              ${if btWakeHog then ''
              # TEST ONLY (docs/plans/2026-10-08-j81-bluetooth-battery-adt.md): a gpio-hog that the kernel's own pinctrl driver applies at boot, driving AP GPIO 164
              # (ADT bluetooth `function-bt_wake`) high. No /dev/mem poking; the production payloads never set btWakeHog.
              fdtput -c "$out/t7001-j81.dtb" /soc/pinctrl@20e300000/bt-wake-hog
              fdtput -t x "$out/t7001-j81.dtb" /soc/pinctrl@20e300000/bt-wake-hog gpios 0xa4 0x0
              fdtput -t s "$out/t7001-j81.dtb" /soc/pinctrl@20e300000/bt-wake-hog line-name bt_wake
              fdtput -t x "$out/t7001-j81.dtb" /soc/pinctrl@20e300000/bt-wake-hog gpio-hog
              fdtput -t x "$out/t7001-j81.dtb" /soc/pinctrl@20e300000/bt-wake-hog output-high
              '' else ""}

              # Base debug initramfs (telnetd, fbdebug, evtest, debug-shell flow) plus one overlay archive.
              gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
              mkdir -p original-etc
              (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
              cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
              printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo

              hook=etc/postmarketos-mkinitfs/hooks/20-debug-shell.sh
              sed 's|@DROPBEAR@|${dropbearPkg}|' ${./boot/ssh-stage1.sh} \
                | sed 's|^loop_forever$|/usr/bin/charging-policy >/var/log/charging-policy.log 2>\&1 \&\n[ -x /usr/bin/wifi-up ] \&\& /usr/bin/wifi-up >/dev/null 2>\&1 \&\n[ -x /usr/bin/tablet-dashboard-screen ] \&\& /usr/bin/tablet-dashboard-screen >/dev/null 2>\&1 \&\nloop_forever|' > "overlay/$hook"
              chmod 755 "overlay/$hook"
              ${if nixosHandoff then ''
              # NixOS in RAM (docs/plans/2026-10-11-nixos-in-ram.md): with j81.nixos=URL on the kernel command line the debug hook returns to /init after starting its services, and a
              # modified /init (the original plus one block right after the hook loop) sources boot/nixos-handoff.sh as PID 1, which fetches the system and switches root;
              # on any failure the block ends in the recovery loop, so telnet and ssh stay available. Without the argument nothing changes.
              sed -i 's|^loop_forever$|grep -q "j81\.nixos=" /proc/cmdline \&\& exit 0\nloop_forever|' "overlay/$hook"
              (cd original-etc && cpio -id --no-absolute-filenames init < ../initramfs.cpio)
              awk '{ print } /^done$/ && !d { d = 1;
                print "if [ -r /usr/bin/nixos-handoff ] && grep -q \"j81\\.nixos=\" /proc/cmdline; then";
                print "\t. /usr/bin/nixos-handoff";
                print "\tnixos_handoff";
                print "\tloop_forever";
                print "fi" }' original-etc/init > overlay/init
              chmod 755 overlay/init
              cp ${./boot/nixos-handoff.sh} overlay/usr/bin/nixos-handoff
              chmod 755 overlay/usr/bin/nixos-handoff
              '' else ""}

              mkdir -p overlay/root/.ssh overlay/var/empty overlay/var/run overlay/var/log
              echo 'root:x:0:0:root:/root:/bin/sh' > overlay/etc/passwd
              echo 'root:x:0:' > overlay/etc/group
              cp ${./boot/ssh/authorized_keys} overlay/root/.ssh/authorized_keys
              chmod 700 overlay/root overlay/root/.ssh
              chmod 600 overlay/root/.ssh/authorized_keys
              chmod 644 overlay/etc/passwd overlay/etc/group

              ${if wifi then ''
              # Wi-Fi userland (item 6 of the base package): public, generic tools only. Everything private (chip files and network
              # credentials) stays in the private overlay (boot/assemble_private_wifi_payload.py); with no network configured wifi-up logs and exits.
              mkdir -p overlay/usr/share/wifi
              cp ${wifiUserlandPkg}/bin/iw ${wifiUserlandPkg}/bin/wpa_supplicant ${wifiUserlandPkg}/bin/wpa_cli overlay/usr/bin/
              # Regulatory database (public, generic): removes the kernel's 'Direct load for regulatory.db failed' and lets a country be selected.
              mkdir -p overlay/lib/firmware
              cp ${pkgs.wireless-regdb}/lib/firmware/regulatory.db ${pkgs.wireless-regdb}/lib/firmware/regulatory.db.p7s overlay/lib/firmware/
              cp ${./boot/wifi-up.sh} overlay/usr/bin/wifi-up
              cp ${./boot/wifi-udhcpc.script} overlay/usr/share/wifi/udhcpc.script
              chmod 755 overlay/usr/bin/iw overlay/usr/bin/wpa_supplicant overlay/usr/bin/wpa_cli overlay/usr/bin/wifi-up overlay/usr/share/wifi/udhcpc.script
              '' else ""}
              ${if dashboard then ''
              # The tablet dashboard on the iPad's own screen (tty0) by default; j81.dashboard=0 on the kernel command line turns it off.
              cp ${./boot/tablet-dashboard-screen.sh} overlay/usr/bin/tablet-dashboard-screen
              chmod 755 overlay/usr/bin/tablet-dashboard-screen
              '' else ""}
              cp ${./boot/tablet-status.sh} overlay/usr/bin/tablet-status
              cp ${./boot/charging-policy.sh} overlay/usr/bin/charging-policy
              cp ${./boot/tablet-dashboard.sh} overlay/usr/bin/tablet-dashboard
              chmod 755 overlay/usr/bin/tablet-status overlay/usr/bin/charging-policy overlay/usr/bin/tablet-dashboard

              # Dropbear runtime closure at its original store paths.
              mkdir -p overlay/nix/store
              while read -r p; do cp -a "$p" overlay/nix/store/; done < ${dropbearClosure}/store-paths
              chmod -R u+w overlay/nix
              find overlay -exec touch -h -d @1 {} +

              (cd overlay; find . -mindepth 1 -print0 | sed -z 's|^\./||' | LC_ALL=C sort -z \
                | cpio --null -o -H newc --owner=0:0 --reproducible) >> initramfs.cpio
              gzip -n -c initramfs.cpio > "$out/initramfs.gz"

              printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused${if bootargsExtra == "" then "" else " " + bootargsExtra}' \
                > "$out/bootargs"
              cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
                "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
              sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" > "$out/SHA256SUMS"
            '';
        in {
        # Linux kernel for iPad Air 2 (A8X)
        kernel = modernKernel;

        # Exact kernel branch used by the June 2022 T7001 proof. Keep this as
        # a control; do not add current-tree fixes until it has booted as-is.
        historical-kernel = historicalKernel;

        # Newer-kernel candidate researched after Round 8 (see
        # research/t7001-usb-next.md). Kept as its own independent output --
        # not yet wired into m1n1-control -- so the working historical
        # control stays the rollback path while this is evaluated.
        hoolock-kernel = hoolockKernel;

        # Inert T7000 PCIe host-driver compile check; no payload uses it.
        hoolock-pcie-check-kernel = hoolockPcieCheckKernel;

        # research/j81-long-term-subsystems.md's ANS1 storage ecosystem
        # check, 2026-09-13: compile-only, not wired into any boot payload.
        hoolock-ans1-check-kernel = hoolockAns1CheckKernel;

        # Kernel backing the combined m1n1-hoolock-ans1-test payload below;
        # exposed on its own so System.map/dtbs can be inspected directly
        # without pulling apart the assembled payload archive.
        hoolock-ans1-test-kernel = hoolockAns1TestKernel;

        # Kernel backing the combined m1n1-hoolock-charging-writable-test
        # payload below; exposed on its own for the same reason
        # hoolock-ans1-test-kernel is.
        hoolock-charging-writable-test-kernel = hoolockChargingWritableTestKernel;
        hoolock-touch-spi-test-kernel = hoolockTouchSpiTestKernel;

        # Kernel backing the combined m1n1-hoolock-pcie-test payload below;
        # exposed on its own for the same reason hoolock-ans1-test-kernel is.
        hoolock-pcie-test-kernel = hoolockPcieTestKernel;

        # Kernel backing the combined m1n1-hoolock-pcie-pmgr-test payload
        # below; exposed on its own for the same reason
        # hoolock-pcie-test-kernel is.
        hoolock-pcie-pmgr-test-kernel = hoolockPciePmgrTestKernel;

        # Kernel backing the combined m1n1-hoolock-pcie-shared-read-test
        # payload below; exposed on its own for the same reason
        # hoolock-pcie-pmgr-test-kernel is.
        hoolock-pcie-shared-read-test-kernel = hoolockPcieSharedReadTestKernel;

        # Kernel backing the combined m1n1-hoolock-pcie-ecam-read-test
        # payload below; exposed on its own for the same reason
        # hoolock-pcie-shared-read-test-kernel is.
        hoolock-pcie-ecam-read-test-kernel = hoolockPcieEcamReadTestKernel;

        # Kernel backing the combined m1n1-hoolock-pcie-ecam-multi-test
        # payload below; exposed on its own for the same reason
        # hoolock-pcie-ecam-read-test-kernel is.
        hoolock-pcie-ecam-multi-test-kernel = hoolockPcieEcamMultiTestKernel;

        # Kernel backing the combined m1n1-hoolock-pcie-hostcommon-test
        # payload below; exposed on its own for the same reason
        # hoolock-pcie-ecam-multi-test-kernel is.
        hoolock-pcie-hostcommon-test-kernel = hoolockPcieHostcommonTestKernel;

        # Kernel backing the combined m1n1-hoolock-pcie-shared-remaining-test
        # payload below; exposed on its own for the same reason
        # hoolock-pcie-hostcommon-test-kernel is.
        hoolock-pcie-shared-remaining-test-kernel = hoolockPcieSharedRemainingTestKernel;

        # Kernels backing the two combined m1n1-hoolock-pcie-dart-*-test
        # payloads below; exposed on their own for the same reason
        # hoolock-pcie-shared-remaining-test-kernel is.
        hoolock-pcie-dart-noiommu-test-kernel = hoolockPcieDartNoIommuTestKernel;
        hoolock-pcie-dart-iommu-map-test-kernel = hoolockPcieDartIommuMapTestKernel;

        # Kernel backing the combined m1n1-hoolock-pcie-dart-recovery-test
        # payload below; exposed on its own for the same reason
        # hoolock-pcie-dart-noiommu-test-kernel is.
        hoolock-pcie-dart-recovery-test-kernel = hoolockPcieDartRecoveryTestKernel;

        # Kernels backing the three combined m1n1-hoolock-pcie-dart-*-test
        # payloads below (ordered domain-gate plan); exposed on their own
        # for the same reason hoolock-pcie-dart-recovery-test-kernel is.
        hoolock-pcie-dart-recovery-pspcie-test-kernel = hoolockPcieDartRecoveryPspcieTestKernel;
        hoolock-pcie-dart-nommio-pspcieaux-test-kernel = hoolockPcieDartNommioPspcieauxTestKernel;
        hoolock-pcie-dart-nommio-pspcieref-test-kernel = hoolockPcieDartNommioPspcierefTestKernel;

        # Kernel backing the combined m1n1-hoolock-pcie-dart-pspcie-fix-test
        # payload below; exposed on its own for the same reason
        # hoolock-pcie-dart-recovery-test-kernel is.
        hoolock-pcie-dart-pspcie-fix-test-kernel = hoolockPcieDartPspcieFixTestKernel;

        # Kernel backing the combined
        # m1n1-hoolock-pcie-dart-pspcie-fix-iommu-map-test payload below;
        # exposed on its own for the same reason
        # hoolock-pcie-dart-pspcie-fix-test-kernel is.
        hoolock-pcie-dart-pspcie-fix-iommu-map-test-kernel = hoolockPcieDartPspcieFixIommuMapTestKernel;

        # Kernel backing the combined m1n1-hoolock-pcie-enable-sequence-test
        # payload below; exposed on its own for the same reason
        # hoolock-pcie-dart-pspcie-fix-test-kernel is.
        hoolock-pcie-enable-sequence-test-kernel = hoolockPcieEnableSequenceTestKernel;

        # Kernel backing the combined m1n1-hoolock-pcie-enable-enumeration-test
        # payload below; exposed on its own for the same reason
        # hoolock-pcie-enable-sequence-test-kernel is.
        hoolock-pcie-enable-enumeration-test-kernel = hoolockPcieEnableEnumerationTestKernel;

        # Kernel backing the combined
        # m1n1-hoolock-pcie-enable-enumeration-perst-test payload below;
        # exposed on its own for the same reason
        # hoolock-pcie-enable-enumeration-test-kernel is.
        hoolock-pcie-enable-enumeration-perst-test-kernel = hoolockPcieEnableEnumerationPerstTestKernel;

        # Kernel backing the combined
        # m1n1-hoolock-pcie-port-controller-window-read-test payload
        # below; exposed on its own for the same reason
        # hoolock-pcie-enable-enumeration-perst-test-kernel is.
        hoolock-pcie-port-controller-window-read-test-kernel = hoolockPciePortControllerWindowReadTestKernel;

        # Kernel backing the combined
        # m1n1-hoolock-pcie-port-controller-window-read-test-v2 payload
        # below; exposed on its own for the same reason
        # hoolock-pcie-port-controller-window-read-test-kernel is.
        hoolock-pcie-port-controller-window-read-test-v2-kernel = hoolockPciePortControllerWindowReadTestV2Kernel;

        # Kernel backing the combined m1n1-hoolock-pcie-link-start-write-test
        # payload below; exposed on its own for the same reason
        # hoolock-pcie-port-controller-window-read-test-kernel is.
        hoolock-pcie-link-start-write-test-kernel = hoolockPcieLinkStartWriteTestKernel;

        # Kernel backing the combined
        # m1n1-hoolock-pcie-link-start-write-test-v2 payload below;
        # exposed on its own for the same reason
        # hoolock-pcie-link-start-write-test-kernel is.
        hoolock-pcie-link-start-write-test-v2-kernel = hoolockPcieLinkStartWriteTestV2Kernel;

        # Kernel backing the combined m1n1-hoolock-pcie-tuning-baseline-test
        # payload below; exposed on its own for the same reason
        # hoolock-pcie-link-start-write-test-v2-kernel is.
        hoolock-pcie-tuning-baseline-test-kernel = hoolockPcieTuningBaselineTestKernel;

        # Kernel backing the Stage 5B read-only DBI ECAM mapping payload.
        hoolock-pcie-dbi-ecam-read-test-kernel = hoolockPcieDbiEcamReadTestKernel;
        hoolock-pcie-dbi-tunables-write-test-kernel = hoolockPcieDbiTunablesWriteTestKernel;
        hoolock-pcie-link-state-probe-test-kernel = hoolockPcieLinkStateProbeTestKernel;
        hoolock-pcie-link-wait-write-test-kernel = hoolockPcieLinkWaitWriteTestKernel;
        hoolock-pcie-link-speed-write-test-kernel = hoolockPcieLinkSpeedWriteTestKernel;
        hoolock-pcie-reg-on-test-kernel = hoolockPcieRegOnTestKernel;
        hoolock-pcie-j81-reg-on-kernel = hoolockPcieJ81RegOnKernel;
        hoolock-pcie-j81-dllla-kernel = hoolockPcieJ81DllaKernel;
        hoolock-pcie-j81-clean-kernel = hoolockPcieJ81CleanKernel;
        hoolock-pcie-j81-doorbell-kernel = hoolockPcieJ81DoorbellKernel;
        hoolock-pcie-j81-msi-kernel = hoolockPcieJ81MsiKernel;
        hoolock-pcie-j81-msi-selftest-kernel = hoolockPcieJ81MsiSelftestKernel;
        hoolock-pcie-j81-msi-diag-kernel = hoolockPcieJ81MsiDiagKernel;
        hoolock-pcie-j81-iova-kernel = hoolockPcieJ81IovaKernel;
        hoolock-pcie-j81-bcm-probe-kernel = hoolockPcieJ81BcmProbeKernel;
        hoolock-pcie-j81-bcm-shadow-kernel = hoolockPcieJ81BcmShadowKernel;
        hoolock-pcie-j81-dma-rebase-kernel = hoolockPcieJ81DmaRebaseKernel;
        hoolock-pcie-j81-dma-raw-kernel = hoolockPcieJ81DmaRawKernel;
        hoolock-pcie-j81-wifi-h1b-kernel = hoolockPcieJ81WifiH1bKernel;
        hoolock-wifi-kernel = hoolockWifiKernel;
        wifi-userland-static = wifiUserlandPkg;
        bt-userland-static = btUserlandPkg;
        pinpoke-static = pinpokePkg;
        uartpeek-static = uartpeekPkg;
        touch-diag-static = touchDiagStaticPkg;
        uartpoke-static = uartpokePkg;
        hoolock-pcie-j81-wifi-h1b-raw-kernel = hoolockPcieJ81WifiH1bRawKernel;
        hoolock-pcie-gate-aux-ref-test-kernel = hoolockPcieGateAuxRefTestKernel;
        hoolock-pcie-gate-register-test-kernel = hoolockPcieGateRegisterTestKernel;

        # Kernel, the published multi-device DTB pack, and debug initramfs in
        # the exact file layout consumed by the historical PongoOS loader.
        historical-payload = pkgs.runCommand "ipad-air2-linux-2022-control" {
          nativeBuildInputs = [ pkgs.xz pkgs.xxd ];
        } ''
          mkdir -p "$out"
          xz --format=lzma -c ${historicalKernel}/Image > "$out/Image.lzma"
          mkdir -p work/arch/arm64/boot/dts
          ln -s ${historicalKernel}/dtbs/apple work/arch/arm64/boot/dts/apple
          (cd work && bash ${inputs.linuxAppleResources}/dtbpack.sh)
          mv work/dtbpack "$out/dtbpack"
          cp ${inputs.linuxAppleResources}/debug_initrd.img "$out/initrd"
        '';

        # Current software-only route: PongoOS bootm -> iDevice m1n1 -> the
        # pinned historical kernel. m1n1 itself can be sent first as a visible
        # handoff diagnostic without involving Linux.
        m1n1-control = pkgs.runCommand "ipad-air2-m1n1-control" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${historicalKernel}/Image > "$out/Image.gz"
          # 2026-09-07: switched from the modern (mainline-sourced) DTB back
          # to the HISTORICAL kernel's own bundled one, now that the reason
          # for the earlier switch (a CPU reg-cell bug) is independently
          # patchable and the historical DTB has something mainline's
          # doesn't: a real T7001 USB-device-controller node
          # (usbdev@20c100000, compatible "apple,t7000-usb"), matched by a
          # real driver in this same historical kernel
          # (drivers/usb/dwc2/params.c). The modern DTB has no USB
          # controller node at all -- confirmed the first time Linux
          # reached a live shell here: g_ether logged "couldn't find an
          # available UDC", so its own telnet debug-shell had no network
          # link to be reached over. See docs/software-only-control.md.
          #
          # Same two structural defects the modern-DTB fix addressed are
          # patched here too, since they're properties of the *historical*
          # DTB, not specific to which DTB was in use:
          #
          # 1. /cpus declares #address-cells=1 (a single-cell "reg" per
          #    CPU), but m1n1's dt_set_cpus() (src/kboot.c) reads that
          #    property with fdt64_ld() -- an 8-byte load. Against a 4-byte
          #    property that over-reads into adjacent DTB data, producing a
          #    corrupted "expected MPIDR" and a hard-fail "DT CPU 1 MPIDR
          #    mismatch" on real hardware (confirmed running the modern DTB
          #    variant of this exact bug -- docs/software-only-control.md).
          #    Converted to the binding's correct #address-cells=2, two-cell
          #    reg format, matching mainline's current t7001.dtsi.
          # 2. The historical DTB has no /chosen/framebuffer node at all
          #    (unlike the modern one, which at least had a misnamed
          #    placeholder) -- m1n1's dt_set_fb() (src/kboot.c) looks it up
          #    by the exact path /chosen/framebuffer via fdt_path_offset()
          #    and silently skips console setup if it's missing (confirmed
          #    non-fatal on real hardware, see docs/software-only-control.md
          #    for the exact "FDT: No framebuffer found" case). Added a
          #    minimal placeholder node at that exact path; m1n1 renames it
          #    to framebuffer@<real base> and fills in
          #    reg/width/height/stride/format itself once found, so the
          #    placeholder's own field values don't matter. Unlike the
          #    modern DTB, this historical one has no PMGR power-domain
          #    nodes at all (predates that level of hardware description),
          #    so no power-domains reference is needed here -- the
          #    pd_ignore_unused/clk_ignore_unused bootargs fix below still
          #    applies globally as a safety net for whatever domains this
          #    DTB does describe.
          # 3. Hardware-tested 2026-09-07 and hit "FDT: couldn't set
          #    cpu-release-addr property" / "Failed to prepare FDT!" / "No
          #    valid payload found" -- m1n1 fell back to its USB proxy
          #    instead of booting. First guess was a blob-space problem
          #    (fixed below with `-p 0x10000`) but a second hardware run
          #    with that padding hit the exact same failure -- reading
          #    m1n1's actual source (src/kboot.c dt_set_cpus()) showed why:
          #    it writes this property with fdt_setprop_inplace_u64(), and
          #    m1n1 *always* reopens the incoming DTB into its own
          #    generously-padded buffer first (fdt_open_into() with +96 KiB,
          #    src/kboot.c ~line 2925) regardless of how the blob we hand it
          #    was compiled -- so blob padding was never the issue.
          #    "Inplace" libfdt calls never grow the tree; they only
          #    overwrite an *existing* same-sized property's value, and
          #    fail with FDT_ERR_NOTFOUND if it's absent. This historical
          #    DTS predates the mainline convention of a static
          #    cpu-release-addr = <0 0>; placeholder in each secondary CPU
          #    node, so it has none, and m1n1 can never write it in. Fixed
          #    by adding that placeholder to cpu@1 and cpu@2 directly (not
          #    needed on cpu@0: dt_set_cpus() skips the boot CPU, matched by
          #    MPIDR, before reaching this property write). The `-p 0x10000`
          #    padding on the final `dtc` compile is kept as harmless,
          #    standard practice but is not what fixes this.
          dtc -I dtb -O dts ${historicalKernel}/dtbs/apple/t7001-j81.dtb \
            | sed \
                -e '/^\tcpus {$/,/^\t};$/ s/#address-cells = <0x01>;/#address-cells = <0x02>;/' \
                -e '/^\tcpus {$/,/^\t};$/ s/reg = <0x00>;/reg = <0x00 0x00>;/' \
                -e '/^\tcpus {$/,/^\t};$/ s/reg = <0x01>;/reg = <0x00 0x01>;\n\t\t\tcpu-release-addr = <0x00 0x00>;/' \
                -e '/^\tcpus {$/,/^\t};$/ s/reg = <0x02>;/reg = <0x00 0x02>;\n\t\t\tcpu-release-addr = <0x00 0x00>;/' \
                -e '/^\tchosen {$/,/^\t};$/ s/ranges;/ranges;\n\t\tframebuffer {\n\t\t\tcompatible = "apple,simple-framebuffer", "simple-framebuffer";\n\t\t\treg = <0x00 0x00 0x00 0x00>;\n\t\t\tstatus = "disabled";\n\t\t};/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"
          cp ${inputs.linuxAppleResources}/debug_initrd.img "$out/initramfs.gz"
          # m1n1's payload parser (src/payload.c check_var()) requires a
          # trailing newline to find the end of a "chosen.X=value" line --
          # without it, it can't terminate the value and falls through to
          # "Unknown payload", exactly what a real hardware run hit here.
          #
          # PMOS_NO_OUTPUT_REDIRECT: the bundled debug_initrd.img is a 2020
          # postmarketOS image for a Sony Xperia Z5. Its /init calls
          # setup_log() (init_functions.sh), which execs PID 1's own stdout
          # and stderr into /pmOS_init.log -- a RAM-only file this project
          # has no way to read -- unless this exact token appears in
          # /proc/cmdline. Confirmed by inspecting the actual bundled
          # init_functions.sh; see docs/software-only-control.md's
          # "Software follow-up" section for the full byte-level evidence
          # (including why the subsequent black screen is a >99%-black
          # 1080x1920 Xperia splash image, not a crash).
          #
          # 2026-09-07, second round: with PMOS_NO_OUTPUT_REDIRECT applied
          # and the attempt re-run at 120fps, the "### postmarketOS
          # initramfs ###" line that setup_log() prints unconditionally --
          # before it even checks the redirect flag -- has never appeared
          # in any captured frame, across either attempt. That means PID 1
          # likely never starts at all; the black screen is upstream of
          # userspace, inside the kernel itself. A concrete, well-targeted
          # candidate: Apple's PMGR power-domain driver
          # (drivers/soc/apple/apple-pmgr-pwrstate.c) uses the generic
          # power-domain (genpd) framework, whose genpd_power_off_unused()
          # runs as a late_initcall() -- right after the device-driver
          # probing this project has now watched complete on video every
          # time -- and powers off any domain with no active consumer.
          # There is no real Linux display driver holding the inherited
          # framebuffer's power domain open, so it's a plausible candidate
          # for being powered off right when the screen goes black.
          # pd_ignore_unused/clk_ignore_unused (drivers/base/power/domain.c,
          # drivers/clk/clk.c) are the real, standard kernel parameters that
          # disable this specific behavior -- added to test it directly.
          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # Newer-kernel candidate (see research/t7001-usb-next.md's "Decision,
        # 2026-09-07" and "Implementation progress") wired into the same
        # proven PongoOS -> m1n1 -> Linux payload shape as m1n1-control.
        # Reuses the same Pongo.bin/m1n1.bin (kernel-agnostic, already
        # proven) and the same debug_initrd.img base, so the only real
        # changes are the kernel Image, its own DTB, and one deviceinfo
        # override the USB gadget setup needs on this kernel.
        m1n1-hoolock-control = pkgs.runCommand "ipad-air2-m1n1-hoolock-control" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockKernel}/Image > "$out/Image.gz"

          # Verified 2026-09-07 (research/t7001-usb-next.md): this kernel's
          # own t7001-j81.dtb already carries #address-cells=2 with correct
          # two-cell CPU reg values, and cpu-release-addr/enable-method as
          # proper mainline placeholders on every cpu@N node -- none of the
          # CPU-topology patching Rounds 3-5 needed for the historical
          # kernel's DTB applies here. It does still have
          # /chosen/framebuffer@0 (a unit address on the node), the same
          # situation the *modern mainline* DTB had back in Round 3 --
          # m1n1's dt_set_fb() (src/kboot.c) looks up the exact path
          # /chosen/framebuffer via fdt_path_offset(), which does not
          # prefix-match a unit address. Same one-line rename fix.
          dtc -I dtb -O dts ${hoolockKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          # This kernel has no CONFIG_USB_ETH (legacy g_ether) at all --
          # gadget setup is configfs-only (CONFIG_USB_CONFIGFS_ECM=y,
          # _NCM=y, _EEM=y, _ACM=y; RNDIS is not compiled in). The bundled
          # debug_initrd.img's own setup_usb_network_configfs()
          # (init_functions.sh) already exists and already tries this on
          # every kernel, but defaults to creating a configfs function
          # named "rndis.usb0" (deviceinfo_usb_rndis_function's fallback),
          # which needs CONFIG_USB_CONFIGFS_RNDIS -- not available here.
          # Override it to "ecm.usb0" to match this kernel's actual
          # CONFIG_USB_CONFIGFS_ECM=y, via a one-line deviceinfo addition
          # appended as a cpio overlay -- same concatenated-newc-archive
          # technique m1n1-usb-diagnostic already uses for its debug hook,
          # applied to a different file. Extracts the *original*
          # etc/deviceinfo from the pinned debug_initrd.img rather than
          # hardcoding a copy, so this never drifts from upstream.
          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc overlay/usr/bin
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo

          # BT-1: bundle the standalone btattach binary alongside the
          # initramfs's other standalone tools (usr/bin/evtest,
          # usr/bin/fftest) so it's reachable on PATH from the debug shell.
          cp ${btattachPkg}/bin/btattach overlay/usr/bin/btattach
          chmod 755 overlay/usr/bin/btattach
          touch -d @1 overlay/usr/bin/btattach

          # BT-3: i2cget/i2cset/i2cdetect/i2ctransfer/i2cdump, for the PMU
          # GPIO2 register scan over pmic@3c now that CONFIG_I2C_CHARDEV is
          # on (see patchedHoolockConfig above) -- m1n1's own USB proxy
          # mode doesn't enumerate on this hardware, so this runs from
          # Linux instead, read-only, over the same chip RTC/backlight
          # already prove works.
          for f in ${i2cToolsPkg}/bin/*; do
            cp "$f" "overlay/usr/bin/$(basename "$f")"
            chmod 755 "overlay/usr/bin/$(basename "$f")"
            touch -d @1 "overlay/usr/bin/$(basename "$f")"
          done

          (cd overlay
           { printf '%s\0' "etc/deviceinfo" "usr/bin/btattach"
             for f in ${i2cToolsPkg}/bin/*; do
               printf 'usr/bin/%s\0' "$(basename "$f")"
             done
           } | cpio --null -o -H newc --owner=0:0 --reproducible
          ) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          # Same proven bootargs baseline as m1n1-control: PMOS_NO_OUTPUT_REDIRECT
          # for the debug initramfs's console-log redirect, and
          # pd_ignore_unused/clk_ignore_unused as a safety net against the
          # same PMGR genpd auto-shutdown Round 2 found -- this DTB's
          # framebuffer node also carries a power-domains reference
          # (unlike the historical kernel's DTB, which had none at all),
          # so the same risk plausibly applies here too.
          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # docs/plans/2026-09-13-j81-ans1-observation-only.md's dedicated
        # ANS1 test payload -- identical to m1n1-hoolock-control above in
        # every respect except the kernel (hoolockAns1TestKernel instead of
        # hoolockKernel), so ANS1 storage is exercised only when this
        # payload is deliberately chosen, never as a side effect of routine
        # touch/battery testing on the default payload. Duplicated rather
        # than parameterized to avoid any risk of changing
        # m1n1-hoolock-control's own already-hardware-proven behavior.
        m1n1-hoolock-ans1-test = pkgs.runCommand "ipad-air2-m1n1-hoolock-ans1-test" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockAns1TestKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockAns1TestKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc overlay/usr/bin
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo

          cp ${btattachPkg}/bin/btattach overlay/usr/bin/btattach
          chmod 755 overlay/usr/bin/btattach
          touch -d @1 overlay/usr/bin/btattach

          for f in ${i2cToolsPkg}/bin/*; do
            cp "$f" "overlay/usr/bin/$(basename "$f")"
            chmod 755 "overlay/usr/bin/$(basename "$f")"
            touch -d @1 "overlay/usr/bin/$(basename "$f")"
          done

          (cd overlay
           { printf '%s\0' "etc/deviceinfo" "usr/bin/btattach"
             for f in ${i2cToolsPkg}/bin/*; do
               printf 'usr/bin/%s\0' "$(basename "$f")"
             done
           } | cpio --null -o -H newc --owner=0:0 --reproducible
          ) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # Charging Stage 2 test payload
        # (docs/plans/2026-09-13-pmic-pcie-execution.md) -- identical to
        # m1n1-hoolock-control above in every respect except the kernel
        # (hoolockChargingWritableTestKernel instead of hoolockKernel),
        # so the new writable input_current_limit property is exercised
        # only when this payload is deliberately chosen.
        m1n1-hoolock-charging-writable-test = pkgs.runCommand "ipad-air2-m1n1-hoolock-charging-writable-test" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockChargingWritableTestKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockChargingWritableTestKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc overlay/usr/bin
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo

          cp ${btattachPkg}/bin/btattach overlay/usr/bin/btattach
          chmod 755 overlay/usr/bin/btattach
          touch -d @1 overlay/usr/bin/btattach

          for f in ${i2cToolsPkg}/bin/*; do
            cp "$f" "overlay/usr/bin/$(basename "$f")"
            chmod 755 "overlay/usr/bin/$(basename "$f")"
            touch -d @1 "overlay/usr/bin/$(basename "$f")"
          done

          (cd overlay
           { printf '%s\0' "etc/deviceinfo" "usr/bin/btattach"
             for f in ${i2cToolsPkg}/bin/*; do
               printf 'usr/bin/%s\0' "$(basename "$f")"
             done
           } | cpio --null -o -H newc --owner=0:0 --reproducible
          ) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # Base payload for the touch SPI experiment: the charging-writable payload
        # with the touch-spi kernel (spidev child on SPI3).
        m1n1-hoolock-touch-spi-test = pkgs.runCommand "ipad-air2-m1n1-hoolock-touch-spi-test" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockTouchSpiTestKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockTouchSpiTestKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc overlay/usr/bin
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo

          cp ${btattachPkg}/bin/btattach overlay/usr/bin/btattach
          chmod 755 overlay/usr/bin/btattach
          touch -d @1 overlay/usr/bin/btattach

          for f in ${i2cToolsPkg}/bin/*; do
            cp "$f" "overlay/usr/bin/$(basename "$f")"
            chmod 755 "overlay/usr/bin/$(basename "$f")"
            touch -d @1 "overlay/usr/bin/$(basename "$f")"
          done

          (cd overlay
           { printf '%s\0' "etc/deviceinfo" "usr/bin/btattach"
             for f in ${i2cToolsPkg}/bin/*; do
               printf 'usr/bin/%s\0' "$(basename "$f")"
             done
           } | cpio --null -o -H newc --owner=0:0 --reproducible
          ) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # PCIe link/enumeration test payload -- identical to
        # m1n1-hoolock-control above in every respect except the kernel
        # (hoolockPcieTestKernel instead of hoolockKernel), so the real
        # T7000 PCIe driver is exercised only when this payload is
        # deliberately chosen, never as a side effect of routine
        # touch/battery/charging testing on the default payload.
        # Duplicated rather than parameterized, same reasoning as
        # m1n1-hoolock-ans1-test above. Per the approved plan
        # (an internal plan file (not part of the repository)), a real
        # hardware boot with this payload is a separate, later, explicit
        # decision -- this output exists for cross-build verification.
        m1n1-hoolock-pcie-test = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-test" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPcieTestKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPcieTestKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc overlay/usr/bin
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo

          cp ${btattachPkg}/bin/btattach overlay/usr/bin/btattach
          chmod 755 overlay/usr/bin/btattach
          touch -d @1 overlay/usr/bin/btattach

          for f in ${i2cToolsPkg}/bin/*; do
            cp "$f" "overlay/usr/bin/$(basename "$f")"
            chmod 755 "overlay/usr/bin/$(basename "$f")"
            touch -d @1 "overlay/usr/bin/$(basename "$f")"
          done

          (cd overlay
           { printf '%s\0' "etc/deviceinfo" "usr/bin/btattach"
             for f in ${i2cToolsPkg}/bin/*; do
               printf 'usr/bin/%s\0' "$(basename "$f")"
             done
           } | cpio --null -o -H newc --owner=0:0 --reproducible
          ) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # PCIe PMGR-only probe test payload -- identical to
        # m1n1-hoolock-pcie-test above in every respect except the kernel
        # (hoolockPciePmgrTestKernel instead of hoolockPcieTestKernel).
        # docs/plans/2026-09-13-j81-wifi-pcie.md's "Post-attempt
        # implementation review": two hardware attempts with the
        # write-capable/"read-only diagnostic" 0018 driver both hung, and a
        # source review found neither actually isolated the platform
        # power-domain attachment from PCI-core/ECAM/DART activity. This
        # payload's driver maps no MMIO and calls no PCI/ECAM/DART code at
        # all, so a hang here (or its absence) means something about the
        # bare status="okay" DT flip and its automatic ps_pcie power-up,
        # not about anything this driver's code does.
        m1n1-hoolock-pcie-pmgr-test = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-pmgr-test" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPciePmgrTestKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPciePmgrTestKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc overlay/usr/bin
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo

          cp ${btattachPkg}/bin/btattach overlay/usr/bin/btattach
          chmod 755 overlay/usr/bin/btattach
          touch -d @1 overlay/usr/bin/btattach

          for f in ${i2cToolsPkg}/bin/*; do
            cp "$f" "overlay/usr/bin/$(basename "$f")"
            chmod 755 "overlay/usr/bin/$(basename "$f")"
            touch -d @1 "overlay/usr/bin/$(basename "$f")"
          done

          (cd overlay
           { printf '%s\0' "etc/deviceinfo" "usr/bin/btattach"
             for f in ${i2cToolsPkg}/bin/*; do
               printf 'usr/bin/%s\0' "$(basename "$f")"
             done
           } | cpio --null -o -H newc --owner=0:0 --reproducible
          ) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # PCIe bounded shared-window read test payload -- identical to
        # m1n1-hoolock-pcie-pmgr-test above in every respect except the
        # kernel (hoolockPcieSharedReadTestKernel instead of
        # hoolockPciePmgrTestKernel). docs/plans/2026-09-13-j81-wifi-pcie.md's
        # "PMGR-only test: hardware-verified clean" section: that test
        # proved the DT status flip and power-domain attachment don't hang
        # the boot alone. This payload's driver adds back the one thing
        # that test never touched -- a real devm_ioremap_resource() +
        # single readl() of the shared register window -- with still no
        # ECAM, no PCI core, no DART, so a hang here (or its absence)
        # isolates whether the shared-window MMIO access itself is safe.
        m1n1-hoolock-pcie-shared-read-test = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-shared-read-test" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPcieSharedReadTestKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPcieSharedReadTestKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc overlay/usr/bin
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo

          cp ${btattachPkg}/bin/btattach overlay/usr/bin/btattach
          chmod 755 overlay/usr/bin/btattach
          touch -d @1 overlay/usr/bin/btattach

          for f in ${i2cToolsPkg}/bin/*; do
            cp "$f" "overlay/usr/bin/$(basename "$f")"
            chmod 755 "overlay/usr/bin/$(basename "$f")"
            touch -d @1 "overlay/usr/bin/$(basename "$f")"
          done

          (cd overlay
           { printf '%s\0' "etc/deviceinfo" "usr/bin/btattach"
             for f in ${i2cToolsPkg}/bin/*; do
               printf 'usr/bin/%s\0' "$(basename "$f")"
             done
           } | cpio --null -o -H newc --owner=0:0 --reproducible
          ) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # PCIe bounded ECAM-window read test payload -- identical to
        # m1n1-hoolock-pcie-shared-read-test above in every respect except
        # the kernel (hoolockPcieEcamReadTestKernel instead of
        # hoolockPcieSharedReadTestKernel).
        # docs/plans/2026-09-13-j81-wifi-pcie.md's "Bounded shared-window
        # read test: hardware-verified clean" section: that test proved the
        # shared register window is safely readable. This payload's driver
        # adds back a real ECAM-window devm_ioremap_resource() + single
        # readl() at config-space offset 0, with still no
        # pci_ecam_create()/pci_host_probe() bus scan and no DART, so a
        # hang here (or its absence) isolates whether the ECAM window
        # itself is safely readable before the controller's enable
        # sequence has ever run.
        m1n1-hoolock-pcie-ecam-read-test = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-ecam-read-test" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPcieEcamReadTestKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPcieEcamReadTestKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc overlay/usr/bin
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo

          cp ${btattachPkg}/bin/btattach overlay/usr/bin/btattach
          chmod 755 overlay/usr/bin/btattach
          touch -d @1 overlay/usr/bin/btattach

          for f in ${i2cToolsPkg}/bin/*; do
            cp "$f" "overlay/usr/bin/$(basename "$f")"
            chmod 755 "overlay/usr/bin/$(basename "$f")"
            touch -d @1 "overlay/usr/bin/$(basename "$f")"
          done

          (cd overlay
           { printf '%s\0' "etc/deviceinfo" "usr/bin/btattach"
             for f in ${i2cToolsPkg}/bin/*; do
               printf 'usr/bin/%s\0' "$(basename "$f")"
             done
           } | cpio --null -o -H newc --owner=0:0 --reproducible
          ) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # PCIe multi-offset bounded ECAM read test payload -- identical to
        # m1n1-hoolock-pcie-ecam-read-test above in every respect except
        # the kernel (hoolockPcieEcamMultiTestKernel instead of
        # hoolockPcieEcamReadTestKernel).
        # docs/plans/2026-09-13-j81-wifi-pcie.md's "Bounded ECAM-window
        # read test: hardware-verified clean" section: that test proved a
        # single ECAM read at offset 0 is safe. This payload's driver
        # reads bus 0 (repeated sanity anchor), bus 1 (the likely slot for
        # the real populated port), and bus 4 (the far edge of the
        # declared bus-range), all still with no pci_ecam_create()/
        # pci_host_probe() bus scan and no DART, to try to localize
        # whether some specific ECAM offset is unsafe before ever
        # re-running the full generic scan.
        m1n1-hoolock-pcie-ecam-multi-test = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-ecam-multi-test" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPcieEcamMultiTestKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPcieEcamMultiTestKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc overlay/usr/bin
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo

          cp ${btattachPkg}/bin/btattach overlay/usr/bin/btattach
          chmod 755 overlay/usr/bin/btattach
          touch -d @1 overlay/usr/bin/btattach

          for f in ${i2cToolsPkg}/bin/*; do
            cp "$f" "overlay/usr/bin/$(basename "$f")"
            chmod 755 "overlay/usr/bin/$(basename "$f")"
            touch -d @1 "overlay/usr/bin/$(basename "$f")"
          done

          (cd overlay
           { printf '%s\0' "etc/deviceinfo" "usr/bin/btattach"
             for f in ${i2cToolsPkg}/bin/*; do
               printf 'usr/bin/%s\0' "$(basename "$f")"
             done
           } | cpio --null -o -H newc --owner=0:0 --reproducible
          ) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # Isolated pci_host_common_init() test payload -- identical to
        # m1n1-hoolock-pcie-ecam-multi-test above in every respect except
        # the kernel (hoolockPcieHostcommonTestKernel instead of
        # hoolockPcieEcamMultiTestKernel).
        # docs/plans/2026-09-13-j81-wifi-pcie.md's "Multi-offset ECAM read
        # test: hardware-verified clean" section: every raw MMIO read
        # tried anywhere on this controller is now safe. This payload's
        # driver calls the one remaining untested code path --
        # pci_host_common_init() itself, with a bare ECAM ops struct and
        # nothing else -- in complete isolation from the shared-window
        # writes, PERST/GPIO handling, and DART the original hanging 0018
        # attempts also had.
        m1n1-hoolock-pcie-hostcommon-test = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-hostcommon-test" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPcieHostcommonTestKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPcieHostcommonTestKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc overlay/usr/bin
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo

          cp ${btattachPkg}/bin/btattach overlay/usr/bin/btattach
          chmod 755 overlay/usr/bin/btattach
          touch -d @1 overlay/usr/bin/btattach

          for f in ${i2cToolsPkg}/bin/*; do
            cp "$f" "overlay/usr/bin/$(basename "$f")"
            chmod 755 "overlay/usr/bin/$(basename "$f")"
            touch -d @1 "overlay/usr/bin/$(basename "$f")"
          done

          (cd overlay
           { printf '%s\0' "etc/deviceinfo" "usr/bin/btattach"
             for f in ${i2cToolsPkg}/bin/*; do
               printf 'usr/bin/%s\0' "$(basename "$f")"
             done
           } | cpio --null -o -H newc --owner=0:0 --reproducible
          ) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # Remaining shared-window offsets read test payload -- identical to
        # m1n1-hoolock-pcie-hostcommon-test above in every respect except
        # the kernel (hoolockPcieSharedRemainingTestKernel instead of
        # hoolockPcieHostcommonTestKernel).
        # docs/plans/2026-09-13-j81-wifi-pcie.md's "Next evidence gate"
        # section: step 1 of the corrected four-step DART/controller plan.
        # This payload's driver reads port 1's REFCLK_EN, PERST_INTERNAL,
        # the undocumented 0x10c, and LINK_ENABLE registers (with the
        # port-stride offset applied) -- the four shared-window offsets
        # the earlier "read-only" 0018 driver read but 0020 never
        # independently isolated -- still with DART disabled, no
        # iommu-map, no ECAM, and no writes.
        m1n1-hoolock-pcie-shared-remaining-test = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-shared-remaining-test" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPcieSharedRemainingTestKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPcieSharedRemainingTestKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc overlay/usr/bin
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo

          cp ${btattachPkg}/bin/btattach overlay/usr/bin/btattach
          chmod 755 overlay/usr/bin/btattach
          touch -d @1 overlay/usr/bin/btattach

          for f in ${i2cToolsPkg}/bin/*; do
            cp "$f" "overlay/usr/bin/$(basename "$f")"
            chmod 755 "overlay/usr/bin/$(basename "$f")"
            touch -d @1 "overlay/usr/bin/$(basename "$f")"
          done

          (cd overlay
           { printf '%s\0' "etc/deviceinfo" "usr/bin/btattach"
             for f in ${i2cToolsPkg}/bin/*; do
               printf 'usr/bin/%s\0' "$(basename "$f")"
             done
           } | cpio --null -o -H newc --owner=0:0 --reproducible
          ) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # DART evidence gate, test 1 of 2: PMGR-only PCIe (inert, same as
        # 0019) with dart_apcie1 also enabled, no iommu-map. Identical to
        # m1n1-hoolock-pcie-shared-remaining-test above in every respect
        # except the kernel (hoolockPcieDartNoIommuTestKernel instead of
        # hoolockPcieSharedRemainingTestKernel).
        m1n1-hoolock-pcie-dart-noiommu-test = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-dart-noiommu-test" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPcieDartNoIommuTestKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPcieDartNoIommuTestKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc overlay/usr/bin
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo

          cp ${btattachPkg}/bin/btattach overlay/usr/bin/btattach
          chmod 755 overlay/usr/bin/btattach
          touch -d @1 overlay/usr/bin/btattach

          for f in ${i2cToolsPkg}/bin/*; do
            cp "$f" "overlay/usr/bin/$(basename "$f")"
            chmod 755 "overlay/usr/bin/$(basename "$f")"
            touch -d @1 "overlay/usr/bin/$(basename "$f")"
          done

          (cd overlay
           { printf '%s\0' "etc/deviceinfo" "usr/bin/btattach"
             for f in ${i2cToolsPkg}/bin/*; do
               printf 'usr/bin/%s\0' "$(basename "$f")"
             done
           } | cpio --null -o -H newc --owner=0:0 --reproducible
          ) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # DART evidence gate, test 2 of 2: same as above with pcie's
        # iommu-map restored -- run only once test 1 hardware-verifies
        # clean. Identical in every respect except the kernel
        # (hoolockPcieDartIommuMapTestKernel).
        m1n1-hoolock-pcie-dart-iommu-map-test = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-dart-iommu-map-test" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPcieDartIommuMapTestKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPcieDartIommuMapTestKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc overlay/usr/bin
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo

          cp ${btattachPkg}/bin/btattach overlay/usr/bin/btattach
          chmod 755 overlay/usr/bin/btattach
          touch -d @1 overlay/usr/bin/btattach

          for f in ${i2cToolsPkg}/bin/*; do
            cp "$f" "overlay/usr/bin/$(basename "$f")"
            chmod 755 "overlay/usr/bin/$(basename "$f")"
            touch -d @1 "overlay/usr/bin/$(basename "$f")"
          done

          (cd overlay
           { printf '%s\0' "etc/deviceinfo" "usr/bin/btattach"
             for f in ${i2cToolsPkg}/bin/*; do
               printf 'usr/bin/%s\0' "$(basename "$f")"
             done
           } | cpio --null -o -H newc --owner=0:0 --reproducible
          ) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # DART recovery-write evidence gate
        # (docs/plans/2026-09-13-j81-wifi-pcie.md,
        # research/t7000-pcie-hardware-findings.md): dedicated test driver
        # performs only Apple's recovered DART+0x24 = 0x0020ffff write
        # before aborting probe. Identical in every respect to the two
        # tests above except the kernel (hoolockPcieDartRecoveryTestKernel).
        m1n1-hoolock-pcie-dart-recovery-test = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-dart-recovery-test" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPcieDartRecoveryTestKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPcieDartRecoveryTestKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc overlay/usr/bin
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo

          cp ${btattachPkg}/bin/btattach overlay/usr/bin/btattach
          chmod 755 overlay/usr/bin/btattach
          touch -d @1 overlay/usr/bin/btattach

          for f in ${i2cToolsPkg}/bin/*; do
            cp "$f" "overlay/usr/bin/$(basename "$f")"
            chmod 755 "overlay/usr/bin/$(basename "$f")"
            touch -d @1 "overlay/usr/bin/$(basename "$f")"
          done

          (cd overlay
           { printf '%s\0' "etc/deviceinfo" "usr/bin/btattach"
             for f in ${i2cToolsPkg}/bin/*; do
               printf 'usr/bin/%s\0' "$(basename "$f")"
             done
           } | cpio --null -o -H newc --owner=0:0 --reproducible
          ) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # DART recovery-write test, ps_pcie direct-attach variant
        # (docs/plans/2026-09-13-j81-wifi-pcie.md,
        # research/t7000-pcie-hardware-findings.md): first step of the
        # ordered domain-gate plan after 0027 hung. Identical to
        # m1n1-hoolock-pcie-dart-recovery-test except the kernel
        # (hoolockPcieDartRecoveryPspcieTestKernel).
        m1n1-hoolock-pcie-dart-recovery-pspcie-test = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-dart-recovery-pspcie-test" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPcieDartRecoveryPspcieTestKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPcieDartRecoveryPspcieTestKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc overlay/usr/bin
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo

          cp ${btattachPkg}/bin/btattach overlay/usr/bin/btattach
          chmod 755 overlay/usr/bin/btattach
          touch -d @1 overlay/usr/bin/btattach

          for f in ${i2cToolsPkg}/bin/*; do
            cp "$f" "overlay/usr/bin/$(basename "$f")"
            chmod 755 "overlay/usr/bin/$(basename "$f")"
            touch -d @1 "overlay/usr/bin/$(basename "$f")"
          done

          (cd overlay
           { printf '%s\0' "etc/deviceinfo" "usr/bin/btattach"
             for f in ${i2cToolsPkg}/bin/*; do
               printf 'usr/bin/%s\0' "$(basename "$f")"
             done
           } | cpio --null -o -H newc --owner=0:0 --reproducible
          ) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # DART sibling power-domain isolation test, ps_pcie_aux variant
        # (docs/plans/2026-09-13-j81-wifi-pcie.md,
        # research/t7000-pcie-hardware-findings.md): no-MMIO logging driver,
        # confirms merely powering ps_pcie_aux is safe before it is ever
        # paired with a real MMIO-touching DART test. Only run if
        # m1n1-hoolock-pcie-dart-recovery-pspcie-test also hangs.
        m1n1-hoolock-pcie-dart-nommio-pspcieaux-test = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-dart-nommio-pspcieaux-test" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPcieDartNommioPspcieauxTestKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPcieDartNommioPspcieauxTestKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc overlay/usr/bin
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo

          cp ${btattachPkg}/bin/btattach overlay/usr/bin/btattach
          chmod 755 overlay/usr/bin/btattach
          touch -d @1 overlay/usr/bin/btattach

          for f in ${i2cToolsPkg}/bin/*; do
            cp "$f" "overlay/usr/bin/$(basename "$f")"
            chmod 755 "overlay/usr/bin/$(basename "$f")"
            touch -d @1 "overlay/usr/bin/$(basename "$f")"
          done

          (cd overlay
           { printf '%s\0' "etc/deviceinfo" "usr/bin/btattach"
             for f in ${i2cToolsPkg}/bin/*; do
               printf 'usr/bin/%s\0' "$(basename "$f")"
             done
           } | cpio --null -o -H newc --owner=0:0 --reproducible
          ) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # DART sibling power-domain isolation test, ps_pcie_ref variant --
        # same as above with ps_pcie_ref instead of ps_pcie_aux. Never
        # combined with it in the same payload.
        m1n1-hoolock-pcie-dart-nommio-pspcieref-test = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-dart-nommio-pspcieref-test" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPcieDartNommioPspcierefTestKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPcieDartNommioPspcierefTestKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc overlay/usr/bin
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo

          cp ${btattachPkg}/bin/btattach overlay/usr/bin/btattach
          chmod 755 overlay/usr/bin/btattach
          touch -d @1 overlay/usr/bin/btattach

          for f in ${i2cToolsPkg}/bin/*; do
            cp "$f" "overlay/usr/bin/$(basename "$f")"
            chmod 755 "overlay/usr/bin/$(basename "$f")"
            touch -d @1 "overlay/usr/bin/$(basename "$f")"
          done

          (cd overlay
           { printf '%s\0' "etc/deviceinfo" "usr/bin/btattach"
             for f in ${i2cToolsPkg}/bin/*; do
               printf 'usr/bin/%s\0' "$(basename "$f")"
             done
           } | cpio --null -o -H newc --owner=0:0 --reproducible
          ) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # DART power-domains fix, real driver
        # (docs/plans/2026-09-13-j81-wifi-pcie.md,
        # research/t7000-pcie-hardware-findings.md): repeats 0025 (the
        # real stock apple-dart driver, no iommu-map) with dart_apcie1
        # given power-domains = <&ps_pcie>, the fix Test A (0028)
        # hardware-verified. Identical in every respect to the payloads
        # above except the kernel (hoolockPcieDartPspcieFixTestKernel).
        m1n1-hoolock-pcie-dart-pspcie-fix-test = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-dart-pspcie-fix-test" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPcieDartPspcieFixTestKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPcieDartPspcieFixTestKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc overlay/usr/bin
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo

          cp ${btattachPkg}/bin/btattach overlay/usr/bin/btattach
          chmod 755 overlay/usr/bin/btattach
          touch -d @1 overlay/usr/bin/btattach

          for f in ${i2cToolsPkg}/bin/*; do
            cp "$f" "overlay/usr/bin/$(basename "$f")"
            chmod 755 "overlay/usr/bin/$(basename "$f")"
            touch -d @1 "overlay/usr/bin/$(basename "$f")"
          done

          (cd overlay
           { printf '%s\0' "etc/deviceinfo" "usr/bin/btattach"
             for f in ${i2cToolsPkg}/bin/*; do
               printf 'usr/bin/%s\0' "$(basename "$f")"
             done
           } | cpio --null -o -H newc --owner=0:0 --reproducible
          ) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # Stage 2 of the real PCIe host-controller implementation
        # (docs/plans/2026-09-13-j81-wifi-pcie.md,
        # research/t7000-pcie-hardware-findings.md): Stage 1's enable
        # sequence combined with generic pci_host_common_init()/ECAM bus
        # enumeration -- still no PERST, so the scan is expected to find
        # nothing. Identical in every respect to the payload above except
        # the kernel (hoolockPcieEnableEnumerationTestKernel).
        m1n1-hoolock-pcie-enable-enumeration-test = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-enable-enumeration-test" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPcieEnableEnumerationTestKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPcieEnableEnumerationTestKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc overlay/usr/bin
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo

          cp ${btattachPkg}/bin/btattach overlay/usr/bin/btattach
          chmod 755 overlay/usr/bin/btattach
          touch -d @1 overlay/usr/bin/btattach

          for f in ${i2cToolsPkg}/bin/*; do
            cp "$f" "overlay/usr/bin/$(basename "$f")"
            chmod 755 "overlay/usr/bin/$(basename "$f")"
            touch -d @1 "overlay/usr/bin/$(basename "$f")"
          done

          (cd overlay
           { printf '%s\0' "etc/deviceinfo" "usr/bin/btattach"
             for f in ${i2cToolsPkg}/bin/*; do
               printf 'usr/bin/%s\0' "$(basename "$f")"
             done
           } | cpio --null -o -H newc --owner=0:0 --reproducible
          ) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # Stage 3 of the real PCIe host-controller implementation
        # (docs/plans/2026-09-13-j81-wifi-pcie.md,
        # research/t7000-pcie-hardware-findings.md): Stage 2's enable
        # sequence + generic ECAM enumeration, now with PERST# deasserted
        # via reset-gpios. Identical in every respect to the payload
        # above except the kernel
        # (hoolockPcieEnableEnumerationPerstTestKernel).
        m1n1-hoolock-pcie-enable-enumeration-perst-test = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-enable-enumeration-perst-test" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPcieEnableEnumerationPerstTestKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPcieEnableEnumerationPerstTestKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc overlay/usr/bin
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo

          cp ${btattachPkg}/bin/btattach overlay/usr/bin/btattach
          chmod 755 overlay/usr/bin/btattach
          touch -d @1 overlay/usr/bin/btattach

          for f in ${i2cToolsPkg}/bin/*; do
            cp "$f" "overlay/usr/bin/$(basename "$f")"
            chmod 755 "overlay/usr/bin/$(basename "$f")"
            touch -d @1 "overlay/usr/bin/$(basename "$f")"
          done

          (cd overlay
           { printf '%s\0' "etc/deviceinfo" "usr/bin/btattach"
             for f in ${i2cToolsPkg}/bin/*; do
               printf 'usr/bin/%s\0' "$(basename "$f")"
             done
           } | cpio --null -o -H newc --owner=0:0 --reproducible
          ) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # Stage 4a of the real PCIe host-controller implementation
        # (docs/plans/2026-09-13-j81-wifi-pcie.md,
        # research/t7000-pcie-hardware-findings.md): Stage 3 plus one
        # bounded read from the per-port controller window, no write.
        # Identical in every respect to the payload above except the
        # kernel (hoolockPciePortControllerWindowReadTestKernel).
        m1n1-hoolock-pcie-port-controller-window-read-test = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-port-controller-window-read-test" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPciePortControllerWindowReadTestKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPciePortControllerWindowReadTestKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc overlay/usr/bin
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo

          cp ${btattachPkg}/bin/btattach overlay/usr/bin/btattach
          chmod 755 overlay/usr/bin/btattach
          touch -d @1 overlay/usr/bin/btattach

          for f in ${i2cToolsPkg}/bin/*; do
            cp "$f" "overlay/usr/bin/$(basename "$f")"
            chmod 755 "overlay/usr/bin/$(basename "$f")"
            touch -d @1 "overlay/usr/bin/$(basename "$f")"
          done

          (cd overlay
           { printf '%s\0' "etc/deviceinfo" "usr/bin/btattach"
             for f in ${i2cToolsPkg}/bin/*; do
               printf 'usr/bin/%s\0' "$(basename "$f")"
             done
           } | cpio --null -o -H newc --owner=0:0 --reproducible
          ) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # Stage 4a v2 (docs/plans/2026-09-13-j81-wifi-pcie.md,
        # research/t7000-pcie-hardware-findings.md): the per-port
        # controller window read, mapped non-exclusively after 0036's
        # real -EBUSY. Identical in every other respect to the payload
        # above except the kernel
        # (hoolockPciePortControllerWindowReadTestV2Kernel).
        m1n1-hoolock-pcie-port-controller-window-read-test-v2 = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-port-controller-window-read-test-v2" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPciePortControllerWindowReadTestV2Kernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPciePortControllerWindowReadTestV2Kernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc overlay/usr/bin
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo

          cp ${btattachPkg}/bin/btattach overlay/usr/bin/btattach
          chmod 755 overlay/usr/bin/btattach
          touch -d @1 overlay/usr/bin/btattach

          for f in ${i2cToolsPkg}/bin/*; do
            cp "$f" "overlay/usr/bin/$(basename "$f")"
            chmod 755 "overlay/usr/bin/$(basename "$f")"
            touch -d @1 "overlay/usr/bin/$(basename "$f")"
          done

          (cd overlay
           { printf '%s\0' "etc/deviceinfo" "usr/bin/btattach"
             for f in ${i2cToolsPkg}/bin/*; do
               printf 'usr/bin/%s\0' "$(basename "$f")"
             done
           } | cpio --null -o -H newc --owner=0:0 --reproducible
          ) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # Stage 4b of the real PCIe host-controller implementation
        # (docs/plans/2026-09-13-j81-wifi-pcie.md,
        # research/t7000-pcie-hardware-findings.md): Stage 4a plus the
        # per-port controller window's link-start bit write. Built ahead
        # of Stage 4a's own hardware result -- do NOT test this payload
        # until Stage 4a's bounded read comes back clean; see
        # kernel/patches/0037's own header comment. Identical in every
        # other respect to the payload above except the kernel
        # (hoolockPcieLinkStartWriteTestKernel).
        m1n1-hoolock-pcie-link-start-write-test = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-link-start-write-test" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPcieLinkStartWriteTestKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPcieLinkStartWriteTestKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc overlay/usr/bin
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo

          cp ${btattachPkg}/bin/btattach overlay/usr/bin/btattach
          chmod 755 overlay/usr/bin/btattach
          touch -d @1 overlay/usr/bin/btattach

          for f in ${i2cToolsPkg}/bin/*; do
            cp "$f" "overlay/usr/bin/$(basename "$f")"
            chmod 755 "overlay/usr/bin/$(basename "$f")"
            touch -d @1 "overlay/usr/bin/$(basename "$f")"
          done

          (cd overlay
           { printf '%s\0' "etc/deviceinfo" "usr/bin/btattach"
             for f in ${i2cToolsPkg}/bin/*; do
               printf 'usr/bin/%s\0' "$(basename "$f")"
             done
           } | cpio --null -o -H newc --owner=0:0 --reproducible
          ) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # Stage 4b v2 (docs/plans/2026-09-13-j81-wifi-pcie.md,
        # research/t7000-pcie-hardware-findings.md): the per-port
        # link-start write, mapped non-exclusively per Stage 4a v2's
        # hardware-confirmed fix. Identical in every other respect to
        # the payload above except the kernel
        # (hoolockPcieLinkStartWriteTestV2Kernel).
        m1n1-hoolock-pcie-link-start-write-test-v2 = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-link-start-write-test-v2" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPcieLinkStartWriteTestV2Kernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPcieLinkStartWriteTestV2Kernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc overlay/usr/bin
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo

          cp ${btattachPkg}/bin/btattach overlay/usr/bin/btattach
          chmod 755 overlay/usr/bin/btattach
          touch -d @1 overlay/usr/bin/btattach

          for f in ${i2cToolsPkg}/bin/*; do
            cp "$f" "overlay/usr/bin/$(basename "$f")"
            chmod 755 "overlay/usr/bin/$(basename "$f")"
            touch -d @1 "overlay/usr/bin/$(basename "$f")"
          done

          (cd overlay
           { printf '%s\0' "etc/deviceinfo" "usr/bin/btattach"
             for f in ${i2cToolsPkg}/bin/*; do
               printf 'usr/bin/%s\0' "$(basename "$f")"
             done
           } | cpio --null -o -H newc --owner=0:0 --reproducible
          ) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # Stage 5A (docs/plans/2026-09-13-j81-wifi-pcie.md,
        # research/t7000-pcie-hardware-findings.md): the full recovered
        # enable sequence plus a read-only controller-tuning baseline
        # capture. Identical in every other respect to the payload
        # above except the kernel (hoolockPcieTuningBaselineTestKernel).
        m1n1-hoolock-pcie-tuning-baseline-test = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-tuning-baseline-test" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPcieTuningBaselineTestKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPcieTuningBaselineTestKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc overlay/usr/bin
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo

          cp ${btattachPkg}/bin/btattach overlay/usr/bin/btattach
          chmod 755 overlay/usr/bin/btattach
          touch -d @1 overlay/usr/bin/btattach

          for f in ${i2cToolsPkg}/bin/*; do
            cp "$f" "overlay/usr/bin/$(basename "$f")"
            chmod 755 "overlay/usr/bin/$(basename "$f")"
            touch -d @1 "overlay/usr/bin/$(basename "$f")"
          done

          (cd overlay
           { printf '%s\0' "etc/deviceinfo" "usr/bin/btattach"
             for f in ${i2cToolsPkg}/bin/*; do
               printf 'usr/bin/%s\0' "$(basename "$f")"
             done
           } | cpio --null -o -H newc --owner=0:0 --reproducible
          ) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # Stage 5B mapping gate: the hardware-clean Stage 5A sequence plus
        # one read of the recovered DBI control through cfg->win at
        # ECAM+0x88bc. It does not write the DBI gate or any override.
        m1n1-hoolock-pcie-dbi-ecam-read-test = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-dbi-ecam-read-test" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPcieDbiEcamReadTestKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPcieDbiEcamReadTestKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc overlay/usr/bin
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo

          cp ${btattachPkg}/bin/btattach overlay/usr/bin/btattach
          chmod 755 overlay/usr/bin/btattach
          touch -d @1 overlay/usr/bin/btattach

          for f in ${i2cToolsPkg}/bin/*; do
            cp "$f" "overlay/usr/bin/$(basename "$f")"
            chmod 755 "overlay/usr/bin/$(basename "$f")"
            touch -d @1 "overlay/usr/bin/$(basename "$f")"
          done

          (cd overlay
           { printf '%s\0' "etc/deviceinfo" "usr/bin/btattach"
             for f in ${i2cToolsPkg}/bin/*; do
               printf 'usr/bin/%s\0' "$(basename "$f")"
             done
           } | cpio --null -o -H newc --owner=0:0 --reproducible
          ) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        m1n1-hoolock-pcie-dbi-tunables-write-test = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-dbi-tunables-write-test" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPcieDbiTunablesWriteTestKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPcieDbiTunablesWriteTestKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc overlay/usr/bin
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo

          cp ${btattachPkg}/bin/btattach overlay/usr/bin/btattach
          chmod 755 overlay/usr/bin/btattach
          touch -d @1 overlay/usr/bin/btattach

          for f in ${i2cToolsPkg}/bin/*; do
            cp "$f" "overlay/usr/bin/$(basename "$f")"
            chmod 755 "overlay/usr/bin/$(basename "$f")"
            touch -d @1 "overlay/usr/bin/$(basename "$f")"
          done

          (cd overlay
           { printf '%s\0' "etc/deviceinfo" "usr/bin/btattach"
             for f in ${i2cToolsPkg}/bin/*; do
               printf 'usr/bin/%s\0' "$(basename "$f")"
             done
           } | cpio --null -o -H newc --owner=0:0 --reproducible
          ) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        m1n1-hoolock-pcie-gate-register-test = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-gate-register-test" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPcieGateRegisterTestKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPcieGateRegisterTestKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc overlay/usr/bin
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo

          cp ${btattachPkg}/bin/btattach overlay/usr/bin/btattach
          chmod 755 overlay/usr/bin/btattach
          touch -d @1 overlay/usr/bin/btattach

          for f in ${i2cToolsPkg}/bin/*; do
            cp "$f" "overlay/usr/bin/$(basename "$f")"
            chmod 755 "overlay/usr/bin/$(basename "$f")"
            touch -d @1 "overlay/usr/bin/$(basename "$f")"
          done

          (cd overlay
           { printf '%s\0' "etc/deviceinfo" "usr/bin/btattach"
             for f in ${i2cToolsPkg}/bin/*; do
               printf 'usr/bin/%s\0' "$(basename "$f")"
             done
           } | cpio --null -o -H newc --owner=0:0 --reproducible
          ) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        m1n1-hoolock-pcie-gate-aux-ref-test = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-gate-aux-ref-test" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPcieGateAuxRefTestKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPcieGateAuxRefTestKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc overlay/usr/bin
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo

          cp ${btattachPkg}/bin/btattach overlay/usr/bin/btattach
          chmod 755 overlay/usr/bin/btattach
          touch -d @1 overlay/usr/bin/btattach

          for f in ${i2cToolsPkg}/bin/*; do
            cp "$f" "overlay/usr/bin/$(basename "$f")"
            chmod 755 "overlay/usr/bin/$(basename "$f")"
            touch -d @1 "overlay/usr/bin/$(basename "$f")"
          done

          (cd overlay
           { printf '%s\0' "etc/deviceinfo" "usr/bin/btattach"
             for f in ${i2cToolsPkg}/bin/*; do
               printf 'usr/bin/%s\0' "$(basename "$f")"
             done
           } | cpio --null -o -H newc --owner=0:0 --reproducible
          ) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        m1n1-hoolock-pcie-link-speed-write-test = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-link-speed-write-test" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPcieLinkSpeedWriteTestKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPcieLinkSpeedWriteTestKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc overlay/usr/bin
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo

          cp ${btattachPkg}/bin/btattach overlay/usr/bin/btattach
          chmod 755 overlay/usr/bin/btattach
          touch -d @1 overlay/usr/bin/btattach

          for f in ${i2cToolsPkg}/bin/*; do
            cp "$f" "overlay/usr/bin/$(basename "$f")"
            chmod 755 "overlay/usr/bin/$(basename "$f")"
            touch -d @1 "overlay/usr/bin/$(basename "$f")"
          done

          (cd overlay
           { printf '%s\0' "etc/deviceinfo" "usr/bin/btattach"
             for f in ${i2cToolsPkg}/bin/*; do
               printf 'usr/bin/%s\0' "$(basename "$f")"
             done
           } | cpio --null -o -H newc --owner=0:0 --reproducible
          ) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        m1n1-hoolock-pcie-reg-on-test = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-reg-on-test" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPcieRegOnTestKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPcieRegOnTestKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc overlay/usr/bin
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo

          cp ${btattachPkg}/bin/btattach overlay/usr/bin/btattach
          chmod 755 overlay/usr/bin/btattach
          touch -d @1 overlay/usr/bin/btattach

          for f in ${i2cToolsPkg}/bin/*; do
            cp "$f" "overlay/usr/bin/$(basename "$f")"
            chmod 755 "overlay/usr/bin/$(basename "$f")"
            touch -d @1 "overlay/usr/bin/$(basename "$f")"
          done

          (cd overlay
           { printf '%s\0' "etc/deviceinfo" "usr/bin/btattach"
             for f in ${i2cToolsPkg}/bin/*; do
               printf 'usr/bin/%s\0' "$(basename "$f")"
             done
           } | cpio --null -o -H newc --owner=0:0 --reproducible
          ) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # The reviewable J81 Wi-Fi-only successor to the 0050 test payload.
        # It deliberately carries neither Bluetooth userland nor I2C tools: the
        # kernel's board-bound 0x0403 action is its entire new PMU surface.
        m1n1-hoolock-pcie-j81-reg-on = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-j81-reg-on" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPcieJ81RegOnKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPcieJ81RegOnKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo
          (cd overlay && printf '%s\0' "etc/deviceinfo" | cpio --null -o -H newc --owner=0:0 --reproducible) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # 0052 + 0053 staging payload: board-gated Wi-Fi REG_ON with the DLLLA link wait.
        m1n1-hoolock-pcie-j81-dllla = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-j81-dllla" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPcieJ81DllaKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPcieJ81DllaKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo
          (cd overlay && printf '%s\0' "etc/deviceinfo" | cpio --null -o -H newc --owner=0:0 --reproducible) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # 0052-0054 staging payload: the DLLLA driver after the behaviour-neutral clean-up.
        m1n1-hoolock-pcie-j81-clean = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-j81-clean" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPcieJ81CleanKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPcieJ81CleanKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo
          (cd overlay && printf '%s\0' "etc/deviceinfo" | cpio --null -o -H newc --owner=0:0 --reproducible) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # 0052-0055 staging payload: clean-up plus the per-controller DART MSI doorbell.
        m1n1-hoolock-pcie-j81-doorbell = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-j81-doorbell" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPcieJ81DoorbellKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPcieJ81DoorbellKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo
          (cd overlay && printf '%s\0' "etc/deviceinfo" | cpio --null -o -H newc --owner=0:0 --reproducible) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # Head of the MSI series: the doorbell payload plus 0056 (and later patches).
        m1n1-hoolock-pcie-j81-msi = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-j81-msi" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPcieJ81MsiKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPcieJ81MsiKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo
          (cd overlay && printf '%s\0' "etc/deviceinfo" | cpio --null -o -H newc --owner=0:0 --reproducible) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # TEST ONLY: MSI series plus the 0058 allocation self-test.
        m1n1-hoolock-pcie-j81-msi-selftest = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-j81-msi-selftest" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPcieJ81MsiSelftestKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPcieJ81MsiSelftestKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo
          (cd overlay && printf '%s\0' "etc/deviceinfo" | cpio --null -o -H newc --owner=0:0 --reproducible) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # TEST ONLY: MSI series plus the 0059 read-only +0x168 dump.
        m1n1-hoolock-pcie-j81-msi-diag = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-j81-msi-diag" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPcieJ81MsiDiagKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPcieJ81MsiDiagKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo
          (cd overlay && printf '%s\0' "etc/deviceinfo" | cpio --null -o -H newc --owner=0:0 --reproducible) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # TEST ONLY: MSI series plus the 0061 BCM4350 metadata observation probe.
        m1n1-hoolock-pcie-j81-bcm-probe = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-j81-bcm-probe" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPcieJ81BcmProbeKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPcieJ81BcmProbeKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo
          (cd overlay && printf '%s\0' "etc/deviceinfo" | cpio --null -o -H newc --owner=0:0 --reproducible) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # TEST ONLY: MSI series plus the 0061 probe and 0062 OTP shadow capture (private data).
        m1n1-hoolock-pcie-j81-bcm-shadow = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-j81-bcm-shadow" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPcieJ81BcmShadowKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPcieJ81BcmShadowKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo
          (cd overlay && printf '%s\0' "etc/deviceinfo" | cpio --null -o -H newc --owner=0:0 --reproducible) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # TEST ONLY: DMA model A (0063 window + 0064 Apple rebase).
        m1n1-hoolock-pcie-j81-dma-rebase = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-j81-dma-rebase" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPcieJ81DmaRebaseKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPcieJ81DmaRebaseKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo
          (cd overlay && printf '%s\0' "etc/deviceinfo" | cpio --null -o -H newc --owner=0:0 --reproducible) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # TEST ONLY: DMA model B (0063 window, raw PTE indexing).
        # TEST ONLY: Wi-Fi H1B base (public): DMA model A + brcmfmac PCIe, NO firmware; private overlay is added locally.
        m1n1-hoolock-pcie-j81-wifi-h1b-base = mkJ81BasePayload {
          name = "m1n1-hoolock-pcie-j81-wifi-h1b-base";
          kernel = hoolockPcieJ81WifiH1bKernel;
          # pcie_aspm=off and device_wake=1 are the proven J81 Wi-Fi link settings (research/2026-10-07-wifi-h1b-modelA-run.md run 38); the DART
          # options and the Wi-Fi endpoint node (MAC) now come from the device tree (patches 0089/0090).
          bootargsExtra = "brcmfmac.debug=0x001c0004 pcie_aspm=off pcie_apple_t7000.device_wake=1";
        };

        # Wi-Fi base (public), PRODUCTION: the permanent configuration without the diagnostic code and with quiet brcmfmac logging; the private
        # overlay (firmware, NVRAM, Wi-Fi userland, credentials) is added locally by boot/assemble_private_wifi_payload.py --production.
        m1n1-hoolock-wifi = mkJ81BasePayload {
          name = "m1n1-hoolock-wifi";
          wifi = true;
          dashboard = true;
          kernel = hoolockWifiKernel;
          bootargsExtra = "pcie_aspm=off pcie_apple_t7000.device_wake=1 fbcon=font:TER16x32";
        };

        # TEST ONLY: the production Wi-Fi base plus a boot-time gpio-hog driving AP GPIO 164 (Bluetooth BT_WAKE) high, for the Bluetooth bring-up
        # (research/2026-10-10-bluetooth-gpio2-hardware-test.md). Same kernel as m1n1-hoolock-wifi; only the DTB differs.
        m1n1-hoolock-wifi-btwake = mkJ81BasePayload {
          name = "m1n1-hoolock-wifi-btwake";
          wifi = true;
          dashboard = true;
          btWakeHog = true;
          kernel = hoolockWifiKernel;
          bootargsExtra = "pcie_aspm=off pcie_apple_t7000.device_wake=1 fbcon=font:TER16x32";
        };

        # TEST ONLY: the production Wi-Fi base with the SPI3 spidev test child enabled and a 64 KiB spidev buffer, for the touch firmware-upload experiment.
        # Same kernel as m1n1-hoolock-wifi; only the DTB and one bootarg differ. Assemble privately like the production payload.
        m1n1-hoolock-wifi-touch = mkJ81BasePayload {
          name = "m1n1-hoolock-wifi-touch";
          wifi = true;
          dashboard = true;
          touchSpidev = true;
          kernel = hoolockWifiKernel;
          bootargsExtra = "pcie_aspm=off pcie_apple_t7000.device_wake=1 fbcon=font:TER16x32 spidev.bufsiz=65536";
        };

        # TEST ONLY: the touch payload with the SPI3 chip select driven as a GPIO (pin 51) like Apple's driver; only the DTB differs from m1n1-hoolock-wifi-touch.
        m1n1-hoolock-wifi-touch-gpiocs = mkJ81BasePayload {
          name = "m1n1-hoolock-wifi-touch-gpiocs";
          wifi = true;
          dashboard = true;
          touchSpidev = true;
          touchGpioCs = true;
          kernel = hoolockWifiKernel;
          bootargsExtra = "pcie_aspm=off pcie_apple_t7000.device_wake=1 fbcon=font:TER16x32 spidev.bufsiz=65536";
        };

        # NixOS in RAM: the production Wi-Fi base plus the stage-1 hand-off. With `j81.nixos=http://172.16.42.2:8000/` it fetches root.squashfs from the Mac and switches root into
        # the NixOS system; without that argument (or on any failure) it behaves exactly like m1n1-hoolock-wifi. Same kernel; only the initramfs differs.
        m1n1-hoolock-wifi-nixos = mkJ81BasePayload {
          name = "m1n1-hoolock-wifi-nixos";
          wifi = true;
          dashboard = true;
          nixosHandoff = true;
          touchSpidev = true;       # the SPI3 touch test node (/dev/spidev0.0) for the touch tools in the image
          kernel = hoolockWifiKernel;
          bootargsExtra = "pcie_aspm=off pcie_apple_t7000.device_wake=1 fbcon=font:TER16x32 spidev.bufsiz=65536 j81.nixos=http://172.16.42.2:8000/";
        };

        # TEST ONLY: Wi-Fi H1B base (public), DMA MODEL B (raw) + brcmfmac PCIe, NO firmware; private overlay is added locally.
        m1n1-hoolock-pcie-j81-wifi-h1b-base-raw = mkJ81BasePayload {
          name = "m1n1-hoolock-pcie-j81-wifi-h1b-base-raw";
          kernel = hoolockPcieJ81WifiH1bRawKernel;
          bootargsExtra = "brcmfmac.debug=0x001c0004";
        };

        # TEST ONLY: DMA model B (0063 window, raw PTE indexing).
        m1n1-hoolock-pcie-j81-dma-raw = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-j81-dma-raw" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPcieJ81DmaRawKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPcieJ81DmaRawKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo
          (cd overlay && printf '%s\0' "etc/deviceinfo" | cpio --null -o -H newc --owner=0:0 --reproducible) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        m1n1-hoolock-pcie-link-wait-write-test = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-link-wait-write-test" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPcieLinkWaitWriteTestKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPcieLinkWaitWriteTestKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc overlay/usr/bin
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo

          cp ${btattachPkg}/bin/btattach overlay/usr/bin/btattach
          chmod 755 overlay/usr/bin/btattach
          touch -d @1 overlay/usr/bin/btattach

          for f in ${i2cToolsPkg}/bin/*; do
            cp "$f" "overlay/usr/bin/$(basename "$f")"
            chmod 755 "overlay/usr/bin/$(basename "$f")"
            touch -d @1 "overlay/usr/bin/$(basename "$f")"
          done

          (cd overlay
           { printf '%s\0' "etc/deviceinfo" "usr/bin/btattach"
             for f in ${i2cToolsPkg}/bin/*; do
               printf 'usr/bin/%s\0' "$(basename "$f")"
             done
           } | cpio --null -o -H newc --owner=0:0 --reproducible
          ) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        m1n1-hoolock-pcie-link-state-probe-test = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-link-state-probe-test" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPcieLinkStateProbeTestKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPcieLinkStateProbeTestKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc overlay/usr/bin
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo

          cp ${btattachPkg}/bin/btattach overlay/usr/bin/btattach
          chmod 755 overlay/usr/bin/btattach
          touch -d @1 overlay/usr/bin/btattach

          for f in ${i2cToolsPkg}/bin/*; do
            cp "$f" "overlay/usr/bin/$(basename "$f")"
            chmod 755 "overlay/usr/bin/$(basename "$f")"
            touch -d @1 "overlay/usr/bin/$(basename "$f")"
          done

          (cd overlay
           { printf '%s\0' "etc/deviceinfo" "usr/bin/btattach"
             for f in ${i2cToolsPkg}/bin/*; do
               printf 'usr/bin/%s\0' "$(basename "$f")"
             done
           } | cpio --null -o -H newc --owner=0:0 --reproducible
          ) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # Stage 1 of the real PCIe host-controller implementation
        # (docs/plans/2026-09-13-j81-wifi-pcie.md,
        # research/t7000-pcie-hardware-findings.md): the recovered
        # AppleT7000PCIe::_enablePortHardware shared-window write
        # sequence for board port 1. Identical in every respect to the
        # payload above except the kernel
        # (hoolockPcieEnableSequenceTestKernel).
        m1n1-hoolock-pcie-enable-sequence-test = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-enable-sequence-test" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPcieEnableSequenceTestKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPcieEnableSequenceTestKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc overlay/usr/bin
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo

          cp ${btattachPkg}/bin/btattach overlay/usr/bin/btattach
          chmod 755 overlay/usr/bin/btattach
          touch -d @1 overlay/usr/bin/btattach

          for f in ${i2cToolsPkg}/bin/*; do
            cp "$f" "overlay/usr/bin/$(basename "$f")"
            chmod 755 "overlay/usr/bin/$(basename "$f")"
            touch -d @1 "overlay/usr/bin/$(basename "$f")"
          done

          (cd overlay
           { printf '%s\0' "etc/deviceinfo" "usr/bin/btattach"
             for f in ${i2cToolsPkg}/bin/*; do
               printf 'usr/bin/%s\0' "$(basename "$f")"
             done
           } | cpio --null -o -H newc --owner=0:0 --reproducible
          ) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # DART power-domains fix, iommu-map restored
        # (docs/plans/2026-09-13-j81-wifi-pcie.md,
        # research/t7000-pcie-hardware-findings.md): `0031`
        # hardware-verified the real apple-dart driver with the
        # power-domains fix; this restores pcie's iommu-map (0026's
        # original scope) with that fix carried over. Identical in every
        # respect to the payload above except the kernel
        # (hoolockPcieDartPspcieFixIommuMapTestKernel).
        m1n1-hoolock-pcie-dart-pspcie-fix-iommu-map-test = pkgs.runCommand "ipad-air2-m1n1-hoolock-pcie-dart-pspcie-fix-iommu-map-test" {
          nativeBuildInputs = [ pkgs.gzip pkgs.dtc pkgs.cpio ];
        } ''
          mkdir -p "$out"
          cp ${inputs.hoolockDocs}/binaries/Pongo.bin "$out/Pongo.bin"
          cp ${inputs.hoolockM1n1}/m1n1.bin "$out/m1n1.bin"
          gzip -n -c ${hoolockPcieDartPspcieFixIommuMapTestKernel}/Image > "$out/Image.gz"

          dtc -I dtb -O dts ${hoolockPcieDartPspcieFixIommuMapTestKernel}/dtbs/apple/t7001-j81.dtb \
            | sed -e '/^\tchosen {$/,/^\t};$/ s/framebuffer@0 {/framebuffer {/' \
            | dtc -I dts -O dtb -p 0x10000 -o "$out/t7001-j81.dtb"

          gzip -dc ${inputs.linuxAppleResources}/debug_initrd.img > initramfs.cpio
          mkdir -p original-etc overlay/etc overlay/usr/bin
          (cd original-etc && cpio -id --no-absolute-filenames etc/deviceinfo < ../initramfs.cpio)
          cp original-etc/etc/deviceinfo overlay/etc/deviceinfo
          printf '\ndeviceinfo_usb_rndis_function="ecm.usb0"\n' >> overlay/etc/deviceinfo
          touch -d @1 overlay/etc/deviceinfo

          cp ${btattachPkg}/bin/btattach overlay/usr/bin/btattach
          chmod 755 overlay/usr/bin/btattach
          touch -d @1 overlay/usr/bin/btattach

          for f in ${i2cToolsPkg}/bin/*; do
            cp "$f" "overlay/usr/bin/$(basename "$f")"
            chmod 755 "overlay/usr/bin/$(basename "$f")"
            touch -d @1 "overlay/usr/bin/$(basename "$f")"
          done

          (cd overlay
           { printf '%s\0' "etc/deviceinfo" "usr/bin/btattach"
             for f in ${i2cToolsPkg}/bin/*; do
               printf 'usr/bin/%s\0' "$(basename "$f")"
             done
           } | cpio --null -o -H newc --owner=0:0 --reproducible
          ) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"

          printf '%s\n' 'chosen.bootargs=console=tty0 loglevel=8 ignore_loglevel rdinit=/init PMOS_NO_OUTPUT_REDIRECT pd_ignore_unused clk_ignore_unused' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/Pongo.bin" "$out/m1n1.bin" "$out/m1n1-linux.bin" \
            > "$out/SHA256SUMS"
        '';

        # Same hardware-proven payload, with a display-only USB diagnostic hook.
        m1n1-usb-diagnostic = pkgs.runCommand "ipad-air2-usb-diagnostic" {
          nativeBuildInputs = [ pkgs.gzip pkgs.cpio ];
        } ''
          mkdir -p "$out" overlay/etc/postmarketos-mkinitfs/hooks
          control=${self.packages.${linuxBuildSystem}.m1n1-control}
          cp "$control/"{Pongo.bin,m1n1.bin,t7001-j81.dtb,Image.gz} "$out/"
          hook=etc/postmarketos-mkinitfs/hooks/20-debug-shell.sh
          cp ${./boot/usb-diagnostic.sh} "overlay/$hook"
          chmod 755 "overlay/$hook"
          touch -d @1 "overlay/$hook"
          # Linux accepts concatenated newc archives. Preserve the original
          # archive (including device nodes) and overlay just its debug hook.
          gzip -dc "$control/initramfs.gz" > initramfs.cpio
          (cd overlay; printf '%s\0' "$hook" | cpio --null -o -H newc \
            --owner=0:0 --reproducible) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"
          # Keep debug messages in dmesg without interrupting dashboard pages.
          sed 's/ ignore_loglevel//' "$control/bootargs" \
            | sed 's/$/ dyndbg="func ecm_setup +p; func ecm_set_alt +p; func gether_connect +p"/' \
            > "$out/bootargs"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/"{Pongo.bin,m1n1.bin,m1n1-linux.bin} > "$out/SHA256SUMS"
        '';

        # SSH stage 1 (docs/plans/2026-09-26-tethered-tablet-and-charging.md):
        # the proven control payload plus a replacement debug-shell hook that
        # keeps telnet recovery and adds key-only Dropbear on the USB address.
        # Dropbear is dynamically linked against musl in the Nix store, so its
        # complete closure is copied to the same store paths in the archive.
        m1n1-hoolock-ssh-stage1 = let
          dropbearPkg = pkgsCrossMusl.dropbear;
          dropbearClosure = pkgs.closureInfo { rootPaths = [ dropbearPkg ]; };
        in pkgs.runCommand "ipad-air2-m1n1-hoolock-ssh-stage1" {
          nativeBuildInputs = [ pkgs.gzip pkgs.cpio pkgs.findutils ];
        } ''
          mkdir -p "$out" overlay/etc/postmarketos-mkinitfs/hooks
          control=${self.packages.${linuxBuildSystem}.m1n1-hoolock-control}
          cp "$control/"{Pongo.bin,m1n1.bin,t7001-j81.dtb,Image.gz,bootargs} "$out/"
          hook=etc/postmarketos-mkinitfs/hooks/20-debug-shell.sh
          sed 's|@DROPBEAR@|${dropbearPkg}|' ${./boot/ssh-stage1.sh} > "overlay/$hook"
          chmod 755 "overlay/$hook"

          # Minimal account state absent from the base image.
          mkdir -p overlay/root/.ssh overlay/var/empty overlay/var/run overlay/var/log
          echo 'root:x:0:0:root:/root:/bin/sh' > overlay/etc/passwd
          echo 'root:x:0:' > overlay/etc/group
          cp ${./boot/ssh/authorized_keys} overlay/root/.ssh/authorized_keys
          chmod 700 overlay/root overlay/root/.ssh
          chmod 600 overlay/root/.ssh/authorized_keys
          chmod 644 overlay/etc/passwd overlay/etc/group

          mkdir -p overlay/usr/bin
          cp ${./boot/tablet-status.sh} overlay/usr/bin/tablet-status
          chmod 755 overlay/usr/bin/tablet-status

          # Dropbear runtime closure at its original store paths.
          mkdir -p overlay/nix/store
          while read -r p; do cp -a "$p" overlay/nix/store/; done < ${dropbearClosure}/store-paths
          chmod -R u+w overlay/nix
          find overlay -exec touch -h -d @1 {} +

          gzip -dc "$control/initramfs.gz" > initramfs.cpio
          (cd overlay; find . -mindepth 1 -print0 | sed -z 's|^\./||' | LC_ALL=C sort -z \
            | cpio --null -o -H newc --owner=0:0 --reproducible) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/"{Pongo.bin,m1n1.bin,m1n1-linux.bin} > "$out/SHA256SUMS"
        '';

        # Tablet payload: SSH stage 1 plus the boot-time charging policy, on the
        # charging-writable kernel (patch 0017). Telnet stays as the recovery path.
        m1n1-hoolock-tablet = let
          dropbearPkg = pkgsCrossMusl.dropbear;
          dropbearClosure = pkgs.closureInfo { rootPaths = [ dropbearPkg ]; };
        in pkgs.runCommand "ipad-air2-m1n1-hoolock-tablet" {
          nativeBuildInputs = [ pkgs.gzip pkgs.cpio pkgs.findutils ];
        } ''
          mkdir -p "$out" overlay/etc/postmarketos-mkinitfs/hooks
          control=${self.packages.${linuxBuildSystem}.m1n1-hoolock-charging-writable-test}
          cp "$control/"{Pongo.bin,m1n1.bin,t7001-j81.dtb,Image.gz,bootargs} "$out/"
          hook=etc/postmarketos-mkinitfs/hooks/20-debug-shell.sh
          sed 's|@DROPBEAR@|${dropbearPkg}|' ${./boot/ssh-stage1.sh} \
            | sed 's|^loop_forever$|/usr/bin/charging-policy >/var/log/charging-policy.log 2>\&1 \&\nloop_forever|' > "overlay/$hook"
          chmod 755 "overlay/$hook"

          # Minimal account state absent from the base image.
          mkdir -p overlay/root/.ssh overlay/var/empty overlay/var/run overlay/var/log
          echo 'root:x:0:0:root:/root:/bin/sh' > overlay/etc/passwd
          echo 'root:x:0:' > overlay/etc/group
          cp ${./boot/ssh/authorized_keys} overlay/root/.ssh/authorized_keys
          chmod 700 overlay/root overlay/root/.ssh
          chmod 600 overlay/root/.ssh/authorized_keys
          chmod 644 overlay/etc/passwd overlay/etc/group

          mkdir -p overlay/usr/bin
          cp ${./boot/tablet-status.sh} overlay/usr/bin/tablet-status
          chmod 755 overlay/usr/bin/tablet-status
          cp ${./boot/charging-policy.sh} overlay/usr/bin/charging-policy
          chmod 755 overlay/usr/bin/charging-policy
          cp ${./boot/tablet-dashboard.sh} overlay/usr/bin/tablet-dashboard
          chmod 755 overlay/usr/bin/tablet-dashboard

          # Dropbear runtime closure at its original store paths.
          mkdir -p overlay/nix/store
          while read -r p; do cp -a "$p" overlay/nix/store/; done < ${dropbearClosure}/store-paths
          chmod -R u+w overlay/nix
          find overlay -exec touch -h -d @1 {} +

          gzip -dc "$control/initramfs.gz" > initramfs.cpio
          (cd overlay; find . -mindepth 1 -print0 | sed -z 's|^\./||' | LC_ALL=C sort -z \
            | cpio --null -o -H newc --owner=0:0 --reproducible) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/"{Pongo.bin,m1n1.bin,m1n1-linux.bin} > "$out/SHA256SUMS"
        '';

        # Touch diagnostic payload: the tablet payload plus /usr/bin/touch-diag
        # (boot/touch-diag.c). The tool is inert unless run with explicit flags.
        m1n1-hoolock-touch-diag = let
          dropbearPkg = pkgsCrossMusl.dropbear;
          touchDiagPkg = pkgsCrossMusl.runCommandCC "touch-diag" {} ''
            mkdir -p $out/bin
            $CC -O2 -Wall -Wextra -Werror -static -o $out/bin/touch-diag ${./boot/touch-diag.c}
          '';
          dropbearClosure = pkgs.closureInfo { rootPaths = [ dropbearPkg ]; };
        in pkgs.runCommand "ipad-air2-m1n1-hoolock-touch-diag" {
          nativeBuildInputs = [ pkgs.gzip pkgs.cpio pkgs.findutils ];
        } ''
          mkdir -p "$out" overlay/etc/postmarketos-mkinitfs/hooks
          control=${self.packages.${linuxBuildSystem}.m1n1-hoolock-charging-writable-test}
          cp "$control/"{Pongo.bin,m1n1.bin,t7001-j81.dtb,Image.gz,bootargs} "$out/"
          hook=etc/postmarketos-mkinitfs/hooks/20-debug-shell.sh
          sed 's|@DROPBEAR@|${dropbearPkg}|' ${./boot/ssh-stage1.sh} \
            | sed 's|^loop_forever$|/usr/bin/charging-policy >/var/log/charging-policy.log 2>\&1 \&\nloop_forever|' > "overlay/$hook"
          chmod 755 "overlay/$hook"

          # Minimal account state absent from the base image.
          mkdir -p overlay/root/.ssh overlay/var/empty overlay/var/run overlay/var/log
          echo 'root:x:0:0:root:/root:/bin/sh' > overlay/etc/passwd
          echo 'root:x:0:' > overlay/etc/group
          cp ${./boot/ssh/authorized_keys} overlay/root/.ssh/authorized_keys
          chmod 700 overlay/root overlay/root/.ssh
          chmod 600 overlay/root/.ssh/authorized_keys
          chmod 644 overlay/etc/passwd overlay/etc/group

          mkdir -p overlay/usr/bin
          cp ${./boot/tablet-status.sh} overlay/usr/bin/tablet-status
          chmod 755 overlay/usr/bin/tablet-status
          cp ${./boot/charging-policy.sh} overlay/usr/bin/charging-policy
          chmod 755 overlay/usr/bin/charging-policy
          cp ${./boot/tablet-dashboard.sh} overlay/usr/bin/tablet-dashboard
          chmod 755 overlay/usr/bin/tablet-dashboard
          cp ${touchDiagPkg}/bin/touch-diag overlay/usr/bin/touch-diag
          chmod 755 overlay/usr/bin/touch-diag

          # Dropbear runtime closure at its original store paths.
          mkdir -p overlay/nix/store
          while read -r p; do cp -a "$p" overlay/nix/store/; done < ${dropbearClosure}/store-paths
          chmod -R u+w overlay/nix
          find overlay -exec touch -h -d @1 {} +

          gzip -dc "$control/initramfs.gz" > initramfs.cpio
          (cd overlay; find . -mindepth 1 -print0 | sed -z 's|^\./||' | LC_ALL=C sort -z \
            | cpio --null -o -H newc --owner=0:0 --reproducible) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/"{Pongo.bin,m1n1.bin,m1n1-linux.bin} > "$out/SHA256SUMS"
        '';

        # Touch SPI experiment payload: touch-spi kernel + tablet overlay + touch-diag.
        m1n1-hoolock-touch-spi = let
          dropbearPkg = pkgsCrossMusl.dropbear;
          touchDiagPkg = pkgsCrossMusl.runCommandCC "touch-diag" {} ''
            mkdir -p $out/bin
            $CC -O2 -Wall -Wextra -Werror -static -o $out/bin/touch-diag ${./boot/touch-diag.c}
          '';
          dropbearClosure = pkgs.closureInfo { rootPaths = [ dropbearPkg ]; };
        in pkgs.runCommand "ipad-air2-m1n1-hoolock-touch-spi" {
          nativeBuildInputs = [ pkgs.gzip pkgs.cpio pkgs.findutils ];
        } ''
          mkdir -p "$out" overlay/etc/postmarketos-mkinitfs/hooks
          control=${self.packages.${linuxBuildSystem}.m1n1-hoolock-touch-spi-test}
          cp "$control/"{Pongo.bin,m1n1.bin,t7001-j81.dtb,Image.gz,bootargs} "$out/"
          hook=etc/postmarketos-mkinitfs/hooks/20-debug-shell.sh
          sed 's|@DROPBEAR@|${dropbearPkg}|' ${./boot/ssh-stage1.sh} \
            | sed 's|^loop_forever$|/usr/bin/charging-policy >/var/log/charging-policy.log 2>\&1 \&\nloop_forever|' > "overlay/$hook"
          chmod 755 "overlay/$hook"

          # Minimal account state absent from the base image.
          mkdir -p overlay/root/.ssh overlay/var/empty overlay/var/run overlay/var/log
          echo 'root:x:0:0:root:/root:/bin/sh' > overlay/etc/passwd
          echo 'root:x:0:' > overlay/etc/group
          cp ${./boot/ssh/authorized_keys} overlay/root/.ssh/authorized_keys
          chmod 700 overlay/root overlay/root/.ssh
          chmod 600 overlay/root/.ssh/authorized_keys
          chmod 644 overlay/etc/passwd overlay/etc/group

          mkdir -p overlay/usr/bin
          cp ${./boot/tablet-status.sh} overlay/usr/bin/tablet-status
          chmod 755 overlay/usr/bin/tablet-status
          cp ${./boot/charging-policy.sh} overlay/usr/bin/charging-policy
          chmod 755 overlay/usr/bin/charging-policy
          cp ${./boot/tablet-dashboard.sh} overlay/usr/bin/tablet-dashboard
          chmod 755 overlay/usr/bin/tablet-dashboard
          cp ${touchDiagPkg}/bin/touch-diag overlay/usr/bin/touch-diag
          chmod 755 overlay/usr/bin/touch-diag

          # Dropbear runtime closure at its original store paths.
          mkdir -p overlay/nix/store
          while read -r p; do cp -a "$p" overlay/nix/store/; done < ${dropbearClosure}/store-paths
          chmod -R u+w overlay/nix
          find overlay -exec touch -h -d @1 {} +

          gzip -dc "$control/initramfs.gz" > initramfs.cpio
          (cd overlay; find . -mindepth 1 -print0 | sed -z 's|^\./||' | LC_ALL=C sort -z \
            | cpio --null -o -H newc --owner=0:0 --reproducible) >> initramfs.cpio
          gzip -n -c initramfs.cpio > "$out/initramfs.gz"
          cat "$out/m1n1.bin" "$out/bootargs" "$out/t7001-j81.dtb" \
            "$out/Image.gz" "$out/initramfs.gz" > "$out/m1n1-linux.bin"
          sha256sum "$out/"{Pongo.bin,m1n1.bin,m1n1-linux.bin} > "$out/SHA256SUMS"
        '';

        # Minimal initramfs — entire root filesystem in RAM
        # Build with SSH access:
        # IPAD_AUTHORIZED_KEYS=/absolute/path/key.pub nix build --impure \
        #   .#packages.x86_64-linux.initramfs
        # Output: result/initrd  (symlink to result/initrd.zst)
        initramfs = pkgsCrossMusl.callPackage ./nixos/initramfs.nix {
          inherit authorizedKeysFile;
        };

        gaster = pkgs.callPackage ./boot/gaster.nix {};
      };

      packages.aarch64-darwin.gaster = darwinGaster;

      # NixOS that lives entirely in RAM (feasibility; docs/plans/2026-10-11-nixos-in-ram.md).
      nixosConfigurations.ipad-air2-ram = nixpkgs.lib.nixosSystem {
        modules = [ ./nixos/ipad-air2-ram.nix ];
      };

      # RookPad: ipad-air2-ram + RetroArch + a TUI launcher (nixos/rookpad.nix).
      # Built as its own NixOS system so the base config stays untouched for other work.
      nixosConfigurations.rookpad = nixpkgs.lib.nixosSystem {
        modules = [ ./nixos/rookpad.nix ];
      };

      # The RAM system's pieces for the stage-1 hand-off (boot/nixos-handoff.sh): the toplevel and a zstd squashfs of its closure, root = the store paths (make-squashfs layout).
      # Built on the aarch64 builder: nix build .#packages.aarch64-linux.ipad-air2-ram-rootfs -o artifacts/live/gcroot-nixos-ram-rootfs
      packages.aarch64-linux = let
        ramSystem = self.nixosConfigurations.ipad-air2-ram;
        rookpadSystem = self.nixosConfigurations.rookpad;
      in {
        ipad-air2-ram-toplevel = ramSystem.config.system.build.toplevel;
        # One directory with exactly what the hand-off fetches, so the image and the toplevel path can never be mismatched: nix build .#packages.aarch64-linux.ipad-air2-ram-serve -o artifacts/live/gcroot-nixos-ram-serve
        ipad-air2-ram-serve = ramSystem.pkgs.runCommand "ipad-air2-ram-serve" { } ''
          mkdir -p $out
          ln -s ${self.packages.aarch64-linux.ipad-air2-ram-rootfs} $out/root.squashfs
          echo ${builtins.unsafeDiscardStringContext (toString ramSystem.config.system.build.toplevel)} > $out/toplevel
        '';
        ipad-air2-ram-rootfs = ramSystem.pkgs.callPackage "${nixpkgs}/nixos/lib/make-squashfs.nix" {
          fileName = "root";
          storeContents = [ ramSystem.config.system.build.toplevel ];
          comp = "zstd -Xcompression-level 19";
        };
        # RookPad flavor: same hand-off pattern, different toplevel.
        rookpad-toplevel = rookpadSystem.config.system.build.toplevel;
        rookpad-serve = rookpadSystem.pkgs.runCommand "rookpad-serve" { } ''
          mkdir -p $out
          ln -s ${self.packages.aarch64-linux.rookpad-rootfs} $out/root.squashfs
          echo ${builtins.unsafeDiscardStringContext (toString rookpadSystem.config.system.build.toplevel)} > $out/toplevel
        '';
        rookpad-rootfs = rookpadSystem.pkgs.callPackage "${nixpkgs}/nixos/lib/make-squashfs.nix" {
          fileName = "root";
          storeContents = [ rookpadSystem.config.system.build.toplevel ];
          comp = "zstd -Xcompression-level 19";
        };
      };

      # macOS remote Linux builder used for every x86_64-linux/aarch64-linux
      # build in this flake (aarch64-darwin cannot build Linux derivations
      # directly). See docs/build-infrastructure.md for the full story of
      # why this exists as a flake output instead of a one-off shell
      # command, and how to run it.
      packages.aarch64-darwin.linux-builder = (import nixpkgsBuilder {
        system = "aarch64-darwin";
      }).darwin.linux-builder-vz.override {
        modules = [{
          virtualisation.cores = 4;
          virtualisation.darwin-builder.memorySize = 8 * 1024;
          virtualisation.darwin-builder.diskSize = 40 * 1024;
        }];
      };
    };
}
