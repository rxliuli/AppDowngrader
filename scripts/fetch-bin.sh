#!/usr/bin/env bash
#
# Fetch and assemble the third-party executables that ship inside
# AppDowngrader.app/Contents/Resources/bin, using scripts/binaries.json as the
# only source of truth.
#
# Why this exists rather than committing the binaries: the universal ipatool is
# ~100MB, which sits on GitHub's 100MiB per-file limit (the v2.8.0 push was
# rejected with "exceeds GitHub's file size limit"), and every Apple auth break
# costs another ~100MB of history. Here a bump is a manifest diff, and the
# diff is reviewable: version, url, sha256 are visible instead of "Bin 83MB ->
# 106MB".
#
# Usage:
#   scripts/fetch-bin.sh                  # all tools from the manifest
#   scripts/fetch-bin.sh --tool ipatool   # one tool
#   scripts/fetch-bin.sh --force          # ignore the cache
#
# Caching: the cache key is a hash of the manifest entry itself, so editing
# version/url/sha256 invalidates it automatically. BIN_CACHE_DIR relocates the
# cache (CI points it at a path that actions/cache restores).
#
# Requires: curl, python3 (stdlib only, for reading the JSON manifest), lipo,
# strip, tar, unzip - all present on macOS and on GitHub's macOS runners.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
MANIFEST=${BIN_MANIFEST:-"$SCRIPT_DIR/binaries.json"}
DEST_DIR="$REPO_ROOT/Sources/bin"
CACHE_ROOT=${BIN_CACHE_DIR:-"$HOME/Library/Caches/AppDowngrader/bin"}
# Bump when the assembly logic changes in a way that should invalidate caches.
FORMAT=1

force=0
only=""

usage() {
    sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --force) force=1 ;;
        --tool)
            [ $# -ge 2 ] || { echo "error: --tool needs a value" >&2; exit 2; }
            only=$2
            shift
            ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

[ -f "$MANIFEST" ] || { echo "error: manifest not found: $MANIFEST" >&2; exit 1; }

# Read the manifest. Records are joined with 0x1f so paths/URLs never collide
# with the separator.
manifest_query() {
    python3 - "$MANIFEST" "$FORMAT" "$@" <<'PY'
import hashlib
import json
import sys

path, fmt, mode = sys.argv[1], sys.argv[2], sys.argv[3]

with open(path) as handle:
    data = json.load(handle)

tools = data["tools"]


def emit(fields):
    sys.stdout.write("\x1f".join(str(f) for f in fields) + "\n")


def find(name):
    for tool in tools:
        if tool["name"] == name:
            return tool
    sys.exit("error: no tool named %r in %s" % (name, path))


if mode == "tools":
    for tool in tools:
        emit([tool["name"]])
elif mode == "tool":
    tool = find(sys.argv[4])
    canonical = json.dumps(tool, sort_keys=True, separators=(",", ":"))
    key = hashlib.sha256((fmt + canonical).encode()).hexdigest()[:12]
    emit([tool["name"], tool["version"], tool.get("strip", ""),
          ",".join(tool["archs"]), key])
elif mode == "inputs":
    for entry in find(sys.argv[4])["inputs"]:
        emit([entry["arch"], entry["sha256"], entry["member"], entry["url"]])
else:
    sys.exit("error: unknown manifest mode %r" % mode)
PY
}

sha256_of() {
    shasum -a 256 "$1" | awk '{print $1}'
}

# download URL SHA256 DEST: download unless DEST already holds exactly SHA256.
download() {
    local url=$1 sha=$2 dest=$3
    if [ -f "$dest" ] && [ "$(sha256_of "$dest")" = "$sha" ]; then
        return 0
    fi
    rm -f "$dest"
    echo "    downloading $(basename "$dest") from $(printf '%s' "$url" | sed 's|://[^/]*/|://…/|')"
    if ! curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 --progress-bar \
        -o "$dest" "$url"; then
        echo "error: download failed: $url" >&2
        rm -f "$dest"
        return 1
    fi
    local got
    got=$(sha256_of "$dest")
    if [ "$got" != "$sha" ]; then
        # Never leave a wrong file behind: the next run would trust it.
        rm -f "$dest"
        echo "error: sha256 mismatch for $url" >&2
        echo "  expected $sha" >&2
        echo "  got      $got" >&2
        return 1
    fi
}

# The cached file is named after its sha256, so the archive type has to come
# from the url rather than from the file name.
extract_archive() {
    local archive=$1 url=$2 dest=$3
    case "$url" in
        *.tar.gz|*.tgz) tar -xzf "$archive" -C "$dest" ;;
        *.zip) unzip -q -o "$archive" -d "$dest" ;;
        *) echo "error: unsupported archive type: $url" >&2; return 1 ;;
    esac
}

mkdir -p "$DEST_DIR" "$CACHE_ROOT"
work=$(mktemp -d "$CACHE_ROOT/.work.XXXXXX")
trap 'rm -rf "$work"' EXIT

names=$(manifest_query tools)
if [ -n "$only" ]; then
    if ! printf '%s\n' "$names" | grep -qx -- "$only"; then
        echo "error: no tool named '$only' in $MANIFEST" >&2
        exit 1
    fi
    names=$only
fi

while IFS= read -r name; do
    [ -n "$name" ] || continue

    tool_line=$(manifest_query tool "$name")
    IFS=$'\x1f' read -r _ version strip archs cachekey <<<"$tool_line"
    cache_dir="$CACHE_ROOT/$name-$version-$cachekey"
    staged="$cache_dir/$name"

    if [ "$force" -eq 0 ] && [ -f "$staged" ] && [ -x "$staged" ] &&
        [ "$(cat "$cache_dir/.stamp" 2>/dev/null)" = "$FORMAT:$cachekey" ]; then
        echo "==> $name $version (cached)"
    else
        echo "==> $name $version"
        mkdir -p "$cache_dir/downloads"
        slices=()
        while IFS=$'\x1f' read -r arch sha member url; do
            [ -n "$arch" ] || continue
            archive="$cache_dir/downloads/$sha.archive"
            download "$url" "$sha" "$archive"

            outdir="$work/extract-$name-$arch"
            mkdir -p "$outdir"
            extract_archive "$archive" "$url" "$outdir"

            if [ ! -f "$outdir/$member" ]; then
                echo "error: '$member' not found inside $(basename "$archive")" >&2
                exit 1
            fi
            slice="$work/slice-$name-$arch"
            cp "$outdir/$member" "$slice"
            slices+=("$slice")
        done < <(manifest_query inputs "$name")

        if [ "${#slices[@]}" -eq 0 ]; then
            echo "error: '$name' has no inputs in $MANIFEST" >&2
            exit 1
        fi

        assembled="$work/assembled-$name"
        if [ "${#slices[@]}" -eq 1 ]; then
            cp "${slices[0]}" "$assembled"
        else
            lipo -create "${slices[@]}" -output "$assembled"
        fi

        # strip is recorded in the manifest because it changes the artifact:
        # ipatool's universal build would otherwise exceed GitHub's file limit.
        if [ -n "$strip" ]; then
            strip "-$strip" "$assembled"
        fi
        chmod +x "$assembled"

        got_archs=$(lipo -archs "$assembled")
        for want in ${archs//,/ }; do
            case " $got_archs " in
                *" $want "*) ;;
                *)
                    echo "error: $name is missing arch '$want' (got: $got_archs)" >&2
                    exit 1
                    ;;
            esac
        done

        cp "$assembled" "$staged"
        printf '%s' "$FORMAT:$cachekey" >"$cache_dir/.stamp"
    fi

    cp "$staged" "$DEST_DIR/$name"
    chmod +x "$DEST_DIR/$name"
    printf '    -> %s (%s bytes, sha256 %s)\n' \
        "${DEST_DIR#"$REPO_ROOT"/}/$name" \
        "$(wc -c <"$DEST_DIR/$name" | tr -d ' ')" \
        "$(sha256_of "$DEST_DIR/$name")"
done <<<"$names"
