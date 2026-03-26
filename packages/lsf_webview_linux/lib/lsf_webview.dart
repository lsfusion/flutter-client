import 'package:flutter/material.dart';
import 'package:webview_cef/webview_cef.dart' as cef;

class LsfWebviewLinux {}

class LsfWebView extends StatefulWidget {
  final dynamic controller;
  const LsfWebView({super.key, required this.controller});

  @override
  State<LsfWebView> createState() => _LsfWebViewState();
}

class _LsfWebViewState extends State<LsfWebView> {
  @override
  Widget build(BuildContext context) {
    return cef.WebView(widget.controller);
  }
}

typedef WebviewManager = cef.WebviewManager;
typedef WebviewEventsListener = cef.WebviewEventsListener;
typedef JavascriptChannel = cef.JavascriptChannel;
typedef JavascriptMessage = cef.JavascriptMessage;

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
