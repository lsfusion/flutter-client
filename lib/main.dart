import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:win32/win32.dart';

import 'cef_webview_stub.dart'
    if (dart.library.io) 'cef_webview_impl.dart';

import 'address_bar.dart';
import 'native.dart';
import 'webview_workarounds.dart';
import 'windows_custom_cursor.dart';

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

  // Reported by themeReporter (webview_workarounds.dart); persisted so the
  // next launch
  // paints in the last known theme before the page gets to report it.
  bool _isDarkTheme = false;

  // lsFusion's Bootstrap body backgrounds: light #fff, dark #212529.
  Color get _backgroundColor =>
      _isDarkTheme ? const Color(0xFF212529) : const Color(0xFFFFFFFF);

  void _applyTheme(String theme) {
    final dark = theme == 'dark';
    if (dark == _isDarkTheme) return;
    setState(() => _isDarkTheme = dark);
    _applySystemBars();
    SharedPreferences.getInstance()
        .then((p) => p.setBool('darkTheme', _isDarkTheme));
  }

  // Mobile system bar icons must contrast with _backgroundColor behind them.
  void _applySystemBars() {
    final icons = _isDarkTheme ? Brightness.light : Brightness.dark;
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      // iOS derives icon contrast from the bar background's brightness.
      statusBarBrightness: _isDarkTheme ? Brightness.dark : Brightness.light,
      statusBarIconBrightness: icons,
      systemNavigationBarColor: _backgroundColor,
      systemNavigationBarIconBrightness: icons,
    ));
  }

  String _currentUrl = 'http://127.0.0.1:8080/main';

  bool get isLinux => Platform.isLinux;
  bool get isMobile => Platform.isAndroid || Platform.isIOS;

  // Applied by the overlay MouseRegion in build(); the custom glyphs are
  // registered asynchronously in initState, system double arrows until then.
  // See cursorOverrideReporter (webview_workarounds.dart) and
  // windows_custom_cursor.dart.
  final ValueNotifier<MouseCursor> _cursorOverride =
      ValueNotifier(MouseCursor.defer);
  MouseCursor _colResizeCursor = SystemMouseCursors.resizeColumn;
  MouseCursor _rowResizeCursor = SystemMouseCursors.resizeRow;
  MouseCursor _colResizeCursorDark = SystemMouseCursors.resizeColumn;
  MouseCursor _rowResizeCursorDark = SystemMouseCursors.resizeRow;

  Future<void> _initCustomCursors() async {
    final scale = WidgetsBinding
            .instance.platformDispatcher.implicitView?.devicePixelRatio ??
        1.0;
    _colResizeCursor = await registerResizeCursor('lsf-col-resize',
        vertical: false, forDarkBackground: false, scale: scale);
    _rowResizeCursor = await registerResizeCursor('lsf-row-resize',
        vertical: true, forDarkBackground: false, scale: scale);
    _colResizeCursorDark = await registerResizeCursor('lsf-col-resize-dark',
        vertical: false, forDarkBackground: true, scale: scale);
    _rowResizeCursorDark = await registerResizeCursor('lsf-row-resize-dark',
        vertical: true, forDarkBackground: true, scale: scale);
  }

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
    if (Platform.isWindows) {
      _initCustomCursors();
    }
  }

  Future<void> _loadLastUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final history = prefs.getStringList('history') ?? [];
    if (history.isNotEmpty) {
      _currentUrl = history.last;
    }

    setState(() {
      _isDarkTheme = prefs.getBool('darkTheme') ?? false;
      _isReady = true;
    });
    _applySystemBars();
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

    if (Platform.isWindows) {
      controller.addJavaScriptHandler(
        handlerName: 'cursorOverride',
        callback: (args) {
          final value = args.isNotEmpty ? args[0] as String : '';
          final dark = value.endsWith('/dark');
          final cursor = dark ? value.substring(0, value.length - 5) : value;
          _cursorOverride.value = switch (cursor) {
            'col-resize' => dark ? _colResizeCursorDark : _colResizeCursor,
            'row-resize' => dark ? _rowResizeCursorDark : _rowResizeCursor,
            _ => MouseCursor.defer,
          };
          return null;
        },
      );
    }

    // Registered wherever the fileOpenInterceptor user script is injected
    // (Windows + mobile): the interceptor hands file URLs here so we open them
    // with the OS instead of letting the webview navigate to them.
    if (Platform.isWindows || isMobile) {
      controller.addJavaScriptHandler(
        handlerName: 'openFileExternally',
        callback: (args) {
          final url = args.isNotEmpty ? args[0] as String : '';
          if (url.isNotEmpty) _openFileExternally(url);
          return null;
        },
      );
    }

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

    controller.addJavaScriptHandler(
      handlerName: 'themeChanged',
      callback: (args) {
        _applyTheme(args.isNotEmpty ? args[0] as String : '');
        return null;
      },
    );
  }

  Widget _buildInAppWebView() {
    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(_currentUrl)),
      initialUserScripts: workaroundUserScripts(
          windows: Platform.isWindows, mobile: isMobile),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
      ),
      onWebViewCreated: _onWebViewCreated,
      onLoadStart: (controller, url) {
        setState(() {
          _isLoading = true;
          _hasLoadError = false;
        });
      },
      onLoadStop: (controller, url) {
        controller.injectCSSCode(source: popupPointerEventsCss);
        controller.injectCSSCode(source: modalShrinkHeightCss);
        setState(() => _isLoading = false);
        controller.evaluateJavascript(source: swipeDetector);
        if (isMobile) controller.evaluateJavascript(source: keyboardScrollFix);
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

  // Dart side of the Explorer-to-page bridge (driver 2 of
  // dragAndDropSupport). desktop_drop positions are logical pixels, which
  // map 1:1 onto the page's CSS pixels.
  DateTime _extDragLastMove = DateTime.fromMillisecondsSinceEpoch(0);

  void _extDragPoint(String fn, Offset p) {
    _inAppController?.evaluateJavascript(
        source: 'window.__lsfExtDrag.$fn('
            '${p.dx.toStringAsFixed(1)}, ${p.dy.toStringAsFixed(1)})');
  }

  void _onExtDragUpdated(DropEventDetails d) {
    final now = DateTime.now();
    if (now.difference(_extDragLastMove).inMilliseconds < 25) return;
    _extDragLastMove = now;
    _extDragPoint('move', d.localPosition);
  }

  Future<void> _onExtDragDone(DropDoneDetails d) async {
    final controller = _inAppController;
    if (controller == null) return;
    // 3 MB per slice; a multiple of 3 keeps each slice standalone base64
    const chunkBytes = 3 * 1024 * 1024;
    var index = 0;
    for (final item in d.files) {
      if (item is DropItemDirectory) continue; // folders have no page-side form
      final Uint8List bytes;
      try {
        bytes = await item.readAsBytes();
      } catch (e) {
        debugPrint('external drop: cannot read ${item.name}: $e');
        continue;
      }
      await controller.evaluateJavascript(
          source: 'window.__lsfExtDrag.file($index, ${jsonEncode(item.name)})');
      for (var off = 0; off < bytes.length; off += chunkBytes) {
        final end = off + chunkBytes > bytes.length ? bytes.length : off + chunkBytes;
        await controller.evaluateJavascript(
            source: 'window.__lsfExtDrag.chunk($index, '
                '"${base64Encode(Uint8List.sublistView(bytes, off, end))}")');
      }
      index++;
    }
    // nothing usable (folders only / unreadable): a native drag would not
    // deliver an empty drop, so end the hover instead
    _extDragPoint(index > 0 ? 'drop' : 'leave', d.localPosition);
  }

  void _initCefWebView() async {
    _cefHelper = CefWebViewHelper();
    await _cefHelper!.initialize(
      _currentUrl,
      onLoadStart: () {
        setState(() => _isLoading = true);
        // the shim must be in place before the page scripts run — onLoadEnd
        // again as a fallback in case the start-time injection raced the
        // navigation
        _cefHelper!.executeJavaScript(cefFlutterShim);
      },
      onLoadEnd: () {
        setState(() => _isLoading = false);
        _checkHideAddressBar();
        _cefHelper!.executeJavaScript(cefFlutterShim);
        // CEF has no document-start user scripts, so (re)install per load.
        // `external` is a persistent CEF V8 extension, unlike the channel
        // alias globals, which are wiped on navigation.
        _cefHelper!.executeJavaScript(themeReporter(
            "external.JavaScriptChannel('themeChanged', theme, null)"));
      },
      onMessage: (message) => execute(message),
      onThemeChanged: _applyTheme,
    );
    setState(() {});
  }

  // Download the file using the webview's session cookies, then open it with the
  // OS-registered application. Falls back to handing the raw URL to the shell.
  Future<void> _openFileExternally(String url) async {
    try {
      final uri = Uri.parse(url);
      final cookies = await CookieManager.instance().getCookies(url: WebUri(url));
      final headers = <String, String>{};
      if (cookies.isNotEmpty) {
        headers['Cookie'] = cookies.map((c) => '${c.name}=${c.value}').join('; ');
      }
      final resp = await http.get(uri, headers: headers);
      if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
        var name = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : 'download';
        name = name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
        if (name.isEmpty) name = 'download';
        final file = File(
            '${Directory.systemTemp.path}${Platform.pathSeparator}$name');
        await file.writeAsBytes(resp.bodyBytes);
        if (Platform.isWindows) {
          _shellOpen(file.path); // ShellExecute via win32
        } else {
          await OpenFilex.open(file.path); // Android/iOS/macOS system opener
        }
        return;
      }
    } catch (e) {
      debugPrint('open file externally failed: $e');
    }
    // Fallback: on Windows hand the raw URL to the shell (default browser).
    // Other platforms have no safe raw-URL opener here, so just log above.
    if (Platform.isWindows) {
      _shellOpen(url);
    }
  }

  void _shellOpen(String target) {
    final pTarget = target.toNativeUtf16();
    final pOp = 'open'.toNativeUtf16();
    try {
      ShellExecute(0, pOp, pTarget, nullptr, nullptr, SW_SHOWNORMAL);
    } finally {
      calloc.free(pTarget);
      calloc.free(pOp);
    }
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
        return await writeFile(arguments[0], arguments[1],
            arguments.length > 2 ? arguments[2] as String? : null);
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
      return Scaffold(
        backgroundColor: _backgroundColor,
        body: const Center(child: CircularProgressIndicator(color: Colors.grey)),
      );
    }

    final webViewContent = isLinux
        ? (_cefHelper != null && _cefHelper!.isReady
            ? _cefHelper!.buildWebView()
            : const Center(child: CircularProgressIndicator(color: Colors.grey)))
        : _buildInAppWebView();

    // Windows: desktop_drop registers the missing OLE drop target; events go
    // to dragAndDropSupport driver 2.
    final webViewArea = Platform.isWindows
        ? DropTarget(
            onDragEntered: (d) => _extDragPoint('enter', d.localPosition),
            onDragUpdated: _onExtDragUpdated,
            onDragExited: (d) => _extDragPoint('leave', d.localPosition),
            onDragDone: _onExtDragDone,
            child: webViewContent,
          )
        : webViewContent;

    // On Android 15+/edge-to-edge the manifest's adjustResize no longer shrinks
    // the window for the soft keyboard, so a focused input in the lower part of
    // a form ends up hidden behind the keyboard. Reserve the keyboard height
    // ourselves (and turn off Scaffold's own resize so we don't subtract it
    // twice) so the webview shrinks and scrolls the focused field into view.
    final imeInset = MediaQuery.of(context).viewInsets.bottom;

    return Scaffold(
      backgroundColor: _backgroundColor,
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              bottom: imeInset,
              child: webViewArea,
            ),
            // Applies the cursors reported by cursorOverrideReporter.
            // opaque: false keeps it transparent to pointer events; being in
            // front of the webview, a non-defer cursor here wins over the
            // plugin's own MouseRegion.
            if (Platform.isWindows)
              Positioned.fill(
                child: ValueListenableBuilder<MouseCursor>(
                  valueListenable: _cursorOverride,
                  builder: (context, cursor, _) =>
                      MouseRegion(cursor: cursor, opaque: false),
                ),
              ),
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
    final addressBar = Theme(
      data: ThemeData(
        brightness: _isDarkTheme ? Brightness.dark : Brightness.light,
      ),
      child: Container(
        color: _backgroundColor,
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
