#!/bin/bash
set -euo pipefail
[[ "$(uname -s)" == Linux ]] || { swift --version; exit 0; }
task_tools=/workspace/toolchains
task_release=swift-6.2-RELEASE-ubuntu24.04
task_archive="$task_tools/downloads/$task_release.tar.gz"
task_base_url=https://download.swift.org/swift-6.2-release/ubuntu2404/swift-6.2-RELEASE
task_key_commit=168af46abefc73c39e214c058af328c735db22c8
mkdir -p "$task_tools/downloads" "$task_tools/gnupg"
chmod 700 "$task_tools/gnupg"
if [[ ! -f "$task_archive" ]]; then
  curl --fail --silent --show-error --location "$task_base_url/$task_release.tar.gz" --output "$task_archive"
fi
if [[ ! -f "$task_archive.sig" ]]; then
  curl --fail --silent --show-error --location "$task_base_url/$task_release.tar.gz.sig" --output "$task_archive.sig"
fi
if [[ ! -d "$task_tools/swift-org-website/.git" ]]; then
  git clone --depth 1 --filter=blob:none --sparse https://github.com/swiftlang/swift-org-website.git "$task_tools/swift-org-website"
  git -C "$task_tools/swift-org-website" sparse-checkout set keys
fi
if [[ -n "$(git -C "$task_tools/swift-org-website" status --porcelain)" ]]; then
  echo 'The toolchain signing-key cache has local changes. Preserve them before refreshing it.' >&2
  exit 1
fi
git -C "$task_tools/swift-org-website" fetch --depth 1 origin "$task_key_commit"
git -C "$task_tools/swift-org-website" checkout --detach "$task_key_commit"
[[ "$(git -C "$task_tools/swift-org-website" rev-parse HEAD)" == "$task_key_commit" ]]
gpg --homedir "$task_tools/gnupg" --batch --import "$task_tools/swift-org-website/keys/all-keys.asc"
gpg --homedir "$task_tools/gnupg" --batch --status-fd 1 --verify "$task_archive.sig" "$task_archive" > "$task_tools/downloads/signature-status.txt"
# Authenticate the historical release signature against its pinned public key.
rg -q '^\[GNUPG:\] VALIDSIG 52BB7E3DE28A71BE22EC05FFEF80A866B47A981F ' "$task_tools/downloads/signature-status.txt"
if [[ ! -x "$task_tools/$task_release/usr/bin/swift" ]]; then tar -xzf "$task_archive" -C "$task_tools"; fi
"$task_tools/$task_release/usr/bin/swift" --version
