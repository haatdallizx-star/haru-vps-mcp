#!/usr/bin/env bash
#
# Clone the pinned xtool upstream, apply the HealthKit background-delivery
# patch, and build the result. We deliberately do NOT vendor xtool's source
# into this repo -- only the pin + the patch live here.
#
# Usage:
#   ./build-patched-xtool.sh prepare   # clone at pin + apply patch
#   ./build-patched-xtool.sh test      # run the test suite
#   ./build-patched-xtool.sh build     # build the xtool binary
#   ./build-patched-xtool.sh all       # prepare + test + build   (default)
#
# Env:
#   WORK_DIR   where the upstream checkout lives (default: ./.work/xtool)
#   FORCE=1    wipe an existing checkout instead of failing
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=upstream.pin
source "${SCRIPT_DIR}/upstream.pin"

# Track whether the caller explicitly set WORK_DIR so FORCE can never delete an
# arbitrary path. Only the script-managed default may be wiped. Deliberately no
# pipeline here: with `pipefail`, `env | grep -q` can SIGPIPE-fail when the env
# is large, which would silently flip this to "explicit" and weaken the guard.
if [[ -n "${WORK_DIR+x}" ]]; then
  EXPLICIT_WORK_DIR=1
else
  EXPLICIT_WORK_DIR=0
fi
DEFAULT_WORK_DIR="${SCRIPT_DIR}/.work/xtool"
WORK_DIR="${WORK_DIR:-${DEFAULT_WORK_DIR}}"
PATCH_PATH="${SCRIPT_DIR}/${XTOOL_PATCH}"
# Bind the image tag to the pinned upstream commit so a new pin rebuilds the image.
DEV_IMAGE="xtool-healthkit-dev:${XTOOL_COMMIT:0:12}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

is_macos() { [[ "$(uname -s)" == "Darwin" ]]; }

prepare() {
  [[ -f "${PATCH_PATH}" ]] || die "patch not found: ${PATCH_PATH}"

  if [[ -d "${WORK_DIR}" ]]; then
    if [[ "${EXPLICIT_WORK_DIR}" == "1" ]]; then
      # Never let FORCE destroy a caller-chosen directory, even if it exists.
      die "refusing to remove '${WORK_DIR}': WORK_DIR was set explicitly and exists; pick another path or move it aside"
    fi
    if [[ "${FORCE:-0}" == "1" ]]; then
      log "removing existing default checkout ${WORK_DIR}"
      rm -rf "${WORK_DIR}"
    else
      die "${WORK_DIR} already exists (set FORCE=1 to recreate)"
    fi
  fi

  log "cloning ${XTOOL_REPO} @ ${XTOOL_COMMIT} (${XTOOL_DESCRIBE})"
  mkdir -p "$(dirname "${WORK_DIR}")"
  git clone --quiet "${XTOOL_REPO}" "${WORK_DIR}"
  git -C "${WORK_DIR}" checkout --quiet "${XTOOL_COMMIT}"

  local actual
  actual="$(git -C "${WORK_DIR}" rev-parse HEAD)"
  [[ "${actual}" == "${XTOOL_COMMIT}" ]] \
    || die "checkout mismatch: expected ${XTOOL_COMMIT}, got ${actual}"

  log "applying ${XTOOL_PATCH}"
  git -C "${WORK_DIR}" apply --check "${PATCH_PATH}" \
    || die "patch does not apply cleanly to ${XTOOL_COMMIT}"
  git -C "${WORK_DIR}" apply "${PATCH_PATH}"

  log "patched checkout ready at ${WORK_DIR}"
}

ensure_prepared() {
  [[ -d "${WORK_DIR}" ]] || die "no checkout at ${WORK_DIR}; run '$0 prepare' first"
}

# On Linux, xtool needs libimobiledevice/libxadi, which upstream's Dockerfile
# builds as the "dev" stage. On macOS we can build natively.
ensure_dev_image() {
  command -v docker >/dev/null 2>&1 || die "docker is required to build xtool on Linux"
  if ! docker image inspect "${DEV_IMAGE}" >/dev/null 2>&1; then
    log "building ${DEV_IMAGE} (first run only; this takes a while)"
    docker build --target dev -t "${DEV_IMAGE}" "${WORK_DIR}"
  fi
}

run_swift() {
  if is_macos; then
    ( cd "${WORK_DIR}" && swift "$@" )
  else
    ensure_dev_image
    docker run --rm -v "${WORK_DIR}:/xtool" -w /xtool "${DEV_IMAGE}" swift "$@"
  fi
}

do_test() {
  ensure_prepared
  log "running tests"
  run_swift test
}

do_build() {
  ensure_prepared
  log "building xtool"
  run_swift build --product xtool -c release
  if is_macos; then
    log "binary: ${WORK_DIR}/.build/release/xtool"
  else
    log "binary (inside container path): ${WORK_DIR}/.build/release/xtool"
  fi
}

case "${1:-all}" in
  prepare) prepare ;;
  test)    do_test ;;
  build)   do_build ;;
  all)     prepare; do_test; do_build ;;
  *)       die "unknown command: ${1}" ;;
esac
