import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_windows/webview_windows.dart' as wv;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  debugPrint('App is starting...');
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WebView Native Demo',
      debugShowCheckedModeBanner: false,
      home: WebViewPage(),
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

  List<String> _history = [];
  bool _showAddressBar = false;
  bool _showHistory = false;
  String _currentUrl = 'http://192.168.0.51:8888/main';
  final TextEditingController _urlController = TextEditingController();

  bool get isWindows => Platform.isWindows;
  bool get isMobile => Platform.isAndroid || Platform.isIOS;

  @override
  void initState() {
    super.initState();
    _loadHistory();
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
          final data = jsonDecode(message.message);
          final cmd = data['command'];
          final arg = data['argument'];
          final id = data['id'];
          if (cmd == 'ping') {
            final result = await _nativePing(arg);
            _flutterWebViewController!.runJavaScript(
              "window.flutterCallback('ping', '${result.replaceAll("'", "\\'")}', '$id');",
            );
          }
        },
      )
      ..loadRequest(Uri.parse(_currentUrl));
  }

  void _initWindowsWebView() async {
    _windowsWebViewController = wv.WebviewController();
    await _windowsWebViewController!.initialize();
    _windowsWebViewController!.webMessage.listen((message) async {
      try {
        final data = jsonDecode(message);
        final cmd = data['command'];
        final arg = data['argument'];
        final id = data['id'];

        if (cmd == 'ping') {
          final result = await _nativePing(arg);
          _windowsWebViewController!.executeScript(
            "window.flutterCallback('ping', '${result.replaceAll("'", "\\'")}', '$id');",
          );
        }
      } catch (e) {
        debugPrint('Invalid message: $message');
      }
    });
    await _windowsWebViewController!.loadUrl(_currentUrl);
    setState(() {
      _windowsControllerReady = true;
    });
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList('history') ?? [];
    setState(() {
      _history = stored;
      _currentUrl = stored.isNotEmpty ? stored.last : _currentUrl;
      _urlController.text = _currentUrl;
    });
  }

  Future<void> _saveUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    _history.remove(url);
    _history.add(url);
    if (_history.length > 10) {
      _history = _history.sublist(_history.length - 10);
    }
    await prefs.setStringList('history', _history);
  }

  Future<String> _nativePing(String host) async {
    try {
      host = Uri.parse(host).host;
      final socket = await Socket.connect(
        host,
        80,
        timeout: Duration(seconds: 5),
      );
      socket.destroy();
      return 'OK';
    } catch (e) {
      return 'Host is not reachable: $e';
    }
  }

  void _handleSubmitted(String url) {
    if (!url.startsWith('http')) url = 'http://$url';
    if (isWindows) {
      _windowsWebViewController?.loadUrl(url);
    } else {
      _flutterWebViewController?.loadRequest(Uri.parse(url));
    }
    setState(() {
      _currentUrl = url;
      _urlController.text = url;
      _showAddressBar = false;
      _showHistory = false;
    });
    _saveUrl(url);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onVerticalDragEnd: (details) {
        if (details.primaryVelocity != null) {
          if (details.primaryVelocity! > 0) {
            setState(() => _showAddressBar = true);
          } else if (details.primaryVelocity! < 0) {
            setState(() {
              _showAddressBar = false;
              _showHistory = false;
            });
          }
        }
      },
      child: Scaffold(
        body: Column(
          children: [
            AnimatedContainer(
              duration: Duration(milliseconds: 300),
              curve: Curves.easeInOut,
              height: _showAddressBar ? (_showHistory && _history.isNotEmpty ? 150 : 60) : 0,
              child: AnimatedOpacity(
                duration: Duration(milliseconds: 200),
                opacity: _showAddressBar ? 1 : 0,
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Column(
                    children: [
                      TextFormField(
                        controller: _urlController,
                        decoration: InputDecoration(
                          labelText: 'Address',
                          border: OutlineInputBorder(),
                        ),
                        onTap: () {
                          setState(() => _showHistory = true);
                        },
                        onFieldSubmitted: (value) {
                          _handleSubmitted(value);
                          setState(() => _showHistory = false);
                        },
                      ),
                      if (_showAddressBar && _showHistory && _history.isNotEmpty) ...[
                        SizedBox(height: 8),
                        Expanded(
                          child: ListView.builder(
                            itemCount: _history.length,
                            itemBuilder: (context, index) {
                              final url = _history[_history.length - 1 - index];
                              return Padding(
                                padding: const EdgeInsets.symmetric(vertical: 2),
                                child: ListTile(
                                  dense: true,
                                  visualDensity: VisualDensity.compact,
                                  contentPadding: EdgeInsets.symmetric(horizontal: 8),
                                  title: Text(
                                    url,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onTap: () {
                                    _handleSubmitted(url);
                                    setState(() => _showHistory = false);
                                  },
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: isWindows
                  ? (_windowsControllerReady && _windowsWebViewController != null
                      ? wv.Webview(_windowsWebViewController!)
                      : Center(child: CircularProgressIndicator()))
                  : (_flutterWebViewController != null
                      ? WebViewWidget(controller: _flutterWebViewController!)
                      : Center(child: CircularProgressIndicator())),
            ),
          ],
        ),
      ),
    );
  }
}