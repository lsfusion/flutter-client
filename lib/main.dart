import 'dart:convert';
import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart' as flutter;
import 'package:webview_windows/webview_windows.dart' as wv;
import 'package:shared_preferences/shared_preferences.dart';

import 'cef_webview_stub.dart'
    if (dart.library.io) 'cef_webview_impl.dart';

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
    return const MaterialApp(
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
  flutter.WebViewController? _flutterWebViewController;
  wv.WebviewController? _windowsWebViewController;
  CefWebViewHelper? _cefHelper;
  bool _windowsControllerReady = false;

  bool _showAddressBar = false;
  bool _isLoading = false;
  bool _isReady = false;

  String _currentUrl = 'http://127.0.0.1:8080/main';

  bool get isWindows => Platform.isWindows;
  bool get isLinux => Platform.isLinux;

  @override
  void initState() {
    super.initState();
    _loadLastUrl();
    if (isWindows) {
      _initWindowsWebView();
    } else if (isLinux) {
      _initCefWebView();
    }
  }

  Future<void> _loadLastUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final history = prefs.getStringList('history') ?? [];
    if (history.isNotEmpty) {
      _currentUrl = history.last;
    }

    if (!isWindows && !isLinux) {
      _initFlutterWebView();
    }

    setState(() {
      _isReady = true;
    });
  }

  void _initFlutterWebView() {
    _flutterWebViewController = flutter.WebViewController()
      ..setJavaScriptMode(flutter.JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'Flutter',
        onMessageReceived: (flutter.JavaScriptMessage message) async {
          _flutterWebViewController!.runJavaScript(
            await execute(message.message),
          );
        },
      )
      ..setNavigationDelegate(flutter.NavigationDelegate(
        onPageStarted: (_) {
          setState(() => _isLoading = true);
        },
        onPageFinished: (_) {
          setState(() => _isLoading = false);
        },
      ))
      ..loadRequest(Uri.parse(_currentUrl));
  }

  void _initWindowsWebView() async {
    _windowsWebViewController = wv.WebviewController();
    await _windowsWebViewController!.initialize();
    _windowsWebViewController!.webMessage.listen((message) async {
      _windowsWebViewController!.executeScript(await execute(message));
    });
    _windowsWebViewController!.loadingState.listen((state) {
      setState(() {
        _isLoading = state == wv.LoadingState.loading;
      });
    });
    await _windowsWebViewController!.loadUrl(_currentUrl);
    setState(() {
      _windowsControllerReady = true;
    });
  }

  void _initCefWebView() async {
    _cefHelper = CefWebViewHelper();
    await _cefHelper!.initialize(
      _currentUrl,
      onLoadStart: () => setState(() => _isLoading = true),
      onLoadEnd: () => setState(() => _isLoading = false),
      onMessage: (message) => execute(message),
    );
    setState(() {});
  }

  Future<String> execute(message) async {
    final data = jsonDecode(message);
    final cmd = data['command'];
    final arguments = data['arguments'] as List<dynamic>;
    final id = data['id'];

    final result = await executeCommand(cmd, arguments);
    return "window.flutterCallback('$cmd', ${jsonEncode(result)}, '$id');";
  }

  Future<Map<String, dynamic>> executeCommand(String cmd, List<dynamic> arguments) async {
    switch (cmd) {
      case 'sendTCP':
        return await sendTCP(arguments[0], arguments[1], arguments[2], arguments[3]);
      case 'sendUDP':
        return await sendUDP(arguments[0], arguments[1], arguments[2]);
      case 'readFile':
        return await readFile(arguments[0]);
      case 'deleteFile':
        return await deleteFile(arguments[0]);
      case 'fileExists':
        return await fileExists(arguments[0]);
      case 'makeDir':
        return await makeDir(arguments[0]);
      case 'moveFile':
        return await moveFile(arguments[0], arguments[1]);
      case 'copyFile':
        return await copyFile(arguments[0], arguments[1]);
      case 'listFiles':
        return await listFiles(arguments[0], arguments[1]);
      case 'writeFile':
        return await writeFile(arguments[0], arguments[1]);
      case 'getAvailablePrinters':
        return await getAvailablePrinters();
      case 'print':
        return await print(arguments[0], arguments[1], arguments[2], arguments[3]);
      case 'runCommand':
        return await runCommand(arguments[0]);
      case 'writeToSocket':
        return await writeToSocket(arguments[0], arguments[1], arguments[2], arguments[3]);
      case 'writeToComPort':
        return await writeToComPort(arguments[0], arguments[1], arguments[2]);
      case 'ping':
        return await ping(arguments[0]);
      default:
        throw UnsupportedError('Unknown command: $cmd');
    }
  }

  // Workaround for scrolling issue in webview_windows package 
  // https://github.com/jnschulze/flutter-webview-windows/issues/28#issuecomment-1765925438
  // may be fixed when newer version (> ) is out
  Future<void> _scrollWebview(double mouseX, double mouseY, double dx, double dy) {
    return _windowsWebViewController!.executeScript("""
      (function() {
        function findScrollable(el) {
          while (el && el !== document.body && el !== document.documentElement) {
            var style = window.getComputedStyle(el);
            var overflowY = style.overflowY;
            var overflowX = style.overflowX;
            if ((overflowY === 'auto' || overflowY === 'scroll') && el.scrollHeight > el.clientHeight) return el;
            if ((overflowX === 'auto' || overflowX === 'scroll') && el.scrollWidth > el.clientWidth) return el;
            el = el.parentElement;
          }
          return document.scrollingElement || document.documentElement;
        }
        var el = document.elementFromPoint($mouseX, $mouseY);
        if (!el) el = document.documentElement;
        var target = findScrollable(el);
        target.scrollBy($dx, $dy);
      })();
    """);
  }

  Widget _buildWindowsWebView() {
    return Listener(
      onPointerSignal: (signal) {
        if (signal is PointerScrollEvent) {
          _scrollWebview(
            signal.localPosition.dx,
            signal.localPosition.dy,
            signal.scrollDelta.dx,
            signal.scrollDelta.dy,
          );
        }
      },
      onPointerPanZoomUpdate: (event) {
        _scrollWebview(
          event.localPosition.dx,
          event.localPosition.dy,
          -event.panDelta.dx,
          -event.panDelta.dy,
        );
      },
      child: wv.Webview(_windowsWebViewController!),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_isReady) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

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
                    isLoading: _isLoading,
                    onNavigate: (url) {
                      setState(() {
                        _currentUrl = url;
                      });
                      if (isWindows) {
                        _windowsWebViewController?.loadUrl(url);
                      } else if (isLinux) {
                        _cefHelper?.loadUrl(url);
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
                  ? (_windowsControllerReady && _windowsWebViewController != null
                      ? _buildWindowsWebView()
                      : const Center(child: CircularProgressIndicator()))
                  : (isLinux
                      ? (_cefHelper != null && _cefHelper!.isReady
                          ? _cefHelper!.buildWebView()
                          : const Center(child: CircularProgressIndicator()))
                      : (_flutterWebViewController != null
                          ? flutter.WebViewWidget(controller: _flutterWebViewController!)
                          : const Center(child: CircularProgressIndicator()))),
            ),
          ],
        ),
      ),
    );
  }
}
