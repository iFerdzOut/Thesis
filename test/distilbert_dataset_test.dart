import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_application_1/smishing_detection_pipeline/pipeline_service.dart';

const String _datasetPath = r'C:\Users\monaliza\Downloads\test.csv';
const double _modelThreshold = 0.5;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('DistilBERT-only dataset evaluation', () async {
    final rows = _readDataset(File(_datasetPath).readAsStringSync());
    expect(rows, isNotEmpty);

    final model = DistilBertModel();
    final scorer = SoftmaxScorer();
    final metrics = _ModelOnlyMetrics();

    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final output = await model.runInference(_preprocessForModel(row.text));
      expect(
        output,
        isNotNull,
        reason: 'DistilBERT returned no logits for row $i. '
            'This test intentionally has no heuristic fallback. '
            'skipReason=${model.skipReason}',
      );
      expect(
        output!.logits,
        isNotEmpty,
        reason: 'DistilBERT returned empty logits for row $i.',
      );

      final spamProbability = await scorer.scoreFromLogits(
        output.logits,
        positiveIndex: output.positiveIndex,
      );
      metrics.add(
        expectedSpam: row.label == 1,
        predictedSpam: spamProbability >= _modelThreshold,
      );
    }

    // ignore: avoid_print
    print('DistilBERT-only dataset: ${metrics.summary}');

    expect(metrics.total, rows.length);
  }, timeout: const Timeout(Duration(minutes: 10)));
}

String _preprocessForModel(String body) {
  var text = body.trim();
  text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return text;
}

List<_DatasetRow> _readDataset(String csv) {
  final records = _parseCsv(csv);
  if (records.isEmpty) return const <_DatasetRow>[];
  final header = records.first;
  final textIndex = header.indexOf('Text');
  final labelIndex = header.indexOf('Label');
  if (textIndex < 0 || labelIndex < 0) {
    throw StateError('Dataset must contain Text and Label columns.');
  }

  return records.skip(1).where((record) {
    return record.length > textIndex && record.length > labelIndex;
  }).map((record) {
    return _DatasetRow(
      text: record[textIndex],
      label: int.parse(record[labelIndex]),
    );
  }).toList(growable: false);
}

List<List<String>> _parseCsv(String input) {
  final rows = <List<String>>[];
  final currentRow = <String>[];
  final currentField = StringBuffer();
  var inQuotes = false;

  for (var i = 0; i < input.length; i++) {
    final char = input[i];
    if (inQuotes) {
      if (char == '"') {
        final nextIsQuote = i + 1 < input.length && input[i + 1] == '"';
        if (nextIsQuote) {
          currentField.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        currentField.write(char);
      }
      continue;
    }

    if (char == '"') {
      inQuotes = true;
    } else if (char == ',') {
      currentRow.add(currentField.toString());
      currentField.clear();
    } else if (char == '\n') {
      currentRow.add(currentField.toString().replaceFirst(RegExp(r'\r$'), ''));
      currentField.clear();
      rows.add(List<String>.from(currentRow));
      currentRow.clear();
    } else {
      currentField.write(char);
    }
  }

  if (currentField.isNotEmpty || currentRow.isNotEmpty) {
    currentRow.add(currentField.toString());
    rows.add(List<String>.from(currentRow));
  }
  return rows;
}

class _DatasetRow {
  const _DatasetRow({required this.text, required this.label});

  final String text;
  final int label;
}

class _ModelOnlyMetrics {
  var truePositive = 0;
  var trueNegative = 0;
  var falsePositive = 0;
  var falseNegative = 0;

  int get total => truePositive + trueNegative + falsePositive + falseNegative;

  void add({required bool expectedSpam, required bool predictedSpam}) {
    if (expectedSpam && predictedSpam) {
      truePositive++;
    } else if (!expectedSpam && !predictedSpam) {
      trueNegative++;
    } else if (!expectedSpam && predictedSpam) {
      falsePositive++;
    } else {
      falseNegative++;
    }
  }

  String get summary {
    final spamTotal = truePositive + falseNegative;
    final hamTotal = trueNegative + falsePositive;
    final accuracy = total == 0 ? 0.0 : (truePositive + trueNegative) / total;
    final recall = spamTotal == 0 ? 0.0 : truePositive / spamTotal;
    final precision = truePositive + falsePositive == 0
        ? 0.0
        : truePositive / (truePositive + falsePositive);
    return 'TP=$truePositive FN=$falseNegative FP=$falsePositive TN=$trueNegative; '
        'spam flagged $truePositive/$spamTotal, ham allowed $trueNegative/$hamTotal; '
        'accuracy=${accuracy.toStringAsFixed(3)}, '
        'precision=${precision.toStringAsFixed(3)}, '
        'recall=${recall.toStringAsFixed(3)}';
  }
}
