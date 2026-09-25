import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// A short copy of exactly the PCM delivered to native wake inference.
/// Neither this ring nor the pending queue opens or retains a microphone.
class WakeRecordingBuffer {
  WakeRecordingBuffer({int Function()? clockMs})
    : _clockMs = clockMs ?? (() => _monotonic.elapsedMilliseconds);

  static final _monotonic = Stopwatch()..start();
  static const sampleRate = 16000;
  static const maxSamples = 5 * sampleRate;
  final int Function() _clockMs;

  final _bytes = Uint8List(maxSamples * 2);
  int _head = 0;
  int _length = 0;
  int _endSample = 0;
  int? _lastChunkMs;
  DateTime? _lastChunkAt;
  String sessionId = recordingUuid();

  void clear({bool newSession = false}) {
    _bytes.fillRange(0, _bytes.length, 0);
    _head = 0;
    _length = 0;
    _endSample = 0;
    _lastChunkMs = null;
    _lastChunkAt = null;
    if (newSession) sessionId = recordingUuid();
  }

  void add(Uint8List pcm, int startSample) {
    if (pcm.isEmpty) return;
    if (pcm.length.isOdd || startSample < 0) {
      clear();
      return;
    }
    final now = _clockMs();
    if (_length > 0 &&
        (startSample != _endSample || now - _lastChunkMs! > 1000)) {
      clear();
    }
    final keep = min(pcm.length, _bytes.length);
    final offset = pcm.length - keep;
    final first = min(keep, _bytes.length - _head);
    _bytes.setRange(_head, _head + first, pcm, offset);
    if (first < keep) _bytes.setRange(0, keep - first, pcm, offset + first);
    _head = (_head + keep) % _bytes.length;
    _length = min(_length + keep, _bytes.length);
    _endSample = startSample + pcm.length ~/ 2;
    _lastChunkMs = now;
    _lastChunkAt = DateTime.now().toUtc();
  }

  /// [endSample] is the detector's sample clock, not the later callback time.
  /// Dropping a stale snapshot is safer than mislabeling unrelated room audio.
  WakeRecordingCapture? snapshot({
    required Map<String, Object?> metadata,
    int? endSample,
  }) {
    if (_length == 0 || _clockMs() - _lastChunkMs! > 1000) return null;
    final end = endSample ?? _endSample;
    final earliest = _endSample - _length ~/ 2;
    if (end <= earliest || end > _endSample) return null;
    final start = max(earliest, end - maxSamples);
    final length = (end - start) * 2;
    final index = (_head - (_endSample - start) * 2) % _bytes.length;
    final pcm = Uint8List(length);
    final first = min(length, _bytes.length - index);
    pcm.setRange(0, first, _bytes, index);
    if (first < length) pcm.setRange(first, length, _bytes);
    final lagMicros = ((_endSample - end) * 1000000 / sampleRate).round();
    return WakeRecordingCapture(pcm, {
      ...metadata,
      'origin': 'native',
      'sample_rate': sampleRate,
      'session_id': sessionId,
      'captured_at': _lastChunkAt!
          .subtract(Duration(microseconds: lagMicros))
          .toIso8601String(),
      'trigger_sample': length ~/ 2,
      'pre_seconds': length / (sampleRate * 2),
      // True until a complete, continuous five-second window is available.
      'discontinuity': length < maxSamples * 2,
      'version': 'native-recordings/1',
    });
  }
}

class WakeRecordingCapture {
  WakeRecordingCapture(this.pcm, Map<String, Object?> metadata)
    : metadata = Map.unmodifiable(metadata);

  final Uint8List pcm;
  final Map<String, Object?> metadata;
}

/// Memory-only outbox owned by WakeWordManager, independent of the WebView.
/// At most 32 five-second clips (~5 MB PCM), retained until HA acknowledges.
class WakeRecordingQueue {
  WakeRecordingQueue({this.maxPending = 32}) : assert(maxPending > 0);
  final int maxPending;
  final _pending = <String, WakeRecordingCapture>{};
  int dropped = 0;

  String? add(WakeRecordingCapture capture) {
    if (_pending.length >= maxPending) {
      // Keep unacknowledged captures stable during an in-flight upload.
      dropped++;
      return null;
    }
    final id = recordingUuid();
    _pending[id] = capture;
    return id;
  }

  Map<String, Object?> list() => {
    'items': [
      for (final entry in _pending.entries)
        {'capture_id': entry.key, ...entry.value.metadata},
    ],
    'dropped': dropped,
  };

  Map<String, Object?>? get(String id) {
    final item = _pending[id];
    if (item == null) return null;
    return {
      'capture_id': id,
      'audio_base64': base64Encode(pcm16Wav(item.pcm)),
      'metadata': item.metadata,
    };
  }

  bool ack(String id) {
    // A lost bridge response must not permanently block the upload queue.
    // Retrying an acknowledgement for a syntactically valid ID is harmless.
    if (!RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    ).hasMatch(id)) {
      return false;
    }
    final capture = _pending.remove(id);
    capture?.pcm.fillRange(0, capture.pcm.length, 0);
    return true;
  }

  void clear() {
    for (final capture in _pending.values) {
      capture.pcm.fillRange(0, capture.pcm.length, 0);
    }
    _pending.clear();
    dropped = 0;
  }
}

String recordingUuid() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

Uint8List pcm16Wav(Uint8List pcm) {
  final wav = Uint8List(44 + pcm.length);
  final data = ByteData.sublistView(wav);
  void tag(int at, String text) => wav.setRange(at, at + 4, text.codeUnits);
  tag(0, 'RIFF');
  data.setUint32(4, 36 + pcm.length, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint32(28, 32000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, pcm.length, Endian.little);
  wav.setRange(44, wav.length, pcm);
  return wav;
}
