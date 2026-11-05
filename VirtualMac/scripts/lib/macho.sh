#!/bin/bash
# Add one LC_LOAD_DYLIB to a thin 64-bit Mach-O from the bootstrap's own
# tools (od, dd, printf), for hosts that have no python3. The counterpart of
# vz/patches/add_macho_dylib.py, with the same structural checks: the command
# must fit between the load commands and the first file-backed section.
#
# inject_macho_dylib MACHO INSTALL_NAME

macho_fail() {
    echo "macho: $*" >&2
    return 1
}

# macho_u32 FILE OFFSET, macho_u64 FILE OFFSET: little-endian fields.
macho_u32() {
    od -An --endian=little -tu4 -j "$2" -N 4 "$1" | tr -d ' \n'
}

macho_u64() {
    od -An --endian=little -tu8 -j "$2" -N 8 "$1" | tr -d ' \n'
}

# macho_le32 VALUE: four little-endian bytes as hex.
macho_le32() {
    local value=$1
    printf '%02x%02x%02x%02x' \
        $((value & 255)) $(((value >> 8) & 255)) \
        $(((value >> 16) & 255)) $(((value >> 24) & 255))
}

# macho_bytes HEX: the bytes of a hex string on stdout.
macho_bytes() {
    local hex=$1 format=
    while [ -n "$hex" ]; do
        format="$format\\x${hex:0:2}"
        hex=${hex:2}
    done
    printf '%b' "$format"
}

# macho_patch FILE OFFSET HEX: overwrite bytes without changing the length.
macho_patch() {
    macho_bytes "$3" | dd of="$1" bs=1 seek="$2" conv=notrunc 2>/dev/null
}

inject_macho_dylib() {
    local file=$1 install_name=$2
    [ -f "$file" ] || { macho_fail "missing $file"; return 1; }

    local magic ncmds sizeofcmds
    magic=$(macho_u32 "$file" 0)
    # MH_MAGIC_64 = 0xfeedfacf. MobileDevice is a dylib, so the file type is
    # not restricted here; only the signing pass looks for executables.
    [ "$magic" = 4277009103 ] || { macho_fail "$file: not a thin 64-bit Mach-O"; return 1; }

    if grep -aqF -- "$install_name" "$file"; then
        echo "already loads $install_name: $file"
        return 0
    fi

    ncmds=$(macho_u32 "$file" 16)
    sizeofcmds=$(macho_u32 "$file" 20)
    local end=$((32 + sizeofcmds))
    local first_section
    first_section=$(wc -c < "$file")
    first_section=${first_section//[!0-9]/}

    local index=0 cursor=32 command cmdsize sections section at offset size
    while [ "$index" -lt "$ncmds" ]; do
        [ $((cursor + 8)) -le "$end" ] || { macho_fail "$file: truncated load commands"; return 1; }
        command=$(macho_u32 "$file" "$cursor")
        cmdsize=$(macho_u32 "$file" $((cursor + 4)))
        if [ "$cmdsize" -lt 8 ] || [ $((cursor + cmdsize)) -gt "$end" ]; then
            macho_fail "$file: invalid load command at $cursor"
            return 1
        fi
        if [ "$command" = 25 ]; then # LC_SEGMENT_64
            sections=$(macho_u32 "$file" $((cursor + 64)))
            if [ $((cursor + 72 + sections * 80)) -gt $((cursor + cmdsize)) ]; then
                macho_fail "$file: invalid LC_SEGMENT_64 sections"
                return 1
            fi
            section=0
            while [ "$section" -lt "$sections" ]; do
                at=$((cursor + 72 + section * 80))
                offset=$(macho_u32 "$file" $((at + 48)))
                size=$(macho_u64 "$file" $((at + 40)))
                if [ "$offset" -ne 0 ] && [ "$size" -ne 0 ] && [ "$offset" -lt "$first_section" ]; then
                    first_section=$offset
                fi
                section=$((section + 1))
            done
        fi
        cursor=$((cursor + cmdsize))
        index=$((index + 1))
    done
    [ "$cursor" -eq "$end" ] || { macho_fail "$file: load-command size mismatch"; return 1; }

    local name_bytes=$(( ${#install_name} + 1 ))
    local command_size=$(( (24 + name_bytes + 7) / 8 * 8 ))
    [ $((cursor + command_size)) -le "$first_section" ] ||
        { macho_fail "$file: need $command_size bytes of header slack"; return 1; }

    local slack
    slack=$(od -An -v -tx1 -j "$cursor" -N "$command_size" "$file" | tr -d ' \n')
    case $slack in
        *[!0]*) macho_fail "$file: header slack is not zero-filled"; return 1 ;;
    esac

    local name_hex= name_index=0
    while [ "$name_index" -lt "${#install_name}" ]; do
        name_hex="$name_hex$(printf '%02x' "'${install_name:$name_index:1}")"
        name_index=$((name_index + 1))
    done
    local payload
    payload="$(macho_le32 12)$(macho_le32 "$command_size")$(macho_le32 24)$(macho_le32 2)$(macho_le32 65536)$(macho_le32 65536)${name_hex}00"
    local written=$(( ${#payload} / 2 ))
    while [ "$written" -lt "$command_size" ]; do
        payload="${payload}00"
        written=$((written + 1))
    done

    macho_patch "$file" "$cursor" "$payload" || { macho_fail "$file: cannot write"; return 1; }
    macho_patch "$file" 16 "$(macho_le32 $((ncmds + 1)))"
    macho_patch "$file" 20 "$(macho_le32 $((sizeofcmds + command_size)))"
    echo "patched $file: LC_LOAD_DYLIB $install_name ($command_size bytes at $cursor)"
}
