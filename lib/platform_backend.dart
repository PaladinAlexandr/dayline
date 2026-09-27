import 'package:flutter/services.dart';

abstract class PlannerBackend {
  bool get isDesktop => false;
  Future<Object?> invoke(String method, [Object? arguments]);
  void setHandler(Future<void> Function(MethodCall call)? handler);
  void dispose() {}
}

class ChannelBackend extends PlannerBackend {
  static const channel = MethodChannel('app.dayline/native');
  @override
  Future<Object?> invoke(String method, [Object? arguments]) =>
      channel.invokeMethod<Object?>(method, arguments);
  @override
  void setHandler(Future<void> Function(MethodCall call)? handler) =>
      channel.setMethodCallHandler(handler);
}
