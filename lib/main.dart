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
  bool _isMouseInAddressBar = false;
  bool _isAddressBarFocused = false;

  String _currentUrl = 'http://127.0.0.1:8080/main';

  bool get isWindows => Platform.isWindows;
  bool get isLinux => Platform.isLinux;
  bool get isMobile => Platform.isAndroid || Platform.isIOS;

  void _setAddressBarVisible(bool visible) {
    setState(() => _showAddressBar = visible);
  }

  void _checkHideAddressBar() {
    if (!_isMouseInAddressBar && !_isAddressBarFocused) {
      setState(() => _showAddressBar = false);
    }
  }

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
      ..addJavaScriptChannel(
        'FlutterAddressBar',
        onMessageReceived: (flutter.JavaScriptMessage message) {
          if (message.message == 'show') {
            _setAddressBarVisible(true);
          } else if (message.message == 'hide') {
            _setAddressBarVisible(false);
          }
        },
      )
      ..setNavigationDelegate(flutter.NavigationDelegate(
        onPageStarted: (_) {
          setState(() => _isLoading = true);
        },
        onPageFinished: (_) {
          setState(() => _isLoading = false);
          _injectSwipeDetector();
        },
      ))
      ..loadRequest(Uri.parse(_currentUrl));
  }

  void _injectSwipeDetector() {
    // detects swipe only on non-scrollable elements to show/hide address bar
    _flutterWebViewController?.runJavaScript('''
      (function() {
        if (window.__swipeDetectorInstalled) return;
        window.__swipeDetectorInstalled = true;

        var startY = 0;
        var startX = 0;
        var startEl = null;

        function findScrollableVertical(el) {
          while (el && el !== document.body && el !== document.documentElement) {
            var style = window.getComputedStyle(el);
            var overflowY = style.overflowY;
            if ((overflowY === 'auto' || overflowY === 'scroll') && el.scrollHeight > el.clientHeight) return el;
            el = el.parentElement;
          }
          var root = document.scrollingElement || document.documentElement;
          if (root.scrollHeight > root.clientHeight) return root;
          return null;
        }

        document.addEventListener('touchstart', function(e) {
          if (e.touches.length === 1) {
            startY = e.touches[0].clientY;
            startX = e.touches[0].clientX;
            startEl = e.touches[0].target;
          }
        }, { passive: true });

        document.addEventListener('touchend', function(e) {
          if (e.changedTouches.length === 1) {
            var dy = e.changedTouches[0].clientY - startY;
            var dx = e.changedTouches[0].clientX - startX;
            if (Math.abs(dy) > 50 && Math.abs(dy) > Math.abs(dx)) {
              var scrollable = findScrollableVertical(startEl);
              if (!scrollable) {
                if (dy > 0) {
                  FlutterAddressBar.postMessage('show');
                } else {
                  FlutterAddressBar.postMessage('hide');
                }
              }
            }
          }
        }, { passive: true });
      })();
    ''');
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

    final webViewContent = isWindows
        ? (_windowsControllerReady && _windowsWebViewController != null
            ? _buildWindowsWebView()
            : const Center(child: CircularProgressIndicator()))
        : (isLinux
            ? (_cefHelper != null && _cefHelper!.isReady
                ? _cefHelper!.buildWebView()
                : const Center(child: CircularProgressIndicator()))
            : (_flutterWebViewController != null
                ? flutter.WebViewWidget(controller: _flutterWebViewController!)
                : const Center(child: CircularProgressIndicator())));

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(child: webViewContent),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!isMobile) _buildDesktopTriggerZone(),
                  _buildAddressBarArea(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDesktopTriggerZone() {
    if (_showAddressBar) return const SizedBox.shrink();
    return MouseRegion(
      onEnter: (_) {
        _isMouseInAddressBar = true;
        _setAddressBarVisible(true);
      },
      child: Container(
        height: 4,
        color: Colors.white.withAlpha((255.0 * 0.3).round()),
      ),
    );
  }

  Widget _buildAddressBarArea() {
    final addressBar = Container(
      color: Theme.of(context).scaffoldBackgroundColor.withAlpha((255.0 * 0.9).round()),
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
    );

    final animatedBar = AnimatedCrossFade(
      duration: const Duration(milliseconds: 300),
      firstChild: addressBar,
      secondChild: const SizedBox(width: double.infinity, height: 0),
      crossFadeState: _showAddressBar ? CrossFadeState.showFirst : CrossFadeState.showSecond,
      sizeCurve: Curves.easeInOut,
    );

    if (isMobile) return animatedBar;

    return MouseRegion(
      onEnter: (_) {
        _isMouseInAddressBar = true;
      },
      onExit: (_) {
        _isMouseInAddressBar = false;
        _checkHideAddressBar();
      },
      child: Focus(
        onFocusChange: (hasFocus) {
          _isAddressBarFocused = hasFocus;
          if (!hasFocus) {
            _checkHideAddressBar();
          }
        },
        child: animatedBar,
      ),
    );
  }
}
