import 'package:flutter/services.dart';

class WordPieceTokenizer {
  final Map<String, int> _vocab;
  final int _maxSeqLength;

  WordPieceTokenizer(this._vocab, {int maxSeqLength = 256})
      : _maxSeqLength = maxSeqLength;

  /// Loads the vocab.txt from assets and maps tokens to their line index IDs.
  static Future<WordPieceTokenizer> load(String assetPath,
      {int maxSeqLength = 256}) async {
    final vocabString = await rootBundle.loadString(assetPath);
    final lines = vocabString.split('\n');
    final vocab = <String, int>{};
    for (var i = 0; i < lines.length; i++) {
      vocab[lines[i].trim()] = i;
    }
    return WordPieceTokenizer(vocab, maxSeqLength: maxSeqLength);
  }

  /// Tokenizes text into a fixed-length array of DistilBERT integer IDs.
  List<int> tokenize(String text) {
    final tokens = <int>[101]; // [CLS] token

    // Basic punctuation splitting and lowercasing for uncased model
    final words = text
        .toLowerCase()
        .replaceAll(RegExp(r'([^\w\s])'), r' $1 ')
        .split(RegExp(r'\s+'));

    for (final word in words) {
      if (word.isEmpty) continue;

      var start = 0;
      var isBad = false;
      final subTokens = <int>[];

      while (start < word.length) {
        var end = word.length;
        var found = false;

        while (start < end) {
          final substr = (start == 0 ? '' : '##') + word.substring(start, end);
          if (_vocab.containsKey(substr)) {
            subTokens.add(_vocab[substr]!);
            start = end;
            found = true;
            break;
          }
          end -= 1;
        }
        if (!found) {
          isBad = true;
          break;
        }
      }

      tokens.addAll(isBad ? [100] : subTokens); // 100 is [UNK]
    }

    tokens.add(102); // [SEP] token

    // Truncate to max length minus 1 (keeping SEP), then pad with 0s [PAD]
    final truncated = tokens.take(_maxSeqLength - 1).toList()..add(102);
    return truncated + List.filled(_maxSeqLength - truncated.length, 0);
  }
}