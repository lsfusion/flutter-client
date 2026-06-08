import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
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
  InAppWebViewController? _inAppController;
  CefWebViewHelper? _cefHelper;

  bool _showAddressBar = true;
  bool _isLoading = false;
  bool _isReady = false;
  bool _isMouseInAddressBar = false;
  bool _isAddressBarFocused = false;
  bool _hasLoadError = false;

  String _currentUrl = 'http://127.0.0.1:8080/main';

  bool get isLinux => Platform.isLinux;
  bool get isMobile => Platform.isAndroid || Platform.isIOS;

  // Compatibility shim injected before any page script runs. The lsFusion web
  // client talks to the host through `Flutter.postMessage`,
  // `FlutterAddressBar.postMessage` and `window.chrome.webview.postMessage`
  // (the APIs exposed by the previous webview_flutter / webview_windows
  // backends). flutter_inappwebview instead exposes
  // `window.flutter_inappwebview.callHandler(name, ...)`, so we recreate the
  // old global names and route them to the new bridge. This keeps the
  // server-side web client working unchanged.
  static const String _bridgeShim = '''
    (function() {
      if (window.__lsfBridgeInstalled) return;
      window.__lsfBridgeInstalled = true;
      function call(name, msg) {
        try { window.flutter_inappwebview.callHandler(name, msg); } catch (e) {}
      }
      window.Flutter = { postMessage: function(m) { call('Flutter', m); } };
      window.FlutterAddressBar = { postMessage: function(m) { call('FlutterAddressBar', m); } };
      window.chrome = window.chrome || {};
      if (!window.chrome.webview || typeof window.chrome.webview.postMessage !== 'function') {
        window.chrome.webview = window.chrome.webview || {};
        window.chrome.webview.postMessage = function(m) { call('Flutter', m); };
      }
    })();
  ''';

  void _setAddressBarVisible(bool visible) {
    setState(() => _showAddressBar = visible);
  }

  void _checkHideAddressBar() {
    if (!_isMouseInAddressBar && !_isAddressBarFocused && !_isLoading) {
      setState(() => _showAddressBar = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _loadLastUrl();
    if (isLinux) {
      _initCefWebView();
    }
  }

  Future<void> _loadLastUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final history = prefs.getStringList('history') ?? [];
    if (history.isNotEmpty) {
      _currentUrl = history.last;
    }

    setState(() {
      _isReady = true;
    });
  }

  void _onWebViewCreated(InAppWebViewController controller) {
    _inAppController = controller;

    controller.addJavaScriptHandler(
      handlerName: 'Flutter',
      callback: (args) async {
        final message = args.isNotEmpty ? args[0] as String : '';
        await controller.evaluateJavascript(source: await execute(message));
        return null;
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'FlutterAddressBar',
      callback: (args) {
        final message = args.isNotEmpty ? args[0] as String : '';
        if (message == 'show') {
          _setAddressBarVisible(true);
        } else if (message == 'hide') {
          _setAddressBarVisible(false);
        }
        return null;
      },
    );
  }

  Widget _buildInAppWebView() {
    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(_currentUrl)),
      initialUserScripts: UnmodifiableListView<UserScript>([
        UserScript(
          source: _bridgeShim,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
      ]),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        transparentBackground: true,
        supportZoom: false,
      ),
      onWebViewCreated: _onWebViewCreated,
      onLoadStart: (controller, url) {
        setState(() {
          _isLoading = true;
          _hasLoadError = false;
        });
      },
      onLoadStop: (controller, url) {
        setState(() => _isLoading = false);
        _injectSwipeDetector();
        if (!_hasLoadError) {
          _checkHideAddressBar();
        }
      },
      onReceivedError: (controller, request, error) {
        if (request.isForMainFrame ?? false) {
          setState(() => _hasLoadError = true);
        }
      },
    );
  }

  void _injectSwipeDetector() {
    // detects swipe only on non-scrollable elements to show/hide address bar
    _inAppController?.evaluateJavascript(source: '''
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

  void _initCefWebView() async {
    _cefHelper = CefWebViewHelper();
    await _cefHelper!.initialize(
      _currentUrl,
      onLoadStart: () => setState(() => _isLoading = true),
      onLoadEnd: () {
        setState(() => _isLoading = false);
        _checkHideAddressBar();
      },
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

  @override
  Widget build(BuildContext context) {
    if (!_isReady) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final webViewContent = isLinux
        ? (_cefHelper != null && _cefHelper!.isReady
            ? _cefHelper!.buildWebView()
            : const Center(child: CircularProgressIndicator()))
        : _buildInAppWebView();

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
        color: Colors.transparent,
      ),
    );
  }

  Widget _buildAddressBarArea() {
    final addressBar = Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      padding: const EdgeInsets.all(8.0),
      child: AddressBar(
        initialUrl: _currentUrl,
        isLoading: _isLoading,
        onNavigate: (url) {
          setState(() {
            _currentUrl = url;
            _showAddressBar = true;
            _isLoading = true;
          });
          if (isLinux) {
            _cefHelper?.loadUrl(url);
          } else {
            _inAppController?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
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
