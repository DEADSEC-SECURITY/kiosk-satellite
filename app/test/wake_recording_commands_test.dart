import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/events.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/js_api/js_api_manager.dart';
import 'package:kiosk_satellite/managers/js_api/user_script.dart';
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:kiosk_satellite/managers/wake_word/engine.dart';
import 'package:kiosk_satellite/managers/wake_word/recordings.dart';
import 'package:kiosk_satellite/managers/wake_word/wake_word_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Engine extends WakeWordEngine {
  @override
  bool running = false;
  bool recording = false;
  bool paused = false;
  void Function(WakeRecordingCapture)? sink;
  @override
  Set<WakeWordEngineType> get supportedEngines => {
    WakeWordEngineType.microWakeWord,
  };
  @override
  bool get supportsWakeWordRecording => true;
  @override
  Future<void> start({
    required WakeWordConfig config,
    required DetectionCallback onDetection,
    StopDetectionCallback? onStopDetection,
    EngineFailureCallback? onFailure,
  }) async => running = true;
  @override
  Future<void> stop() async => running = false;
  @override
  Future<void> pauseDetection() async => paused = true;
  @override
  Future<void> resumeDetection() async => paused = false;
  @override
  void configureWakeWordRecording({
    required bool enabled,
    void Function(WakeRecordingCapture)? onCapture,
  }) {
    recording = enabled;
    sink = enabled ? onCapture : null;
  }

  @override
  WakeRecordingCapture? captureWakeWordRecording() =>
      recording && !paused ? clip('missed') : null;
  WakeRecordingCapture clip(String kind) =>
      WakeRecordingCapture(Uint8List(2560), {
        'origin': 'native',
        'engine': 'microWakeWord',
        'capture_kind': kind,
        'sample_rate': 16000,
        'pre_seconds': 0.08,
        'trigger_sample': 1280,
      });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late EventBus bus;
  late CommandRegistry commands;
  late WakeWordManager manager;
  late JsApiManager api;
  late _Engine engine;

  Future<Object?> call(String name, [Map<String, Object?> params = const {}]) =>
      api.handleCall([name, params]);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final log = Logger();
    bus = EventBus();
    commands = CommandRegistry(log);
    final settings = SettingsManager(bus, commands, log);
    await settings.init();
    engine = _Engine();
    manager = WakeWordManager(
      bus,
      commands,
      log,
      settings,
      engines: {WakeWordEngineType.microWakeWord: engine},
    );
    await manager.init();
    api = JsApiManager(bus, commands, log, 'test');
    await api.init();
    await call('setWakeWordConfig', {
      'engine': 'microWakeWord',
      'models': [
        {
          'id': 'atlas',
          'wakeWord': 'Atlas',
          'manifestUrl': 'http://ha/atlas.json',
        },
      ],
    });
  });

  tearDown(() async {
    await api.dispose();
    await manager.dispose();
    await bus.dispose();
  });

  test(
    'five public methods are exposed; missing captures return null, not true',
    () async {
      final script = buildKioskSatelliteScript(version: 'test', os: 'android');
      for (final method in [
        'configureWakeWordRecording',
        'listWakeWordRecordings',
        'getWakeWordRecording',
        'ackWakeWordRecording',
        'captureWakeWordRecording',
      ]) {
        expect(script, contains('$method: function'));
      }
      expect(engine.recording, false);
      expect(await call('captureWakeWordRecording'), isNull);
      expect(
        await call('getWakeWordRecording', {'capture_id': 'missing'}),
        isNull,
      );
      expect(
        await call('ackWakeWordRecording', {'capture_id': 'missing'}),
        false,
      );
      expect(
        await call('configureWakeWordRecording', {'enabled': 'true'}),
        false,
      );
      expect(engine.recording, false);
    },
  );

  test(
    'clip event, list/get/ack survive page navigation with no stream takeover',
    () async {
      final ready = <WakeWordRecordingReady>[];
      final subscription = bus.on<WakeWordRecordingReady>().listen(ready.add);
      expect(await call('configureWakeWordRecording', {'enabled': true}), {
        'available': true,
        'enabled': true,
      });
      engine.sink!(engine.clip('wake'));
      await Future<void>.delayed(Duration.zero);
      expect(ready, hasLength(1));
      final id = ready.single.captureId;
      expect(ready.single.toJson(), {'capture_id': id});
      final before = await call('getWakeWordRecording', {'capture_id': id});
      expect(before, isA<Map>());
      // HA metadata accepts plain JSON only; settings must not leak platform
      // objects/enums through the JavaScript bridge.
      expect(() => jsonEncode(before), returnsNormally);
      api.onPageStarted();
      expect(await call('getWakeWordRecording', {'capture_id': id}), before);
      final listing = await call('listWakeWordRecordings') as Map;
      expect(listing['items'], hasLength(1));
      expect(await call('ackWakeWordRecording', {'capture_id': id}), true);
      expect(await call('getWakeWordRecording', {'capture_id': id}), isNull);
      await subscription.cancel();
    },
  );

  test(
    'manual capture is unlabeled and unavailable while paused; off purges',
    () async {
      await call('configureWakeWordRecording', {'enabled': true});
      final manual = await call('captureWakeWordRecording') as Map;
      final item =
          await call('getWakeWordRecording', {
                'capture_id': manual['capture_id'],
              })
              as Map;
      expect((item['metadata'] as Map)['capture_kind'], 'missed');
      expect(item['metadata'] as Map, isNot(contains('word_present')));
      await call('setWakeWordActive', {'active': false});
      expect(await call('captureWakeWordRecording'), isNull);
      await call('configureWakeWordRecording', {'enabled': false});
      expect(engine.recording, false);
      expect(await call('listWakeWordRecordings'), {'items': [], 'dropped': 0});
      expect(
        await call('getWakeWordRecording', {
          'capture_id': manual['capture_id'],
        }),
        isNull,
      );
    },
  );

  test(
    'temporary suspension clears listening but retains pending acknowledgements',
    () async {
      await call('configureWakeWordRecording', {'enabled': true});
      final manual = await call('captureWakeWordRecording') as Map;
      final id = manual['capture_id'];
      await call('configureWakeWordRecording', {
        'enabled': false,
        'clear_pending': false,
      });
      expect(engine.recording, false);
      expect(await call('captureWakeWordRecording'), isNull);
      expect(
        await call('getWakeWordRecording', {'capture_id': id}),
        isA<Map>(),
      );
      api.onPageStarted();
      await call('configureWakeWordRecording', {'enabled': true});
      expect(
        await call('getWakeWordRecording', {'capture_id': id}),
        isA<Map>(),
      );
      // Explicit Off remains a purge, independent of the earlier suspension.
      await call('configureWakeWordRecording', {'enabled': false});
      expect(await call('listWakeWordRecordings'), {'items': [], 'dropped': 0});
    },
  );

  test(
    'a changed server/satellite owner cannot inherit pending audio',
    () async {
      const owner = 'https://ha.example|assist_satellite.kitchen';
      await call('configureWakeWordRecording', {
        'enabled': true,
        'owner': owner,
      });
      final first = await call('captureWakeWordRecording') as Map;
      api.onPageStarted();
      await call('configureWakeWordRecording', {
        'enabled': true,
        'owner': owner,
      });
      expect(
        await call('getWakeWordRecording', first.cast<String, Object?>()),
        isA<Map>(),
      );
      expect(
        await call('configureWakeWordRecording', {
          'enabled': false,
          'owner': ' ',
        }),
        false,
      );
      expect(engine.recording, true);
      await call('configureWakeWordRecording', {
        'enabled': true,
        'owner': 'https://ha.example|assist_satellite.office',
      });
      expect(await call('listWakeWordRecordings'), {'items': [], 'dropped': 0});
      expect(
        await call('getWakeWordRecording', first.cast<String, Object?>()),
        isNull,
      );
      expect(engine.recording, true);
    },
  );
}
