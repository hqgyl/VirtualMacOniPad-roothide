#!/bin/sh
set -eu
export PATH=/usr/bin:/usr/sbin:/bin:/sbin:/rootfs/bin:/rootfs/usr/bin

native_root=$(jbroot /)
native_root=${native_root%/}
process_helper=/usr/libexec/VirtualMac/install/runtime-processes
processes() {
    # runtime-processes is the only process matcher the package can rely on:
    # the RootHide bootstrap ships neither ps nor awk, and an upgrade from a
    # build predating the helper has nothing left to match with.
    if test -x "$process_helper"; then
        "$process_helper" --list
    fi
}

if test "${1:-}" = --list; then
    processes
    exit 0
fi
for domain in system user/501; do
    for service in com.apple.NetworkSharing vzi.apple.bootpd; do
        plist=com.apple.NetworkSharing.plist
        test "$service" != vzi.apple.bootpd || plist=com.apple.bootpd.plist
        job=$(launchctl print "$domain/$service" 2>/dev/null || true)
        job_path=$(printf '%s\n' "$job" | sed -n 's/^[[:space:]]*path = //p')
        case "$job_path" in
            "$native_root/Library/LaunchDaemons/$plist"|\
            "/private$native_root/Library/LaunchDaemons/$plist")
                launchctl bootout "$domain/$service" 2>/dev/null || true
                ;;
        esac
    done
done
if test -x "$process_helper"; then
    "$process_helper" --stop
else
    active=$(processes)
    for process in $active; do kill "$process" 2>/dev/null || true; done
    attempt=0
    while :; do
        pending=
        for process in $active; do
            kill -0 "$process" 2>/dev/null && pending=1
        done
        test -n "$pending" || break
        attempt=$((attempt + 1))
        if test "$attempt" -ge 30; then
            echo "Virtual Mac is still stopping; retry the package operation." >&2
            exit 1
        fi
        sleep 0.1
    done
fi
