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
      cef.JavascriptChannel(
        name: 'Flutter',
        onMessageReceived: (cef.JavascriptMessage message) async {
          controller.executeJavaScript(await onMessage(message.message));
        },
      )
    });

    _isReady = true;
  }

  Widget buildWebView() {
    return cef.WebView(_controller!);
  }

  void loadUrl(String url) {
    _controller?.loadUrl(url);
  }
}
