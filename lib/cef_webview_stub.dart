import 'package:flutter/widgets.dart';

class CefWebViewHelper {
  bool get isReady => false;

  Future<void> initialize(
    String url, {
    required void Function() onLoadStart,
    required void Function() onLoadEnd,
    required Future<String> Function(String message) onMessage,
  }) async {}

  Widget buildWebView() => const SizedBox();

  void loadUrl(String url) {}
}
