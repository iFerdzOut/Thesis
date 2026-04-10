import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import 'native_channel_router.dart';

class SmishingModelOutput {
  const SmishingModelOutput({
    required this.logits,
    required this.positiveIndex,
  });

  final List<double> logits;
  final int positiveIndex;
}

class SmishingModelService {
  SmishingModelService._internal();

  static final SmishingModelService instance = SmishingModelService._internal();
  factory SmishingModelService() => instance;

  static const String _configAssetPath = 'assets/config.json';
  static const String _modelAssetPath = 'assets/distilbert_model.tflite';
  static const String _tokenizerAssetPath = 'assets/tokenizer.json';
  static const String _tokenizerConfigAssetPath =
      'assets/tokenizer_config.json';
  static const String _vocabAssetPath = 'assets/vocab.txt';
  static const int _mobileMaxSequenceLength = 256;
  static const int _lowRamMemoryClassMb = 192;
  static const int _lowRamTotalMemoryMb = 4096;

  bool _modelLoaded = false;
  bool _loadFailed = false;
  Future<void>? _loadFuture;
  Interpreter? _interpreter;
  Map<String, int> _vocab = <String, int>{};
  int _modelMaxLength = _mobileMaxSequenceLength;
  bool _doLowerCase = false;
  int _padTokenId = 0;
  String _clsToken = '[CLS]';
  String _sepToken = '[SEP]';
  String _unkToken = '[UNK]';
  int _positiveIndex = 1;
  _DevicePerformanceProfile? _deviceProfile;
  Future<_DevicePerformanceProfile>? _deviceProfileFuture;
  String? _skipReason;

  bool get isModelLoaded => _modelLoaded;
  String? get skipReason => _skipReason;

  Future<void> loadModel() async {
    if (_modelLoaded || _loadFailed) {
      return;
    }
    final Future<void>? inFlight = _loadFuture;
    if (inFlight != null) {
      await inFlight;
      return;
    }

    _loadFuture = () async {
      if (_modelLoaded || _loadFailed) {
        return;
      }
      final profile = await _getDevicePerformanceProfile();
      if (_shouldSkipForPerformance(profile)) {
        _skipReason =
            'DistilBERT disabled on low-memory device '
            '(memoryClass=${profile.memoryClassMb}MB, totalRam=${profile.totalRamMb}MB).';
        _loadFailed = true;
        debugPrint('[SmishingModelService] $_skipReason');
        return;
      }
      try {
        final Map<String, dynamic> config = jsonDecode(
          await rootBundle.loadString(_configAssetPath),
        ) as Map<String, dynamic>;
        final Map<String, dynamic> tokenizerConfig = jsonDecode(
          await rootBundle.loadString(_tokenizerConfigAssetPath),
        ) as Map<String, dynamic>;
        _vocab = await _loadVocabulary();
        final configuredMaxLength =
            (tokenizerConfig['model_max_length'] as num?)?.toInt() ??
                (config['max_position_embeddings'] as num?)?.toInt() ??
                _mobileMaxSequenceLength;
        _modelMaxLength = math.min(
          configuredMaxLength,
          _mobileMaxSequenceLength,
        );
        _doLowerCase = tokenizerConfig['do_lower_case'] == true;
        _padTokenId = (config['pad_token_id'] as num?)?.toInt() ?? 0;
        _clsToken = tokenizerConfig['cls_token']?.toString() ?? '[CLS]';
        _sepToken = tokenizerConfig['sep_token']?.toString() ?? '[SEP]';
        _unkToken = tokenizerConfig['unk_token']?.toString() ?? '[UNK]';
        final Map<String, dynamic>? id2Label =
            config['id2label'] as Map<String, dynamic>?;
        if (id2Label != null) {
          for (final MapEntry<String, dynamic> entry in id2Label.entries) {
            if (entry.value.toString().toLowerCase() == 'spam') {
              _positiveIndex = int.tryParse(entry.key) ?? 1;
              break;
            }
          }
        }

        final options = InterpreterOptions()..threads = 1;
        _interpreter = await Interpreter.fromAsset(
          _modelAssetPath,
          options: options,
        );
        _modelLoaded = true;
        _loadFailed = false;
        _skipReason = null;
        debugPrint(
          '[SmishingModelService] DistilBERT model loaded '
          '(vocab=${_vocab.length}, maxLen=$_modelMaxLength).',
        );
      } catch (error) {
        _modelLoaded = false;
        _loadFailed = true;
        _interpreter = null;
        _vocab = <String, int>{};
        debugPrint('[SmishingModelService] Failed to load model: $error');
      }
    }();

    try {
      await _loadFuture;
    } finally {
      _loadFuture = null;
    }
  }

  Future<SmishingModelOutput?> runInference(String normalizedMessage) async {
    await loadModel();
    if (!_modelLoaded || _interpreter == null) {
      return null;
    }

    try {
      final _EncodedModelInput encoded = _encodeForModel(normalizedMessage);
      final List<Tensor> inputTensors = _interpreter!.getInputTensors();
      final List<Object?> inputs = List<Object?>.filled(inputTensors.length, null);

      for (int index = 0; index < inputTensors.length; index++) {
        final String lowerName = inputTensors[index].name.toLowerCase();
        if (lowerName.contains('input_ids')) {
          inputs[index] = encoded.inputIds;
        } else if (lowerName.contains('attention_mask')) {
          inputs[index] = encoded.attentionMask;
        } else if (lowerName.contains('token_type_ids')) {
          inputs[index] = encoded.tokenTypeIds;
        }
      }

      if (inputs.any((Object? value) => value == null)) {
        final List<Object> fallbackInputs = <Object>[
          encoded.inputIds,
          encoded.attentionMask,
          if (inputTensors.length > 2) encoded.tokenTypeIds,
        ];
        for (int index = 0; index < inputTensors.length; index++) {
          inputs[index] = fallbackInputs[index];
        }
      }

      final Tensor outputTensor = _interpreter!.getOutputTensors().first;
      final List<int> outputShape = outputTensor.shape;
      final int outputColumns = outputShape.isNotEmpty ? outputShape.last : 2;
      final List<List<double>> output = List<List<double>>.generate(
        1,
        (_) => List<double>.filled(outputColumns, 0.0),
      );

      _interpreter!.runForMultipleInputs(
        inputs.cast<Object>(),
        <int, Object>{0: output},
      );

      return SmishingModelOutput(
        logits: output.first,
        positiveIndex: _positiveIndex,
      );
    } catch (error) {
      debugPrint('[SmishingModelService] Inference failed: $error');
      return null;
    }
  }

  Future<void> releaseModel() async {
    final interpreter = _interpreter;
    if (interpreter == null) {
      return;
    }
    try {
      interpreter.close();
    } catch (_) {}
    _interpreter = null;
    _modelLoaded = false;
    if (!_loadFailed) {
      _skipReason = null;
    }
  }

  Future<_DevicePerformanceProfile> _getDevicePerformanceProfile() async {
    final cached = _deviceProfile;
    if (cached != null) {
      return cached;
    }
    final inFlight = _deviceProfileFuture;
    if (inFlight != null) {
      return inFlight;
    }

    final future = () async {
      if (defaultTargetPlatform != TargetPlatform.android) {
        return const _DevicePerformanceProfile();
      }
      try {
        final raw = await NativeChannelRouter.channel.invokeMethod<dynamic>(
          'getDevicePerformanceProfile',
        );
        return _DevicePerformanceProfile.fromMap(
          Map<String, dynamic>.from(raw as Map<dynamic, dynamic>? ?? const {}),
        );
      } catch (error) {
        debugPrint(
          '[SmishingModelService] Device profile unavailable, using defaults: '
          '$error',
        );
        return const _DevicePerformanceProfile();
      }
    }();

    _deviceProfileFuture = future;
    try {
      final resolved = await future;
      _deviceProfile = resolved;
      return resolved;
    } finally {
      if (identical(_deviceProfileFuture, future)) {
        _deviceProfileFuture = null;
      }
    }
  }

  Future<Map<String, int>> _loadVocabulary() async {
    final Map<String, int> tokenizerJsonVocab =
        await _loadVocabularyFromTokenizerJson();
    if (tokenizerJsonVocab.isNotEmpty) {
      return tokenizerJsonVocab;
    }

    final String vocabText = await rootBundle.loadString(_vocabAssetPath);
    final List<String> vocabList = const LineSplitter()
        .convert(vocabText)
        .map((String line) => line.trim())
        .where((String line) => line.isNotEmpty)
        .toList(growable: false);
    return <String, int>{
      for (int index = 0; index < vocabList.length; index++)
        vocabList[index]: index,
    };
  }

  Future<Map<String, int>> _loadVocabularyFromTokenizerJson() async {
    try {
      final Map<String, dynamic> tokenizerJson = jsonDecode(
        await rootBundle.loadString(_tokenizerAssetPath),
      ) as Map<String, dynamic>;
      final Map<String, dynamic>? model =
          tokenizerJson['model'] as Map<String, dynamic>?;
      final Map<String, dynamic>? vocab =
          model?['vocab'] as Map<String, dynamic>?;
      if (vocab == null || vocab.isEmpty) {
        return <String, int>{};
      }
      return <String, int>{
        for (final MapEntry<String, dynamic> entry in vocab.entries)
          entry.key: (entry.value as num).toInt(),
      };
    } catch (_) {
      return <String, int>{};
    }
  }

  bool _shouldSkipForPerformance(_DevicePerformanceProfile profile) {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    if (profile.isLowRamDevice) {
      return true;
    }
    if (profile.memoryClassMb > 0 &&
        profile.memoryClassMb <= _lowRamMemoryClassMb) {
      return true;
    }
    if (profile.totalRamMb > 0 && profile.totalRamMb <= _lowRamTotalMemoryMb) {
      return true;
    }
    return false;
  }

  _EncodedModelInput _encodeForModel(String message) {
    final int maxContentLength =
        _modelMaxLength > 2 ? _modelMaxLength - 2 : 510;
    final List<String> tokens = _tokenize(message);
    final List<String> truncated = tokens.length > maxContentLength
        ? tokens.sublist(0, maxContentLength)
        : tokens;
    final List<int> inputIds = <int>[
      _tokenIdFor(_clsToken),
      ...truncated.map(_tokenIdFor),
      _tokenIdFor(_sepToken),
    ];
    final List<int> attentionMask = List<int>.filled(inputIds.length, 1);
    while (inputIds.length < _modelMaxLength) {
      inputIds.add(_padTokenId);
      attentionMask.add(0);
    }
    return _EncodedModelInput(
      inputIds: <List<int>>[inputIds],
      attentionMask: <List<int>>[attentionMask],
      tokenTypeIds: <List<int>>[List<int>.filled(_modelMaxLength, 0)],
    );
  }

  List<String> _tokenize(String text) {
    final String cleaned = _cleanTextForTokenizer(text);
    if (cleaned.isEmpty) {
      return const <String>[];
    }
    final List<String> basicTokens = _basicTokenize(cleaned);
    final List<String> wordPieces = <String>[];
    for (final String token in basicTokens) {
      wordPieces.addAll(_wordPieceTokenize(token));
    }
    return wordPieces;
  }

  String _cleanTextForTokenizer(String text) {
    final StringBuffer buffer = StringBuffer();
    for (final int rune in text.runes) {
      if (_isControl(rune)) {
        continue;
      }
      if (_isWhitespace(rune)) {
        buffer.write(' ');
      } else {
        buffer.writeCharCode(rune);
      }
    }
    final String cleaned = buffer.toString().trim();
    return _doLowerCase ? cleaned.toLowerCase() : cleaned;
  }

  List<String> _basicTokenize(String text) {
    final List<String> tokens = <String>[];
    final StringBuffer buffer = StringBuffer();

    void flush() {
      if (buffer.isEmpty) {
        return;
      }
      tokens.add(buffer.toString());
      buffer.clear();
    }

    for (final int rune in text.runes) {
      if (_isWhitespace(rune)) {
        flush();
        continue;
      }
      if (_isChineseChar(rune) || _isPunctuation(rune)) {
        flush();
        tokens.add(String.fromCharCode(rune));
        continue;
      }
      buffer.writeCharCode(rune);
    }
    flush();
    return tokens;
  }

  List<String> _wordPieceTokenize(String token) {
    if (token.isEmpty) {
      return const <String>[];
    }
    if (_vocab.containsKey(token)) {
      return <String>[token];
    }

    final List<String> characters = token.runes
        .map((int rune) => String.fromCharCode(rune))
        .toList(growable: false);
    final List<String> subTokens = <String>[];
    int start = 0;

    while (start < characters.length) {
      int end = characters.length;
      String? currentSubToken;

      while (start < end) {
        final String piece = characters.sublist(start, end).join();
        final String candidate = start == 0 ? piece : '##$piece';
        if (_vocab.containsKey(candidate)) {
          currentSubToken = candidate;
          break;
        }
        end--;
      }

      if (currentSubToken == null) {
        return <String>[_unkToken];
      }

      subTokens.add(currentSubToken);
      start = end;
    }

    return subTokens;
  }

  int _tokenIdFor(String token) {
    return _vocab[token] ?? _vocab[_unkToken] ?? 100;
  }

  bool _isWhitespace(int rune) {
    return rune == 0x0009 ||
        rune == 0x000A ||
        rune == 0x000D ||
        rune == 0x0020 ||
        rune == 0x00A0;
  }

  bool _isControl(int rune) {
    if (rune == 0x0009 || rune == 0x000A || rune == 0x000D) {
      return false;
    }
    return rune < 0x0020 || rune == 0x007F;
  }

  bool _isPunctuation(int rune) {
    return (rune >= 33 && rune <= 47) ||
        (rune >= 58 && rune <= 64) ||
        (rune >= 91 && rune <= 96) ||
        (rune >= 123 && rune <= 126);
  }

  bool _isChineseChar(int rune) {
    return (rune >= 0x4E00 && rune <= 0x9FFF) ||
        (rune >= 0x3400 && rune <= 0x4DBF) ||
        (rune >= 0x20000 && rune <= 0x2A6DF) ||
        (rune >= 0x2A700 && rune <= 0x2B73F) ||
        (rune >= 0x2B740 && rune <= 0x2B81F) ||
        (rune >= 0x2B820 && rune <= 0x2CEAF) ||
        (rune >= 0xF900 && rune <= 0xFAFF) ||
        (rune >= 0x2F800 && rune <= 0x2FA1F);
  }
}

class _EncodedModelInput {
  const _EncodedModelInput({
    required this.inputIds,
    required this.attentionMask,
    required this.tokenTypeIds,
  });

  final List<List<int>> inputIds;
  final List<List<int>> attentionMask;
  final List<List<int>> tokenTypeIds;
}

class _DevicePerformanceProfile {
  const _DevicePerformanceProfile({
    this.isLowRamDevice = false,
    this.memoryClassMb = 0,
    this.largeMemoryClassMb = 0,
    this.totalRamMb = 0,
  });

  factory _DevicePerformanceProfile.fromMap(Map<String, dynamic> map) {
    return _DevicePerformanceProfile(
      isLowRamDevice: map['isLowRamDevice'] == true,
      memoryClassMb: (map['memoryClassMb'] as num?)?.toInt() ?? 0,
      largeMemoryClassMb: (map['largeMemoryClassMb'] as num?)?.toInt() ?? 0,
      totalRamMb: (map['totalRamMb'] as num?)?.toInt() ?? 0,
    );
  }

  final bool isLowRamDevice;
  final int memoryClassMb;
  final int largeMemoryClassMb;
  final int totalRamMb;
}
