# VirtualMacOniPad — RootHide port, built on the iPad itself

Workspace of `yyyr-p/VirtualMacOniPad`, branch `codex/roothide-compat`
(upstream PR #78, RootHide/Dopamine compatibility). This file records how the
project builds on this device and what has been verified, so a later session
does not repeat the port.

## Build

```
apelin_project_build          # apelin/build.sh → VirtualMac/scripts/build-roothide-deb.sh
apelin_package_install        # takes the artifact the build answered
```

`apelin/build.sh` is the only entry point. It:

1. makes sure `VirtualMac/build/downloads/VirtualMac_1.2.3.deb` is the released
   1.2.3 package (sha256 `435ce1dc76b9e18b1547c77b84e2cf33ffe40a16be63e366f181d14709a41aa0`,
   `https://github.com/nfzerox/VirtualMacOniPad/releases/download/1.2.3/VirtualMac_1.2.3.deb`),
   fetching it with `icli probe` when it is missing — the device has no curl;
2. writes the RootHide devkit stub the build expects
   (`VirtualMac/build/toolchain/roothide-sdk/devkit`: `roothide.h` with
   `jbroot`/`rootfs`/`jbrand`, and `roothide/libroothide.tbd` with install name
   `@loader_path/.jbroot/usr/lib/libroothide.dylib`);
3. runs the package script with `VZ_BASE_DEB`, `VZ_ROOTHIDE_SDK` and
   `VZ_BUILD_ROOT` set, then copies `VirtualMac/build/roothide/VirtualMac_roothide.deb`
   into the build's package folder.

The build is a snapshot build from the released deb: the Apple payload, the
app resources and the helper binaries come from that deb, and the RootHide parts
are compiled here — the host app and its switches, `VZHostCompat.dylib`,
`VirtualMacPaths.dylib`, `runtime-processes`, `legacy-storage`,
`install-launcher`, `install-macos`, `MetalCompat`, `LaunchServicesCompat`,
`InstallationCompat` (both iPadOS variants), `VZKeyboardPassthrough.dylib` and
`virtualmac-diagnostics`.

Package: `com.mac.virtual`, `iphoneos-arm64e`, version
`2:1.2.3+roothide14.device.<commit>`. Depends on `roothide`,
`dopamine-basebin-link`, `ellekit` (all installed on this device).

## What had to change for the device

The script was a Mac script. On the iPad there is no `xcrun`, `ditto`, `rsync`,
`shasum`, `python3`, `plutil`, `awk`, `ps`, `gzip` or `git`, and the toolchain's
`ld` is an Xcode 15.3 driver that cannot start the classic linker.

- `xcrun --sdk iphoneos clang` → `clang` with the prepared `SDKROOT`.
- `ditto` → `cp -a` (`copy_tree`/`copy_item`), `shasum` → `sha256sum`,
  `sed -i ''` → `sed -i`, commit read from `.git/HEAD` instead of `git rev-parse`.
- The Python plist work is shell now: `sed` rewrites the launch daemons'
  `/var/jb` and `/tmp` paths, adds the two storage entitlements before the root
  `</dict>` of the host entitlements and of every `ldid -e` result, and sets
  `CFBundleShortVersionString`. The Python audits became shell checks at the end
  of the script.
- `vz/patches/add_macho_dylib.py` → `scripts/lib/macho.sh`
  (`inject_macho_dylib`), the same LC_LOAD_DYLIB insertion with `od`, `dd` and
  `printf`, same structural checks. It is not restricted to executables:
  `MobileDevice` is a dylib and gets the load command too.
- `-Wl,-undefined,dynamic_lookup` cannot link a dylib on this device
  (`ld` answers `can't exec ld64`). `link_dylib` links once, collects the
  symbols it reported as undefined and re-links with `-Wl,-U,<symbol>`; the
  result is the same runtime lookups.
- `packaging/roothide/stop-runtime.sh` used `ps` and `awk`, which this bootstrap
  does not ship: the fallback that scanned `ps` is gone, and `runtime-processes`
  is the only process matcher. It is spliced into `preinst`/`prerm` by the build.
- Two SDK fixes for the 17.4 headers: `vz/host/VZPaths.h` includes `<string.h>`
  (it calls `strlen`), and `VirtualMacApp.m` falls back to the `0x80` option bit
  for `AVAudioSessionCategoryOptionAllowBluetoothHFP`, which the 17.4 SDK no
  longer declares.

An ad-hoc `ldid -S` binary built in the project does **not** run on this device
(killed with SIGKILL by AMFI, no crash report). That is why there is no
device-side helper tool for the build: everything the build needs runs as
bootstrap binaries. Do not spend time on one without first getting the binary
into the jailbreak trust cache as root.

## Verified on this device (iPad14,4, iPadOS 16.1.1, Dopamine-roothide)

- `apelin_project_build` produces `VirtualMac_roothide.deb` (~21 MB, 387 files,
  `Installed-Size` ~104 MB).
- `apelin_package_install` succeeds; `postinst` creates
  `/var/mobile/Library/VirtualMac/{Root,Network,User}`, migrates an existing
  standard library into `User/Legacy`, adds every Mach-O to the jailbreak trust
  cache and registers the app with `uicache`.
- `/Applications/VirtualMac.app` (bundle `com.mac.virtual`,
  `CFBundleShortVersionString` `1.2.3-roothide`), `/usr/libexec/VirtualMac`,
  `/usr/lib/VirtualMacPaths.dylib` and
  `/usr/lib/TweakInject/VZKeyboardPassthrough.dylib` are installed, signed with
  the storage entitlements RootHide needs on top of their own.
- The app launches (`icli app launch com.mac.virtual`) and shows its VM library;
  `VirtualMac.log` is written to `/var/mobile/Library/VirtualMac/User/Run/`
  with the expected startup lines (`installed Metal keyboard-rendering fix`,
  `VM picker ready`, `presenting VM library`).

## Not verified

- Booting a guest (the Sequoia bundle the install migrated): the VMM, the
  injected `VirtualMacPaths.dylib`, `com.apple.security.virtualization` and the
  hypervisor path have not been exercised.
- The network daemons are bootstrapped by `postinst` and show up under
  `launchctl print user/501/com.apple.NetworkSharing` (spawn scheduled) and
  `user/501/vzi.apple.bootpd` (not running, socket activated); they have not
  been made to serve an actual VM network.
- `install-macos` / restore-OS installation, the keyboard passthrough tweak, and
  the iPadOS 15 binaries (`*.ipados15`) on this iPadOS 16 device.
