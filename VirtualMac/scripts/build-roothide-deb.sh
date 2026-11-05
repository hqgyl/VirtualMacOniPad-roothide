#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/macho.sh"

# The script was written for a Mac (xcrun, ditto, shasum, python3, rsync). It
# also runs on the iPad itself against the on-device toolchain, where those
# tools do not exist: clang comes from PATH with SDKROOT already set, cp -a and
# sha256sum replace ditto and shasum, and scripts/lib/macho.sh plus sed replace
# the Python helpers. VZ_DEVICE_TOOLS=1 in .env or the environment forces the
# device behaviour.
DEVICE_BUILD=0
if ! command -v xcrun >/dev/null 2>&1; then
    DEVICE_BUILD=1
fi

if [[ "$DEVICE_BUILD" == 1 ]]; then
    for tool in clang ldid dpkg-deb sha256sum od dd cut sed grep find du; do
        need_command "$tool"
    done
    need_command od
else
    for tool in xcrun ldid dpkg-deb python3 shasum ditto plutil rsync; do
        need_command "$tool"
    done
fi

"$SCRIPT_DIR/development/prepare-roothide-sdk.sh"

DEVELOPMENT=0
if [[ "${1:-}" == --development ]]; then
    DEVELOPMENT=1
    shift
fi
[[ $# == 0 ]] || die "usage: build-roothide-deb.sh [--development]"
if [[ "$DEVICE_BUILD" == 1 ]]; then
    [[ -n "${SDKROOT:-}" ]] || die "SDKROOT is not set"
    SDK="$SDKROOT"
else
    SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
fi
ROOTHIDE_SDK="${VZ_ROOTHIDE_SDK:-$VZ_BUILD_ROOT/toolchain/roothide-sdk/devkit}"
OUT="$VZ_BUILD_ROOT/roothide"
STAGE="$OUT/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" "$STAGE/Applications" \
    "$STAGE/usr/libexec" "$STAGE/usr/bin" "$STAGE/usr/lib" \
    "$STAGE/usr/sbin" "$STAGE/Library/LaunchDaemons"
RUNTIME="$STAGE/usr/libexec/VirtualMac"
APP="$STAGE/Applications/VirtualMac.app"

# ditto merges a source directory's contents into the destination; cp -a does
# the same with a trailing "/.", so the device keeps one code path for both.
copy_tree() { # SRC DST
    if [[ "$DEVICE_BUILD" == 1 ]]; then
        mkdir -p "$2"
        cp -a "$1/." "$2/"
    else
        ditto "$1" "$2"
    fi
}

copy_item() { # SRC DST
    if [[ "$DEVICE_BUILD" == 1 ]]; then
        mkdir -p "$(dirname "$2")"
        cp -a "$1" "$2"
    else
        ditto "$1" "$2"
    fi
}

sha256_of() { # FILE
    if [[ "$DEVICE_BUILD" == 1 ]]; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

sed_in_place() { # FILE -e EXPR...
    local file=$1
    shift
    if [[ "$DEVICE_BUILD" == 1 ]]; then
        sed -i "$@" "$file"
    else
        sed -i '' "$@" "$file"
    fi
}

# The device toolchain's ld wrapper cannot start the classic linker that
# `-undefined dynamic_lookup` selects, so a dylib there links once, the symbols
# it reports as undefined are allowed one by one with -U, and the link runs
# again: the same runtime lookups, without the flag that ld refuses.
DYLIB_UNDEFINED="-Wl,-undefined,dynamic_lookup"
if [[ "$DEVICE_BUILD" == 1 ]]; then
    DYLIB_UNDEFINED=""
fi

link_dylib() { # COMMAND ARGS...
    if [[ "$DEVICE_BUILD" != 1 ]]; then
        "$@"
        return
    fi
    local attempt=0 log="$OUT/link.log" symbols symbol
    local -a allowed=()
    while :; do
        if "$@" "${allowed[@]+"${allowed[@]}"}" 2> "$log"; then
            return 0
        fi
        attempt=$((attempt + 1))
        symbols=$(sed -n 's/^  "\(_.*\)", referenced from:$/\1/p' "$log" | sort -u)
        if [[ -z "$symbols" ]] || [[ "$attempt" -ge 6 ]]; then
            cat "$log" >&2
            return 1
        fi
        while IFS= read -r symbol; do
            allowed+=("-Wl,-U,$symbol")
        done <<< "$symbols"
    done
}

# The default build assembles from freshly built component products (the same
# Apple-extracted runtime the standard package builds from), so payload-internal
# fixes flow in without reissuing a release deb. Set VZ_BASE_DEB to fall back to
# the released deb for reproducible-from-snapshot builds; in that mode component
# builds are skipped and the deb's extracted payload is reused.
if [[ -n "${VZ_BASE_DEB:-}" ]]; then
    DEB="$VZ_BASE_DEB"
    need_file "$DEB"
    actual="$(sha256_of "$DEB")"
    [[ "$(dpkg-deb -f "$DEB" Package)" == com.mac.virtual ]] || die "unexpected base package"
    CACHE="$OUT/base-$actual"
    if [[ ! -f "$CACHE/.source-sha256" ]] ||
        [[ "$(cat "$CACHE/.source-sha256")" != "$actual" ]]; then
        mkdir -p "$CACHE"
        dpkg-deb -x "$DEB" "$CACHE"
        printf '%s\n' "$actual" > "$CACHE/.source-sha256"
    fi
    copy_tree "$CACHE/var/root/VirtualMac/payload" "$RUNTIME/payload"
    copy_tree "$CACHE/var/root/VirtualMac/install" "$RUNTIME/install"
    copy_tree "$CACHE/var/jb/Applications/VirtualMac.app" "$APP"
    copy_tree "$CACHE/var/jb/usr/lib" "$STAGE/usr/lib"
    copy_tree "$CACHE/var/jb/usr/libexec" "$STAGE/usr/libexec"
    copy_tree "$CACHE/var/jb/usr/sbin" "$STAGE/usr/sbin"
    for plist in com.apple.NetworkSharing.plist com.apple.bootpd.plist; do
        cp "$CACHE/var/jb/Library/LaunchDaemons/$plist" "$STAGE/Library/LaunchDaemons/"
    done
    mkdir -p "$STAGE/usr/lib/TweakInject"
    copy_tree "$CACHE/var/root/VirtualMac/bootstrap-common/usr/lib/TweakInject" \
        "$STAGE/usr/lib/TweakInject"
    SOURCE_TAG="deb:$actual"
else
    if [[ "${VZ_SKIP_REBUILD:-0}" != 1 ]]; then
        "$SCRIPT_DIR/build-ipad-vm.sh"
        "$SCRIPT_DIR/build-ipad-network-helpers.sh"
        "$SCRIPT_DIR/build-ipad-network-sharing.sh"
        "$SCRIPT_DIR/build-ipad-installation.sh"
        "$SCRIPT_DIR/build-ipad-app.sh"
        "$SCRIPT_DIR/build-springboard-tweak.sh"
    fi
    "$SCRIPT_DIR/audit-ipados-compatibility.sh"
    # Payload overlay order matters: the installation payload is staged first,
    # then the VM payload overlays it so the shared framework tree is the
    # authoritative VM-runtime copy (mirrors build-ipad-deb.sh).
    copy_tree "$VZ_BUILD_ROOT/ipad-installation/payload" "$RUNTIME/payload"
    copy_tree "$VZ_BUILD_ROOT/ipad-vm/payload" "$RUNTIME/payload"
    copy_tree "$VZ_BUILD_ROOT/ipad-installation/install" "$RUNTIME/install"
    copy_tree "$VZ_BUILD_ROOT/ipad-app/VirtualMac.app" "$APP"
    install -m 755 "$VZ_BUILD_ROOT/ipad-app/virtualmac-diagnostics" \
        "$STAGE/usr/bin/virtualmac-diagnostics"
    # Component products retain dev-only probes that the standard deb strips;
    # remove them so the roothide package matches the released layout.
    rm -rf "$RUNTIME/payload/bin"
    rm -f "$RUNTIME/payload/trustcache.txt" \
        "$RUNTIME/install/restore-image-probe" \
        "$RUNTIME/install/usb-bridge-probe"
    install -m 755 "$VZ_BUILD_ROOT/ipad-network-sharing/InternetSharing" \
        "$STAGE/usr/libexec/InternetSharing"
    install -m 755 "$VZ_BUILD_ROOT/ipad-network-sharing/InternetSharing.ipados15" \
        "$STAGE/usr/libexec/InternetSharing.ipados15"
    install -m 755 "$VZ_BUILD_ROOT/ipad-network-sharing/InternetSharing.ipados16" \
        "$STAGE/usr/libexec/InternetSharing.ipados16"
    install -m 755 "$VZ_BUILD_ROOT/ipad-network-sharing/libmrc.dylib" \
        "$STAGE/usr/lib/libmrc.dylib"
    install -m 755 "$VZ_BUILD_ROOT/ipad-network-sharing/libmrc.ipados15-auth.dylib" \
        "$STAGE/usr/lib/libmrc.ipados15-auth.dylib"
    install -m 755 "$VZ_BUILD_ROOT/ipad-network-sharing/AuthorizationCompat.dylib" \
        "$STAGE/usr/lib/AuthorizationCompat.dylib"
    install -m 755 "$VZ_BUILD_ROOT/ipad-network-sharing/NetworkMemoryPolicy.dylib" \
        "$STAGE/usr/lib/NetworkMemoryPolicy.dylib"
    install -m 755 "$VZ_BUILD_ROOT/ipad-network-helpers/bootpd" \
        "$STAGE/usr/libexec/bootpd"
    install -m 755 "$VZ_BUILD_ROOT/ipad-network-helpers/rtadvd" \
        "$STAGE/usr/sbin/rtadvd"
    install -m 755 "$VZ_BUILD_ROOT/ipad-network-helpers/OpenDirectoryCompat.dylib" \
        "$STAGE/usr/lib/OpenDirectoryCompat.dylib"
    install -m 755 "$VZ_BUILD_ROOT/ipad-network-helpers/IOKit14Compat.dylib" \
        "$STAGE/usr/lib/IOKit14Compat.dylib"
    install -m 644 "$VZ_BUILD_ROOT/ipad-network-sharing/com.apple.NetworkSharing.plist" \
        "$STAGE/Library/LaunchDaemons/com.apple.NetworkSharing.plist"
    install -m 644 "$VZ_BUILD_ROOT/ipad-network-helpers/com.apple.bootpd.plist" \
        "$STAGE/Library/LaunchDaemons/com.apple.bootpd.plist"
    mkdir -p "$STAGE/usr/lib/TweakInject"
    install -m 755 "$VZ_BUILD_ROOT/ipad-tweak/VZKeyboardPassthrough.dylib" \
        "$STAGE/usr/lib/TweakInject/VZKeyboardPassthrough.dylib"
    install -m 644 "$VZ_BUILD_ROOT/ipad-tweak/VZKeyboardPassthrough.plist" \
        "$STAGE/usr/lib/TweakInject/VZKeyboardPassthrough.plist"
    find "$STAGE" -type f \( -name .DS_Store -o -name '._*' \) -delete
    if command -v xattr >/dev/null 2>&1; then
        xattr -cr "$STAGE"
    fi
    SOURCE_TAG="component-build"
fi

# Select the iPadOS 16 variant as the default runtime/installation/network
# binary; the on-device selector promotes the matching variant on boot. This
# runs after both input branches have populated the stage.
vmm="$RUNTIME/payload/VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
cp "$vmm.ipados16" "$vmm"
installer="$RUNTIME/payload/Installation.xpc/Contents/MacOS/com.apple.Virtualization.Installation"
cp "$installer.ipados16" "$installer"
cp "$STAGE/usr/libexec/InternetSharing.ipados16" "$STAGE/usr/libexec/InternetSharing"

compile=(clang -miphoneos-version-min=15.0
    -isysroot "$SDK" -DVZ_ROOTHIDE -I"$ROOTHIDE_SDK"
    -L"$ROOTHIDE_SDK/roothide" -lroothide)
if [[ "$DEVELOPMENT" == 1 ]]; then
    compile+=(-DVZ_DEVELOPMENT)
fi
host="$VZ_REPO_ROOT/vz/host"
install_source="$VZ_REPO_ROOT/vz/install"
"${compile[@]}" -arch arm64 -fblocks \
    -framework AVFAudio -framework CoreImage -framework Foundation \
    -framework GameController -framework Metal -framework Security -framework UIKit \
    -framework UniformTypeIdentifiers -Wl,-export_dynamic -Wl,-undefined,dynamic_lookup \
    "$host/NSViewShim.m" "$host/VZAppSettings.m" "$host/VZDiagnostics.m" \
    "$host/VZFailureDetailsViewController.m" "$host/VZRestoreCatalog.m" \
    "$host/VZSupport.m" "$host/VZGuestTools.m" "$host/VZGuestRuntimePolicy.m" \
    "$host/VZNewVMViewController.m" "$host/VZProgressViewController.m" \
    "$host/VZSettingsViewController.m" "$host/VZTrackpadScrollBridge.m" \
    "$host/VZVMLibraryViewController.m" "$host/VirtualMacApp.m" -o "$APP/VirtualMac"
link_dylib "${compile[@]}" -arch arm64e -dynamiclib -fblocks $DYLIB_UNDEFINED \
    -install_name '@rpath/VZHostCompat.dylib' "$host/vzxpchook.m" -o "$APP/VZHostCompat.dylib"
cp "$APP/VZHostCompat.dylib" "$RUNTIME/install/VZHostCompat.dylib"
"${compile[@]}" -arch arm64 -fblocks -framework Foundation -framework UIKit \
    "$host/VZAppSettings.m" "$host/VZDiagnostics.m" "$host/virtualmac_diagnostics_main.m" \
    -o "$STAGE/usr/bin/virtualmac-diagnostics"
"${compile[@]}" -arch arm64 "$install_source/install_launcher.c" \
    -o "$RUNTIME/install/install-launcher"
"${compile[@]}" -arch arm64 -Wall -Wextra -Werror \
    "$install_source/roothide_runtime_processes.c" -o "$RUNTIME/install/runtime-processes"
"${compile[@]}" -arch arm64 -Wall -Wextra -Werror "$install_source/roothide_legacy_storage.c" \
    -o "$RUNTIME/install/legacy-storage"
"${compile[@]}" -arch arm64 -fblocks -framework Foundation -framework Metal \
    -framework UIKit -Wl,-export_dynamic "$host/NSViewShim.m" \
    "$install_source/install_macos.m" -o "$RUNTIME/install/install-macos"
cp "$install_source/start-install.sh" "$RUNTIME/install/start-install.sh"
sed_in_place "$RUNTIME/install/start-install.sh" \
    -e 's|^VZ_INSTALL_ROOTHIDE=0$|VZ_INSTALL_ROOTHIDE=1|'
"${compile[@]}" -arch arm64e -dynamiclib -framework Foundation \
    -Wl,-reexport_framework,Metal -install_name '@rpath/MetalCompat.dylib' \
    "$host/native_bc_texture_support.m" "$host/metalshim.m" \
    -o "$RUNTIME/payload/Frameworks/MetalCompat.dylib"
link_dylib "${compile[@]}" -arch arm64e -dynamiclib -fblocks $DYLIB_UNDEFINED \
    -framework AVFAudio -framework CoreFoundation -framework CoreServices \
    -framework Foundation -framework IOKit -framework Metal \
    -Wl,-reexport_framework,CoreServices -install_name '@rpath/LaunchServicesCompat.dylib' \
    "$host/lsshim.m" "$host/vmmhook.m" "$host/pvg_trace.m" \
    -o "$RUNTIME/payload/Frameworks/LaunchServicesCompat.dylib"
link_dylib "${compile[@]}" -arch arm64e -dynamiclib -fblocks $DYLIB_UNDEFINED \
    -framework CoreFoundation -framework IOKit \
    -Wl,-reexport_library,"$host/DiskArbitration-iOS.tbd" \
    -install_name '@rpath/InstallationCompat.dylib' \
    "$host/installationhook.m" "$host/installation_usb_shim.m" \
    -o "$RUNTIME/payload/Installation.xpc/Contents/Frameworks/InstallationCompat.dylib"
cp "$RUNTIME/payload/Installation.xpc/Contents/Frameworks/InstallationCompat.dylib" \
    "$RUNTIME/payload/Installation.xpc/Contents/Frameworks/InstallationCompat.dylib.ipados16"
link_dylib "${compile[@]}" -arch arm64e -dynamiclib -fblocks $DYLIB_UNDEFINED \
    -framework CoreFoundation -framework IOKit -install_name '@rpath/InstallationCompat.dylib' \
    "$host/installationhook.m" "$host/installation_usb_shim.m" \
    "$host/diskarbitration15_compat.c" \
    -o "$RUNTIME/payload/Installation.xpc/Contents/Frameworks/InstallationCompat.dylib.ipados15"
link_dylib "${compile[@]}" -arch arm64e -dynamiclib -fblocks -framework Foundation \
    $DYLIB_UNDEFINED \
    -install_name '@loader_path/.jbroot/usr/lib/TweakInject/VZKeyboardPassthrough.dylib' \
    "$VZ_REPO_ROOT/vz/tweak/VZKeyboardPassthrough.m" \
    -o "$STAGE/usr/lib/TweakInject/VZKeyboardPassthrough.dylib"
"${compile[@]}" -arch arm64 -arch arm64e -dynamiclib -fblocks -Wall -Wextra -Werror \
    -lutil \
    -install_name '@loader_path/.jbroot/usr/lib/VirtualMacPaths.dylib' \
    "$host/roothide_paths.c" -o "$STAGE/usr/lib/VirtualMacPaths.dylib"
for helper in \
    "$STAGE/usr/libexec/InternetSharing" "$STAGE/usr/libexec/bootpd" \
    "$STAGE/usr/libexec/InternetSharing.ipados15" "$STAGE/usr/libexec/InternetSharing.ipados16" \
    "$STAGE/usr/sbin/rtadvd" \
    "$RUNTIME/payload/Installation.xpc/Contents/MacOS/com.apple.Virtualization.Installation" \
    "$RUNTIME/payload/Installation.xpc/Contents/MacOS/com.apple.Virtualization.Installation.ipados15" \
    "$RUNTIME/payload/Installation.xpc/Contents/MacOS/com.apple.Virtualization.Installation.ipados15-auth" \
    "$RUNTIME/payload/Installation.xpc/Contents/MacOS/com.apple.Virtualization.Installation.ipados16" \
    "$RUNTIME/payload/Installation.xpc/Contents/Frameworks/MobileDevice.framework/Versions/A/Resources/usbmuxd" \
    "$RUNTIME/payload/Installation.xpc/Contents/Frameworks/MobileDevice.framework/Versions/A/MobileDevice" \
    "$RUNTIME/payload/Installation.xpc/Contents/Frameworks/MobileDevice.framework/Versions/A/MobileDevice.ipados15" \
    "$RUNTIME/payload/Installation.xpc/Contents/Frameworks/MobileDevice.framework/Versions/A/MobileDevice.ipados15-auth" \
    "$RUNTIME/payload/Installation.xpc/Contents/Frameworks/MobileDevice.framework/Versions/A/MobileDevice.ipados16"; do
    inject_macho_dylib "$helper" \
        '@loader_path/.jbroot/usr/lib/VirtualMacPaths.dylib'
done

# These are bootstrap paths; RootHide launchctl resolves the current jbroot.
# Launch daemons name the package's own binaries, so /var/jb drops away and the
# per-VM sockets and leases live under the state directory.
for plist in "$STAGE/Library/LaunchDaemons"/*.plist; do
    [[ -f "$plist" ]] || continue
    sed_in_place "$plist" \
        -e 's|>/var/jb/|>/|g' \
        -e 's|>/tmp/|>/var/mobile/Library/VirtualMac/Network/|g'
done
# launchd treats a job labelled with Apple's own name as a platform binary and
# refuses the ad-hoc helper with OS_REASON_CODESIGNING, so the job is renamed
# while the Mach service it registers keeps the name its clients look up.
sed_in_place "$STAGE/Library/LaunchDaemons/com.apple.NetworkSharing.plist" \
    -e 's|<string>com.apple.NetworkSharing</string>|<string>vzi.apple.NetworkSharing</string>|'

# RootHide needs storage access on every executable, including the extracted
# VMM, Installation, usbmuxd and network helpers; retain their other keys.
storage_entitlements() { # SRC(or empty) DST
    local source=$1 destination=$2
    if [[ -s "$source" ]] && grep -q '^</dict>' "$source"; then
        # Only the root dictionary's closing line starts in column zero;
        # nested dictionaries are indented, so they keep their keys.
        sed -e 's|^</dict>[[:space:]]*$|\t<key>com.apple.private.security.storage.AppBundles</key>\n\t<true/>\n\t<key>com.apple.private.security.storage.AppDataContainers</key>\n\t<true/>\n</dict>|' \
            "$source" > "$destination"
    else
        cat > "$destination" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.private.security.storage.AppBundles</key>
	<true/>
	<key>com.apple.private.security.storage.AppDataContainers</key>
	<true/>
</dict>
</plist>
PLIST
    fi
}

entitlements="$OUT/host.entitlements.plist"
storage_entitlements "$VZ_REPO_ROOT/vz/host/VirtualMac.entitlements" "$entitlements"
grep -q 'com.apple.security.virtualization' "$entitlements" ||
    die "host entitlements lost their virtualization keys"
for relative in 'Applications/VirtualMac.app/VirtualMac' \
    'Applications/VirtualMac.app/VZHostCompat.dylib' \
    'usr/bin/virtualmac-diagnostics' \
    'usr/libexec/VirtualMac/install/install-launcher' \
    'usr/libexec/VirtualMac/install/runtime-processes' \
    'usr/libexec/VirtualMac/install/legacy-storage' \
    'usr/libexec/VirtualMac/install/install-macos' \
    'usr/libexec/VirtualMac/install/VZHostCompat.dylib'; do
    ldid -S"$entitlements" "$STAGE/$relative"
done
for relative in 'usr/libexec/VirtualMac/payload/Frameworks/MetalCompat.dylib' \
    'usr/libexec/VirtualMac/payload/Frameworks/LaunchServicesCompat.dylib' \
    'usr/libexec/VirtualMac/payload/Installation.xpc/Contents/Frameworks/InstallationCompat.dylib' \
    'usr/libexec/VirtualMac/payload/Installation.xpc/Contents/Frameworks/InstallationCompat.dylib.ipados15' \
    'usr/libexec/VirtualMac/payload/Installation.xpc/Contents/Frameworks/InstallationCompat.dylib.ipados16' \
    'usr/libexec/VirtualMac/payload/Installation.xpc/Contents/Frameworks/MobileDevice.framework/Versions/A/MobileDevice' \
    'usr/libexec/VirtualMac/payload/Installation.xpc/Contents/Frameworks/MobileDevice.framework/Versions/A/MobileDevice.ipados15' \
    'usr/libexec/VirtualMac/payload/Installation.xpc/Contents/Frameworks/MobileDevice.framework/Versions/A/MobileDevice.ipados15-auth' \
    'usr/libexec/VirtualMac/payload/Installation.xpc/Contents/Frameworks/MobileDevice.framework/Versions/A/MobileDevice.ipados16' \
    'usr/lib/TweakInject/VZKeyboardPassthrough.dylib' \
    'usr/lib/VirtualMacPaths.dylib'; do
    ldid -S "$STAGE/$relative"
done

# Every remaining executable keeps the entitlements it shipped with plus the
# storage keys RootHide needs. od reads the Mach-O header, ldid -e its
# entitlements, and ldid -S signs it again.
while IFS= read -r -d '' file; do
    magic=$(macho_u32 "$file" 0)
    [[ "$magic" == 4277009103 ]] || continue
    [[ "$(macho_u32 "$file" 12)" == 2 ]] || continue
    current="$OUT/current.entitlements.plist"
    ldid -e "$file" > "$current" 2>/dev/null || : > "$current"
    storage_entitlements "$current" "$current.merged"
    ldid -S"$current.merged" "$file"
    chmod 755 "$file"
done < <(find "$STAGE" -type f)

info="$STAGE/Applications/VirtualMac.app/Info.plist"
short_version='1.2.3-roothide'
[[ "$DEVELOPMENT" == 1 ]] && short_version="$short_version-dev"
sed_in_place "$info" \
    -e "/<key>CFBundleShortVersionString<\/key>/{n;s|<string>[^<]*</string>|<string>$short_version</string>|;}"
# Setuid belongs on the target after postinst verifies the root owner. The
# build machine only needs a regular executable in the package stage.
chmod 755 "$RUNTIME/install/install-launcher"
for control in control preinst postinst prerm; do
    cp "$VZ_REPO_ROOT/packaging/roothide/$control" "$STAGE/DEBIAN/$control"
done
# preinst and prerm carry stop-runtime.sh inline: a package script can only
# run what the package installs. Each line that sources an external copy is
# replaced by the script itself.
stop_runtime="$VZ_REPO_ROOT/packaging/roothide/stop-runtime.sh"
for name in preinst prerm; do
    script="$STAGE/DEBIAN/$name"
    {
        while IFS= read -r line || [[ -n "$line" ]]; do
            case "$line" in
                '. '*) cat "$stop_runtime" ;;
                *) printf '%s\n' "$line" ;;
            esac
        done < "$script"
    } > "$script.spliced"
    mv -f "$script.spliced" "$script"
done
# git is not installed on the device; the commit is read from the repository's
# own refs instead.
source_commit=""
# The repository root is one level above the VirtualMac checkout when this
# workspace was imported, and the checkout itself otherwise.
for git_root in "$VZ_REPO_ROOT/.." "$VZ_REPO_ROOT"; do
    if [[ -r "$git_root/.git/HEAD" ]]; then
        head_value="$(cat "$git_root/.git/HEAD")"
        case "$head_value" in
            'ref: '*) source_commit="$(cat "$git_root/.git/${head_value#ref: }" 2>/dev/null || true)" ;;
            *) source_commit="$head_value" ;;
        esac
        [[ -n "$source_commit" ]] && break
    fi
done
source_commit="${source_commit:-unknown}"
base_version=$(sed -n 's/^Version: //p' "$STAGE/DEBIAN/control")
if [[ -n "${VZ_PACKAGE_VERSION:-}" ]]; then
    version="$VZ_PACKAGE_VERSION"
elif [[ "$source_commit" != unknown ]]; then
    version="$base_version.device.${source_commit:0:10}"
else
    version="$base_version.device"
fi
sed_in_place "$STAGE/DEBIAN/control" -e "s|^Version:.*|Version: $version|"
printf 'Installed-Size: %s\n' "$(du -sk "$STAGE" | cut -f1)" >> "$STAGE/DEBIAN/control"
printf 'source=%s\nsource-commit=%s\ndevelopment=%s\n' "$SOURCE_TAG" "$source_commit" "$DEVELOPMENT" > "$RUNTIME/build-source.txt"
# Replace the base deb's checked-in localization files with the ones
# from the source tree so new and updated UI strings ship in the package.
localizations="$VZ_REPO_ROOT/resources/Localizations"
if [[ -d "$localizations" ]]; then
    copy_tree "$localizations" "$APP/../Localizations-staging"
    for locale_dir in "$APP/../Localizations-staging"/*.lproj; do
        [[ -d "$locale_dir" ]] || continue
        name=$(basename "$locale_dir")
        copy_item "$locale_dir/Localizable.strings" "$APP/$name/Localizable.strings"
        copy_item "$locale_dir/InfoPlist.strings" "$APP/$name/InfoPlist.strings"
    done
    rm -rf "$APP/../Localizations-staging"
fi
chmod 755 "$STAGE/DEBIAN/preinst" "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm"

# The Python audits are replaced by the same checks in shell: the package must
# carry its setuid helpers, a RootHide-stamped installer, and a signed host
# binary that kept its virtualization entitlements.
require_stage() { # CONDITION DESCRIPTION
    [[ "$1" ]] || die "RootHide package audit: $2"
}
require_stage "$([[ -x "$RUNTIME/install/runtime-processes" ]] && echo yes)" \
    "native process owner check is missing"
require_stage "$([[ -x "$RUNTIME/install/legacy-storage" ]] && echo yes)" \
    "reversible legacy migration utility is missing"
require_stage "$(grep -q 'VZ_INSTALL_ROOTHIDE=1' "$RUNTIME/install/start-install.sh" && echo yes)" \
    "installer was not stamped for RootHide"
require_stage "$(! grep -q 'VZ_INSTALL_ROOTHIDE=0' "$RUNTIME/install/start-install.sh" && echo yes)" \
    "installer still has standard mode"
for script in "$RUNTIME/install/start-install.sh" "$STAGE/DEBIAN/preinst" \
    "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm"; do
    sh -n "$script" || die "RootHide package audit: $script does not parse"
done
grep -q '^Architecture: iphoneos-arm64e' "$STAGE/DEBIAN/control" ||
    die "RootHide package audit: package architecture must be iphoneos-arm64e"
grep -q '^Package: com.mac.virtual' "$STAGE/DEBIAN/control" ||
    die "RootHide package audit: unexpected package identity"
ldid -e "$APP/VirtualMac" > "$OUT/audit-entitlements.plist"
for key in platform-application com.apple.private.security.no-sandbox \
    com.apple.private.security.storage.AppBundles \
    com.apple.private.security.storage.AppDataContainers; do
    grep -q "<key>$key</key>" "$OUT/audit-entitlements.plist" ||
        die "RootHide package audit: host binary is missing $key"
done
grep -aq '@loader_path/.jbroot/usr/lib/VirtualMacPaths.dylib' \
    "$RUNTIME/payload/Installation.xpc/Contents/Frameworks/MobileDevice.framework/Versions/A/MobileDevice" ||
    die "RootHide package audit: helpers were not linked against VirtualMacPaths"

dpkg-deb --root-owner-group --build "$STAGE" "$OUT/VirtualMac_roothide.deb"
echo "roothide package: $OUT/VirtualMac_roothide.deb"
