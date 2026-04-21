import 'dart:isolate';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'sanitizer_utils.dart';
import 'wordpiece_tokenizer.dart';

class SmishingDetector {
  // Rule 3: DistilBERT threshold
  static const double _smishingThreshold = 0.75;
  static const int _maxSeqLength = 256;

  /// Layer 1: Local Heuristics / Whitelist Bypass
  /// Checks if the URL/sender is trusted to bypass ML scanning altogether.
  Future<bool> _isWhitelisted(String message) async {
    // TODO: Implement SQLite whitelist check here
    return false; 
  }

  /// Layer 2: Offloaded TFLite Inference
  /// Uses Isolate.run() to guarantee 60/120fps UI animations are never blocked.
  Future<bool> analyzeMessage(String rawMessage) async {
    // 1. Layer 1 Check
    if (await _isWhitelisted(rawMessage)) {
      return false; // Trusted, safely bypass ML
    }

    // 2. Sanitize PII
    final sanitizedMessage = SanitizerUtils.sanitizePii(rawMessage);
    final token = RootIsolateToken.instance;

    // 3. Offload heavy tensor math to a background thread
    final isSmishing = await Isolate.run(() => _runInference(sanitizedMessage, token));
    return isSmishing;
  }

  /// The heavy lifting executed safely in a separate memory space.
  static Future<bool> _runInference(String text, RootIsolateToken? token) async {
    try {
      if (token != null) {
        BackgroundIsolateBinaryMessenger.ensureInitialized(token);
      }

      // Load Tokenizer
      final tokenizer = await WordPieceTokenizer.load(
        'assets/vocab.txt',
        maxSeqLength: _maxSeqLength,
      );

      // Interpreter must be loaded inside the Isolate
      final interpreter = await Interpreter.fromAsset('assets/distilbert_model.tflite');
      
      // Shape input to [1, 256] array
      var input = [tokenizer.tokenize(text)];
      var output = List.filled(1 * 2, 0.0).reshape([1, 2]); // Output logits
      
      interpreter.run(input, output);
      interpreter.close();

      // Convert raw logits to probability via Softmax
      final logit0 = output[0][0] as double;
      final logit1 = output[0][1] as double;
      final probability = exp(logit1) / (exp(logit0) + exp(logit1));
      
      return probability >= _smishingThreshold;
    } catch (e) {
      debugPrint('[ML Isolate] DistilBERT Inference failed: $e');
      return false; // Fail open to avoid blocking messages on crash
    }
  }
}