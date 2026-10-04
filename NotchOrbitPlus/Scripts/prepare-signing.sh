#!/bin/bash
set -euo pipefail
set +x
task_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$task_root/build"
[[ "$(uname -s)" == Darwin ]] || { echo 'Signing preparation requires macOS.' >&2; exit 1; }
python3 - "$task_root/build/signing-credential-status.json" <<'PY'
import json, os, pathlib, sys
names = ['NOTCHORBITPLUS_DEVELOPER_ID_P12_BASE64', 'NOTCHORBITPLUS_DEVELOPER_ID_P12_PASSWORD',
         'NOTCHORBITPLUS_SIGNING_IDENTITY', 'NOTCHORBITPLUS_NOTARY_PROFILE',
         'NOTCHORBITPLUS_NOTARY_KEY_BASE64', 'NOTCHORBITPLUS_NOTARY_KEY_ID', 'NOTCHORBITPLUS_NOTARY_ISSUER_ID']
pathlib.Path(sys.argv[1]).write_text(json.dumps({'credential_bindings_present': {name: bool(os.environ.get(name)) for name in names}}, indent=2) + '\n')
PY
if [[ -z "${NOTCHORBITPLUS_DEVELOPER_ID_P12_BASE64:-}" ]]; then
  echo 'No Developer ID certificate import was requested; existing identity/profile bindings remain available.'
  exit 0
fi
[[ -n "${NOTCHORBITPLUS_DEVELOPER_ID_P12_PASSWORD:-}" ]] || { echo 'The provided certificate requires its secure password binding.' >&2; exit 1; }
[[ -n "${GITHUB_ENV:-}" && -n "${RUNNER_TEMP:-}" ]] || { echo 'Certificate import is supported in the ephemeral CI runner; local builds use an existing keychain identity.' >&2; exit 1; }
signing_directory="$(mktemp -d "$RUNNER_TEMP/notchorbitplus-signing.XXXXXX")"
chmod 700 "$signing_directory"
export NOTCHORBITPLUS_SIGNING_DIRECTORY="$signing_directory"
python3 - <<'PY'
import base64, os, pathlib
file = pathlib.Path(os.environ['NOTCHORBITPLUS_SIGNING_DIRECTORY']) / 'developer-id.p12'
file.write_bytes(base64.b64decode(os.environ['NOTCHORBITPLUS_DEVELOPER_ID_P12_BASE64'], validate=True)); file.chmod(0o600)
PY
keychain_path="$signing_directory/signing.keychain-db"
keychain_password="$(openssl rand -hex 32)"
security create-keychain -p "$keychain_password" "$keychain_path"
security set-keychain-settings -lut 21600 "$keychain_path"
security unlock-keychain -p "$keychain_password" "$keychain_path"
security import "$signing_directory/developer-id.p12" -k "$keychain_path" -P "$NOTCHORBITPLUS_DEVELOPER_ID_P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain_path" >/dev/null
rm "$signing_directory/developer-id.p12"
signing_identity="${NOTCHORBITPLUS_SIGNING_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
  signing_identity="$(security find-identity -v -p codesigning "$keychain_path" | python3 -c 'import re,sys; values=re.findall(r"\b([A-F0-9]{40})\s+\"Developer ID Application:",sys.stdin.read()); print(values[0] if len(values)==1 else "")')"
fi
[[ -n "$signing_identity" ]] || { echo 'Exactly one valid Developer ID Application identity is required.' >&2; exit 1; }
{
  echo "NOTCHORBITPLUS_SIGNING_IDENTITY=$signing_identity"
  echo "NOTCHORBITPLUS_SIGNING_KEYCHAIN=$keychain_path"
  echo "NOTCHORBITPLUS_SIGNING_DIRECTORY=$signing_directory"
} >> "$GITHUB_ENV"
if [[ -n "${NOTCHORBITPLUS_NOTARY_KEY_BASE64:-}" ]]; then
  [[ -n "${NOTCHORBITPLUS_NOTARY_KEY_ID:-}" && -n "${NOTCHORBITPLUS_NOTARY_ISSUER_ID:-}" ]] || { echo 'Notary API key ID and issuer bindings are required.' >&2; exit 1; }
  python3 - <<'PY'
import base64, os, pathlib
file = pathlib.Path(os.environ['NOTCHORBITPLUS_SIGNING_DIRECTORY']) / 'notary.p8'
file.write_bytes(base64.b64decode(os.environ['NOTCHORBITPLUS_NOTARY_KEY_BASE64'], validate=True)); file.chmod(0o600)
PY
  xcrun notarytool store-credentials notchorbitplus-ci --key "$signing_directory/notary.p8" --key-id "$NOTCHORBITPLUS_NOTARY_KEY_ID" --issuer "$NOTCHORBITPLUS_NOTARY_ISSUER_ID" --keychain "$keychain_path" >/dev/null
  rm "$signing_directory/notary.p8"
  echo 'NOTCHORBITPLUS_NOTARY_PROFILE=notchorbitplus-ci' >> "$GITHUB_ENV"
  echo "NOTCHORBITPLUS_NOTARY_KEYCHAIN=$keychain_path" >> "$GITHUB_ENV"
fi
echo 'Temporary signing keychain prepared; no credential values were printed.'
