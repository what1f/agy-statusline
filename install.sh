#!/bin/sh
set -eu

REPO="${AGY_STATUSLINE_REPO:-what1f/agy-statusline}"
AGY_HOME="${AGY_HOME:-$HOME/.gemini/antigravity-cli}"
DEST_BIN="$AGY_HOME/statusline"
SETTINGS_PATH="$AGY_HOME/settings.json"

FROM_SOURCE=0
YES=0
NO_CONFIG=0
VERSION="latest"

usage() {
    cat <<'EOF'
Install agy-statusline for Antigravity CLI.

Usage:
  install.sh [options]

Options:
  --from-source       Build from local source using zig instead of downloading a release
  --version <tag>     Install a specific release tag (default: latest)
  -y, --yes           Overwrite existing statusLine in settings.json without prompting
  --no-config         Install binary only; do not modify settings.json
  -h, --help          Show this help
EOF
}

log() {
    printf '%s\n' "$*"
}

err() {
    printf 'Error: %s\n' "$*" >&2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --from-source)
            FROM_SOURCE=1
            shift
            ;;
        -y|--yes)
            YES=1
            shift
            ;;
        --no-config)
            NO_CONFIG=1
            shift
            ;;
        --version)
            if [ "$#" -lt 2 ]; then
                err "--version requires a tag argument"
                exit 1
            fi
            VERSION="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            err "Unknown option: $1"
            usage >&2
            exit 1
            ;;
    esac
done

detect_target() {
    os_name="$(uname -s)"
    arch_name="$(uname -m)"

    case "$os_name" in
        Darwin) os="macos" ;;
        Linux) os="linux-musl" ;;
        *)
            err "Unsupported OS: $os_name (supported: macOS, Linux)"
            exit 1
            ;;
    esac

    case "$arch_name" in
        arm64|aarch64) arch="aarch64" ;;
        x86_64|amd64) arch="x86_64" ;;
        *)
            err "Unsupported architecture: $arch_name (supported: arm64/aarch64, x86_64)"
            exit 1
            ;;
    esac

    printf '%s-%s' "$arch" "$os"
}

download_file() {
    url="$1"
    dest="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$dest"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$dest" "$url"
    else
        err "Neither curl nor wget is installed"
        return 1
    fi
}

verify_checksum() {
    archive_path="$1"
    archive_name="$2"
    sums_path="$3"

    expected="$(awk -v name="$archive_name" '$2 == name || $2 == ("*" name) { print $1; exit }' "$sums_path")"
    if [ -z "$expected" ]; then
        return 0
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        actual="$(sha256sum "$archive_path" | awk '{ print $1 }')"
    elif command -v shasum >/dev/null 2>&1; then
        actual="$(shasum -a 256 "$archive_path" | awk '{ print $1 }')"
    else
        return 0
    fi

    if [ "$actual" != "$expected" ]; then
        err "Checksum mismatch for $archive_name"
        return 1
    fi
}

build_from_source() {
    out_prefix="$1"
    if [ ! -f "build.zig" ]; then
        err "build.zig not found in current directory. Clone the repository first or omit --from-source."
        exit 1
    fi
    if ! command -v zig >/dev/null 2>&1; then
        err "zig is required for --from-source"
        exit 1
    fi
    log "Building agy-statusline from source..."
    zig build -Doptimize=ReleaseFast --prefix "$out_prefix"
}

TMP_DIR="$(mktemp -d)"
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

if [ "$FROM_SOURCE" -eq 1 ]; then
    build_from_source "$TMP_DIR/out"
    BUILT_BIN="$TMP_DIR/out/bin/statusline"
else
    TARGET="$(detect_target)"
    ARCHIVE_NAME="agy-statusline-${TARGET}.tar.gz"
    if [ "$VERSION" = "latest" ]; then
        BASE_URL="https://github.com/${REPO}/releases/latest/download"
    else
        BASE_URL="https://github.com/${REPO}/releases/download/${VERSION}"
    fi

    ARCHIVE_PATH="$TMP_DIR/$ARCHIVE_NAME"
    SUMS_PATH="$TMP_DIR/checksums.txt"

    log "Downloading $ARCHIVE_NAME ($VERSION)..."
    if download_file "$BASE_URL/$ARCHIVE_NAME" "$ARCHIVE_PATH"; then
        if download_file "$BASE_URL/checksums.txt" "$SUMS_PATH" 2>/dev/null; then
            verify_checksum "$ARCHIVE_PATH" "$ARCHIVE_NAME" "$SUMS_PATH"
        fi
        tar -xzf "$ARCHIVE_PATH" -C "$TMP_DIR"
        BUILT_BIN="$TMP_DIR/statusline"
    elif [ -f "build.zig" ] && command -v zig >/dev/null 2>&1; then
        log "Release download unavailable; falling back to local source build..."
        build_from_source "$TMP_DIR/out"
        BUILT_BIN="$TMP_DIR/out/bin/statusline"
    else
        err "Failed to download $BASE_URL/$ARCHIVE_NAME"
        exit 1
    fi
fi

if [ ! -f "$BUILT_BIN" ]; then
    err "Installed binary not found at $BUILT_BIN"
    exit 1
fi

mkdir -p "$AGY_HOME"
STAGE_BIN="$DEST_BIN.tmp.$$"
cp "$BUILT_BIN" "$STAGE_BIN"
chmod 755 "$STAGE_BIN"
mv -f "$STAGE_BIN" "$DEST_BIN"
log "Installed binary to $DEST_BIN"

if [ "$NO_CONFIG" -eq 1 ]; then
    exit 0
fi

if [ "$AGY_HOME" = "$HOME/.gemini/antigravity-cli" ]; then
    COMMAND_VALUE='~/.gemini/antigravity-cli/statusline'
else
    COMMAND_VALUE="$DEST_BIN"
fi

run_settings_python() {
    mode="$1"
    python3 - "$SETTINGS_PATH" "$COMMAND_VALUE" "$DEST_BIN" "$mode" <<'PY'
import json
import os
import stat
import sys

settings_path, command_value, dest_bin, mode = sys.argv[1:5]

def norm(p: str) -> str:
    return os.path.realpath(os.path.expanduser(p))

data = {}
file_mode = None
if os.path.exists(settings_path):
    try:
        file_mode = stat.S_IMODE(os.stat(settings_path).st_mode)
        with open(settings_path, "r", encoding="utf-8") as f:
            raw = f.read().strip()
            if raw:
                loaded = json.loads(raw)
                if not isinstance(loaded, dict):
                    sys.stderr.write("settings.json root is not a JSON object.\n")
                    sys.exit(2)
                data = loaded
    except (OSError, json.JSONDecodeError) as exc:
        sys.stderr.write(f"Could not parse {settings_path}: {exc}\n")
        sys.exit(2)

existing = data.get("statusLine")
if mode != "force" and existing is not None:
    if isinstance(existing, dict):
        ex_type = existing.get("type", "command")
        ex_cmd = existing.get("command", "")
        ex_enabled = existing.get("enabled", True)
        if (
            ex_type == "command"
            and isinstance(ex_cmd, str)
            and ex_cmd
            and norm(ex_cmd) == norm(dest_bin)
            and ex_enabled is not False
        ):
            print(f"statusLine is already configured in {settings_path}")
            sys.exit(0)
    print(json.dumps(existing, ensure_ascii=False))
    sys.exit(10)

data["statusLine"] = {
    "type": "command",
    "command": command_value,
}

tmp_path = f"{settings_path}.tmp.{os.getpid()}"
with open(tmp_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")

if file_mode is not None:
    os.chmod(tmp_path, file_mode)
os.replace(tmp_path, settings_path)
print(f"Configured statusLine in {settings_path}")
PY
}

if command -v python3 >/dev/null 2>&1; then
    set +e
    OUT="$(run_settings_python check)"
    RC=$?
    set -e

    case "$RC" in
        0)
            [ -n "$OUT" ] && log "$OUT"
            ;;
        10)
            if [ "$YES" -eq 1 ]; then
                run_settings_python force
            elif ( : </dev/tty && : >/dev/tty ) 2>/dev/null; then
                log "Existing statusLine found in $SETTINGS_PATH:"
                log "  $OUT"
                printf 'Overwrite existing statusLine configuration? [y/N] ' >/dev/tty
                read -r answer </dev/tty || answer=""
                case "$answer" in
                    y|Y|yes|YES)
                        run_settings_python force
                        ;;
                    *)
                        log "Kept existing settings.json unchanged."
                        log "To switch later, run inside Antigravity CLI:"
                        log "  /statusline $COMMAND_VALUE"
                        ;;
                esac
            else
                log "Existing statusLine found in $SETTINGS_PATH: $OUT"
                log "Skipped overwriting in non-interactive mode. Re-run with --yes or run inside Antigravity CLI:"
                log "  /statusline $COMMAND_VALUE"
            fi
            ;;
        *)
            err "Skipped updating $SETTINGS_PATH automatically."
            log "Configure manually inside Antigravity CLI:"
            log "  /statusline $COMMAND_VALUE"
            ;;
    esac
else
    log "python3 not found; skipped automatic settings.json update."
    log "Activate inside Antigravity CLI:"
    log "  /statusline $COMMAND_VALUE"
fi
