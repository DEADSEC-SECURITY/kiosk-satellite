# Wake recording trial

This fork records up to five seconds of native inference-input audio per wake,
then lets Voice Satellite save and review it in Home Assistant. It needs the
matching Voice Satellite recordings implementation. It does not train models,
infer correct/incorrect labels, or enable recording by itself.

The [JavaScript API](js-api.md#wake-word-recordings-opt-in) describes opt-in,
bounded upload retries, acknowledgements, metadata, and the memory-only queue.
Capture uses the common native engine, so microWakeWord, openWakeWord and
vsWakeWord share the same behavior. No microphone data is written to a public
web directory or included in command logs.

## Build an app alongside the official installation

From `app`, build the normal remote admin assets with `npm run build`, obtain
Flutter dependencies with `flutter pub get`, and set `KIOSK_RECORDING_TRIAL=true`
in the build process environment before `flutter build apk --release`. Gradle
also accepts the equivalent project property `wakeRecordingTrial=true`.

Only with this flag, the APK uses application ID
`me.jxl.kiosk_satellite.recordings` and launcher label **Kiosk Recordings Trial**.
It has separate Android storage, permissions, provider authorities and task
affinity. It can be installed alongside the official app without uninstalling
it, and must be configured separately. Normal builds keep the official ID and
label. A contributor APK uses the local debug signing key unless a release key
has explicitly been configured.

Run one app's microphone listener at a time during comparison. Configure a
separate trial satellite and verify its engine/model before enabling recording.
The trial's settings and in-app updater still describe upstream Kiosk Satellite;
do not use the upstream updater or update-helper bootstrap with this separate
trial identity. Replace a trial with a newly built trial APK when needed.

## Targeted checks

openWakeWord waits for two seconds of real microphone input after startup or
reset before classifying. This replaces the synthetic mel and embedding history
that can otherwise produce a high wake score on silence. Wake words spoken in
this initial period do not trigger. The recording still contains only real input
from the current listening period; no padding or earlier Assist audio is added.

`test/oww_startup_test.dart` can exercise actual ONNX sessions when
`OWW_TEST_RESOURCES` points to the mel/embedding directory and
`OWW_TEST_CLASSIFIER` points to an Atlas classifier. It covers startup and repeated
resets; without these optional local model files that test is explicitly skipped.

`flutter test test/wake_recordings_test.dart test/wake_recording_commands_test.dart
test/isolate_engine_test.dart test/js_api_test.dart` exercises exact PCM retention,
sample-aligned snapshots, stale/gapped history, unchanged Assist streaming,
stop/tester exclusion, bounded pending storage, retry acknowledgements, bridge
null responses, navigation recovery, and explicit Off purge.

A physical tablet check is still required: create a real wake and a deliberate
false wake, verify the saved audio includes the triggering sound, label them,
then repeat while Home Assistant is temporarily disconnected. Reconnect and
verify each ID saves once and is acknowledged. Confirm turning recording Off
stops capture and clears unsaved clips. Process death is deliberately outside
the memory-only recovery guarantee.
