import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_windows/webview_windows.dart' as wv;

import 'address_bar.dart';
import 'native.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: const WebViewPage(),
    );
  }
}

class WebViewPage extends StatefulWidget {
  const WebViewPage({super.key});

  @override
  _WebViewPageState createState() => _WebViewPageState();
}

class _WebViewPageState extends State<WebViewPage> {
  WebViewController? _flutterWebViewController;
  wv.WebviewController? _windowsWebViewController;
  bool _windowsControllerReady = false;

  bool _showAddressBar = false;
  String _currentUrl = 'http://192.168.1.26:8888/main';

  bool get isWindows => Platform.isWindows;
  bool get isMobile => Platform.isAndroid || Platform.isIOS;

  @override
  void initState() {
    super.initState();
    if (isWindows) {
      _initWindowsWebView();
    } else {
      _initFlutterWebView();
    }
  }

  void _initFlutterWebView() {
    _flutterWebViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'Flutter',
        onMessageReceived: (JavaScriptMessage message) async {
          _flutterWebViewController!.runJavaScript(execute(message.message));
        },
      )
      ..loadRequest(Uri.parse(_currentUrl));
  }

  void _initWindowsWebView() async {
    _windowsWebViewController = wv.WebviewController();
    await _windowsWebViewController!.initialize();
    _windowsWebViewController!.webMessage.listen((message) async {
      try {
        _windowsWebViewController!.executeScript(execute(message));
      } catch (e) {
        debugPrint('Failed: $e');
      }
    });
    await _windowsWebViewController!.loadUrl(_currentUrl);
    setState(() {
      _windowsControllerReady = true;
    });
  }

  String execute(message) {
    final data = jsonDecode(message);
    final cmd = data['command'];
    final arguments = data['arguments'] as List<dynamic>;
    final id = data['id'];

    final result = jsonEncode(executeCommand(cmd, arguments));

    return "window.flutterCallback('$cmd', $result, '$id');";
  }

  Future<String> executeCommand(String cmd, List<dynamic> arguments) async {
    switch (cmd) {
      case 'ping':
        return await ping(arguments[0]);
      case 'listFiles':
        return await listFiles(
          arguments[0],
          arguments[1].toString().toLowerCase() == 'true',
        );
      default:
        throw UnsupportedError('Unknown command: $cmd');
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onVerticalDragEnd: (details) {
        if (details.primaryVelocity != null) {
          if (details.primaryVelocity! > 0) {
            setState(() => _showAddressBar = true);
          } else if (details.primaryVelocity! < 0) {
            setState(() => _showAddressBar = false);
          }
        }
      },
      child: Scaffold(
        body: Column(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
              height: _showAddressBar ? 60 : 0,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                opacity: _showAddressBar ? 1 : 0,
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: AddressBar(
                    initialUrl: _currentUrl,
                    onNavigate: (url) {
                      setState(() {
                        _currentUrl = url;
                      });
                      if (isWindows) {
                        _windowsWebViewController?.loadUrl(url);
                      } else {
                        _flutterWebViewController?.loadRequest(Uri.parse(url));
                      }
                    },
                  ),
                ),
              ),
            ),
            Expanded(
              child: isWindows
                  ? (_windowsControllerReady &&
                            _windowsWebViewController != null
                        ? wv.Webview(_windowsWebViewController!)
                        : const Center(child: CircularProgressIndicator()))
                  : (_flutterWebViewController != null
                        ? WebViewWidget(controller: _flutterWebViewController!)
                        : const Center(child: CircularProgressIndicator())),
            ),
          ],
        ),
      ),
    );
  }
}
