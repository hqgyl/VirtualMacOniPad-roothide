#!/bin/bash
# Apelin builds this workspace with VirtualMac/scripts/build-roothide-deb.sh,
# ported to run on the iPad itself against the on-device toolchain (see
# AGENTS.md). The package is a RootHide snapshot build from the released 1.2.3
# deb: component payloads come from that deb, and the RootHide host binaries,
# path library and installer are compiled here.
set -eu

: "${APELIN_PACKAGE_DIR:?run this through apelin_project_build}"
: "${APELIN_PROJECT_ROOT:?}"
: "${APELIN_BOOTSTRAP:?}"
: "${APELIN_ARCHITECTURE:?}"
: "${TMPDIR:?}"

[ "$APELIN_BOOTSTRAP" = roothide ] ||
    { echo "error: this workspace only builds for roothide, not $APELIN_BOOTSTRAP" >&2; exit 1; }

source_tree="$APELIN_PROJECT_ROOT/VirtualMac"
build_root="$source_tree/build"
base_deb="$build_root/downloads/VirtualMac_1.2.3.deb"
base_url=https://github.com/nfzerox/VirtualMacOniPad/releases/download/1.2.3/VirtualMac_1.2.3.deb
base_sha256=435ce1dc76b9e18b1547c77b84e2cf33ffe40a16be63e366f181d14709a41aa0

mkdir -p "$build_root/downloads"

if [ ! -f "$base_deb" ] || [ "$(sha256sum "$base_deb" | cut -d' ' -f1)" != "$base_sha256" ]; then
    echo "fetching the 1.2.3 base package with icli probe"
    command -v icli >/dev/null 2>&1 ||
        { echo "error: icli is missing and $base_deb is not downloaded yet" >&2; exit 1; }
    : > "$base_deb.empty"
    icli probe -e "var NSData=ObjC.use('NSData'),NSURL=ObjC.use('NSURL'),NSFH=ObjC.use('NSFileHandle'); var d=NSData.dataWithContentsOfURL(NSURL.URLWithString('$base_url')); if(!d){throw new Error('download failed')}; var fh=NSFH.fileHandleForWritingAtPath('$base_deb.empty'); fh.writeData_(d); fh.closeFile(); d.length()" >/dev/null
    if [ "$(sha256sum "$base_deb.empty" | cut -d' ' -f1)" != "$base_sha256" ]; then
        rm -f "$base_deb.empty"
        echo "error: the downloaded base package does not match $base_sha256" >&2
        exit 1
    fi
    mv -f "$base_deb.empty" "$base_deb"
fi

# The RootHide devkit is only a header and a stub for the dylib the bootstrap
# already ships; the upstream prepare-roothide-sdk.sh would download it.
devkit="$build_root/toolchain/roothide-sdk/devkit"
mkdir -p "$devkit/roothide"
if [ ! -f "$devkit/roothide.h" ]; then
    cat > "$devkit/roothide.h" <<'HEADER'
#ifndef VZ_ROOTHIDE_DEVKIT_H
#define VZ_ROOTHIDE_DEVKIT_H

#ifdef __cplusplus
extern "C" {
#endif

const char *jbroot(const char *path);
const char *rootfs(const char *path);
unsigned long long jbrand(void);

#ifdef __cplusplus
}
#endif

#endif
HEADER
fi
if [ ! -f "$devkit/roothide/libroothide.tbd" ]; then
    cat > "$devkit/roothide/libroothide.tbd" <<'TBD'
--- !tapi-tbd
tbd-version: 4
targets: [ arm64-ios, arm64e-ios ]
install-name: '@loader_path/.jbroot/usr/lib/libroothide.dylib'
current-version: 1.0
compatibility-version: 1.0
exports:
  - targets: [ arm64-ios, arm64e-ios ]
    symbols: [ _jbroot, _rootfs, _jbrand ]
...
TBD
fi

export VZ_BASE_DEB="$base_deb"
export VZ_ROOTHIDE_SDK="$devkit"
export VZ_BUILD_ROOT="$build_root"
export VZ_IGNORE_ENV_FILE=1

cd "$source_tree"
bash ./scripts/build-roothide-deb.sh "$@"

package="$build_root/roothide/VirtualMac_roothide.deb"
[ -f "$package" ] || { echo "error: the build wrote no package" >&2; exit 1; }
cp -f "$package" "$APELIN_PACKAGE_DIR/VirtualMac_roothide.deb"
echo "package ready: $APELIN_PACKAGE_DIR/VirtualMac_roothide.deb"
