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
  String _currentUrl = 'http://192.168.0.19:8888/main';

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
          _flutterWebViewController!.runJavaScript(
            await execute(message.message),
          );
        },
      )
      ..loadRequest(Uri.parse(_currentUrl));
  }

  void _initWindowsWebView() async {
    _windowsWebViewController = wv.WebviewController();
    await _windowsWebViewController!.initialize();
    _windowsWebViewController!.webMessage.listen((message) async {
        _windowsWebViewController!.executeScript(await execute(message));
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
