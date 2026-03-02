import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_windows/webview_windows.dart' as wv;
import 'package:flutter_linux_webview/flutter_linux_webview.dart' as lv;
import 'package:shared_preferences/shared_preferences.dart';

import 'address_bar.dart';
import 'native.dart' as native;

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

class _WebViewPageState extends State<WebViewPage> with WidgetsBindingObserver {
  WebViewController? _controller;
  wv.WebviewController? _windowsWebViewController;
  bool _windowsControllerReady = false;
  bool _linuxInitialized = false;

  bool _showAddressBar = false;
  bool _isLoading = false;
  bool _isReady = false;

  String _currentUrl = 'http://192.168.1.44:8888/main';

  bool get isWindows => Platform.isWindows;
  bool get isLinux => Platform.isLinux;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (isLinux) {
      WebView.platform = lv.LinuxWebView();
      _initLinuxWebView();
    }
    _loadLastUrl();
    if (isWindows) {
      _initWindowsWebView();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (isLinux) {
      lv.LinuxWebViewPlugin.terminate();
    }
    super.dispose();
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    if (isLinux) {
      await lv.LinuxWebViewPlugin.terminate();
    }
    return AppExitResponse.exit;
  }

  Future<void> _initLinuxWebView() async {
    try {
      await lv.LinuxWebViewPlugin.initialize();
      if (mounted) {
        setState(() {
          _linuxInitialized = true;
        });
      }
    } catch (e) {
      debugPrint('Failed to initialize Linux WebView: $e');
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
        return await native.sendTCP(arguments[0], arguments[1], arguments[2], arguments[3]);
      case 'sendUDP':
        return await native.sendUDP(arguments[0], arguments[1], arguments[2]);
      case 'readFile':
        return await native.readFile(arguments[0]);
      case 'deleteFile':
        return await native.deleteFile(arguments[0]);
      case 'fileExists':
        return await native.fileExists(arguments[0]);
      case 'makeDir':
        return await native.makeDir(arguments[0]);
      case 'moveFile':
        return await native.moveFile(arguments[0], arguments[1]);
      case 'copyFile':
        return await native.copyFile(arguments[0], arguments[1]);
      case 'listFiles':
        return await native.listFiles(arguments[0], arguments[1]);
      case 'writeFile':
        return await native.writeFile(arguments[0], arguments[1]);
      case 'getAvailablePrinters':
        return await native.getAvailablePrinters();
      case 'print':
        return await native.print(arguments[0], arguments[1], arguments[2], arguments[3]);
      case 'runCommand':
        return await native.runCommand(arguments[0]);
      case 'writeToSocket':
        return await native.writeToSocket(arguments[0], arguments[1], arguments[2], arguments[3]);
      case 'writeToComPort':
        return await native.writeToComPort(arguments[0], arguments[1], arguments[2]);
      case 'ping':
        return await native.ping(arguments[0]);
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
                      } else {
                        _controller?.loadUrl(url);
                      }
                    },
                  ),
                ),
              ),
            ),
            Expanded(
              child: isWindows
                  ? (_windowsControllerReady && _windowsWebViewController != null
                      ? wv.Webview(_windowsWebViewController!)
                      : const Center(child: CircularProgressIndicator()))
                  : (isLinux && !_linuxInitialized
                      ? const Center(child: CircularProgressIndicator())
                      : WebView(
                          initialUrl: _currentUrl,
                          javascriptMode: JavascriptMode.unrestricted,
                          onWebViewCreated: (WebViewController webViewController) {
                            _controller = webViewController;
                          },
                          javascriptChannels: <JavascriptChannel>{
                            JavascriptChannel(
                              name: 'Flutter',
                              onMessageReceived: (JavascriptMessage message) async {
                                final jsResponse = await execute(message.message);
                                _controller?.runJavascript(jsResponse);
                              },
                            ),
                          },
                          onPageStarted: (url) {
                            setState(() {
                              _isLoading = true;
                              _currentUrl = url;
                            });
                          },
                          onPageFinished: (url) {
                            setState(() {
                              _isLoading = false;
                            });
                          },
                        )),
            ),
          ],
        ),
      ),
    );
  }
}
