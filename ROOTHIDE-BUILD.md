# RootHide build — credits and what works

This branch (`codex/roothide-compat`) carries the RootHide (Dopamine-roothide)
port of Virtual Mac, and builds the package **on the iPad itself** instead of
on a Mac. Nothing here changes the app's behaviour for a standard
Dopamine/Taurine install; the standard package still comes from the upstream
build.

## Credits

- **Virtual Mac on iPad** — [nfzerox/VirtualMacOniPad](https://github.com/nfzerox/VirtualMacOniPad),
  the original project: the Virtualization-based macOS runtime, the UIKit host,
  the guest tools and the shared-frameworks extraction. All of it is theirs;
  this branch only adds a jailbreak compatibility layer and a device-side build.
- **RootHide/Dopamine compatibility** — upstream PR #78 (yyyr-p), which this
  branch starts from: `VZHostCompat.dylib`, `VirtualMacPaths.dylib` path
  redirection, the RootHide installer stamps and the roothide packaging.
- **RootHide / Dopamine-roothide** — the bootstrap, `libroothide` and `jbctl`
  that make an ad-hoc signed package runnable on a non-platform jailbreak.
- The device-side build port in this branch was written and verified on an
  iPad Pro 11" (M2, iPad14,4) running iPadOS 16.1.1 with Dopamine-roothide.

## What this branch does

1. **RootHide package** `com.mac.virtual` (`iphoneos-arm64e`), built from the
   released 1.2.3 deb as a snapshot: the Apple payload and app resources come
   from that deb, while the host app, `VZHostCompat.dylib`,
   `VirtualMacPaths.dylib`, `runtime-processes`, `legacy-storage`,
   `install-launcher`, `install-macos`, `MetalCompat`, `LaunchServicesCompat`,
   `InstallationCompat`, the keyboard passthrough tweak and
   `virtualmac-diagnostics` are compiled here.
2. **Builds on the device**: `scripts/build-roothide-deb.sh` no longer needs
   `xcrun`, `ditto`, `shasum`, `python3`, `plutil`, `rsync` or `awk`. It uses
   the on-device clang/SDK, `cp -a`, `sha256sum`, GNU sed, and
   `scripts/lib/macho.sh` (od/dd) for the LC_LOAD_DYLIB injection that used to
   be `vz/patches/add_macho_dylib.py`. It still runs unchanged on a Mac.
3. **Launch daemons that launchd accepts**: the NetworkSharing job is shipped
   as `vzi.apple.NetworkSharing`, the label roothide's launchd assigns to a
   bootstrap `com.apple.NetworkSharing`; postinst and the stop-runtime helper
   recognise both labels.
4. **Smoother host input**: the scroll-coalescing `CADisplayLink` asks for
   60–120 Hz instead of the default 60, and the guest's presented frame rate is
   logged every two seconds (`guest frames N/s`).

## Verified on the device

Tested on iPad Pro 11" M2 / iPadOS 16.1.1 / Dopamine-roothide:

- the package installs; `postinst` creates the private state tree, migrates a
  legacy library, trusts every Mach-O with `jbctl` and registers the app;
- the app launches and shows its VM library;
- a macOS 15.6.1 (24G90) restore installation runs to `INSTALL_SUCCEEDED`;
- that VM cold-boots: the payload VMM runs, `[GuestPolicy] guest CSR policy
  complete`, twelve `IOSurfaceCreate` calls, `PVG frame=1..3`, keys and pointer
  events reach the guest, and its disk is written while it runs;
- the guest's frame rate measures ~30 fps at most (33.8 fps peak during boot)
  and drops to almost no frames when the desktop is idle — that ceiling is the
  Virtualization framework's framebuffer rate, not the app's drawing loop, so
  the VM picture cannot be 120 Hz;
- with `NetworkMode = NAT`, `InternetSharing` and `bootpd` come up under
  launchd and the guest receives a `192.168.64.2` lease from vmnet.

## Not verified

- Bridged networking on `en0` (Wi-Fi): the bridge is configured but the guest
  gets no lease; NAT is the working mode.
- The keyboard passthrough tweak, the iPadOS 15 runtime variants on iPadOS 16,
  suspend/resume, shared folders, audio and external displays.
- The 120 Hz scroll path can only be felt with a trackpad or mouse; it was not
  exercised.

## Building

On the device (or a Mac, unchanged):

```sh
VZ_BASE_DEB=/path/to/VirtualMac_1.2.3.deb \
VZ_ROOTHIDE_SDK=/path/to/roothide-sdk/devkit \
bash VirtualMac/scripts/build-roothide-deb.sh
```

`VZ_BASE_DEB` selects the released-deb snapshot build; without it the script
runs the component builds first. The RootHide devkit is only a `roothide.h`
(`jbroot`/`rootfs`/`jbrand`) and a `libroothide.tbd` stub with install name
`@loader_path/.jbroot/usr/lib/libroothide.dylib`. `AGENTS.md` records the
device-specific pitfalls of this port.
