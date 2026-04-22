import 'dart:async';
import 'dart:isolate';

import 'package:flutter/services.dart';

import 'smishing_model_service.dart';

class SmishingInferenceIsolateService {
  SmishingInferenceIsolateService._internal();

  static final SmishingInferenceIsolateService _instance =
      SmishingInferenceIsolateService._internal();
  factory SmishingInferenceIsolateService() => _instance;

  Isolate? _isolate;
  SendPort? _sendPort;
  Future<void>? _spawnFuture;
  int _requestId = 0;
  final Map<int, Completer<SmishingModelOutput?>> _pending =
      <int, Completer<SmishingModelOutput?>>{};

  Future<void> ensureStarted() async {
    if (_sendPort != null) {
      return;
    }
    final inFlight = _spawnFuture;
    if (inFlight != null) {
      await inFlight;
      return;
    }

    _spawnFuture = () async {
      final RootIsolateToken? rootToken = RootIsolateToken.instance;
      if (rootToken == null) {
        throw StateError('Root isolate token is unavailable.');
      }

      final ReceivePort receivePort = ReceivePort();
      final Completer<void> readyCompleter = Completer<void>();
      receivePort.listen((dynamic message) {
        if (message is SendPort) {
          _sendPort = message;
          if (!readyCompleter.isCompleted) {
            readyCompleter.complete();
          }
          return;
        }
        if (message is! Map) {
          return;
        }
        final int id = (message['id'] as num?)?.toInt() ?? -1;
        final Completer<SmishingModelOutput?>? completer = _pending.remove(id);
        if (completer == null || completer.isCompleted) {
          return;
        }
        final Object? error = message['error'];
        if (error != null) {
          completer.completeError(StateError(error.toString()));
          return;
        }
        final List<dynamic> logitsRaw =
            message['logits'] as List<dynamic>? ?? const <dynamic>[];
        completer.complete(
          SmishingModelOutput(
            logits: logitsRaw
                .map((dynamic item) => (item as num).toDouble())
                .toList(growable: false),
            positiveIndex: (message['positiveIndex'] as num?)?.toInt() ?? 1,
          ),
        );
      });
      _isolate = await Isolate.spawn<_IsolateBootstrapMessage>(
        _workerMain,
        _IsolateBootstrapMessage(
          sendPort: receivePort.sendPort,
          rootToken: rootToken,
        ),
        debugName: 'smishing_inference_worker',
      );
      await readyCompleter.future;
    }();

    try {
      await _spawnFuture;
    } finally {
      _spawnFuture = null;
    }
  }

  Future<SmishingModelOutput?> runInference(String normalizedMessage) async {
    await ensureStarted();
    final SendPort? port = _sendPort;
    if (port == null) {
      return null;
    }

    final int id = ++_requestId;
    final Completer<SmishingModelOutput?> completer =
        Completer<SmishingModelOutput?>();
    _pending[id] = completer;
    port.send(<String, dynamic>{
      'id': id,
      'text': normalizedMessage,
    });
    return completer.future;
  }

  Future<void> dispose() async {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _sendPort = null;
    for (final Completer<SmishingModelOutput?> completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.complete(null);
      }
    }
    _pending.clear();
  }

  static Future<void> _workerMain(_IsolateBootstrapMessage bootstrap) async {
    BackgroundIsolateBinaryMessenger.ensureInitialized(bootstrap.rootToken);
    final SmishingModelService modelService = SmishingModelService();
    final ReceivePort requestPort = ReceivePort();
    bootstrap.sendPort.send(requestPort.sendPort);

    await for (final dynamic raw in requestPort) {
      if (raw is! Map) {
        continue;
      }
      final int id = (raw['id'] as num?)?.toInt() ?? -1;
      final SendPort replyPort = bootstrap.sendPort;
      try {
        final String text = raw['text']?.toString() ?? '';
        final SmishingModelOutput? output =
            await modelService.runInference(text.trim());
        replyPort.send(<String, dynamic>{
          'id': id,
          'logits': output?.logits ?? const <double>[],
          'positiveIndex': output?.positiveIndex ?? 1,
        });
      } catch (error) {
        replyPort.send(<String, dynamic>{
          'id': id,
          'error': error.toString(),
        });
      }
    }
  }
}

class _IsolateBootstrapMessage {
  const _IsolateBootstrapMessage({
    required this.sendPort,
    required this.rootToken,
  });

  final SendPort sendPort;
  final RootIsolateToken rootToken;
}
