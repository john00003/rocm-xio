#!/bin/sh
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Generate debian/changelog from CMakeLists.txt version and git metadata.
# Optionally writes debian/generated-release-notes.md for GitHub Releases.
# Intended for CI use.
#
# Environment:
#   GEN_CHANGELOG_ROLLING=1  — range from rolling tag (see below) to HEAD.
#   GEN_CHANGELOG_ROLLING_TAG=name — rolling tag (default: rocm-xio-latest).

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RELEASE_NOTES="${SCRIPT_DIR}/generated-release-notes.md"
ROLLING_TAG="${GEN_CHANGELOG_ROLLING_TAG:-rocm-xio-latest}"

MAJOR=$(sed -n \
  's/^set(ROCM_XIO_LIBRARY_MAJOR \([0-9]*\))/\1/p' \
  "${PROJECT_DIR}/CMakeLists.txt")
MINOR=$(sed -n \
  's/^set(ROCM_XIO_LIBRARY_MINOR \([0-9]*\))/\1/p' \
  "${PROJECT_DIR}/CMakeLists.txt")
PATCH=$(sed -n \
  's/^set(ROCM_XIO_LIBRARY_PATCH \([0-9]*\))/\1/p' \
  "${PROJECT_DIR}/CMakeLists.txt")

if [ -z "${MAJOR}" ] || [ -z "${MINOR}" ] \
   || [ -z "${PATCH}" ]; then
  echo "ERROR: failed to parse version from" \
    "CMakeLists.txt" >&2
  echo "  MAJOR='${MAJOR}' MINOR='${MINOR}'" \
    "PATCH='${PATCH}'" >&2
  exit 1
fi

VERSION="${MAJOR}.${MINOR}.${PATCH}"

SHORT_SHA="HEAD"
FULL_SHA=""
if command -v git >/dev/null 2>&1 && \
   git -C "${PROJECT_DIR}" rev-parse HEAD \
     >/dev/null 2>&1; then
  SHORT_SHA=$(git -C "${PROJECT_DIR}" \
    rev-parse --short HEAD)
  FULL_SHA=$(git -C "${PROJECT_DIR}" rev-parse HEAD)
  DEB_VERSION="${VERSION}~git${SHORT_SHA}"
else
  DEB_VERSION="${VERSION}"
fi

DIST=$(lsb_release -cs 2>/dev/null || echo "noble")
DATE=$(date -R)
DATE_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Determine git log range for changelog bullets (git only; same gate as
# FULL_SHA — avoids invoking git under set -e when unavailable).
RANGE=""
RANGE_LABEL=""
cd "${PROJECT_DIR}"

if [ -n "${FULL_SHA}" ]; then
  if [ "${GEN_CHANGELOG_ROLLING:-}" = "1" ]; then
    if git -C "${PROJECT_DIR}" rev-parse -q --verify \
      "refs/tags/${ROLLING_TAG}" >/dev/null 2>&1; then
      RANGE="${ROLLING_TAG}..HEAD"
      RANGE_LABEL="since tag \`${ROLLING_TAG}\`"
    else
      PREV_V=$(git -C "${PROJECT_DIR}" describe --tags --abbrev=0 \
        --match='v[0-9]*.[0-9]*.[0-9]*' HEAD 2>/dev/null \
        || true)
      if [ -n "${PREV_V}" ]; then
        RANGE="${PREV_V}..HEAD"
        RANGE_LABEL="since latest semver tag \`${PREV_V}\` (rolling tag absent)"
      else
        RANGE="HEAD"
        RANGE_LABEL="single revision (no prior tag)"
      fi
    fi
  else
    PREV_V=$(git -C "${PROJECT_DIR}" describe --tags --abbrev=0 \
      --match='v[0-9]*.[0-9]*.[0-9]*' HEAD~1 2>/dev/null \
      || true)
    if [ -n "${PREV_V}" ]; then
      RANGE="${PREV_V}..HEAD"
      RANGE_LABEL="since \`${PREV_V}\`"
    else
      RANGE="HEAD"
      RANGE_LABEL="initial or first tagged release"
    fi
  fi
else
  RANGE="HEAD"
  RANGE_LABEL="git unavailable (no revision range)"
fi

# Collect commit subjects (no merges), newest first, cap for Debian noise.
TMP_SUBJ=$(mktemp "${TMPDIR:-/tmp}/rocm-xio-changelog-subj.XXXXXX") \
  || exit 1
DEB_BULLETS=$(mktemp "${TMPDIR:-/tmp}/rocm-xio-deb-bullets.XXXXXX") \
  || {
    rm -f "${TMP_SUBJ}"
    exit 1
  }
trap 'rm -f "${TMP_SUBJ}" "${DEB_BULLETS}"' EXIT INT HUP
if [ -n "${FULL_SHA}" ]; then
  if [ "${RANGE}" = "HEAD" ]; then
    git -C "${PROJECT_DIR}" log --no-merges -n 1 \
      --pretty='%s' HEAD | head -n 80 > "${TMP_SUBJ}" || true
  else
    git -C "${PROJECT_DIR}" log --no-merges --pretty='%s' \
      "${RANGE}" | head -n 80 > "${TMP_SUBJ}" || true
  fi
fi

if [ ! -s "${TMP_SUBJ}" ]; then
  printf '%s\n' \
    "  * Automated build from git ${SHORT_SHA}" >> "${DEB_BULLETS}"
else
  while IFS= read -r line; do
    # Debian changelog: indent bullet; skip blank lines
    case "${line}" in
      '') continue ;;
      *) printf '%s\n' "  * ${line}" >> "${DEB_BULLETS}" ;;
    esac
  done < "${TMP_SUBJ}"
fi

{
  printf '%s\n' "rocm-xio (${DEB_VERSION}) ${DIST}; urgency=low"
  printf '%s\n' ""
  cat "${DEB_BULLETS}"
  printf '%s\n' ""
  printf '%s\n' \
    " -- AMD ROCm Build <rocm-xio@amd.com>  ${DATE}"
} > "${SCRIPT_DIR}/changelog"

# Markdown release notes (GitHub Release body).
HEAD_LINE="ROCm XIO ${DEB_VERSION}"
if [ "${GEN_CHANGELOG_ROLLING:-}" = "1" ]; then
  TITLE="# Rolling package build (\`${ROLLING_TAG}\`)"
else
  TITLE="# Release ${VERSION}"
fi

{
  printf '%s\n\n' "${TITLE}"
  printf '%s\n\n' "${HEAD_LINE}"
  printf '%s\n' "**Package version:** \`${DEB_VERSION}\`  "
  if [ -n "${FULL_SHA}" ]; then
    printf '%s\n' "**Commit:** \`${FULL_SHA}\`  "
  else
    printf '%s\n' "**Commit:** (git unavailable)  "
  fi
  printf '%s\n' "**Built:** ${DATE_ISO}  "
  printf '%s\n\n' "**Change range:** ${RANGE_LABEL}"
  if [ "${GEN_CHANGELOG_ROLLING:-}" = "1" ]; then
    printf '%s\n\n' \
"This pre-release is updated on each push to \`main\`. It may be less stable than a semver-tagged release; for production, prefer a tagged \`vX.Y.Z\` release."
  fi
  printf '%s\n\n' "## Changes"
  if [ ! -s "${TMP_SUBJ}" ]; then
    printf '%s\n' "* Automated build from git ${SHORT_SHA}"
  else
    while IFS= read -r line; do
      [ -z "${line}" ] && continue
      printf '* %s\n' "${line}"
    done < "${TMP_SUBJ}"
  fi
} > "${RELEASE_NOTES}"

echo "Generated debian/changelog: ${DEB_VERSION}"
echo "Generated ${RELEASE_NOTES}"
