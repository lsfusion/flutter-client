import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:webview_all/webview_all.dart';
import 'package:webview_all_windows/webview_all_windows.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'address_bar.dart';
import 'native.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    await WindowsWebViewController.initializeEnvironment();
  }
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
  State<WebViewPage> createState() => _WebViewPageState();
}

class _WebViewPageState extends State<WebViewPage> {
  WebViewController? _controller;
  bool _controllerReady = false;

  bool _showAddressBar = false;
  bool _isLoading = false;
  bool _isReady = false;

  // String _currentUrl = 'http://192.168.1.44:8080/lsf';
  // String _currentUrl = 'https://demo.lsfusion.org/mycompany/';
  String _currentUrl = 'http://192.168.1.44:8888/main';

  bool get isWindows => Platform.isWindows;
  bool get isLinux => Platform.isLinux;

  @override
  void initState() {
    super.initState();
    _loadLastUrl();
    _initWebView();
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

  void _initWebView() {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'Flutter',
        onMessageReceived: (JavaScriptMessage message) async {
          _controller!.runJavaScript(
            await execute(message.message),
          );
        },
      )
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) {
          setState(() => _isLoading = true);
        },
        onPageFinished: (_) {
          setState(() => _isLoading = false);
        },
      ))
      ..loadRequest(Uri.parse(_currentUrl));

    setState(() {
      _controllerReady = true;
    });
  }

  Future<String> execute(dynamic message) async {
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
              child: ClipRect(
                child: OverflowBox(
                  minHeight: 60,
                  maxHeight: 60,
                  alignment: Alignment.topCenter,
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
                          _controller?.loadRequest(Uri.parse(url));
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: _controllerReady && _controller != null
                  ? WebViewWidget(controller: _controller!)
                  : const Center(child: CircularProgressIndicator()),
            ),
          ],
        ),
      ),
    );
  }
}
