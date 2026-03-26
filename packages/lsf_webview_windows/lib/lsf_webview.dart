import 'package:flutter/material.dart';

class LsfWebviewWindows {}

class LsfWebView extends StatefulWidget {
  final dynamic controller;
  const LsfWebView({super.key, required this.controller});

  @override
  State<LsfWebView> createState() => _LsfWebViewState();
}

class _LsfWebViewState extends State<LsfWebView> {
  @override
  Widget build(BuildContext context) {
    return const Center(child: Text('Windows Dummy WebView'));
  }
}

class WebviewManager {
  static final _instance = WebviewManager._();
  WebviewManager._();
  factory WebviewManager() => _instance;

  Future<void> initialize() async {}
  dynamic createWebView() => _DummyController();
}

class _DummyController {
  void setWebviewListener(WebviewEventsListener listener) {}
  Future<void> initialize(String url) async {}
  void setJavaScriptChannels(Set<JavascriptChannel> channels) {}
  void executeJavaScript(String script) {}
  void loadUrl(String url) {}
}

class WebviewEventsListener {
  WebviewEventsListener({
    Function(dynamic, String)? onLoadStart,
    Function(dynamic, String)? onLoadEnd,
  });
}

class JavascriptChannel {
  JavascriptChannel({
    required String name,
    required Function(JavascriptMessage) onMessageReceived,
  });
}

class JavascriptMessage {
  final String message;
  JavascriptMessage(this.message);
}

WebviewManager getWebviewManager() => WebviewManager();

WebviewEventsListener createWebviewEventsListener({
  required Function(dynamic, String) onLoadStart,
  required Function(dynamic, String) onLoadEnd,
}) =>
    WebviewEventsListener(onLoadStart: onLoadStart, onLoadEnd: onLoadEnd);

JavascriptChannel createJavascriptChannel({
  required String name,
  required Function(JavascriptMessage) onMessageReceived,
}) =>
    JavascriptChannel(name: name, onMessageReceived: onMessageReceived);
