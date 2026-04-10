import 'dart:async';

import 'package:flutter/services.dart';

typedef NativeMethodHandler = FutureOr<dynamic> Function(MethodCall call);

class NativeChannelRouter {
  NativeChannelRouter._();

  static const MethodChannel channel = MethodChannel('sms_channel');

  static bool _initialized = false;
  static int _nextHandlerId = 0;
  static final Map<int, _NativeHandlerRegistration> _handlersById =
      <int, _NativeHandlerRegistration>{};

  static void ensureInitialized() {
    if (_initialized) return;
    _initialized = true;
    channel.setMethodCallHandler(_dispatch);
  }

  static int registerHandler({
    required String method,
    required NativeMethodHandler handler,
  }) {
    ensureInitialized();
    final id = ++_nextHandlerId;
    _handlersById[id] = _NativeHandlerRegistration(
      method: method,
      handler: handler,
    );
    return id;
  }

  static void unregisterHandler(int? id) {
    if (id == null) return;
    _handlersById.remove(id);
  }

  static Future<dynamic> _dispatch(MethodCall call) async {
    final registrations = _handlersById.values
        .where((registration) => registration.method == call.method)
        .toList(growable: false);

    dynamic lastResult;
    for (final registration in registrations) {
      lastResult = await registration.handler(call);
    }
    return lastResult;
  }
}

class _NativeHandlerRegistration {
  const _NativeHandlerRegistration({
    required this.method,
    required this.handler,
  });

  final String method;
  final NativeMethodHandler handler;
}
