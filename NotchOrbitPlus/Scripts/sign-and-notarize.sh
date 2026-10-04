#!/bin/bash
set -euo pipefail
set +x
task_root="$(cd "$(dirname "$0")/.." && pwd)"
app_path="${1:?Pass the application bundle path.}"
mkdir -p "$task_root/build"
signing_identity="${NOTCHORBITPLUS_SIGNING_IDENTITY:-}"
notary_profile="${NOTCHORBITPLUS_NOTARY_PROFILE:-}"
notarized=false
signature_kind=adhoc
signing_arguments=()
if [[ -n "${NOTCHORBITPLUS_SIGNING_KEYCHAIN:-}" ]]; then signing_arguments+=(--keychain "$NOTCHORBITPLUS_SIGNING_KEYCHAIN"); fi
if [[ -n "$signing_identity" ]]; then
  entitlements="$task_root/build/distribution-entitlements.plist"
  python3 - "$app_path/Contents/Info.plist" "$entitlements" <<'PY'
import pathlib, plistlib, sys
info=plistlib.loads(pathlib.Path(sys.argv[1]).read_bytes())
rights={'com.apple.security.device.camera':True,'com.apple.security.automation.apple-events':True}
if 'NSMicrophoneUsageDescription' in info: rights['com.apple.security.device.audio-input']=True
pathlib.Path(sys.argv[2]).write_bytes(plistlib.dumps(rights))
PY
  codesign --force --deep --options runtime --timestamp --entitlements "$entitlements" --sign "$signing_identity" "${signing_arguments[@]}" "$app_path"
  codesign --verify --deep --strict -R 'anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and identifier "com.sknitd.NotchOrbitPlus"' "$app_path"
  signature_kind=developer-id
else
  [[ -z "$notary_profile" ]] || { echo 'Notarization requires a Developer ID signing identity.' >&2; exit 1; }
  codesign --force --deep --sign - "$app_path"
fi
codesign --verify --deep --strict "$app_path"
if [[ -n "$notary_profile" ]]; then
  notary_archive="$task_root/build/NotchOrbitPlus-notary.zip"
  ditto -c -k --sequesterRsrc --keepParent "$app_path" "$notary_archive"
  notary_arguments=(--keychain-profile "$notary_profile")
  if [[ -n "${NOTCHORBITPLUS_NOTARY_KEYCHAIN:-}" ]]; then notary_arguments+=(--keychain "$NOTCHORBITPLUS_NOTARY_KEYCHAIN"); fi
  xcrun notarytool submit "$notary_archive" "${notary_arguments[@]}" --wait --timeout 20m --output-format json > "$task_root/build/notary-submit.json"
  python3 - "$task_root/build/notary-submit.json" <<'PY'
import json,pathlib,sys
if json.loads(pathlib.Path(sys.argv[1]).read_text()).get('status')!='Accepted': raise SystemExit('Apple did not accept this notarization submission.')
PY
  xcrun stapler staple "$app_path"
  xcrun stapler validate "$app_path"
  codesign --verify --deep --strict "$app_path"
  spctl --assess --type execute --verbose=2 "$app_path"
  notarized=true
  rm "$notary_archive"
fi
export NOTCHORBITPLUS_REPORT_SIGNATURE_KIND="$signature_kind" NOTCHORBITPLUS_REPORT_NOTARIZED="$notarized"
python3 - "$app_path" "$task_root/build/distribution-signing.json" <<'PY'
import json,os,pathlib,re,subprocess,sys
result=subprocess.run(['codesign','-dv','--verbose=4',sys.argv[1]],capture_output=True,text=True,check=True)
match=re.search(r'^TeamIdentifier=([A-Z0-9]{10})$',result.stderr,re.M)
kind=os.environ['NOTCHORBITPLUS_REPORT_SIGNATURE_KIND']; notarized=os.environ['NOTCHORBITPLUS_REPORT_NOTARIZED']=='true'
if kind=='developer-id' and not match: raise SystemExit('Developer ID signature lacks its actual Team Identifier.')
pathlib.Path(sys.argv[2]).write_text(json.dumps({'kind':kind,'team_identifier':match.group(1) if match else None,
 'notarized':notarized,'notarization_status':'accepted_and_stapled' if notarized else 'pending_credentials',
 'codesign_verified':True,'hardened_runtime':kind=='developer-id'},indent=2)+'\n')
PY
echo "Distribution signature: $signature_kind; notarized: $notarized."
