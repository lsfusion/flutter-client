import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:webview_cef/webview_cef.dart' as cef;

class CefWebViewHelper {
  dynamic _controller;
  bool _isReady = false;

  bool get isReady => _isReady;

  Future<void> initialize(
    String url, {
    required void Function() onLoadStart,
    required void Function() onLoadEnd,
    required Future<String> Function(String message) onMessage,
    required void Function(String theme) onThemeChanged,
  }) async {
    await cef.WebviewManager().initialize();
    final controller = cef.WebviewManager().createWebView();
    _controller = controller;

    controller.setWebviewListener(cef.WebviewEventsListener(
      onLoadStart: (c, u) => onLoadStart(),
      onLoadEnd: (c, u) => onLoadEnd(),
    ));

    await controller.initialize(url);

    controller.setJavaScriptChannels({
      // The CEF transport JSON-stringifies the payload once more on the way
      // here, hence the jsonDecode.
      cef.JavascriptChannel(
        name: 'Flutter',
        onMessageReceived: (cef.JavascriptMessage message) async {
          controller.executeJavaScript(
              await onMessage(jsonDecode(message.message) as String));
        },
      ),
      cef.JavascriptChannel(
        name: 'themeChanged',
        onMessageReceived: (cef.JavascriptMessage message) =>
            onThemeChanged(jsonDecode(message.message) as String),
      ),
    });

    _isReady = true;
  }

  void executeJavaScript(String code) {
    _controller?.executeJavaScript(code);
  }

  Widget buildWebView() {
    return cef.WebView(_controller!);
  }

  void loadUrl(String url) {
    _controller?.loadUrl(url);
  }
}
