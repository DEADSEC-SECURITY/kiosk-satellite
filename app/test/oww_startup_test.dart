import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:kiosk_satellite/managers/wake_word/oww/oww_pipeline.dart';

/// Run with real ONNX resources to cover the native frontend, not a clock mock.
/// OWW_TEST_CLASSIFIER selects the Atlas model that exposed the startup spike.
void main() {
  final resources = Platform.environment['OWW_TEST_RESOURCES'];
  final classifier = Platform.environment['OWW_TEST_CLASSIFIER'];
  test(
    'real native startup and resume do not score artificial history',
    () {
      OrtEnv.instance.init();
      final options = OrtSessionOptions()
        ..setIntraOpNumThreads(2)
        ..setInterOpNumThreads(1);
      OrtSession load(String path) =>
          OrtSession.fromBuffer(File(path).readAsBytesSync(), options);
      final mel = load('$resources/melspectrogram.onnx');
      final embedding = load('$resources/embedding_model.onnx');
      final head = load(classifier!);
      final pipeline = OwwPipeline(
        melSession: mel,
        embeddingSession: embedding,
      );
      final runOptions = OrtRunOptions();
      try {
        pipeline.warmup();
        for (var cycle = 0; cycle < 3; cycle++) {
          if (cycle > 0) pipeline.reset();
          for (var chunk = 0; chunk < 24; chunk++) {
            expect(
              pipeline.process(Float32List(1280)),
              isNull,
              reason:
                  'Synthetic mel/embedding history must not reach the classifier',
            );
          }
          for (var chunk = 24; chunk < 63; chunk++) {
            final window = pipeline.process(Float32List(1280));
            expect(
              window,
              isNotNull,
              reason: 'Scoring resumes after two seconds of live audio',
            );
            final input = OrtValueTensor.createTensorWithDataList(window!, [
              1,
              16,
              96,
            ]);
            final output = head.run(runOptions, {head.inputNames.first: input});
            try {
              final score = (output.first!.value as List).first.first as double;
              expect(
                score,
                lessThan(.01),
                reason:
                    'Atlas v3 must not wake on silence after startup/resume',
              );
            } finally {
              input.release();
              for (final tensor in output) {
                tensor?.release();
              }
            }
          }
        }
      } finally {
        pipeline.dispose();
        runOptions.release();
        head.release();
        embedding.release();
        mel.release();
        options.release();
      }
    },
    skip: resources == null || classifier == null
        ? 'Set OWW_TEST_RESOURCES and OWW_TEST_CLASSIFIER for real-model validation'
        : false,
  );
}
