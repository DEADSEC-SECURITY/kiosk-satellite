import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/managers/wake_word/recordings.dart';

Uint8List _pcm(int samples, int value) {
  final bytes = Uint8List(samples * 2);
  final view = ByteData.sublistView(bytes);
  for (var i = 0; i < samples; i++) {
    view.setInt16(i * 2, value, Endian.little);
  }
  return bytes;
}

void main() {
  group('wake recording history', () {
    test('a suspended microphone cannot supply stale manual audio', () {
      var now = 0;
      final ring = WakeRecordingBuffer(clockMs: () => now);
      ring.add(_pcm(1280, 1), 0);
      now = 1200;
      expect(ring.snapshot(metadata: const {}), isNull);
      // Device capture may resume with a continuous sample counter despite
      // the real wall-clock gap. Never join the pre-suspend audio back in.
      ring.add(_pcm(1280, 2), 1280);
      expect(ring.snapshot(metadata: const {})!.pcm, _pcm(1280, 2));
    });
    test(
      'retains exact last five seconds across circular wrap and chunk reuse',
      () {
        final ring = WakeRecordingBuffer();
        // Five seconds is 62.5 microphone chunks, so a correct sample cap must
        // retain half of the first chunk rather than rounding to a chunk count.
        for (var chunk = 0; chunk < 80; chunk++) {
          final audio = _pcm(1280, chunk);
          ring.add(audio, chunk * 1280);
          audio.fillRange(
            0,
            audio.length,
            0,
          ); // source may be reused immediately
        }
        final capture = ring.snapshot(metadata: const {})!;
        expect(capture.pcm, hasLength(160000));
        final data = ByteData.sublistView(capture.pcm);
        expect(data.getInt16(0, Endian.little), 17);
        expect(data.getInt16(639 * 2, Endian.little), 17);
        expect(data.getInt16(640 * 2, Endian.little), 18);
        expect(data.getInt16(159998, Endian.little), 79);
        expect(capture.metadata['trigger_sample'], 80000);
        expect(capture.metadata['pre_seconds'], 5);
        expect(capture.metadata['discontinuity'], false);
      },
    );

    test(
      'uses detector position, excluding audio already ahead on the UI isolate',
      () {
        final ring = WakeRecordingBuffer();
        ring.add(_pcm(1280, 7), 0);
        ring.add(_pcm(1280, 9), 1280);
        final capture = ring.snapshot(metadata: const {}, endSample: 1280)!;
        expect(capture.pcm, _pcm(1280, 7));
        expect(capture.metadata['trigger_sample'], 1280);
        expect(capture.metadata['discontinuity'], true);
        expect(ring.snapshot(metadata: const {}, endSample: 2561), isNull);
        expect(ring.snapshot(metadata: const {}, endSample: 0), isNull);
      },
    );

    test('a sample gap never splices unrelated audio together', () {
      final ring = WakeRecordingBuffer();
      ring.add(_pcm(1280, 7), 0);
      ring.add(_pcm(1280, 9), 4000);
      final capture = ring.snapshot(metadata: const {})!;
      expect(capture.pcm, _pcm(1280, 9));
      expect(capture.metadata['discontinuity'], true);
      expect(ring.snapshot(metadata: const {}, endSample: 1280), isNull);
    });

    test('oversized chunks stay bounded and restart creates a new session', () {
      final ring = WakeRecordingBuffer();
      final oldSession = ring.sessionId;
      ring.add(_pcm(90000, 5), 0);
      final capture = ring.snapshot(metadata: const {})!;
      expect(capture.pcm, _pcm(80000, 5));
      ring.clear(newSession: true);
      expect(ring.snapshot(metadata: const {}), isNull);
      expect(ring.sessionId, isNot(oldSession));
      // Captures are copies, unaffected by a later disable/reset.
      expect(capture.pcm, _pcm(80000, 5));
    });

    test(
      'malformed PCM invalidates history rather than shifting sample alignment',
      () {
        final ring = WakeRecordingBuffer();
        ring.add(_pcm(1280, 7), 0);
        ring.add(Uint8List(3), 1280);
        expect(ring.snapshot(metadata: const {}), isNull);
      },
    );
  });

  group('native pending outbox', () {
    WakeRecordingCapture capture() => WakeRecordingCapture(_pcm(1280, 321), {
      'origin': 'native',
      'capture_kind': 'wake',
      'sample_rate': 16000,
    });

    test('reading is repeatable; only acknowledgement removes a clip', () {
      final queue = WakeRecordingQueue();
      final id = queue.add(capture())!;
      expect(
        id,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
      final first = queue.get(id)!;
      expect(queue.get(id), first);
      final wav = base64Decode(first['audio_base64'] as String);
      final view = ByteData.sublistView(wav);
      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(view.getUint32(4, Endian.little), wav.length - 8);
      expect(view.getUint16(20, Endian.little), 1);
      expect(view.getUint16(22, Endian.little), 1);
      expect(view.getUint32(24, Endian.little), 16000);
      expect(view.getUint16(34, Endian.little), 16);
      expect(wav.sublist(44), _pcm(1280, 321));
      expect(queue.list()['items'] as List, hasLength(1));
      expect(queue.ack(id), true);
      expect(queue.get(id), isNull);
      expect(queue.ack(id), true, reason: 'lost ACK replies are safe to retry');
      expect(queue.ack('malformed'), false);
    });

    test('overflow drops new clips without changing an in-flight capture', () {
      final queue = WakeRecordingQueue(maxPending: 2);
      final one = queue.add(capture())!;
      final two = queue.add(capture())!;
      expect(queue.add(capture()), isNull);
      expect(queue.list()['dropped'], 1);
      expect(queue.get(one), isNotNull);
      expect(queue.get(two), isNotNull);
      queue.ack(one);
      expect(queue.add(capture()), isNotNull);
      expect(queue.list()['dropped'], 1);
      queue.clear();
      expect(queue.list(), {'items': [], 'dropped': 0});
    });
  });
}
