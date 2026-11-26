#!/usr/bin/env bash
set -euo pipefail
umask 077

if [[ $# != 3 ]]; then
  printf 'Usage: %s GPG_RECIPIENT NEW_BACKUP_DIR STORAGE_DIR\n' "$0" >&2
  exit 2
fi
recipient=$1
destination=$2
storage=$3
[[ -d "$storage" ]] || { echo 'Storage directory does not exist' >&2; exit 2; }
[[ -n "${PGSERVICE:-}" ]] || { echo 'Configure PGSERVICE for the backup database' >&2; exit 2; }
for executable in pg_dump pg_dumpall gpg tar sha256sum; do
  command -v "$executable" >/dev/null
done
gpg --batch --list-keys -- "$recipient" >/dev/null
mkdir -- "$destination"
work=$(mktemp -d "$destination/.incomplete.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT

encrypt() {
  gpg --batch --trust-model always --recipient "$recipient" --encrypt > "$1"
}

# Default dump includes application and managed schemas, grants and migration history.
# No unencrypted SQL archive is written to disk.
pg_dump --format=custom | encrypt "$work/database.dump.gpg"
pg_dumpall --roles-only --no-role-passwords --database=postgres | encrypt "$work/roles.sql.gpg"
tar -C "$storage" -cf - . | encrypt "$work/storage.tar.gpg"

(
  cd "$work"
  sha256sum database.dump.gpg roles.sql.gpg storage.tar.gpg > SHA256SUMS
)
for file in database.dump.gpg roles.sql.gpg storage.tar.gpg SHA256SUMS; do
  mv -- "$work/$file" "$destination/$file"
done
printf 'Encrypted backup completed: %s\n' "$destination"
