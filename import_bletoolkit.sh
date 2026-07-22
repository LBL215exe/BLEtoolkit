#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
archive_path="${1:-$repo_root/BLEToolkit.tar.gz.tar}"
commit_message="${COMMIT_MESSAGE:-BLE Toolkit iOS app}"
push_enabled="${PUSH:-0}"
push_remote="${PUSH_REMOTE:-origin}"
push_branch="${PUSH_BRANCH:-}"

if [[ ! -f "$archive_path" ]]; then
  echo "Archive not found: $archive_path" >&2
  exit 1
fi

if ! command -v tar >/dev/null 2>&1; then
  echo "tar is required but was not found" >&2
  exit 1
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

mkdir -p "$repo_root"

extract_dir="$work_dir/extracted"
mkdir -p "$extract_dir"
tar -xzf "$archive_path" -C "$extract_dir" >/dev/null

source_dir="$extract_dir/BLEToolkit"
if [[ ! -d "$source_dir" ]]; then
  shopt -s nullglob
  candidates=("$extract_dir"/*)
  if [[ ${#candidates[@]} -eq 1 && -d "${candidates[0]}" ]]; then
    source_dir="${candidates[0]}"
  else
    echo "Could not locate the extracted BLEToolkit directory" >&2
    exit 1
  fi
fi

shopt -s dotglob
cp -a "$source_dir"/. "$repo_root"/

if git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "$repo_root" add -A

  if git -C "$repo_root" diff --cached --quiet; then
    echo "No changes to commit."
  else
    git -C "$repo_root" commit -m "$commit_message"
  fi

  if [[ "$push_enabled" == "1" ]]; then
    if [[ -z "$push_branch" ]]; then
      push_branch="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD)"
    fi
    git -C "$repo_root" push "$push_remote" "$push_branch"
  fi
else
  echo "Git repository not found; skipped commit/push steps."
fi

echo "BLEToolkit imported into $repo_root"
