#!/usr/bin/env bash
# build.sh — build xray-container under linux/arm64 (MikroTik hAP ax3)
# and export it as an OCI tar that RouterOS can import via /container/add.
#
# Usage:
#   ./build.sh                              build local image only
#   ./build.sh --export                     also save to dist/xray-container.tar
#   ./build.sh --export --push HOST         scp the tar to admin@HOST:usb1/
#   ./build.sh --export --push HOST \
#              --slot disk1                 override the RouterOS disk slot
#
# Environment overrides:
#   IMAGE_TAG       (default: xray-container:latest)
#   IMAGE_PLATFORM  (default: linux/arm64)
#   BUILDER         (default: docker — also matches the nerdctl alias)
#   ROUTER_SLOT     (default: usb1 — RouterOS disk slot name)

set -o errexit
set -o nounset
set -o pipefail

IMAGE_TAG="${IMAGE_TAG:-xray-container:latest}"
IMAGE_PLATFORM="${IMAGE_PLATFORM:-linux/arm64}"
BUILDER="${BUILDER:-docker}"
ROUTER_SLOT="${ROUTER_SLOT:-usb1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${SCRIPT_DIR}/dist"
TAR_PATH="${DIST_DIR}/xray-container.tar"

export_tar=0
push_host=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --export)        export_tar=1; shift ;;
        --push)          push_host="$2"; export_tar=1; shift 2 ;;
        --tag)           IMAGE_TAG="$2"; shift 2 ;;
        --platform)      IMAGE_PLATFORM="$2"; shift 2 ;;
        --slot)          ROUTER_SLOT="$2"; shift 2 ;;
        --help|-h)
            # BSD/POSIX short flags below — this script runs on the host (macOS),
            # which ships BSD coreutils without GNU long-flag aliases.
            grep -E '^#( |$)' "${BASH_SOURCE[0]}" | cut -c3-
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

command -v "${BUILDER}" >/dev/null 2>&1 \
    || { echo "ERROR: '${BUILDER}' not found in PATH" >&2; exit 1; }

echo "building ${IMAGE_TAG} for ${IMAGE_PLATFORM}"
"${BUILDER}" build \
    --platform "${IMAGE_PLATFORM}" \
    --file "${SCRIPT_DIR}/Containerfile" \
    --tag "${IMAGE_TAG}" \
    --load \
    "${SCRIPT_DIR}"

if [ "${export_tar}" -eq 1 ]; then
    # BSD mkdir on macOS hosts has no --parents long alias.
    mkdir -p "${DIST_DIR}"
    echo "exporting ${IMAGE_TAG} → ${TAR_PATH}"
    "${BUILDER}" save --output "${TAR_PATH}" "${IMAGE_TAG}"
    # BSD du on macOS hosts has no --human-readable long alias.
    echo "tar size: $(du -h "${TAR_PATH}" | awk '{print $1}')"
fi

if [ -n "${push_host}" ]; then
    # RouterOS exposes disks by their slot name (see /disk/print). The scp
    # destination path is relative to the admin user's home, so writing to
    # `<slot>/` lands the file on the correct disk.
    echo "uploading to ${push_host}:${ROUTER_SLOT}/"
    scp "${TAR_PATH}" "admin@${push_host}:${ROUTER_SLOT}/xray-container.tar"
    echo "tar uploaded. On RouterOS run:"
    echo "    /container/add file=${ROUTER_SLOT}/xray-container.tar interface=veth-xray ..."
fi
