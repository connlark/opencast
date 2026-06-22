#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

swift_category="$(
  sed -nE 's/^[[:space:]]*static let episode = "([^"]+)".*$/\1/p' \
    "${repo_dir}/OpenCast/App/OpenCastNotificationCategory.swift" |
    head -n 1
)"
plist_category="$(
  /usr/libexec/PlistBuddy -c \
    'Print :NSExtension:NSExtensionAttributes:UNNotificationExtensionCategory' \
    "${repo_dir}/OpenCastNotificationContent/Info.plist"
)"
rust_category="$(
  sed -nE 's/^const EPISODE_NOTIFICATION_CATEGORY: &str = "([^"]+)";$/\1/p' \
    "${repo_dir}/Server/NotificationsWorker/src/apns.rs" |
    head -n 1
)"

if [[ -z "${swift_category}" || -z "${plist_category}" || -z "${rust_category}" ]]; then
  echo "Failed to read one or more notification category values." >&2
  exit 1
fi

if [[ "${swift_category}" != "${plist_category}" || "${swift_category}" != "${rust_category}" ]]; then
  cat >&2 <<EOF
Notification category drift detected:
  OpenCastNotificationCategory.episode: ${swift_category}
  OpenCastNotificationContent Info.plist: ${plist_category}
  NotificationsWorker APNs category: ${rust_category}
EOF
  exit 1
fi

echo "Notification category values match: ${swift_category}"
