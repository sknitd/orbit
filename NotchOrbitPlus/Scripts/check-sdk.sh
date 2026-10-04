#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
[[ "$(uname -s)" == Darwin ]] || { echo 'NotchOrbitPlus needs genuine Xcode 26+ and the macOS 26+ SDK.' >&2; exit 1; }
xcode_version="$(xcodebuild -version)"
echo "$xcode_version"
if [[ "$xcode_version" =~ Xcode[[:space:]]+([0-9]+) ]]; then
  xcode_major="${BASH_REMATCH[1]}"
else
  echo 'Cannot identify the selected Xcode version.' >&2
  exit 1
fi
(( xcode_major >= 26 )) || { echo 'Select Xcode 26 or newer; FoundationModels must be compiled into NotchOrbitPlus.' >&2; exit 1; }
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
[[ "$sdk_version" =~ ^([0-9]+) ]] || { echo 'Cannot identify the selected macOS SDK.' >&2; exit 1; }
sdk_major="${BASH_REMATCH[1]}"
(( sdk_major >= 26 )) || { echo 'A macOS 26 or newer SDK is required for FoundationModels.' >&2; exit 1; }
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
[[ -d "$sdk_path/System/Library/Frameworks/FoundationModels.framework" ]] || { echo 'The selected SDK has no public FoundationModels framework.' >&2; exit 1; }
[[ -d "$sdk_path/System/Library/Frameworks/Translation.framework" ]] || { echo 'The selected SDK has no public Translation framework.' >&2; exit 1; }
host_arch="$(uname -m)"
[[ "$host_arch" == arm64 || "$host_arch" == x86_64 ]] || { echo 'Unsupported macOS host architecture.' >&2; exit 1; }
mkdir -p build/sdk-probe-cache
task_probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/notchorbitplus-sdk.XXXXXX")"
trap 'rm -rf "$task_probe_dir"' EXIT
cat > "$task_probe_dir/FoundationModelsProbe.swift" <<'SWIFT'
import FoundationModels
@available(macOS 26.0, *)
@MainActor
func foundationModelsProbe() {
    _ = SystemLanguageModel.default.availability
}
SWIFT
xcrun swiftc -typecheck -swift-version 6 -strict-concurrency=complete \
  -target "$host_arch-apple-macos14.0" -sdk "$sdk_path" \
  -module-cache-path "$task_root/build/sdk-probe-cache" "$task_probe_dir/FoundationModelsProbe.swift"
cat > "$task_probe_dir/TranslationSpeechProbe.swift" <<'SWIFT'
import Foundation
import Combine
import SwiftUI
import Translation
import Speech

@MainActor
final class ActorBindingSDKStore: NSObject, ObservableObject {
    @Published private(set) var enabled = false
    func setEnabled(_ enabled: Bool) { self.enabled = enabled }
    func refresh() { }
}

@MainActor
struct ActorBindingSDKProbe: View {
    @ObservedObject private var store = ActorBindingSDKStore()
    var body: some View {
        VStack {
            Toggle("Explicit actor binding", isOn: Binding(
                get: { store.enabled }, set: { store.setEnabled($0) }))
            HStack {
                Button("Refresh") { store.refresh() }
                Button("Disable") { store.setEnabled(false) }
            }
        }
    }
}

struct TranslationSDKRequest: Sendable {
    let id: UUID
    let text: String
}

@MainActor
final class TranslationSDKStore {
    var request: TranslationSDKRequest? = .init(id: UUID(), text: "Hello")
    func isCurrent(_ id: UUID) -> Bool { request?.id == id }
    func prepared(_ id: UUID) { }
    func complete(_ id: UUID, text: String) { }
    func fail(_ id: UUID, message: String) { }
}

@available(macOS 15.0, *)
@MainActor
struct TranslationSDKProbe: View {
    private let store = TranslationSDKStore()
    @State private var configuration: TranslationSession.Configuration? = .init(
        source: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "es"))
    var body: some View {
        Text("SDK probe").translationTask(configuration, action: Self.translationAction(store: store))
    }
    nonisolated static func translationAction(store: TranslationSDKStore) -> @Sendable (TranslationSession) async -> Void {
        { session in
            guard let request = await store.request, await store.isCurrent(request.id) else { return }
            do {
                try Task.checkCancellation()
                try await session.prepareTranslation()
                try Task.checkCancellation()
                guard await store.isCurrent(request.id) else { return }
                await store.prepared(request.id)
                let result = try await session.translate(request.text)
                try Task.checkCancellation()
                await store.complete(request.id, text: result.targetText)
            } catch { await store.fail(request.id, message: error.localizedDescription) }
        }
    }
    func invalidate() { configuration?.invalidate() }
}

@MainActor
func onDeviceSpeechSDKProbe() {
    let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    _ = recognizer?.supportsOnDeviceRecognition
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.requiresOnDeviceRecognition = true
}
SWIFT
for architecture in arm64 x86_64; do
  xcrun swiftc -emit-object -parse-as-library -swift-version 6 -strict-concurrency=complete \
    -target "$architecture-apple-macos14.0" -sdk "$sdk_path" \
    -module-cache-path "$task_root/build/sdk-probe-cache" \
    -o "$task_probe_dir/TranslationSpeech-$architecture.o" "$task_probe_dir/TranslationSpeechProbe.swift"
  [[ -s "$task_probe_dir/TranslationSpeech-$architecture.o" ]]
done
swift_version="$(xcrun swiftc --version)"
python3 - "$xcode_version" "$sdk_version" "$sdk_path" "$swift_version" "$host_arch" "$task_probe_dir" <<'PY'
import hashlib, json, pathlib, struct, sys
probe = pathlib.Path(sys.argv[6])
objects = []
for architecture, cpu in [('arm64', 0x100000c), ('x86_64', 0x1000007)]:
    data = (probe / f'TranslationSpeech-{architecture}.o').read_bytes()
    if len(data) < 32:
        raise SystemExit(f'Missing generated SDK probe object for {architecture}.')
    magic, actual_cpu, subtype, filetype = struct.unpack_from('<IIII', data)
    if magic != 0xfeedfacf or actual_cpu != cpu or filetype != 1:
        raise SystemExit(f'The generated SDK probe is not a {architecture} Mach-O object.')
    objects.append({'architecture': architecture, 'mach_o_cpu': hex(actual_cpu),
                    'file_type': 'MH_OBJECT', 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
pathlib.Path('build/sdk-inventory.json').write_text(json.dumps({
    'xcode': sys.argv[1], 'macos_sdk': sys.argv[2], 'sdk_path': sys.argv[3],
    'swift': sys.argv[4], 'host_architecture': sys.argv[5],
    'deployment_target': '14.0', 'foundation_models_api_typechecked': True,
    'translation_api_typechecked': True, 'on_device_speech_api_typechecked': True,
    'translation_nonisolated_session_action_typechecked': True,
    'translation_speech_probe_architectures': ['arm64', 'x86_64'],
    'translation_speech_probe_codegen_verified': True,
    'main_actor_bool_binding_codegen_verified': True,
    'translation_speech_probe_source_sha256': hashlib.sha256((probe / 'TranslationSpeechProbe.swift').read_bytes()).hexdigest(),
    'translation_speech_probe_objects': objects
}, indent=2) + '\n')
PY
echo "SDK $sdk_version verified: FoundationModels typecheck and both-CPU Translation, Speech and explicit actor-binding object generation passed with deployment target 14.0."
