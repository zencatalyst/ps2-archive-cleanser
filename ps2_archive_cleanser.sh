#!/usr/bin/env bash

# ps2_archive_cleanser.sh (v1.0.0-2026-11-09 Copyright (c) 2026 zencatalyst) - Automates extracting, cleaning, recompressing, and multi-format timestamp alignment.

set -euo pipefail
avail_locales=$(locale -a 2>/dev/null || true)
if grep -qiE '^C\.utf-?8$' <<< "$avail_locales"; then
    export LC_ALL=C.UTF-8
else
    export LC_ALL=C
fi
unset avail_locales

# ==============================================================================
# Signal Trap & Background Process Cleanup
# ==============================================================================
active_pid=""
active_ext_dir=""
active_new_archive=""
EXTRACTED_ROOT_DIR=""
PROCESSED_ROOT_DIR=""
created_extracted_root=0
created_processed_root=0

cleanup_staging_roots() {
    if [[ "$created_processed_root" -eq 1 && -n "$PROCESSED_ROOT_DIR" && -d "$PROCESSED_ROOT_DIR" ]]; then
        rmdir "$PROCESSED_ROOT_DIR" 2>/dev/null || true
    fi
    if [[ "$created_extracted_root" -eq 1 && -n "$EXTRACTED_ROOT_DIR" && -d "$EXTRACTED_ROOT_DIR" ]]; then
        rmdir "$EXTRACTED_ROOT_DIR" 2>/dev/null || true
    fi
}

cleanup_on_exit() {
    local exit_code=$?
    if [[ -n "$active_pid" ]] && kill -0 "$active_pid" 2>/dev/null; then
        kill -TERM "$active_pid" 2>/dev/null || true
        wait "$active_pid" 2>/dev/null || true
    fi
    active_pid=""
    if [[ -n "$active_ext_dir" && -d "$active_ext_dir" ]]; then
        rm -rf "$active_ext_dir"
    fi
    active_ext_dir=""
    if [[ -n "$active_new_archive" ]]; then
        rm -f "$active_new_archive" "${active_new_archive}".tmp* 2>/dev/null || true
    fi
    active_new_archive=""
    cleanup_staging_roots
    exit "$exit_code"
}

cleanup_on_signal() {
    printf "\r\033[K\n"
    echo "-> Interrupt received! Terminating active background tasks..."
    if [[ -n "$active_pid" ]] && kill -0 "$active_pid" 2>/dev/null; then
        kill -TERM "$active_pid" 2>/dev/null || true
        wait "$active_pid" 2>/dev/null || true
    fi
    active_pid=""
    if [[ -n "$active_ext_dir" && -d "$active_ext_dir" ]]; then
        rm -rf "$active_ext_dir"
        echo "-> Removed incomplete staging directory: \"$active_ext_dir\""
    fi
    active_ext_dir=""
    if [[ -n "$active_new_archive" ]]; then
        rm -f "$active_new_archive" "${active_new_archive}".tmp* 2>/dev/null || true
    fi
    active_new_archive=""
    cleanup_staging_roots
    echo "Operation aborted."
    exit 130
}

fail_game() {
    local msg
    if [[ -n "$active_pid" ]]; then
        if kill -0 "$active_pid" 2>/dev/null; then
            kill -TERM "$active_pid" 2>/dev/null || true
            wait "$active_pid" 2>/dev/null || true
        fi
        active_pid=""
        printf "\r\033[K"
    fi
    for msg in "$@"; do
        echo "$msg"
    done
    if [[ -n "$active_ext_dir" && -d "$active_ext_dir" ]]; then
        rm -rf "$active_ext_dir"
    fi
    active_ext_dir=""
    if [[ -n "$active_new_archive" ]]; then
        rm -f "$active_new_archive" "${active_new_archive}".tmp* 2>/dev/null || true
    fi
    active_new_archive=""
    cleanup_staging_roots
    exit 1
}

abort_on_eof() {
    echo ""
    echo "Operation aborted (EOF)."
    exit 1
}

trap cleanup_on_exit EXIT
trap cleanup_on_signal INT TERM HUP

# ==============================================================================
# CLI Argument Handling & Timestamp Validation Helper
# ==============================================================================
# 2014-01-01T00:00:00Z (1388534400) ensures base archive timestamps are never older than any official PS2 game release
MIN_BASE_EPOCH=1388534400
VALIDATED_EPOCH=0
VALIDATED_TZ=""

# Helper function to validate an ISO 8601 timestamp string (YYYY-MM-DDTHH:mm:ss±hh:mm)
# Returns: 0 = valid, 1 = invalid syntax/calendar date, 2 = older than 2014-01-01T00:00:00Z
validate_iso_timestamp() {
    local input_ts="$1"
    local iso_regex='^([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2}:[0-9]{2}:[0-9]{2})([+-])([0-9]{2}:[0-9]{2})$'
    local iso_sign iso_offset posix_sign candidate_tz parsed_epoch roundtrip_iso

    if [[ ! "$input_ts" =~ $iso_regex ]]; then
        return 1
    fi

    iso_sign="${BASH_REMATCH[3]}"
    iso_offset="${BASH_REMATCH[4]}"
    posix_sign="+"
    if [[ "$iso_sign" == "+" ]]; then
        posix_sign="-"
    fi
    candidate_tz="UTC${posix_sign}${iso_offset}"

    if ! parsed_epoch=$(date -d "$input_ts" +%s 2>/dev/null); then
        return 1
    fi

    roundtrip_iso=$(TZ="$candidate_tz" date -d "@$parsed_epoch" +'%Y-%m-%dT%H:%M:%S%:z')
    if [[ "$roundtrip_iso" != "$input_ts" ]]; then
        return 1
    fi

    if [[ "$parsed_epoch" -lt "$MIN_BASE_EPOCH" ]]; then
        return 2
    fi

    VALIDATED_EPOCH="$parsed_epoch"
    VALIDATED_TZ="$candidate_tz"
    return 0
}

print_help() {
    echo ""
    echo "ps2_archive_cleanser.sh for GNU/Linux - Automates extracting, cleaning,"
    echo "recompressing, and multi-format timestamp alignment."
    echo ""
    echo "- This script recompresses game files (i.e. ISO, BIN, CUE) aggressively and"
    echo "  efficiently with LZMA2 algorithm and using 8 compression threads. The target"
    echo "  dictionary size is 256 MiB. Every resulting archive has 2 or 3 internal"
    echo "  blocks (depending on the existence of jxl and/or pdf files in the original"
    echo "  archive). These blocks are independent of each other and can be extracted"
    echo "  separately and quickly without needing to extract the whole archive first."
    echo ""
    echo "- The resulting archives have an internal structure that allows them to be"
    echo "  extracted rapidly since the extraction software (e.g. 7-zip, Peazip, etc.)"
    echo "  can use 8+ threads to decompress them efficiently. The extraction speedup"
    echo "  is 4.5-10X compared to single-threaded LZMA archives."
    echo ""
    echo "- Every input archive is validated to ensure a flat root directory structure,"
    echo "  matching base filenames (including multi-track \"Name (Track n).bin\" layouts),"
    echo "  valid CUE sheet FILE references, and exact sector alignment (2048-byte ISO"
    echo "  or 2352-byte raw BIN sectors). The script also inspects the disc filesystem"
    echo "  to verify a valid root SYSTEM.CNF, a \"BOOT2 = cdrom0:\" entry, and the"
    echo "  existence of the target boot executable inside the disc image."
    echo ""
    echo "- If a Redump PlayStation 2 \".dat\" XML file is present in the working"
    echo "  directory, the script automatically detects it and offers two-stage"
    echo "  verification: a fast pre-flight check (filename, size, and CRC32) before"
    echo "  extraction, followed by a full cryptographic check (filename, size, and"
    echo "  SHA-1) of the extracted disc images. A newly generated Verification.txt"
    echo "  manifest recording the BOOT2 executable, Redump verification status, and"
    echo "  CRC32, SHA-1, SHA-512, and SHA3-512 checksums is embedded into each archive."
    echo ""
    echo "- Internal disc files (.iso, .bin) are stamped in UTC to their original"
    echo "  ISO-9660 mastering timestamp (with .cue sheets staggered +1 second later)."
    echo "  Outer archives and internal auxiliary files (Verification.txt, .jxl, .pdf)"
    echo "  are regularized sequentially (+1 minute per archive, +1 second per file)"
    echo "  using either the first archive's timestamp or a user-specified ISO 8601"
    echo "  timestamp (YYYY-MM-DDTHH:mm:ss±hh:mm, minimum 2014-01-01T00:00:00Z), while"
    echo "  preserving the chosen timezone offset in Verification.txt."
    echo ""
    echo "Options:"
    echo "  -h, --help"
    echo "      Display this help message and exit."
    echo "  -v, --version"
    echo "      Display version and license information and exit."
    echo "  -y, --yes"
    echo "      Run in non-interactive mode. Automatically answers 'yes' to workflow"
    echo "      confirmation prompts (scanning, validation, creating PS2-Games/, and"
    echo "      launching) and applies safe defaults unless overridden by option flags."
    echo "      Requires '-t' / '--timestamp'. All option flags below (except"
    echo "      '--ramdisk-dir') require '-y'."
    echo "  -t, --timestamp <ISO8601|first>"
    echo "      Required with '-y'. Set the base archive timestamp to a custom ISO 8601"
    echo "      date/time (YYYY-MM-DDTHH:mm:ss±hh:mm, minimum 2014-01-01T00:00:00Z) or"
    echo "      'first' to keep the first archive's modification timestamp."
    echo "  --redump-verification, --no-redump-verification"
    echo "      Enable or disable Redump .dat verification in non-interactive mode"
    echo "      (default with -y: '--redump-verification'; aborts if no .dat is found)."
    echo "  --skip-existing, --overwrite-existing"
    echo "      Skip duplicate archives that already exist in PS2-Games/ and move them"
    echo "      to Skipped-PS2-Game-Archives/, or reprocess and overwrite them"
    echo "      (default with -y: '--skip-existing')."
    echo "  --integrity-test, --no-integrity-test"
    echo "      Enable or disable the '7z t' archive integrity test on newly created"
    echo "      archives in Step 9 (default with -y: '--integrity-test')."
    echo "  --display-hash <SHA-1|SHA-512|SHA3-512>"
    echo "      Select the hash algorithm displayed for extracted files in Step 3"
    echo "      (default with -y: 'SHA-1')."
    echo "  --ramdisk-dir <DIR>"
    echo "      Extract game archives into '<DIR>/temporary-extracted-archives' on a"
    echo "      ramdisk (tmpfs/ramfs) to reduce SSD/HDD wear and speed up processing."
    echo "      Can be used in both interactive and non-interactive ('-y') modes."
    echo "      Recommended for systems with at least 24 GB of RAM (18.5 GiB free) and"
    echo "      at least 9.00 GiB of free space in '<DIR>'."
    echo "  --force-with-risks"
    echo "      Proceed in non-interactive mode even if system RAM is below the"
    echo "      recommended threshold (< 16 GB, or < 24 GB with '--ramdisk-dir'), free"
    echo "      disk space is under 24.00 GiB, or free ramdisk space is under 9.00 GiB."
    echo ""
    echo "Warning: This script uses ~11.4 GiB (~12.2 GB) of RAM during the compression"
    echo "step (i.e. step 8), and using '--ramdisk-dir' requires up to an additional"
    echo "~8.5 GiB (~9.1 GB) of RAM to stage extracted DVD-9 disc files in memory."
    echo "Thus, running it may cause a system freeze when there is not enough free memory."
    echo "Modern operating systems use swap space to increase the available free memory."
    echo "In this case, the compression step may succeed but it slows down."
    echo ""
    echo "System requirements:"
    echo ""
    echo "- Minimum system specs (tolerable performance):"
    echo "  RAM: 16 GB + 4 GB swap"
    echo "  CPU: 4 cores (min. 8 threads)"
    echo "  Storage: 2.5\" HDD (min. 24 GiB free space)"
    echo ""
    echo "- Medium system specs (moderate performance):"
    echo "  RAM: 16 GB + 8 GB swap"
    echo "  CPU: 8 cores (min. 12 threads)"
    echo "  Storage: 3.5\" HDD (min. 24 GiB free space)"
    echo ""
    echo "- High-end system specs (high performance):"
    echo "  RAM: 24 GB + 8 GB swap"
    echo "  CPU: 12 cores (min. 16 threads)"
    echo "  Storage: 2.5\" SSD (min. 24 GiB free space)"
    echo ""
    echo "- Ultimate system specs (maximum performance):"
    echo "  RAM: 32 GB"
    echo "  CPU: 16 cores (min. 24 threads)"
    echo "  Storage: NVMe SSD (min. 24 GiB free space)"
    echo ""
    echo ""
    echo "Released under the GNU GPL, version 2 or later (at your option)."
    echo "Copyright (c) 2026 zencatalyst."
    echo ""
}

print_version() {
    echo ""
    echo "ps2_archive_cleanser.sh v1.0.0-2026-11-09"
    echo "Copyright (c) 2026, zencatalyst."
    echo ""
    echo "This program is free software; you can redistribute it and/or modify"
    echo "it under the terms of the GNU General Public License as published by"
    echo "the Free Software Foundation; either version 2 of the License, or"
    echo "(at your option) any later version."
    echo ""
    echo "This program is distributed in the hope that it will be useful,"
    echo "but WITHOUT ANY WARRANTY; without even the implied warranty of"
    echo "MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the"
    echo "GNU General Public License for more details."
    echo ""
    echo "You should have received a copy of the GNU General Public License"
    echo "along with this program. If not, see http://www.gnu.org/licenses/."
    echo ""
}

# Pre-scan for --help/-h or --version/-v
for arg in "$@"; do
    case "$arg" in
        --help|-h)
            print_help
            exit 0
            ;;
        --version|-v)
            print_version
            exit 0
            ;;
    esac
done

NON_INTERACTIVE=0
CLI_FORCE_WITH_RISKS=0
CLI_TIMESTAMP_MODE=""
CLI_TIMESTAMP_RAW=""
CLI_PARSED_EPOCH=0
CLI_CUSTOM_TZ=""
CLI_REDUMP_MODE=""
CLI_OVERWRITE_MODE=""
CLI_INTEGRITY_MODE=""
CLI_DISPLAY_HASH="SHA-1"
CLI_DISPLAY_HASH_SET=0
USE_RAMDISK=0
RAMDISK_DIR=""
used_option_flags=()

parse_display_hash_arg() {
    local val="$1"
    case "${val,,}" in
        1|sha-1|sha1)
            CLI_DISPLAY_HASH="SHA-1"
            ;;
        2|sha-512|sha512)
            CLI_DISPLAY_HASH="SHA-512"
            ;;
        3|sha3-512|sha3_512|sha3512)
            CLI_DISPLAY_HASH="SHA3-512"
            ;;
        *)
            echo "Error: Invalid value '$val' for '--display-hash'. Expected 'SHA-1', 'SHA-512', or 'SHA3-512'."
            echo "Use --help for usage information."
            exit 1
            ;;
    esac
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)
            NON_INTERACTIVE=1
            shift
            ;;
        --force-with-risks)
            CLI_FORCE_WITH_RISKS=1
            used_option_flags+=("$1")
            shift
            ;;
        -t|--timestamp)
            if [[ $# -lt 2 || "$2" == -* ]]; then
                echo "Error: Option '$1' requires an argument (<ISO8601|first>)."
                echo "Use --help for usage information."
                exit 1
            fi
            used_option_flags+=("$1")
            CLI_TIMESTAMP_RAW="$2"
            if [[ "${2,,}" == "first" ]]; then
                CLI_TIMESTAMP_MODE="first"
            else
                CLI_TIMESTAMP_MODE="custom"
            fi
            shift 2
            ;;
        --timestamp=*)
            used_option_flags+=("--timestamp")
            CLI_TIMESTAMP_RAW="${1#*=}"
            if [[ -z "$CLI_TIMESTAMP_RAW" ]]; then
                echo "Error: Option '--timestamp' requires a non-empty argument (<ISO8601|first>)."
                echo "Use --help for usage information."
                exit 1
            fi
            if [[ "${CLI_TIMESTAMP_RAW,,}" == "first" ]]; then
                CLI_TIMESTAMP_MODE="first"
            else
                CLI_TIMESTAMP_MODE="custom"
            fi
            shift
            ;;
        --redump-verification)
            if [[ "$CLI_REDUMP_MODE" == "disable" ]]; then
                echo "Error: Cannot specify both '--redump-verification' and '--no-redump-verification'."
                exit 1
            fi
            CLI_REDUMP_MODE="enable"
            used_option_flags+=("$1")
            shift
            ;;
        --no-redump-verification)
            if [[ "$CLI_REDUMP_MODE" == "enable" ]]; then
                echo "Error: Cannot specify both '--redump-verification' and '--no-redump-verification'."
                exit 1
            fi
            CLI_REDUMP_MODE="disable"
            used_option_flags+=("$1")
            shift
            ;;
        --overwrite-existing)
            if [[ "$CLI_OVERWRITE_MODE" == "skip" ]]; then
                echo "Error: Cannot specify both '--overwrite-existing' and '--skip-existing'."
                exit 1
            fi
            CLI_OVERWRITE_MODE="overwrite"
            used_option_flags+=("$1")
            shift
            ;;
        --skip-existing)
            if [[ "$CLI_OVERWRITE_MODE" == "overwrite" ]]; then
                echo "Error: Cannot specify both '--overwrite-existing' and '--skip-existing'."
                exit 1
            fi
            CLI_OVERWRITE_MODE="skip"
            used_option_flags+=("$1")
            shift
            ;;
        --integrity-test)
            if [[ "$CLI_INTEGRITY_MODE" == "disable" ]]; then
                echo "Error: Cannot specify both '--integrity-test' and '--no-integrity-test'."
                exit 1
            fi
            CLI_INTEGRITY_MODE="enable"
            used_option_flags+=("$1")
            shift
            ;;
        --no-integrity-test)
            if [[ "$CLI_INTEGRITY_MODE" == "enable" ]]; then
                echo "Error: Cannot specify both '--integrity-test' and '--no-integrity-test'."
                exit 1
            fi
            CLI_INTEGRITY_MODE="disable"
            used_option_flags+=("$1")
            shift
            ;;
        --display-hash)
            if [[ $# -lt 2 || "$2" == -* ]]; then
                echo "Error: Option '--display-hash' requires an argument (<SHA-1|SHA-512|SHA3-512>)."
                echo "Use --help for usage information."
                exit 1
            fi
            used_option_flags+=("--display-hash")
            CLI_DISPLAY_HASH_SET=1
            parse_display_hash_arg "$2"
            shift 2
            ;;
        --display-hash=*)
            used_option_flags+=("--display-hash")
            CLI_DISPLAY_HASH_SET=1
            parse_display_hash_arg "${1#*=}"
            shift
            ;;
        --ramdisk-dir)
            if [[ $# -lt 2 || "$2" == -* ]]; then
                echo "Error: Option '--ramdisk-dir' requires an argument (<DIR>)."
                echo "Use --help for usage information."
                exit 1
            fi
            USE_RAMDISK=1
            RAMDISK_DIR="$2"
            shift 2
            ;;
        --ramdisk-dir=*)
            RAMDISK_DIR="${1#*=}"
            if [[ -z "$RAMDISK_DIR" ]]; then
                echo "Error: Option '--ramdisk-dir' requires a non-empty argument (<DIR>)."
                echo "Use --help for usage information."
                exit 1
            fi
            USE_RAMDISK=1
            shift
            ;;
        *)
            echo "Error: Unknown argument '$1'."
            echo "Use --help for usage information."
            exit 1
            ;;
    esac
done

# Strict mode validation: option flags require -y / --yes
if [[ "$NON_INTERACTIVE" -eq 0 && "${#used_option_flags[@]}" -gt 0 ]]; then
    echo "Error: Option '${used_option_flags[0]}' requires non-interactive mode ('-y' or '--yes')."
    echo "Use --help for usage information."
    exit 1
fi

# Non-interactive mode requires -t / --timestamp <ISO8601|first>
if [[ "$NON_INTERACTIVE" -eq 1 && -z "$CLI_TIMESTAMP_MODE" ]]; then
    echo "Error: Non-interactive mode ('-y' / '--yes') requires '--timestamp <ISO8601|first>' (or '-t <ISO8601|first>')."
    echo "Use --help for usage information."
    exit 1
fi

# Validate custom CLI ISO 8601 timestamp up front before touching the filesystem
if [[ "$CLI_TIMESTAMP_MODE" == "custom" ]]; then
    ts_rc=0
    validate_iso_timestamp "$CLI_TIMESTAMP_RAW" || ts_rc=$?
    if [[ "$ts_rc" -eq 2 ]]; then
        echo "Error: Base timestamp cannot be older than 2014-01-01T00:00:00Z (2014-01-01 00:00:00 UTC)."
        exit 1
    elif [[ "$ts_rc" -ne 0 ]]; then
        echo "Error: Invalid ISO 8601 date/time or calendar value '$CLI_TIMESTAMP_RAW'. Please follow YYYY-MM-DDTHH:mm:ss±hh:mm (e.g. 2020-03-04T00:00:00+09:00) or 'first'."
        exit 1
    fi
    CLI_PARSED_EPOCH="$VALIDATED_EPOCH"
    CLI_CUSTOM_TZ="$VALIDATED_TZ"
fi

# Validate --ramdisk-dir path, permissions, and tmpfs/ramfs filesystem backing up front
if [[ "$USE_RAMDISK" -eq 1 ]]; then
    if [[ ! -e "$RAMDISK_DIR" ]]; then
        echo "Error: Ramdisk directory \"$RAMDISK_DIR\" does not exist."
        exit 1
    fi
    if [[ ! -d "$RAMDISK_DIR" ]]; then
        echo "Error: Ramdisk path \"$RAMDISK_DIR\" is not a directory."
        exit 1
    fi
    if [[ ! -w "$RAMDISK_DIR" || ! -x "$RAMDISK_DIR" ]]; then
        echo "Error: Ramdisk directory \"$RAMDISK_DIR\" is not writable (permission denied)."
        exit 1
    fi
    ramdisk_fstype=$(stat -f -c %T "$RAMDISK_DIR" 2>/dev/null || true)
    ramdisk_df_type=$(df -P -T "$RAMDISK_DIR" 2>/dev/null | awk 'NR==2 {print $2}' || true)
    if [[ "${ramdisk_fstype,,}" != "tmpfs" && "${ramdisk_fstype,,}" != "ramfs" && \
          "${ramdisk_df_type,,}" != "tmpfs" && "${ramdisk_df_type,,}" != "ramfs" ]]; then
        echo "Error: Directory \"$RAMDISK_DIR\" is not backed by a ramdisk (tmpfs or ramfs) filesystem (detected: ${ramdisk_fstype:-unknown})."
        exit 1
    fi
    RAMDISK_DIR=$(cd "$RAMDISK_DIR" && pwd)
fi

echo ""
echo "ps2_archive_cleanser.sh (v1.0.0-2026-11-09 Copyright (c) 2026 zencatalyst) - Automates extracting, cleaning, recompressing, and multi-format timestamp alignment."
echo ""

# ==============================================================================
# Pre-flight System RAM & Disk Space Checks
# ==============================================================================
mem_total_kb=0
mem_avail_kb=0

# Read /proc/meminfo directly using pure Bash
if [[ -f /proc/meminfo ]]; then
    while read -r key val _; do
        case "$key" in
            MemTotal:) mem_total_kb="$val" ;;
            MemAvailable:) mem_avail_kb="$val" ;;
        esac
        if [[ "$mem_total_kb" -gt 0 && "$mem_avail_kb" -gt 0 ]]; then
            break
        fi
    done < /proc/meminfo
fi

# 15,000,000 KiB (~14.3 GiB / 15.36 GB) accounts for hardware-reserved RAM on 16 GB systems
THRESHOLD_16GB_KB=15000000
# 23,000,000 KiB (~21.93 GiB / 23.55 GB) accounts for hardware-reserved RAM on 24 GB systems
THRESHOLD_24GB_KB=23000000
# 10 GiB = 10 * 1024 * 1024 KiB = 10,485,760 KiB
THRESHOLD_10GIB_KB=10485760
# 18.5 GiB = 18.5 * 1024 * 1024 KiB = 19,398,656 KiB
THRESHOLD_18_5GIB_KB=19398656

if [[ "$USE_RAMDISK" -eq 1 ]]; then
    if [[ "$mem_total_kb" -lt "$THRESHOLD_24GB_KB" ]]; then
        echo "⚠️  WARNING: System RAM detected is less than 24 GB."
        echo "Running ps2_archive_cleanser.sh with --ramdisk-dir on systems with less than 24 GB of RAM can lead to out-of-memory errors and system crashes."
        if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
            if [[ "$CLI_FORCE_WITH_RISKS" -eq 1 ]]; then
                echo "-> Non-interactive mode (--force-with-risks): Proceeding at user's risk..."
            else
                echo "Error: Non-interactive mode aborted due to low system RAM (< 24 GB for --ramdisk-dir). Pass '--force-with-risks' with '-y' to override."
                exit 1
            fi
        else
            read -r -p "Do you want to proceed anyway? (y/N) [default: N]: " ram_confirm || abort_on_eof
            case "$ram_confirm" in
                [yY][eE][sS]|[yY])
                    echo "-> Proceeding at user's risk..."
                    ;;
                *)
                    echo "Operation aborted by user."
                    exit 0
                    ;;
            esac
        fi
    else
        # 24+ GB RAM System with --ramdisk-dir: Ensure at least 18.5 GiB of available RAM
        if [[ "$mem_avail_kb" -lt "$THRESHOLD_18_5GIB_KB" ]]; then
            gib_int=$(( mem_avail_kb / 1048576 ))
            gib_dec=$(( (mem_avail_kb % 1048576) * 100 / 1048576 ))
            printf -v avail_gib "%d.%02d" "$gib_int" "$gib_dec"

            echo "Error: At least 18.5 GiB of free RAM must be available to launch this script with '--ramdisk-dir'."
            echo "Current available RAM: ${avail_gib} GiB."
            echo "Please free up memory by closing apps."
            exit 1
        fi
    fi
else
    if [[ "$mem_total_kb" -lt "$THRESHOLD_16GB_KB" ]]; then
        echo "⚠️  WARNING: System RAM detected is less than 16 GB."
        echo "Running ps2_archive_cleanser.sh on systems with less than 16 GB of RAM can lead to out-of-memory errors and system crashes."
        if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
            if [[ "$CLI_FORCE_WITH_RISKS" -eq 1 ]]; then
                echo "-> Non-interactive mode (--force-with-risks): Proceeding at user's risk..."
            else
                echo "Error: Non-interactive mode aborted due to low system RAM (< 16 GB). Pass '--force-with-risks' with '-y' to override."
                exit 1
            fi
        else
            read -r -p "Do you want to proceed anyway? (y/N) [default: N]: " ram_confirm || abort_on_eof
            case "$ram_confirm" in
                [yY][eE][sS]|[yY])
                    echo "-> Proceeding at user's risk..."
                    ;;
                *)
                    echo "Operation aborted by user."
                    exit 0
                    ;;
            esac
        fi
    else
        # 16+ GB RAM System: Ensure at least 10 GiB of available RAM
        if [[ "$mem_avail_kb" -lt "$THRESHOLD_10GIB_KB" ]]; then
            # Pure Bash fixed-point arithmetic for 2 decimal places (no subshells or external tools)
            gib_int=$(( mem_avail_kb / 1048576 ))
            gib_dec=$(( (mem_avail_kb % 1048576) * 100 / 1048576 ))
            printf -v avail_gib "%d.%02d" "$gib_int" "$gib_dec"

            echo "Error: At least 10 GiB of free RAM must be available to launch this script."
            echo "Current available RAM: ${avail_gib} GiB."
            echo "Please free up memory by closing apps."
            exit 1
        fi
    fi
fi

# ==============================================================================
# Environment Configuration & Prerequisites
# ==============================================================================
TARGET_DIR="$PWD"
GAMES_DIR="$TARGET_DIR/PS2-Games"
SKIPPED_DIR="$TARGET_DIR/Skipped-PS2-Game-Archives"
if [[ "$USE_RAMDISK" -eq 1 ]]; then
    EXTRACTED_ROOT_DIR="$RAMDISK_DIR/temporary-extracted-archives"
else
    EXTRACTED_ROOT_DIR="$TARGET_DIR/temporary-extracted-archives"
fi
PROCESSED_ROOT_DIR="$TARGET_DIR/temporary-processed-archives"

# Ensure at least 24 GiB (25,165,824 KiB) of free disk space in TARGET_DIR
THRESHOLD_24GIB_KB=25165824
disk_avail_kb=$(df -P -k "$TARGET_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)

if [[ -n "$disk_avail_kb" && "$disk_avail_kb" -gt 0 && "$disk_avail_kb" -lt "$THRESHOLD_24GIB_KB" ]]; then
    disk_gib_int=$(( disk_avail_kb / 1048576 ))
    disk_gib_dec=$(( (disk_avail_kb % 1048576) * 100 / 1048576 ))
    printf -v avail_disk_gib "%d.%02d" "$disk_gib_int" "$disk_gib_dec"

    echo "⚠️  WARNING: Free disk space in \"$TARGET_DIR\" is ${avail_disk_gib} GiB (less than the recommended 24.00 GiB)."
    echo "Extracting and recompressing large DVD-9 ISOs may fail if storage runs out."
    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        if [[ "$CLI_FORCE_WITH_RISKS" -eq 1 ]]; then
            echo "-> Non-interactive mode (--force-with-risks): Proceeding at user's risk..."
        else
            echo "Error: Non-interactive mode aborted due to low free disk space (< 24.00 GiB). Pass '--force-with-risks' with '-y' to override."
            exit 1
        fi
    else
        read -r -p "Do you want to proceed anyway? (y/N) [default: N]: " disk_confirm || abort_on_eof
        case "$disk_confirm" in
            [yY][eE][sS]|[yY])
                echo "-> Proceeding at user's risk..."
                ;;
            *)
                echo "Operation aborted by user."
                exit 0
                ;;
        esac
    fi
fi

# When --ramdisk-dir is active, ensure at least 9.00 GiB (9,437,184 KiB) of free space in RAMDISK_DIR
THRESHOLD_9GIB_KB=9437184
if [[ "$USE_RAMDISK" -eq 1 ]]; then
    ramdisk_avail_kb=$(df -P -k "$RAMDISK_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)
    if [[ -n "$ramdisk_avail_kb" && "$ramdisk_avail_kb" -gt 0 && "$ramdisk_avail_kb" -lt "$THRESHOLD_9GIB_KB" ]]; then
        ramdisk_gib_int=$(( ramdisk_avail_kb / 1048576 ))
        ramdisk_gib_dec=$(( (ramdisk_avail_kb % 1048576) * 100 / 1048576 ))
        printf -v avail_ramdisk_gib "%d.%02d" "$ramdisk_gib_int" "$ramdisk_gib_dec"

        echo "⚠️  WARNING: Free ramdisk space in \"$RAMDISK_DIR\" is ${avail_ramdisk_gib} GiB (less than the recommended 9.00 GiB)."
        echo "Extracting and recompressing large DVD-9 ISOs may fail if ramdisk runs out."
        if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
            if [[ "$CLI_FORCE_WITH_RISKS" -eq 1 ]]; then
                echo "-> Non-interactive mode (--force-with-risks): Proceeding at user's risk..."
            else
                echo "Error: Non-interactive mode aborted due to low free ramdisk space (< 9.00 GiB). Pass '--force-with-risks' with '-y' to override."
                exit 1
            fi
        else
            read -r -p "Do you want to proceed anyway? (y/N) [default: N]: " ramdisk_confirm || abort_on_eof
            case "$ramdisk_confirm" in
                [yY][eE][sS]|[yY])
                    echo "-> Proceeding at user's risk..."
                    ;;
                *)
                    echo "Operation aborted by user."
                    exit 0
                    ;;
            esac
        fi
    fi
    echo "-> Ramdisk extraction staging enabled: \"$EXTRACTED_ROOT_DIR\""
fi

# Ensure required utilities are installed
if ! command -v 7z &> /dev/null; then
    echo "Error: '7z' command not found."
    echo "Please install it before launching the ps2_archive_cleanser.sh script."
    exit 1
fi

if ! command -v bchunk &> /dev/null; then
    echo "Error: 'bchunk' command not found."
    echo "Please install it before launching the ps2_archive_cleanser.sh script."
    exit 1
fi

if ! command -v rhash &> /dev/null; then
    echo "Error: 'rhash' command not found."
    echo "Please install it before launching the ps2_archive_cleanser.sh script."
    exit 1
fi

# ==============================================================================
# Helper Functions
# ==============================================================================
# Helper function to validate a Redump PlayStation 2 DAT header and print its version
get_redump_dat_version() {
    local dat_file="$1"
    awk '
        function get_tag(line, tag,    open_t, close_t, s, r, e) {
            open_t = "<" tag ">";
            close_t = "</" tag ">";
            s = index(line, open_t);
            if (s == 0) return "";
            r = substr(line, s + length(open_t));
            e = index(r, close_t);
            if (e == 0) return "";
            return substr(r, 1, e - 1);
        }
        BEGIN { in_hdr = 0; name = ""; ver = ""; }
        NR > 50 && !in_hdr { exit; }
        /<header>/ { in_hdr = 1; next; }
        /<\/header>/ {
            if (tolower(name) == "sony - playstation 2" && ver != "") {
                print ver;
            }
            exit;
        }
        in_hdr {
            sub(/\r$/, "");
            t = get_tag($0, "name");
            if (t != "") name = t;
            v = get_tag($0, "version");
            if (v != "") ver = v;
        }
    ' "$dat_file"
}

# Helper function to extract all <rom> entries for a given game name from the Redump DAT file
# Output format per line: rom_name \t size \t crc32_lower \t sha1_lower
get_redump_game_roms() {
    local dat_file="$1"
    local game_name="$2"

    TARGET_GAME="$game_name" awk '
        function unescape_xml(s) {
            gsub(/&quot;/, "\"", s);
            gsub(/&apos;/, "\x27", s);
            gsub(/&lt;/, "<", s);
            gsub(/&gt;/, ">", s);
            gsub(/&amp;/, "\\&", s);
            return s;
        }
        function get_attr(line, attr,    pat, start, rest, end_q, val) {
            pat = attr "=\"";
            start = index(line, pat);
            if (start == 0) return "";
            rest = substr(line, start + length(pat));
            end_q = index(rest, "\"");
            if (end_q == 0) return "";
            val = substr(rest, 1, end_q - 1);
            return unescape_xml(val);
        }
        BEGIN {
            target_game = ENVIRON["TARGET_GAME"];
            in_game = 0;
        }
        /<game[[:space:]]+/ {
            sub(/\r$/, "");
            if (get_attr($0, "name") == target_game) {
                in_game = 1;
            }
            next;
        }
        in_game && /<\/game>/ {
            exit;
        }
        in_game && /<rom[[:space:]]+/ {
            sub(/\r$/, "");
            rname = get_attr($0, "name");
            rsize = get_attr($0, "size");
            rcrc  = tolower(get_attr($0, "crc"));
            rsha1 = tolower(get_attr($0, "sha1"));
            if (rname != "") {
                printf "%s\t%s\t%s\t%s\n", rname, rsize, rcrc, rsha1;
            }
        }
    ' "$dat_file"
}

# Helper function to verify 7z -slt core game files against extracted Redump DAT <rom> lines (Filename + Size + CRC32)
verify_slt_against_dat_roms() {
    local slt_text="$1"
    local dat_roms="$2"

    DAT_ROMS="$dat_roms" awk '
        BEGIN {
            n_dat = split(ENVIRON["DAT_ROMS"], lines, "\n");
            dat_count = 0;
            for (i = 1; i <= n_dat; i++) {
                if (lines[i] == "") continue;
                split(lines[i], f, "\t");
                rname = f[1];
                dat_size[rname] = f[2];
                dat_crc[rname]  = tolower(f[3]);
                dat_valid[rname] = 1;
                dat_count++;
            }
            header_done = 0;
            curr_path = "";
            curr_size = "";
            curr_crc = "";
            curr_folder = 0;
            core_count = 0;
            mismatch = 0;
        }
        { sub(/\r$/, ""); }
        /^----------/ {
            header_done = 1;
            next;
        }
        header_done && /^Path = / {
            if (curr_path != "") {
                check_item(curr_path, curr_folder, curr_size, curr_crc);
            }
            curr_path = $0;
            sub(/^Path = /, "", curr_path);
            curr_size = "";
            curr_crc = "";
            curr_folder = 0;
        }
        header_done && /^Folder = / {
            val = $0;
            sub(/^Folder = /, "", val);
            if (val == "+") curr_folder = 1;
        }
        header_done && /^Size = / {
            curr_size = $0;
            sub(/^Size = /, "", curr_size);
        }
        header_done && /^CRC = / {
            val = $0;
            sub(/^CRC = /, "", val);
            curr_crc = tolower(val);
        }
        END {
            if (curr_path != "") {
                check_item(curr_path, curr_folder, curr_size, curr_crc);
            }
            if (mismatch > 0 || core_count != dat_count) {
                print "MISMATCH";
            } else {
                print "OK";
            }
        }
        function check_item(p, fold, sz, crc,    n, parts, ext) {
            if (fold == 1) return;
            ext = "";
            if (p ~ /\./) {
                n = split(p, parts, ".");
                ext = tolower(parts[n]);
            }
            if (ext == "iso" || ext == "bin" || ext == "cue") {
                core_count++;
                if (!(p in dat_valid)) {
                    mismatch++;
                    return;
                }
                if (sz != dat_size[p] || crc != dat_crc[p]) {
                    mismatch++;
                    return;
                }
                seen[p]++;
                if (seen[p] > 1) {
                    mismatch++;
                }
            }
        }
    ' <<< "$slt_text"
}

# Helper function to format an epoch timestamp using CUSTOM_TZ when active, or system local time otherwise
format_tz_date() {
    local epoch="$1"
    local fmt="$2"
    if [[ -n "$CUSTOM_TZ" ]]; then
        TZ="$CUSTOM_TZ" date -d "@$epoch" +"$fmt"
    else
        date -d "@$epoch" +"$fmt"
    fi
}

# Helper function to check memory usage using pure Bash and trigger guard if >= 99%
check_memory_safety() {
    local key val m_total=0 m_avail=0 pct_used
    if [[ -f /proc/meminfo ]]; then
        while read -r key val _; do
            case "$key" in
                MemTotal:) m_total="$val" ;;
                MemAvailable:) m_avail="$val" ;;
            esac
            if [[ "$m_total" -gt 0 && "$m_avail" -gt 0 ]]; then
                break
            fi
        done < /proc/meminfo
    fi

    if [[ "$m_total" -gt 0 && "$m_avail" -gt 0 ]]; then
        pct_used=$(( 100 - (m_avail * 100 / m_total) ))
        if [[ "$pct_used" -ge 99 ]]; then
            return 1 # Memory limit exceeded
        fi
    fi
    return 0
}

# Helper function to compute a single selected file checksum via rhash (used for redundant .txt files in Step 3)
compute_file_hash() {
    local algo="$1"
    local file="$2"

    case "$algo" in
        "SHA-1")
            (rhash --sha1 --simple "$file" 2>/dev/null || true) | awk '{print $1}'
            ;;
        "SHA-512")
            (rhash --sha512 --simple "$file" 2>/dev/null || true) | awk '{print $1}'
            ;;
        "SHA3-512")
            (rhash --sha3-512 --simple "$file" 2>/dev/null || true) | awk '{print $1}'
            ;;
        *)
            echo ""
            ;;
    esac
}

# Helper function to compute all four checksums (CRC32, SHA-1, SHA-512, SHA3-512) in a single rhash pass
compute_all_hashes() {
    local file="$1"
    (rhash --crc32 --sha1 --sha512 --sha3-512 --bsd "$file" 2>/dev/null || true) | awk '
        {
            sub(/\r$/, "");
            lab = toupper($1);
            gsub(/-/, "", lab);
            if      (lab == "CRC32")   crc32 = $NF;
            else if (lab == "SHA1")    sha1 = $NF;
            else if (lab == "SHA512")  sha512 = $NF;
            else if (lab == "SHA3512") sha3_512 = $NF;
        }
        END {
            if (crc32 != "" && sha1 != "" && sha512 != "" && sha3_512 != "") {
                printf "%s\t%s\t%s\t%s\n", crc32, sha1, sha512, sha3_512;
            }
        }
    '
}

# Helper function to verify that an ISO image contains a root PlayStation 2 SYSTEM.CNF,
# a valid BOOT2 = cdrom0: entry, and that the target executable file actually exists inside the ISO
verify_ps2_iso() {
    local iso_path="$1"
    local iso_slt sys_cnf_path boot2_info boot2_raw boot2_norm matched_exec

    iso_slt=$(7z l -slt -sccUTF-8 -- "$iso_path" 2>/dev/null || true)
    if [[ -z "$iso_slt" ]]; then
        return 1
    fi

    sys_cnf_path=$(awk '
        BEGIN { header_done = 0; }
        { sub(/\r$/, ""); }
        /^----------/ { header_done = 1; next; }
        header_done && /^Path = / {
            p = $0;
            sub(/^Path = /, "", p);
            lp = tolower(p);
            if (lp == "system.cnf" || lp == "system.cnf;1") {
                print p;
                exit;
            }
        }
    ' <<< "$iso_slt")

    if [[ -z "$sys_cnf_path" ]]; then
        return 1
    fi

    boot2_info=$( (7z e -so -r- -- "$iso_path" "$sys_cnf_path" 2>/dev/null || true) | awk '
        {
            sub(/\r$/, "");
            if (match(tolower($0), /^[[:space:]]*boot2[[:space:]]*=[[:space:]]*cdrom0:/)) {
                eq_pos = index($0, "=");
                raw_val = substr($0, eq_pos + 1);
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", raw_val);

                norm = raw_val;
                sub(/^[Cc][Dd][Rr][Oo][Mm]0:[\/\\]*/, "", norm);
                sub(/[[:space:]].*$/, "", norm);
                sub(/;[0-9]+$/, "", norm);
                gsub(/\\/, "/", norm);
                gsub(/^\/+|\/+$/, "", norm);

                if (raw_val != "" && norm != "") {
                    print raw_val "\t" norm;
                    exit;
                }
            }
        }
    ')

    if [[ -z "$boot2_info" ]]; then
        return 1
    fi

    IFS=$'\t' read -r boot2_raw boot2_norm <<< "$boot2_info"

    # Verify that the executable referenced by BOOT2 actually exists as a non-empty file inside the ISO
    matched_exec=$(TARGET_EXEC="$boot2_norm" awk '
        BEGIN {
            target = tolower(ENVIRON["TARGET_EXEC"]);
            header_done = 0;
            found = 0;
            curr_path = "";
            curr_folder = 0;
            curr_size = 0;
        }
        { sub(/\r$/, ""); }
        /^----------/ {
            header_done = 1;
            next;
        }
        header_done && /^Path = / {
            if (curr_path != "") {
                check_item(curr_path, curr_folder, curr_size);
                if (found) exit;
            }
            curr_path = $0;
            sub(/^Path = /, "", curr_path);
            curr_folder = 0;
            curr_size = 0;
        }
        header_done && /^Folder = / {
            val = $0;
            sub(/^Folder = /, "", val);
            if (val == "+") curr_folder = 1;
        }
        header_done && /^Size = / {
            val = $0;
            sub(/^Size = /, "", val);
            curr_size = val + 0;
        }
        END {
            if (!found && curr_path != "") {
                check_item(curr_path, curr_folder, curr_size);
            }
        }
        function check_item(p, f, s,    np, clean_p) {
            if (f == 1 || s <= 0) return;
            clean_p = p;
            gsub(/\\/, "/", clean_p);
            gsub(/^\/+|\/+$/, "", clean_p);
            sub(/;[0-9]+$/, "", clean_p);
            np = tolower(clean_p);
            if (np == target) {
                print clean_p;
                found = 1;
            }
        }
    ' <<< "$iso_slt")

    if [[ -z "$matched_exec" ]]; then
        return 1
    fi

    printf '%s\t%s\n' "$matched_exec" "$boot2_raw"
    return 0
}

# Helper function to extract CRCs of non-txt files inside the archive, sorted by type priority (.iso/.bin, .cue, .jxl, .pdf) and natural track order
get_game_crcs() {
    local archive="$1"
    7z l -slt -sccUTF-8 -- "$archive" | awk '
        BEGIN { header_done = 0; path = ""; }
        { sub(/\r$/, ""); }
        /^----------/ { header_done = 1; next; }
        header_done && /^Path = / {
            path = $0;
            sub(/^Path = /, "", path);
        }
        header_done && /^CRC = / {
            crc = $0;
            sub(/^CRC = /, "", crc);
            lp = tolower(path);
            if (lp !~ /\.txt$/ && crc != "") {
                if (lp ~ /\.(iso|bin)$/) prio = 1;
                else if (lp ~ /\.cue$/) prio = 2;
                else if (lp ~ /\.jxl$/) prio = 3;
                else if (lp ~ /\.pdf$/) prio = 4;
                else prio = 5;
                printf "%d\t%s\t%s \"%s\"\n", prio, path, crc, path;
            }
        }
    ' | sort -t$'\t' -k1,1n -k2,2V | cut -f3-
}

# Helper to format and print the Dolphin-style size comparison
report_savings() {
    local orig_bytes="$1"
    local new_bytes="$2"

    awk -v orig="$orig_bytes" -v new="$new_bytes" '
    function format_diff_size(b,    mib, unit) {
        if (b < 0) b = -b;
        mib = b / 1048576;
        if (mib >= 0.001) {
            return sprintf("%.3f MiB", mib);
        }
        unit = (b == 1) ? "Byte" : "Bytes";
        return sprintf("%d %s", b, unit);
    }
    function format_diff_pct(p,    d, s) {
        if (p < 0) p = -p;
        if (p == 0) return "0.000";
        d = 3;
        while (d < 15 && (p * (10 ^ d)) < 1) {
            d++;
        }
        s = sprintf("%." d "f", p);
        if (d > 3 && s ~ /^0\.0*10$/) {
            s = substr(s, 1, length(s) - 1);
        }
        return s;
    }
    BEGIN {
        diff = orig - new;
        abs_diff = (diff < 0) ? -diff : diff;
        pct = (orig > 0) ? (abs_diff / orig) * 100 : 0;

        printf "\n================== SIZE COMPARISON ==================\n"
        printf "Original Archive: %.2f MiB\n", orig / 1048576
        printf "Optimized Archive: %.2f MiB\n", new / 1048576
        if (diff > 0) {
            printf "Compression Result: Saved %s (%s%% smaller) ★\n", format_diff_size(abs_diff), format_diff_pct(pct)
        } else if (diff == 0) {
            printf "Compression Result: Identical size (0.000%% change)\n"
        } else {
            printf "Compression Result: Grew by %s (%s%% larger) ⚠\n", format_diff_size(abs_diff), format_diff_pct(pct)
        }
        printf "=====================================================\n\n"
    }'
}

# ==============================================================================
# Archive Discovery & Scan
# ==============================================================================
echo ""
if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
    echo "-> Non-interactive mode (-y): Scanning for game archives in \"$TARGET_DIR\"..."
else
    read -r -p "Do you want to scan for game archives in \"$TARGET_DIR\"? (y/N) [default: N]: " scan_confirm || abort_on_eof
    case "$scan_confirm" in
        [yY][eE][sS]|[yY])
            ;;
        *)
            echo "Operation aborted by user."
            exit 0
            ;;
    esac
    echo ""
    echo "Scanning for game archives in \"$TARGET_DIR\"..."
fi

mapfile -d '' -t archive_files < <(find "$TARGET_DIR" -maxdepth 1 -type f -iname "*.7z" -print0 | sort -z -V)
total_files="${#archive_files[@]}"

if [[ "$total_files" -eq 0 ]]; then
    echo "No .7z archives found in \"$TARGET_DIR\"."
    exit 0
fi

echo "--------------------------------------------------"
echo "Archives found ($total_files):"

total_scan_bytes=0

# List archives naturally sorted and calculate total size
for f in "${archive_files[@]}"; do
    size_bytes=$(stat -c %s "$f")
    total_scan_bytes=$((total_scan_bytes + size_bytes))
    awk -v name="$(basename "$f")" -v bytes="$size_bytes" 'BEGIN {
        printf "  - %-45s (%.2f MiB / %.2f GiB)\n", name, bytes / 1048576, bytes / 1073741824
    }'
done

awk -v bytes="$total_scan_bytes" 'BEGIN {
    printf "\nTotal Archive Size: %.2f GiB\n", bytes / 1073741824
}'
echo "--------------------------------------------------"

# Discover optional Redump PlayStation 2 DAT file in TARGET_DIR
USE_REDUMP_DAT=0
REDUMP_DAT_FILE=""
REDUMP_DAT_VERSION=""
valid_dat_count=0

while IFS= read -r -d '' candidate_dat; do
    candidate_ver=$(get_redump_dat_version "$candidate_dat")
    if [[ -n "$candidate_ver" ]]; then
        REDUMP_DAT_FILE="$candidate_dat"
        REDUMP_DAT_VERSION="$candidate_ver"
        valid_dat_count=$((valid_dat_count + 1))
    fi
done < <(find "$TARGET_DIR" -maxdepth 1 -type f -iname "*.dat" -print0 | sort -z -V)

if [[ -n "$REDUMP_DAT_FILE" ]]; then
    if [[ "$valid_dat_count" -gt 1 ]]; then
        echo "Notice: Multiple Redump PlayStation 2 \".dat\" files found in \"$TARGET_DIR\" ($valid_dat_count)."
        echo "        Selected latest DAT file: \"$(basename "$REDUMP_DAT_FILE")\"."
    fi
    echo "Found Redump DAT file: \"$(basename "$REDUMP_DAT_FILE")\" (Version: $REDUMP_DAT_VERSION)"
    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        if [[ "$CLI_REDUMP_MODE" == "disable" ]]; then
            USE_REDUMP_DAT=0
            echo "-> Non-interactive mode (--no-redump-verification): Redump DAT verification: Disabled"
        elif [[ "$CLI_REDUMP_MODE" == "enable" ]]; then
            USE_REDUMP_DAT=1
            echo "-> Non-interactive mode (--redump-verification): Redump DAT verification: Enabled (Version: $REDUMP_DAT_VERSION)"
        else
            USE_REDUMP_DAT=1
            echo "-> Non-interactive mode (-y): Redump DAT verification: Enabled (Version: $REDUMP_DAT_VERSION)"
        fi
    else
        read -r -p "Do you want to verify game archives against this Redump DAT file? (Y/n) [default: Y]: " redump_confirm || abort_on_eof
        case "$redump_confirm" in
            [nN][oO]|[nN])
                USE_REDUMP_DAT=0
                echo "-> Redump DAT verification: Disabled"
                ;;
            *)
                USE_REDUMP_DAT=1
                echo "-> Redump DAT verification: Enabled (Version: $REDUMP_DAT_VERSION)"
                ;;
        esac
    fi
else
    echo "⚠️  WARNING: No Redump \".dat\" file found in \"$TARGET_DIR\"."
    echo "Verifying game files against Redump.org database will not be possible."
    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        if [[ "$CLI_REDUMP_MODE" == "disable" ]]; then
            USE_REDUMP_DAT=0
            echo "-> Non-interactive mode (--no-redump-verification): Proceeding without Redump verification..."
        else
            echo "Error: Non-interactive mode aborted because no Redump \".dat\" file was found in \"$TARGET_DIR\"."
            echo "Place a valid Redump PlayStation 2 \".dat\" file in \"$TARGET_DIR\" or pass '--no-redump-verification' with '-y' to proceed without it."
            exit 1
        fi
    else
        read -r -p "Do you want to proceed without Redump verification? (y/N) [default: N]: " no_dat_confirm || abort_on_eof
        case "$no_dat_confirm" in
            [yY][eE][sS]|[yY])
                USE_REDUMP_DAT=0
                echo "-> Proceeding without Redump verification..."
                ;;
            *)
                echo "Operation aborted by user."
                exit 0
                ;;
        esac
    fi
fi
echo ""

# Safety validation prompt before scanning directory structures
echo "To avoid unintended personal data loss, scanning directory structures of all $total_files archives is required to ensure all of them are game archives."
if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
    echo "-> Non-interactive mode (-y): Proceeding with directory structure scan..."
else
    read -r -p "Do you want to proceed? (Y/n) [default: Y]: " validate_confirm || abort_on_eof
    case "$validate_confirm" in
        [nN][oO]|[nN])
            echo "Operation aborted by user."
            exit 0
            ;;
        *)
            ;;
    esac
fi

# Validate that the temporary staging root directories do not already exist before scanning archives
staging_collision=0
if [[ -e "$EXTRACTED_ROOT_DIR" || -L "$EXTRACTED_ROOT_DIR" ]]; then
    echo "Found an existing file or directory at \"$EXTRACTED_ROOT_DIR\" (possibly in use by another running instance or left over from a previous run)."
    echo "If no other instance is running, please remove or move \"$EXTRACTED_ROOT_DIR\" before relaunching this script."
    staging_collision=1
fi

if [[ -e "$PROCESSED_ROOT_DIR" || -L "$PROCESSED_ROOT_DIR" ]]; then
    echo "Found an existing file or directory at \"$PROCESSED_ROOT_DIR\" (possibly in use by another running instance or left over from a previous run)."
    echo "If no other instance is running, please remove or move \"$PROCESSED_ROOT_DIR\" before relaunching this script."
    staging_collision=1
fi

if [[ "$staging_collision" -eq 1 ]]; then
    echo "Aborting the process"
    exit 1
fi

# Validate each archive to ensure a flat root structure, valid game dump files,
# matching base filenames, and optional Redump pre-check
for f in "${archive_files[@]}"; do
    fname=$(basename "$f")
    expected_base="${fname%.[7][zZ]}"

    if ! archive_slt=$(7z l -slt -sccUTF-8 -- "$f" 2>/dev/null); then
        echo "Found an archive named \"$fname\" that could not be read (corrupt or invalid .7z archive). Fix or remove the non-compliant archive before relaunching this script."
        echo "Aborting the process"
        exit 1
    fi
    archive_status=$(EXPECTED_BASE="$expected_base" awk '
        BEGIN {
            expected_base = ENVIRON["EXPECTED_BASE"];
            header_done = 0;
            file_count = 0;
            iso_count = 0;
            bin_count = 0;
            cue_count = 0;
            invalid_ext = 0;
            has_subdir = 0;
            name_mismatch = 0;

            curr_path = "";
            curr_folder = 0;
        }

        { sub(/\r$/, ""); }

        /^----------/ {
            header_done = 1;
            next;
        }

        header_done && /^Path = / {
            if (curr_path != "") {
                process_item(curr_path, curr_folder);
            }
            curr_path = $0;
            sub(/^Path = /, "", curr_path);
            curr_folder = 0;
        }

        header_done && /^Folder = / {
            val = $0;
            sub(/^Folder = /, "", val);
            if (val == "+") {
                curr_folder = 1;
            }
        }

        END {
            if (curr_path != "") {
                process_item(curr_path, curr_folder);
            }

            if (has_subdir > 0) {
                print "HAS_SUBDIR";
                exit;
            }

            if (file_count == 0) {
                print "EMPTY";
                exit;
            }

            if (invalid_ext > 0) {
                print "INVALID_EXT";
                exit;
            }

            if (!((iso_count == 1 && bin_count == 0 && cue_count == 0) || (iso_count == 0 && bin_count >= 1 && cue_count == 1))) {
                print "INVALID_DUMP";
                exit;
            }

            if (bin_count == 1) {
                if (bin_bases[1] != expected_base) {
                    name_mismatch++;
                }
            } else if (bin_count > 1) {
                prefix = expected_base " (Track ";
                for (i = 1; i <= bin_count; i++) {
                    b = bin_bases[i];
                    if (index(b, prefix) != 1 || substr(b, length(b), 1) != ")") {
                        name_mismatch++;
                        continue;
                    }
                    t_str = substr(b, length(prefix) + 1, length(b) - length(prefix) - 1);
                    if (t_str !~ /^[0-9]+$/) {
                        name_mismatch++;
                        continue;
                    }
                    t_num = t_str + 0;
                    if (t_num < 1 || t_num > bin_count) {
                        name_mismatch++;
                        continue;
                    }
                    if (t_str != (t_num "") && !(bin_count >= 10 && t_str == sprintf("%02d", t_num))) {
                        name_mismatch++;
                        continue;
                    }
                    seen_track[t_num]++;
                }
                for (t = 1; t <= bin_count; t++) {
                    if (seen_track[t] != 1) {
                        name_mismatch++;
                    }
                }
            }

            if (name_mismatch > 0) {
                print "NAME_MISMATCH";
                exit;
            }

            print "OK";
        }

        function process_item(p, f,    n, ext_parts, ext, base_part) {
            if (f == 1 || p ~ /[\/\\]/) {
                has_subdir++;
                return;
            }

            file_count++;

            ext = "";
            base_part = p;
            if (p ~ /\./) {
                n = split(p, ext_parts, ".");
                ext = tolower(ext_parts[n]);
                base_part = substr(p, 1, length(p) - length(ext) - 1);
            }

            if (ext == "iso") {
                iso_count++;
                if (base_part != expected_base) name_mismatch++;
            } else if (ext == "bin") {
                bin_count++;
                bin_bases[bin_count] = base_part;
            } else if (ext == "cue") {
                cue_count++;
                if (base_part != expected_base) name_mismatch++;
            } else if (ext == "txt" || ext == "jxl" || ext == "pdf") {
                # Allowed metadata/documentation files (any name permitted at root)
            } else {
                invalid_ext++;
            }
        }
    ' <<< "$archive_slt")

    if [[ "$archive_status" == "HAS_SUBDIR" ]]; then
        echo "Found an archive named \"$fname\" that contains subdirectories."
        echo "Please flatten the directory structure inside \"$fname\" so all files are at the root of the archive before relaunching this script."
        echo "Aborting the process"
        exit 1
    elif [[ "$archive_status" == "NAME_MISMATCH" ]]; then
        echo "Found an archive named \"$fname\" whose internal game file names do not match the archive name."
        echo "Please make the game file names inside \"$fname\" match \"$expected_base\" (or \"$expected_base (Track n).bin\" for multi-track CD games) before relaunching this script."
        echo "Aborting the process"
        exit 1
    elif [[ "$archive_status" != "OK" ]]; then
        echo "Found an archive named \"$fname\" that does not seem to be a game archive. Fix or remove the non-compliant archive before relaunching this script."
        echo "Aborting the process"
        exit 1
    fi

    # Stage 1 Pre-flight Redump check (Filename + Size + CRC32) without extracting the archive
    if [[ "$USE_REDUMP_DAT" -eq 1 ]]; then
        dat_roms=$(get_redump_game_roms "$REDUMP_DAT_FILE" "$expected_base")
        if [[ -z "$dat_roms" ]]; then
            echo "Found an archive named \"$fname\" that was not found in the Redump DAT file (\"$(basename "$REDUMP_DAT_FILE")\")."
            echo "Fix or remove the non-compliant archive before relaunching this script."
            echo "Aborting the process"
            exit 1
        fi

        redump_precheck=$(verify_slt_against_dat_roms "$archive_slt" "$dat_roms")
        if [[ "$redump_precheck" != "OK" ]]; then
            echo "Found an archive named \"$fname\" whose internal game files do not match the Redump DAT file (filename, size, or CRC32 mismatch)."
            echo "Fix or remove the non-compliant archive before relaunching this script."
            echo "Aborting the process"
            exit 1
        fi
    fi
done

if [[ "$USE_REDUMP_DAT" -eq 1 ]]; then
    echo "All $total_files archives are valid Redump game archives!"
else
    echo "All $total_files archives are game archives!"
fi

# Pre-flight overwrite check for archives that already exist in GAMES_DIR
if [[ -d "$GAMES_DIR" ]]; then
    duplicate_archives=()
    for f in "${archive_files[@]}"; do
        fname=$(basename "$f")
        dup_base="${fname%.[7][zZ]}"
        if [[ -f "$GAMES_DIR/${dup_base}.7z" || -f "$GAMES_DIR/$fname" ]]; then
            duplicate_archives+=("$f")
        fi
    done

    if [[ "${#duplicate_archives[@]}" -gt 0 ]]; then
        echo ""
        echo "--------------------------------------------------"
        echo "⚠️  WARNING: The following archives already exist in \"$GAMES_DIR\" (${#duplicate_archives[@]}):"
        for dup_f in "${duplicate_archives[@]}"; do
            dup_size_bytes=$(stat -c %s "$dup_f")
            awk -v name="$(basename "$dup_f")" -v bytes="$dup_size_bytes" 'BEGIN {
                printf "  - %-45s (%.2f MiB / %.2f GiB)\n", name, bytes / 1048576, bytes / 1073741824
            }'
        done
        echo "--------------------------------------------------"
        if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
            if [[ "$CLI_OVERWRITE_MODE" == "overwrite" ]]; then
                echo "-> Non-interactive mode (--overwrite-existing): Overwriting existing archives in \"$GAMES_DIR\"..."
                overwrite_confirm="y"
            elif [[ "$CLI_OVERWRITE_MODE" == "skip" ]]; then
                echo "-> Non-interactive mode (--skip-existing): Skipping existing archives and moving them to \"$SKIPPED_DIR\"..."
                overwrite_confirm="N"
            else
                echo "-> Non-interactive mode (-y): Skipping existing archives and moving them to \"$SKIPPED_DIR\"..."
                overwrite_confirm="N"
            fi
        else
            echo "Entering 'y' will reprocess these archives and overwrite the existing files in \"$GAMES_DIR\"."
            echo "Entering 'N' will skip these archives and move them to \"$SKIPPED_DIR\"."
            read -r -p "Do you want to proceed with overwriting the existing archives? (y/N) [default: N]: " overwrite_confirm || abort_on_eof
        fi
        case "$overwrite_confirm" in
            [yY][eE][sS]|[yY])
                echo "-> Proceeding with all $total_files archives (existing files in \"$GAMES_DIR\" will be overwritten)."
                echo ""
                ;;
            *)
                if [[ ( -e "$SKIPPED_DIR" || -L "$SKIPPED_DIR" ) && ! -d "$SKIPPED_DIR" ]]; then
                    echo "Error: Skipped archives path \"$SKIPPED_DIR\" already exists and is not a directory. Please remove or rename it before relaunching this script."
                    exit 1
                fi
                if [[ ! -d "$SKIPPED_DIR" ]]; then
                    mkdir -p "$SKIPPED_DIR"
                    echo "-> Created directory: \"$SKIPPED_DIR\""
                fi
                for dup_f in "${duplicate_archives[@]}"; do
                    mv -f "$dup_f" "$SKIPPED_DIR/"
                done
                echo "-> Moved ${#duplicate_archives[@]} duplicate archive(s) to \"$SKIPPED_DIR\"."

                mapfile -d '' -t archive_files < <(find "$TARGET_DIR" -maxdepth 1 -type f -iname "*.7z" -print0 | sort -z -V)
                total_files="${#archive_files[@]}"
                if [[ "$total_files" -eq 0 ]]; then
                    echo ""
                    echo "All duplicate archives have been moved to \"$SKIPPED_DIR\"."
                    echo "No remaining archives to process in \"$TARGET_DIR\"."
                    exit 0
                fi

                echo ""
                echo "--------------------------------------------------"
                echo "Remaining archives to process ($total_files):"
                total_scan_bytes=0
                for rem_f in "${archive_files[@]}"; do
                    size_bytes=$(stat -c %s "$rem_f")
                    total_scan_bytes=$((total_scan_bytes + size_bytes))
                    awk -v name="$(basename "$rem_f")" -v bytes="$size_bytes" 'BEGIN {
                        printf "  - %-45s (%.2f MiB / %.2f GiB)\n", name, bytes / 1048576, bytes / 1073741824
                    }'
                done

                awk -v bytes="$total_scan_bytes" 'BEGIN {
                    printf "\nTotal Remaining Archive Size: %.2f GiB\n", bytes / 1073741824
                }'
                echo "--------------------------------------------------"
                ;;
        esac
    fi
fi

# Interactive user confirmation prompt to continue working with validated archives
if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
    echo "-> Non-interactive mode (-y): Proceeding with validated archives..."
else
    read -r -p "Do you want to keep working with these archives? (y/N) [default: N]: " confirm || abort_on_eof
    case "$confirm" in
        [yY][eE][sS]|[yY])
            ;;
        *)
            echo "Operation aborted by user."
            exit 0
            ;;
    esac
fi

# ==============================================================================
# Output Directory Setup
# ==============================================================================
# Check if destination directory exists, prompt user if missing
if [[ ( -e "$GAMES_DIR" || -L "$GAMES_DIR" ) && ! -d "$GAMES_DIR" ]]; then
    echo "Error: Output path \"$GAMES_DIR\" already exists and is not a directory. Please remove or rename it before relaunching this script."
    exit 1
fi
if [[ ! -d "$GAMES_DIR" ]]; then
    echo ""
    echo "Notice: Output directory \"$GAMES_DIR\" does not exist."
    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        mkdir -p "$GAMES_DIR"
        echo "-> Non-interactive mode (-y): Created directory: \"$GAMES_DIR\""
    else
        read -r -p "Would you like to create \"PS2-Games\" in current directory and continue? (y/N) [default: N]: " dir_confirm || abort_on_eof
        case "$dir_confirm" in
            [yY][eE][sS]|[yY])
                mkdir -p "$GAMES_DIR"
                echo "-> Created directory: \"$GAMES_DIR\""
                ;;
            *)
                echo "Operation aborted by user."
                exit 0
                ;;
        esac
    fi
fi

# ==============================================================================
# Base Archive Timestamp Confirmation
# ==============================================================================
CUSTOM_TZ=""

first_archive="${archive_files[0]:-}"
if [[ -n "$first_archive" && -f "$first_archive" ]]; then
    base_archive_epoch=$(stat -c %Y "$first_archive")
    first_archive_name=$(basename "$first_archive")
    first_archive_local=$(date -d "@$base_archive_epoch" +'%Y-%m-%d %H:%M:%S (UTC%:z)')
    first_archive_utc=$(date -u -d "@$base_archive_epoch" +'%Y-%m-%d %H:%M:%S UTC')
else
    base_archive_epoch=$(date +%s)
    first_archive_name="N/A"
    first_archive_local=$(date -d "@$base_archive_epoch" +'%Y-%m-%d %H:%M:%S (UTC%:z)')
    first_archive_utc=$(date -u -d "@$base_archive_epoch" +'%Y-%m-%d %H:%M:%S UTC')
fi

echo ""
echo "Modification timestamp of the first archive ($first_archive_name) is:"
echo "  $first_archive_local ($first_archive_utc)"

if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
    if [[ "$CLI_TIMESTAMP_MODE" == "first" ]]; then
        if [[ "$base_archive_epoch" -lt "$MIN_BASE_EPOCH" ]]; then
            echo "⚠️  WARNING: The first archive's timestamp ($first_archive_utc) is older than 2014-01-01 00:00:00 UTC."
            echo "Error: Cannot use '--timestamp first' when the first archive's timestamp is older than 2014-01-01T00:00:00Z."
            echo "Please specify a custom ISO 8601 timestamp on or after 2014-01-01T00:00:00Z via '--timestamp YYYY-MM-DDTHH:mm:ss±hh:mm'."
            exit 1
        fi
        echo "-> Non-interactive mode (--timestamp first): Keeping first archive's timestamp as base."
    else
        base_archive_epoch="$CLI_PARSED_EPOCH"
        CUSTOM_TZ="$CLI_CUSTOM_TZ"
        custom_local=$(TZ="$CUSTOM_TZ" date -d "@$base_archive_epoch" +'%Y-%m-%d %H:%M:%S (UTC%:z)')
        custom_utc=$(date -u -d "@$base_archive_epoch" +'%Y-%m-%d %H:%M:%S UTC')
        echo "-> Non-interactive mode (--timestamp): Base timestamp set to: $custom_local ($custom_utc)"
    fi
else
    read -r -p "This timestamp will be used as a base to regularize the timestamps of the rest of the archives. Do you want to change the base timestamp? (Y/n) [default: Y]: " ts_confirm || abort_on_eof

    prompt_custom_ts=1
    case "$ts_confirm" in
        [nN][oO]|[nN])
            if [[ "$base_archive_epoch" -lt "$MIN_BASE_EPOCH" ]]; then
                echo "⚠️  WARNING: The first archive's timestamp ($first_archive_utc) is older than 2014-01-01 00:00:00 UTC."
                echo "Please enter a base timestamp on or after 2014-01-01T00:00:00Z so archives are never older than the games inside them."
                prompt_custom_ts=1
            else
                echo "-> Keeping first archive's timestamp as base."
                prompt_custom_ts=0
            fi
            ;;
        *)
            prompt_custom_ts=1
            ;;
    esac

    if [[ "$prompt_custom_ts" -eq 1 ]]; then
        while true; do
            read -r -p "Enter the date and time in the ISO 8601 format (i.e. YYYY-MM-DDTHH:mm:ss±hh:mm, e.g. 2020-03-04T00:00:00+09:00): " user_iso_ts || abort_on_eof
            ts_rc=0
            validate_iso_timestamp "$user_iso_ts" || ts_rc=$?
            if [[ "$ts_rc" -eq 0 ]]; then
                base_archive_epoch="$VALIDATED_EPOCH"
                CUSTOM_TZ="$VALIDATED_TZ"
                custom_local=$(TZ="$CUSTOM_TZ" date -d "@$base_archive_epoch" +'%Y-%m-%d %H:%M:%S (UTC%:z)')
                custom_utc=$(date -u -d "@$base_archive_epoch" +'%Y-%m-%d %H:%M:%S UTC')
                echo "-> Base timestamp set to: $custom_local ($custom_utc)"
                break
            elif [[ "$ts_rc" -eq 2 ]]; then
                echo "Error: Base timestamp cannot be older than 2014-01-01T00:00:00Z (2014-01-01 00:00:00 UTC)."
            else
                echo "Error: Invalid ISO 8601 date/time or calendar value. Please follow YYYY-MM-DDTHH:mm:ss±hh:mm (e.g. 2020-03-04T00:00:00+09:00)."
            fi
        done
    fi
fi

# ==============================================================================
# Processing Options
# ==============================================================================

# Prompt for optional 7z integrity test (Default: Yes)
echo ""
if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
    if [[ "$CLI_INTEGRITY_MODE" == "disable" ]]; then
        RUN_INTEGRITY_TEST=0
        echo "-> Non-interactive mode (--no-integrity-test): 7z archive integrity test: Disabled"
    elif [[ "$CLI_INTEGRITY_MODE" == "enable" ]]; then
        RUN_INTEGRITY_TEST=1
        echo "-> Non-interactive mode (--integrity-test): 7z archive integrity test: Enabled"
    else
        RUN_INTEGRITY_TEST=1
        echo "-> Non-interactive mode (-y): 7z archive integrity test: Enabled"
    fi
else
    read -r -p "Perform '7z t' archive integrity test on new archives? (Y/n) [default: Y]: " test_choice || abort_on_eof
    case "$test_choice" in
        [nN][oO]|[nN])
            RUN_INTEGRITY_TEST=0
            echo "-> 7z archive integrity test: Disabled"
            ;;
        *)
            RUN_INTEGRITY_TEST=1
            echo "-> 7z archive integrity test: Enabled"
            ;;
    esac
fi

# Prompt for hash calculation during extraction (Default: SHA-1)
echo ""
if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
    CHECKSUM_ALGO="$CLI_DISPLAY_HASH"
    if [[ "$CLI_DISPLAY_HASH_SET" -eq 1 ]]; then
        echo "-> Non-interactive mode (--display-hash): Hash calculation: Enabled ($CHECKSUM_ALGO)"
    else
        echo "-> Non-interactive mode (-y): Hash calculation: Enabled ($CHECKSUM_ALGO)"
    fi
else
    echo "Select a hash function to generate and view hash values for extracted files:"
    echo "  [1] SHA-1     (Default) (Legacy, low error detection reliability, super fast (use for comparing hashes against sources e.g. Redump))"
    echo "  [2] SHA-512   (Modern, high error detection reliability, fast (use for a balance of speed and reliability))"
    echo "  [3] SHA3-512  (Post-modern, top-tier error detection reliability, slow (use for ensuring maximum reliability))"
    read -r -p "Enter choice (1-3) [default: 1]: " checksum_choice || abort_on_eof

    case "$checksum_choice" in
        2)
            CHECKSUM_ALGO="SHA-512"
            echo "-> Hash calculation: Enabled (SHA-512)"
            ;;
        3)
            CHECKSUM_ALGO="SHA3-512"
            echo "-> Hash calculation: Enabled (SHA3-512)"
            ;;
        *)
            CHECKSUM_ALGO="SHA-1"
            echo "-> Hash calculation: Enabled (SHA-1)"
            ;;
    esac
fi
echo ""

# Final launch prompt
if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
    echo "-> Non-interactive mode (-y): Starting batch operation..."
else
    read -r -p "Everything set. Do you want to launch the task? (Y/n) [default: Y]: " launch_confirm || abort_on_eof
    case "$launch_confirm" in
        [nN][oO]|[nN])
            echo "Operation aborted by user."
            echo ""
            exit 0
            ;;
        *)
            echo "Starting batch operation..."
            ;;
    esac
fi
echo ""

# ==============================================================================
# Batch Execution Loop
# ==============================================================================
current_count=0
processed_count=0

# Track global metrics
script_start_time=$(date +%s)
total_orig_bytes=0
total_new_bytes=0

# Shared base options for 7z ultra-compression passes
SEVENZ_BASE_OPTS=(
    -t7z -m0=LZMA2 -mmt=8 -mmemuse=p90 -mx9 -md=256m -mfb=256 -mqs=on
    -sccUTF-8 -bb0 -bse0 -bsp1 -snh -snl -mtm=on -mtc=off -mta=off
)

# Create temporary staging root directories for extracted files and newly compressed archives
staging_collision=0
if [[ -e "$EXTRACTED_ROOT_DIR" || -L "$EXTRACTED_ROOT_DIR" ]]; then
    echo "-> ERROR: Staging directory \"$EXTRACTED_ROOT_DIR\" already exists! Refusing to overwrite or delete existing path."
    staging_collision=1
fi
if [[ -e "$PROCESSED_ROOT_DIR" || -L "$PROCESSED_ROOT_DIR" ]]; then
    echo "-> ERROR: Staging directory \"$PROCESSED_ROOT_DIR\" already exists! Refusing to overwrite or delete existing path."
    staging_collision=1
fi
if [[ "$staging_collision" -eq 1 ]]; then
    exit 1
fi
mkdir "$EXTRACTED_ROOT_DIR"
created_extracted_root=1
mkdir "$PROCESSED_ROOT_DIR"
created_processed_root=1

# Process files in natural alphabetical order from pre-validated array
for file in "${archive_files[@]}"; do
    current_count=$((current_count + 1))
    file_name=$(basename "$file")
    base_name="${file_name%.[7][zZ]}"
    ext_dir="$EXTRACTED_ROOT_DIR/$base_name"
    new_archive="$PROCESSED_ROOT_DIR/${base_name}.7z"

    # Calculate scheduled base timestamp for this archive (+1 minute for each sequential archive)
    archive_base_epoch=$((base_archive_epoch + (current_count - 1) * 60))

    echo "--------------------------------------------------"
    echo "1. [$current_count/$total_files] Processing: $base_name.7z"

    # Pre-flight memory check
    if ! check_memory_safety; then
        echo "-> ERROR: Critical low memory detected (>= 99% usage) before processing \"$base_name.7z\". Aborting script."
        exit 1
    fi

    # Build per-file original compression method mapping
    declare -A file_methods=()
    while IFS=$'\t' read -r rel_p file_m; do
        if [[ -n "$rel_p" && -n "$file_m" ]]; then
            file_methods["$rel_p"]="$file_m"
        fi
    done < <(7z l -slt -sccUTF-8 -- "$file" | awk '
        BEGIN { header_done = 0; path = ""; method = ""; }
        { sub(/\r$/, ""); }
        /^----------/ { header_done = 1; next; }
        header_done && /^Path = / {
            if (path != "" && method != "") {
                print path "\t" method;
            }
            path = $0;
            sub(/^Path = /, "", path);
            method = "";
        }
        header_done && /^Method = / {
            method = $0;
            sub(/^Method = /, "", method);
        }
        END {
            if (path != "" && method != "") {
                print path "\t" method;
            }
        }
    ')

    # Measure original file size in bytes
    orig_size=$(stat -c %s "$file")

    # 2. Retrieve original game CRCs
    echo "2. Retrieving original game CRCs..."
    orig_crc=$(get_game_crcs "$file")
    if [[ -z "$orig_crc" ]]; then
        echo "Warning: No valid game files found in \"$base_name.7z\"."
        exit 1
    fi
    echo "-> Original game CRCs retrieved."

    # 3. Extract to a dedicated folder with live percentage, elapsed timer, and 99% memory check
    echo "3. Extracting..."
    if [[ -e "$ext_dir" ]]; then
        echo "-> ERROR: Staging path \"$ext_dir\" already exists! Refusing to overwrite or delete existing path."
        exit 1
    fi
    mkdir "$ext_dir"
    active_ext_dir="$ext_dir"
    extract_start=$(date +%s)
    extract_log="$ext_dir/.extract_progress.log"

    7z x -aos -bsp1 -sccUTF-8 -o"$ext_dir" -- "$file" > "$extract_log" 2>&1 &
    extract_pid=$!
    active_pid="$extract_pid"

    while kill -0 "$extract_pid" 2>/dev/null; do
        if ! check_memory_safety; then
            printf "\r\033[K"
            echo "-> CRITICAL ERROR: System memory reached 99% capacity!"
            echo "   Killing extraction process to protect system stability."
            kill -9 "$extract_pid" 2>/dev/null || true
            wait "$extract_pid" 2>/dev/null || true
            active_pid=""
            fail_game
        fi
        pct="0"
        if [[ -f "$extract_log" ]]; then
            parsed_pct=$(tail -c 256 "$extract_log" 2>/dev/null | grep -oE '[0-9]{1,3}%' | tail -n 1 | tr -d '%' || true)
            if [[ -n "$parsed_pct" ]]; then
                pct="$parsed_pct"
            fi
        fi
        now=$(date +%s)
        elapsed=$((now - extract_start))
        printf "\r   Progress: %3d%% | Elapsed time: %02dm %02ds" "$pct" $((elapsed / 60)) $((elapsed % 60))
        sleep 1
    done

    if ! wait "$extract_pid" 2>/dev/null; then
        active_pid=""
        rm -f "$extract_log"
        printf "\r\033[K"
        fail_game "-> ERROR: Extraction failed for \"$base_name.7z\" (corrupt archive or insufficient disk space)."
    fi
    active_pid=""
    rm -f "$extract_log"

    extract_end=$(date +%s)
    extract_duration=$((extract_end - extract_start))
    printf "\r\033[K"
    printf -- "-> Extraction finished in %dm %ds\n" $((extract_duration / 60)) $((extract_duration % 60))

    # Pre-calculate hashes and gather file info for extracted files with a live elapsed timer before printing the list.
    # Surviving files are hashed once across all 4 algorithms and cached for Step 6; redundant .txt files are hashed with CHECKSUM_ALGO.
    echo "-> Computing hash values and fetching file info of the extracted files..."
    fetch_start=$(date +%s)
    (
        { set +x; } 2>/dev/null
        trap 'exit 0' TERM INT HUP
        while true; do
            now=$(date +%s)
            elapsed=$((now - fetch_start))
            printf "\r   Elapsed time: %02dm %02ds" $((elapsed / 60)) $((elapsed % 60))
            read -r -t 1 _ <> <(:) || true
        done
    ) &
    fetch_timer_pid=$!
    active_pid="$fetch_timer_pid"

    declare -A cached_crc32=()
    declare -A cached_sha1=()
    declare -A cached_sha512=()
    declare -A cached_sha3_512=()
    extracted_file_entries=()

    while IFS= read -r -d '' ext_file; do
        rel_path="${ext_file#"$ext_dir"/}"
        file_bytes=$(stat -c %s "$ext_file")

        method="Unknown"
        if [[ -v file_methods["$rel_path"] ]]; then
            method="${file_methods["$rel_path"]}"
        fi

        if [[ "${rel_path,,}" == *.txt ]]; then
            hash_val=$(compute_file_hash "$CHECKSUM_ALGO" "$ext_file")
            if [[ -z "$hash_val" ]]; then
                fail_game "-> ERROR: Failed to calculate $CHECKSUM_ALGO checksum via rhash for \"$rel_path\"!"
            fi
        else
            all_hashes=$(compute_all_hashes "$ext_file")
            if [[ -z "$all_hashes" ]]; then
                fail_game "-> ERROR: Failed to calculate checksums via rhash for \"$rel_path\"!"
            fi
            IFS=$'\t' read -r h_crc32 h_sha1 h_sha512 h_sha3_512 <<< "$all_hashes"
            cached_crc32["$rel_path"]="$h_crc32"
            cached_sha1["$rel_path"]="$h_sha1"
            cached_sha512["$rel_path"]="$h_sha512"
            cached_sha3_512["$rel_path"]="$h_sha3_512"

            case "$CHECKSUM_ALGO" in
                "SHA-512")  hash_val="$h_sha512" ;;
                "SHA3-512") hash_val="$h_sha3_512" ;;
                *)          hash_val="$h_sha1" ;;
            esac
        fi

        entry_text=$(awk -v tag="$CHECKSUM_ALGO" -v hash="$hash_val" -v name="$rel_path" -v bytes="$file_bytes" -v m="$method" '
        function format_ext_size(b,    mib, unit, s) {
            mib = b / 1048576;
            if (mib >= 0.001) {
                return sprintf("%9.3f MiB", mib);
            }
            unit = (b == 1) ? "Byte" : "Bytes";
            s = sprintf("%d %s", b, unit);
            return sprintf("%13s", s);
        }
        BEGIN {
            printf "   - %s\n", name
            printf "     [%s: %s]  (%s)  [Method: %s]", tag, hash, format_ext_size(bytes), m
        }')
        extracted_file_entries+=("$entry_text")
    done < <(
        find "$ext_dir" -type f \( -iname "*.iso" -o -iname "*.bin" \) -print0 | sort -z -V
        find "$ext_dir" -type f -iname "*.cue" -print0 | sort -z -V
        find "$ext_dir" -type f ! -iname "*.iso" ! -iname "*.bin" ! -iname "*.cue" -print0 | sort -z -V
    )

    kill -TERM "$fetch_timer_pid" 2>/dev/null || true
    wait "$fetch_timer_pid" 2>/dev/null || true
    active_pid=""

    fetch_end=$(date +%s)
    fetch_duration=$((fetch_end - fetch_start))
    printf "\r\033[K"
    printf -- "-> Fetching finished in %dm %ds\n" $((fetch_duration / 60)) $((fetch_duration % 60))

    echo "-> Extracted files:"
    for entry_line in "${extracted_file_entries[@]}"; do
        printf '%s\n' "$entry_line"
    done

    # 4. Removing redundant text files...
    echo "4. Removing redundant text files..."
    find "$ext_dir" -type f -iname "*.txt" -delete
    echo "-> Redundant text files removed."

    # 5. Verify PlayStation 2 disc structure, inspect internal mastering date, and establish paired timestamps
    echo "5. Verifying PlayStation 2 disc structure and inspecting internal mastering date..."

    iso_file=$(find "$ext_dir" -type f -iname "*.iso" -print -quit)
    bin_file=""
    IFS= read -r -d '' bin_file < <(find "$ext_dir" -type f -iname "*.bin" -print0 | sort -z -V) || true
    cue_file=$(find "$ext_dir" -type f -iname "*.cue" -print -quit)

    internal_date=""
    base_target_file=""
    ps2_boot_exec=""
    ps2_boot_raw=""

    if [[ -n "$iso_file" ]]; then
        iso_size=$(stat -c %s "$iso_file")
        if [[ "$iso_size" -le 0 || $((iso_size % 2048)) -ne 0 ]]; then
            fail_game "-> ERROR: \"$(basename "$iso_file")\" is not a valid ISO image (file size is not a multiple of 2048 bytes)!"
        fi

        if ! boot2_verified=$(verify_ps2_iso "$iso_file"); then
            fail_game "-> ERROR: \"$(basename "$iso_file")\" is not a valid PlayStation 2 game disc (missing root SYSTEM.CNF, BOOT2 = cdrom0: entry, or target boot executable)!"
        fi
        IFS=$'\t' read -r ps2_boot_exec ps2_boot_raw <<< "$boot2_verified"
        echo "-> Verified PlayStation 2 ISO image: $ps2_boot_exec (BOOT2 = $ps2_boot_raw)."

        # Standard DVD ISO layout parsing (in UTC)
        internal_date=$( (TZ=UTC 7z l -sccUTF-8 -- "$iso_file" 2>/dev/null || true) | awk '/^[0-9]{4}-[0-9]{2}-[0-9]{2}/ {print $1, $2}' | sort | tail -n 1)
        base_target_file="$iso_file"

    elif [[ -n "$bin_file" && -n "$cue_file" ]]; then
        echo "-> BIN/CUE layout detected. Validating CUE sheet and BIN sector alignment..."

        actual_bins=""
        while IFS= read -r -d '' bf; do
            bf_size=$(stat -c %s "$bf")
            if [[ "$bf_size" -le 0 || $((bf_size % 2352)) -ne 0 ]]; then
                fail_game "-> ERROR: \"$(basename "$bf")\" is not a valid raw CD-ROM BIN track (file size is not a multiple of 2352 bytes)!"
            fi
            if [[ -n "$actual_bins" ]]; then
                actual_bins+=$'\n'
            fi
            actual_bins+="$(basename "$bf")"
        done < <(find "$ext_dir" -type f -iname "*.bin" -print0 | sort -z -V)

        cue_bins=$(awk '
            {
                sub(/\r$/, "");
                if (match($0, /^[[:space:]]*[Ff][Ii][Ll][Ee][[:space:]]+/)) {
                    rest = substr($0, RSTART + RLENGTH);
                    if (substr(rest, 1, 1) == "\"") {
                        rest = substr(rest, 2);
                        q_end = index(rest, "\"");
                        if (q_end > 0) {
                            print substr(rest, 1, q_end - 1);
                        } else {
                            print "INVALID_CUE_LINE";
                        }
                    } else {
                        split(rest, parts, /[[:space:]]+/);
                        if (parts[1] != "") {
                            print parts[1];
                        } else {
                            print "INVALID_CUE_LINE";
                        }
                    }
                }
            }
        ' "$cue_file")

        if [[ -z "$cue_bins" || "$cue_bins" != "$actual_bins" ]]; then
            echo "-> ERROR: CUE sheet \"$(basename "$cue_file")\" internal FILE references do not match the extracted BIN file names!"
            echo "--- Expected BIN files ---"
            awk '{print "  \"" $0 "\""}' <<< "$actual_bins"
            echo "--- CUE FILE references ---"
            if [[ -n "$cue_bins" ]]; then
                awk '{print "  \"" $0 "\""}' <<< "$cue_bins"
            else
                echo "  (None found)"
            fi
            fail_game
        fi
        echo "-> CUE sheet FILE references and 2352-byte BIN sector alignment verified."
        echo "-> Generating temporary track mapping via bchunk..."

        track1_mode=$(awk '
            {
                sub(/\r$/, "");
                if (match(toupper($0), /^[[:space:]]*TRACK[[:space:]]+0*1[[:space:]]+[A-Z0-9\/]+/)) {
                    line = toupper($0);
                    sub(/^[[:space:]]*TRACK[[:space:]]+0*1[[:space:]]+/, "", line);
                    sub(/[[:space:]].*$/, "", line);
                    if (line != "") {
                        print line;
                        exit;
                    }
                }
            }
        ' "$cue_file")
        if [[ -z "$track1_mode" ]]; then
            track1_mode="MODE2/2352"
        fi

        # Run bchunk inside the staging folder using a dedicated single-track CUE descriptor for Track 01
        # so multi-BIN CUE sheets (where Track 02 resets INDEX to 00:02:00) never truncate Track 01
        (
            cd "$ext_dir"
            {
                printf 'FILE "%s" BINARY\n' "$(basename "$bin_file")"
                printf '  TRACK 01 %s\n' "$track1_mode"
                printf '    INDEX 01 00:00:00\n'
            } > "temp_bchunk_scan.cue"
            bchunk "$(basename "$bin_file")" "temp_bchunk_scan.cue" "temp_bchunk_scan" > /dev/null 2>&1 || true
        )

        # Locate the newly generated temporary data ISO (Track 01 first)
        temp_iso=""
        IFS= read -r -d '' temp_iso < <(find "$ext_dir" -type f -name "temp_bchunk_scan*.iso" -print0 | sort -z -V) || true

        if [[ -z "$temp_iso" ]] || ! boot2_verified=$(verify_ps2_iso "$temp_iso"); then
            find "$ext_dir" -type f -name "temp_bchunk_scan*" -delete
            fail_game "-> ERROR: \"$(basename "$bin_file")\" is not a valid PlayStation 2 game disc (missing root SYSTEM.CNF, BOOT2 = cdrom0: entry, or target boot executable)!"
        fi
        IFS=$'\t' read -r ps2_boot_exec ps2_boot_raw <<< "$boot2_verified"
        echo "-> Verified PlayStation 2 BIN/CUE image: $ps2_boot_exec (BOOT2 = $ps2_boot_raw)."

        # Parse the timestamp out of the clean ISO structure (in UTC)
        internal_date=$( (TZ=UTC 7z l -sccUTF-8 -- "$temp_iso" 2>/dev/null || true) | awk '/^[0-9]{4}-[0-9]{2}-[0-9]{2}/ {print $1, $2}' | sort | tail -n 1)

        # Immediately purge the temporary CUE and conversion tracks so they aren't compressed
        find "$ext_dir" -type f -name "temp_bchunk_scan*" -delete
        base_target_file="$bin_file"
    else
        fail_game "-> ERROR: No valid ISO or BIN/CUE disc image found in \"$ext_dir\"!"
    fi

    # Apply historical metadata timestamps in UTC if image mapping was successful
    if [[ -n "$base_target_file" ]]; then
        if [[ -n "$internal_date" ]]; then
            echo "-> Success: Found original game mastering timestamp: $internal_date UTC"
            base_epoch=$(date -u -d "$internal_date" +%s)
        else
            echo "-> Note: Internal date unreadable. Defaulting to 2013-12-31 00:00:00 UTC."
            # 2013-12-31T00:00:00Z = 1388448000
            base_epoch=1388448000
        fi
        cue_epoch=$((base_epoch + 1))

        # Set core binary dumps (ISO/BIN) to historical master time in UTC, excluding auxiliary files
        find "$ext_dir" -type f ! -iname "*.cue" ! -iname "Verification.txt" ! -iname "*.jxl" ! -iname "*.pdf" -exec touch -d "@$base_epoch" {} +

        # Stagger the .cue descriptor sheets exactly 1 second behind
        find "$ext_dir" -type f -iname "*.cue" -exec touch -d "@$cue_epoch" {} +

        # Determine latest game file timestamp (.cue if present, otherwise .iso)
        if [[ -n "$cue_file" ]]; then
            latest_game_epoch="$cue_epoch"
        else
            latest_game_epoch="$base_epoch"
        fi

        # Exception guard: If the game was mastered more recently than (or at) the scheduled archive base time,
        # anchor this archive's base time to the latest game file so Verification.txt and the .7z archive are never older than the game
        if [[ "$latest_game_epoch" -ge "$archive_base_epoch" ]]; then
            archive_base_epoch="$latest_game_epoch"
            override_fmt=$(format_tz_date "$archive_base_epoch" "%Y-%m-%d %H:%M:%S (UTC%:z)")
            echo "-> Note: Game mastering timestamp is newer than scheduled base time. Advancing base time for this archive to $override_fmt."
        fi
    fi

    verif_epoch=$((archive_base_epoch + 1))
    verif_local_date=$(format_tz_date "$verif_epoch" '%Y-%m-%d %H:%M:%S (UTC%:z)')
    verif_utc_date=$(date -u -d "@$verif_epoch" +'%Y-%m-%d %H:%M:%S UTC')

    # 6. Creating Verification.txt file...
    echo "6. Creating Verification.txt file..."
    verif_file="$ext_dir/Verification.txt"

    # Assemble checksums for game image components from the Step 3 cache
    # Core disc image files (.iso, .bin, .cue) are sorted first to appear at the top of Verification.txt
    file_blocks=()
    ordered_gfiles=()
    core_game_relfiles=()

    while IFS= read -r -d '' gfile; do
        ordered_gfiles+=("$gfile")
        core_game_relfiles+=("${gfile#"$ext_dir"/}")
    done < <(find "$ext_dir" -type f ! -iname "Verification.txt" \( -iname "*.iso" -o -iname "*.bin" \) -print0 | sort -z -V)

    while IFS= read -r -d '' gfile; do
        ordered_gfiles+=("$gfile")
        core_game_relfiles+=("${gfile#"$ext_dir"/}")
    done < <(find "$ext_dir" -type f ! -iname "Verification.txt" -iname "*.cue" -print0 | sort -z -V)

    while IFS= read -r -d '' gfile; do
        ordered_gfiles+=("$gfile")
    done < <(find "$ext_dir" -type f ! -iname "Verification.txt" ! -iname "*.iso" ! -iname "*.bin" ! -iname "*.cue" -print0 | sort -z -V)

    declare -A dat_rom_size=()
    declare -A dat_rom_sha1=()
    dat_rom_total=0

    if [[ "$USE_REDUMP_DAT" -eq 1 ]]; then
        while IFS=$'\t' read -r r_name r_size _ r_sha1; do
            if [[ -n "$r_name" ]]; then
                dat_rom_size["$r_name"]="$r_size"
                dat_rom_sha1["$r_name"]="${r_sha1,,}"
                dat_rom_total=$((dat_rom_total + 1))
            fi
        done < <(get_redump_game_roms "$REDUMP_DAT_FILE" "$base_name")

        if [[ "$dat_rom_total" -eq 0 || "${#core_game_relfiles[@]}" -ne "$dat_rom_total" ]]; then
            fail_game "-> ERROR: Redump verification failed for \"$base_name.7z\" (game entry or track count mismatch against Redump DAT)!"
        fi
    fi

    for gfile in "${ordered_gfiles[@]}"; do
        rel_gpath="${gfile#"$ext_dir"/}"
        rel_gname=$(basename "$gfile")

        if [[ -v cached_crc32["$rel_gpath"] && -v cached_sha1["$rel_gpath"] && -v cached_sha512["$rel_gpath"] && -v cached_sha3_512["$rel_gpath"] ]]; then
            c_crc32="${cached_crc32["$rel_gpath"]}"
            c_sha1="${cached_sha1["$rel_gpath"]}"
            c_sha512="${cached_sha512["$rel_gpath"]}"
            c_sha3_512="${cached_sha3_512["$rel_gpath"]}"
        else
            parsed_hashes=$(compute_all_hashes "$gfile")
            if [[ -z "$parsed_hashes" ]]; then
                fail_game "-> ERROR: Failed to calculate checksums via rhash for \"$rel_gname\"!"
            fi
            IFS=$'\t' read -r c_crc32 c_sha1 c_sha512 c_sha3_512 <<< "$parsed_hashes"
        fi

        if [[ "$USE_REDUMP_DAT" -eq 1 ]]; then
            case "${rel_gname,,}" in
                *.iso|*.bin|*.cue)
                    gfile_size=$(stat -c %s "$gfile")
                    if [[ ! -v dat_rom_size["$rel_gname"] ]] || \
                       [[ "$gfile_size" != "${dat_rom_size["$rel_gname"]}" ]] || \
                       [[ "${c_sha1,,}" != "${dat_rom_sha1["$rel_gname"]}" ]]; then
                        fail_game "-> ERROR: Redump verification failed for \"$rel_gname\" in \"$base_name.7z\" (filename, size, or SHA-1 mismatch against Redump DAT)!"
                    fi
                    ;;
            esac
        fi

        file_blocks+=("$rel_gname" "$c_crc32" "$c_sha1" "$c_sha512" "$c_sha3_512")
    done

    if [[ "$USE_REDUMP_DAT" -eq 1 ]]; then
        echo "-> Verified game files against Redump DAT (Version: $REDUMP_DAT_VERSION)."
        redump_status_line="This PlayStation 2 software is verified by Redump (DAT version: $REDUMP_DAT_VERSION)."
    else
        redump_status_line="Redump verification was not performed for this archive."
    fi

    # Build ASCII table border string
    table_border="+------------+$(printf '%.0s-' {1..130})+"

    {
        echo ""
        echo "This archive was created using ps2_archive_cleanser.sh (v1.0.0-2026-11-09) Copyright (c) 2026 zencatalyst."
        echo ""
        echo "$redump_status_line"
        echo ""
        echo ""
        echo "Archive: ${base_name}.7z"
        echo "BOOT2:   ${ps2_boot_exec} (${ps2_boot_raw})"
        echo ""

        num_blocks=$((${#file_blocks[@]} / 5))
        for (( i=0; i<num_blocks; i++ )); do
            if [[ "$i" -gt 0 ]]; then
                echo ""
            fi
            idx=$((i * 5))
            echo "${file_blocks[idx]}"
            echo "$table_border"
            printf "| %-10s | %-128s |\n" "Algorithm" "Value"
            echo "$table_border"
            printf "| %-10s | %-128s |\n" "CRC32"    "${file_blocks[idx+1]}"
            printf "| %-10s | %-128s |\n" "SHA-1"    "${file_blocks[idx+2]}"
            printf "| %-10s | %-128s |\n" "SHA-512"  "${file_blocks[idx+3]}"
            printf "| %-10s | %-128s |\n" "SHA3-512" "${file_blocks[idx+4]}"
            echo "$table_border"
        done

        echo ""
        echo ""
        echo "Date:       $verif_local_date"
        echo "Date (UTC): $verif_utc_date"
    } > "$verif_file"

    echo "-> Verification.txt created."

    # 7. Stamping auxiliary files (Verification.txt, JXL, PDF)...
    echo "7. Stamping auxiliary files (Verification.txt, JXL, PDF)..."

    # Stamp Verification.txt exactly 1s after archive base time
    touch -d "@$verif_epoch" "$verif_file"
    curr_aux_epoch=$verif_epoch

    v_fmt=$(format_tz_date "$verif_epoch" "%Y-%m-%d %H:%M:%S (UTC%:z)")
    echo "   - Verification.txt: $v_fmt"

    # Stamp JXL files sequentially starting 1 second after Verification.txt
    while IFS= read -r -d '' jxl_f; do
        curr_aux_epoch=$((curr_aux_epoch + 1))
        touch -d "@$curr_aux_epoch" "$jxl_f"
        jxl_fmt=$(format_tz_date "$curr_aux_epoch" "%Y-%m-%d %H:%M:%S (UTC%:z)")
        echo "   - $(basename "$jxl_f"): $jxl_fmt"
    done < <(find "$ext_dir" -type f -iname "*.jxl" -print0 | sort -z -V)

    # Stamp PDF files sequentially following JXL files
    while IFS= read -r -d '' pdf_f; do
        curr_aux_epoch=$((curr_aux_epoch + 1))
        touch -d "@$curr_aux_epoch" "$pdf_f"
        pdf_fmt=$(format_tz_date "$curr_aux_epoch" "%Y-%m-%d %H:%M:%S (UTC%:z)")
        echo "   - $(basename "$pdf_f"): $pdf_fmt"
    done < <(find "$ext_dir" -type f -iname "*.pdf" -print0 | sort -z -V)

    echo "-> Applied new clean timestamps to Verification.txt and auxiliary files."

    # 8. Recompress using exact ultra-settings with live percentage, elapsed timer, and 99% memory check
    echo "8. Recompressing with ultra-settings (-m0=LZMA2, -mmt=8, -mx=9, -md=256m, -mfb=256, -ms=16g, -mqs=on)..."
    if [[ -e "$new_archive" || -L "$new_archive" ]]; then
        fail_game "-> ERROR: Target staging archive \"$new_archive\" already exists!"
    fi
    compress_start=$(date +%s)
    compress_log="$ext_dir/.compress_progress.log"
    active_new_archive="$new_archive"

    # Pass 1: Compress core game files into new archive (Block 0) inside PROCESSED_ROOT_DIR using exec so compress_pid is the 7z process itself
    (
        cd "$ext_dir" && exec 7z a "${SEVENZ_BASE_OPTS[@]}" -ms=16g \
             -- "$new_archive" "${core_game_relfiles[@]}" > "$compress_log" 2>&1
    ) &
    compress_pid=$!
    active_pid="$compress_pid"

    while kill -0 "$compress_pid" 2>/dev/null; do
        if ! check_memory_safety; then
            printf "\r\033[K"
            echo "-> CRITICAL ERROR: System memory reached 99% capacity!"
            echo "   Killing compression process to protect system stability."
            kill -9 "$compress_pid" 2>/dev/null || true
            wait "$compress_pid" 2>/dev/null || true
            active_pid=""
            fail_game
        fi
        pct="0"
        if [[ -f "$compress_log" ]]; then
            parsed_pct=$(tail -c 256 "$compress_log" 2>/dev/null | grep -oE '[0-9]{1,3}%' | tail -n 1 | tr -d '%' || true)
            if [[ -n "$parsed_pct" ]]; then
                pct="$parsed_pct"
            fi
        fi
        now=$(date +%s)
        elapsed=$((now - compress_start))
        printf "\r   Progress: %3d%% | Elapsed time: %02dm %02ds" "$pct" $((elapsed / 60)) $((elapsed % 60))
        sleep 1
    done

    if ! wait "$compress_pid" 2>/dev/null; then
        active_pid=""
        rm -f "$compress_log"
        printf "\r\033[K"
        fail_game "-> ERROR: Recompression failed for \"$base_name.7z\"."
    fi
    active_pid=""
    rm -f "$compress_log"

    # Pass 2: Append Verification.txt as a second independent ultra-compressed block
    if ! (
        cd "$ext_dir" && exec 7z a "${SEVENZ_BASE_OPTS[@]}" \
             -- "$new_archive" "Verification.txt" > /dev/null 2>&1
    ); then
        printf "\r\033[K"
        fail_game "-> ERROR: Failed to append Verification.txt to \"$base_name.7z\"."
    fi

    # Pass 3: Append optional auxiliary files (JXL and PDF) as a third independent ultra-compressed block
    aux_files=()
    while IFS= read -r -d '' aux_f; do
        aux_files+=("${aux_f#"$ext_dir"/}")
    done < <(find "$ext_dir" -type f -iname "*.jxl" -print0 | sort -z -V)

    while IFS= read -r -d '' aux_f; do
        aux_files+=("${aux_f#"$ext_dir"/}")
    done < <(find "$ext_dir" -type f -iname "*.pdf" -print0 | sort -z -V)

    if [[ ${#aux_files[@]} -gt 0 ]]; then
        if ! (
            cd "$ext_dir" && exec 7z a "${SEVENZ_BASE_OPTS[@]}" \
                 -- "$new_archive" "${aux_files[@]}" > /dev/null 2>&1
        ); then
            printf "\r\033[K"
            fail_game "-> ERROR: Failed to append auxiliary files to \"$base_name.7z\"."
        fi
    fi

    compress_end=$(date +%s)
    compress_duration=$((compress_end - compress_start))
    printf "\r\033[K"
    printf -- "-> Recompression finished in %dm %ds\n" $((compress_duration / 60)) $((compress_duration % 60))

    # 9. Verify integrity by checking internal CRCs and running optional integrity test
    echo "9. Verifying data integrity..."
    new_crc=$(get_game_crcs "$new_archive")

    # Guard clause: Fail fast if CRCs do not match
    if [[ "$orig_crc" != "$new_crc" ]]; then
        echo "-> ERROR: CRC mismatch detected for \"$base_name.7z\"!"
        echo "--- Original CRCs ---"
        awk '{print "  " $0}' <<< "$orig_crc"
        echo "--- New CRCs ---"
        awk '{print "  " $0}' <<< "$new_crc"
        echo "Leaving extracted files in \"$ext_dir\" and archive in \"$new_archive\" for you to inspect."
        if [[ "$USE_RAMDISK" -eq 1 ]]; then
            echo "Note: Extracted files in \"$ext_dir\" are on the ramdisk and will continue to occupy system RAM until removed."
        fi
        active_ext_dir=""
        active_new_archive=""
        exit 1
    fi

    echo "-> Verification Success! CRCs match perfectly:"
    awk '{print "  [CRC32] " $0}' <<< "$new_crc"

    # Verify the final compression format
    final_method=$(7z l -slt -sccUTF-8 -- "$new_archive" | awk '{ sub(/\r$/, ""); } /^Method = LZMA2:/ { if (!printed) { val = $0; sub(/^Method = /, "", val); print val; printed = 1 } }')
    if [[ "$final_method" != "LZMA2:28" ]]; then
        echo "⚠️  ALERT: Archive compressed using $final_method instead of LZMA2:28"
        echo "   (This is normal if the extracted game files are smaller than 256 MiB)"
    fi

    # Sub-step: Run 7z t archive integrity test if requested
    if [[ "$RUN_INTEGRITY_TEST" -eq 1 ]]; then
        echo "-> Archive integrity test (7z t)..."
        test_start=$(date +%s)

        7z t -- "$new_archive" > /dev/null 2>&1 &
        test_pid=$!
        active_pid="$test_pid"

        while kill -0 "$test_pid" 2>/dev/null; do
            if ! check_memory_safety; then
                printf "\r\033[K"
                echo "-> CRITICAL ERROR: System memory reached 99% capacity!"
                echo "   Killing archive integrity test process to protect system stability."
                kill -9 "$test_pid" 2>/dev/null || true
                wait "$test_pid" 2>/dev/null || true
                active_pid=""
                fail_game
            fi
            now=$(date +%s)
            elapsed=$((now - test_start))
            printf "\r   Elapsed time: %02dm %02ds" $((elapsed / 60)) $((elapsed % 60))
            sleep 1
        done

        test_rc=0
        wait "$test_pid" 2>/dev/null || test_rc=$?
        active_pid=""

        test_end=$(date +%s)
        test_duration=$((test_end - test_start))
        printf "\r\033[K"
        printf -- "-> Testing finished in %dm %ds\n" $((test_duration / 60)) $((test_duration % 60))

        if [[ "$test_rc" -eq 0 ]]; then
            echo "-> Archive integrity test: Passed."
        else
            echo "-> ERROR: Archive integrity test failed for \"$base_name.7z\"!"
            echo "Leaving extracted files in \"$ext_dir\" and archive in \"$new_archive\" for your inspection."
            if [[ "$USE_RAMDISK" -eq 1 ]]; then
                echo "Note: Extracted files in \"$ext_dir\" are on the ramdisk and will continue to occupy system RAM until removed."
            fi
            active_ext_dir=""
            active_new_archive=""
            exit 1
        fi
    fi

    # Measure new file size in bytes
    new_size=$(stat -c %s "$new_archive")

    # Aggregate global data stats
    total_orig_bytes=$((total_orig_bytes + orig_size))
    total_new_bytes=$((total_new_bytes + new_size))

    # 10. Move file and cleanup temporary directory
    echo "10. Finalizing archive and moving to destination..."

    # Stamp archive 1 second after the latest auxiliary file (Verification.txt, JXL, or PDF)
    archive_stamp_epoch=$((curr_aux_epoch + 1))
    touch -d "@$archive_stamp_epoch" "$new_archive"
    formatted_archive_stamp=$(format_tz_date "$archive_stamp_epoch" "%Y-%m-%d %H:%M:%S (UTC%:z)")
    echo "-> Stamped archive \"${base_name}.7z\" with timestamp: $formatted_archive_stamp"

    mv "$new_archive" "$file"
    active_new_archive=""
    echo "-> Updated archive in working directory."

    rm -rf "$ext_dir"
    active_ext_dir=""
    echo "-> Cleaned up temporary extracted files."

    mv -f "$file" "$GAMES_DIR/${base_name}.7z"
    echo "-> Moved cleaned archive to \"$GAMES_DIR/$base_name.7z\""

    processed_count=$((processed_count + 1))

    # Print size savings comparison as the final summary receipt for this archive
    report_savings "$orig_size" "$new_size"
done

# Remove temporary staging root directories once all archives are processed
cleanup_staging_roots

# Calculate global execution metrics
script_end_time=$(date +%s)
total_duration=$((script_end_time - script_start_time))
total_min=$((total_duration / 60))
total_sec=$((total_duration % 60))

echo "--------------------------------------------------"
echo "All done! Your cleaned PS2 library has been consolidated in \"$GAMES_DIR\"."
echo "Execution Summary:"
echo "  - Total time spent: ${total_min}m ${total_sec}s"
echo "  - Successfully processed: $processed_count"

if [[ "$processed_count" -gt 0 ]]; then
    awk -v orig="$total_orig_bytes" -v new="$total_new_bytes" '
    function format_diff_size(b,    mib, unit) {
        if (b < 0) b = -b;
        mib = b / 1048576;
        if (mib >= 0.001) {
            return sprintf("%.3f MiB", mib);
        }
        unit = (b == 1) ? "Byte" : "Bytes";
        return sprintf("%d %s", b, unit);
    }
    function format_diff_pct(p,    d, s) {
        if (p < 0) p = -p;
        if (p == 0) return "0.000";
        d = 3;
        while (d < 15 && (p * (10 ^ d)) < 1) {
            d++;
        }
        s = sprintf("%." d "f", p);
        if (d > 3 && s ~ /^0\.0*10$/) {
            s = substr(s, 1, length(s) - 1);
        }
        return s;
    }
    BEGIN {
        diff = orig - new;
        abs_diff = (diff < 0) ? -diff : diff;
        pct = (orig > 0) ? (abs_diff / orig) * 100 : 0;

        printf "\n  --- Total Library Data Impact ---\n"
        printf "  Original Total:  %.2f MiB (%.2f GiB)\n", orig / 1048576, orig / 1073741824
        printf "  Optimized Total: %.2f MiB (%.2f GiB)\n", new / 1048576, new / 1073741824
        if (diff > 0) {
            printf "  Overall Savings: Saved %s (%s%% smaller) ★\n", format_diff_size(abs_diff), format_diff_pct(pct)
        } else if (diff == 0) {
            printf "  Overall Savings: Identical size (0.000%% change)\n"
        } else {
            printf "  Overall Growth:  Grew by %s (%s%% larger) ⚠\n", format_diff_size(abs_diff), format_diff_pct(pct)
        }
    }'
fi
echo "--------------------------------------------------"
