import 'dart:collection';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
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

  // Reported by _themeReporter (see below); persisted so the next launch
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
  // See _cursorOverrideReporter and windows_custom_cursor.dart.
  final ValueNotifier<MouseCursor> _cursorOverride =
      ValueNotifier(MouseCursor.defer);
  MouseCursor _colResizeCursor = SystemMouseCursors.resizeColumn;
  MouseCursor _rowResizeCursor = SystemMouseCursors.resizeRow;
  MouseCursor _colResizeCursorDark = SystemMouseCursors.resizeColumn;
  MouseCursor _rowResizeCursorDark = SystemMouseCursors.resizeRow;

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

  // The flutter_inappwebview Windows backend hosts WebView2 via a composition
  // controller with a hidden HWND. Because of that, every click first lets the
  // Flutter window steal focus (firing `blur`/`focusout`) and then WebView2
  // takes focus back (firing `focus`/`focusin`). lsFusion hides tooltips/menus
  // on `focusout`, so they vanish on the very first click. A genuine in-page
  // focus change keeps the document focused, whereas this artifact fires while
  // the document has lost focus — so swallow focus-out events that happen while
  // `document.hasFocus()` is false. See WebView2Feedback#4944.
  static const String _focusArtifactGuard = '''
    (function() {
      ['focusout', 'blur'].forEach(function(type) {
        document.addEventListener(type, function(e) {
          if (!document.hasFocus()) {
            e.stopImmediatePropagation();
          }
        }, true);
      });
    })();
  ''';

  // lsFusion opens generated files (PDF, XLSX, ...) via `window.open` /
  // `target="_blank"`. In a browser that's a new tab; under the WebView2 backend
  // it falls back to navigating the same window — a "leave site" prompt and the
  // file rendered inline, replacing the app. Intercept those file URLs in JS
  // (before any navigation happens, so no beforeunload prompt) and hand them to
  // the native side, which opens them with the OS-registered application.
  static const String _fileOpenInterceptor = r'''
    (function() {
      if (window.__lsfFileInterceptor) return;
      window.__lsfFileInterceptor = true;
      var FILE_EXTS = {pdf:1,xls:1,xlsx:1,doc:1,docx:1,csv:1,txt:1,rtf:1,png:1,jpg:1,jpeg:1,gif:1,bmp:1,svg:1,tif:1,tiff:1,zip:1,rar:1,'7z':1,xml:1,json:1,ppt:1,pptx:1,odt:1,ods:1,odp:1};
      function isFile(u) {
        try {
          var p = new URL(u, location.href).pathname.toLowerCase();
          if (p.indexOf('/file/') >= 0) return true;
          var m = p.match(/\.([a-z0-9]+)$/);
          return !!(m && FILE_EXTS[m[1]]);
        } catch (e) { return false; }
      }
      function hand(u) {
        var abs = u;
        try { abs = new URL(u, location.href).href; } catch (e) {}
        try { window.flutter_inappwebview.callHandler('openFileExternally', String(abs)); } catch (e) {}
      }
      // Return a Window-like stub instead of null: lsFusion's print/report code
      // assigns to the value returned by window.open (e.g. win.onload = ...), and
      // `null.onload = ...` throws "Cannot set properties of null". The real file
      // is opened natively via hand(), so this stub only needs to absorb the
      // calls the caller makes on the "opened" window.
      function fakeWin() {
        var noop = function() {};
        return {
          closed: false, opener: window, onload: null, onunload: null, name: '',
          focus: noop, blur: noop, print: noop, close: function() { this.closed = true; },
          addEventListener: noop, removeEventListener: noop, postMessage: noop,
          location: { href: '', replace: noop, assign: noop, reload: noop },
          document: { write: noop, writeln: noop, open: noop, close: noop }
        };
      }
      var _open = window.open;
      window.open = function(u) {
        if (u && isFile(u)) { hand(u); return fakeWin(); }
        return _open.apply(window, arguments);
      };
      document.addEventListener('click', function(e) {
        var a = e.target && e.target.closest ? e.target.closest('a[href]') : null;
        if (a && (a.target === '_blank' || a.hasAttribute('download')) && isFile(a.href)) {
          e.preventDefault();
          hand(a.href);
        }
      }, true);
    })();
  ''';

  // A native <select> opens an OS popup list. Under the composition-mode WebView2
  // backend that popup flickers (show -> hide -> show): the webview's hidden HWND
  // keeps losing focus to the Flutter window, so the OS popup, which is tied to
  // that focus, closes and reopens. Block the native popup (preventDefault on
  // mousedown) and show a custom in-DOM dropdown instead — it doesn't depend on
  // native focus, so it can't flicker. Selecting an option sets the value and
  // dispatches input/change so lsFusion picks it up. Keyboard use is left to the
  // native control (only mouse opening is intercepted).
  //
  // IMPORTANT: do NOT close the menu on `blur`/`focusout` or gate it on
  // `document.hasFocus()`. In this backend the focus signal is unreliable —
  // `hasFocus()` reports false for sustained periods and a continuous focus churn
  // fires ~2 blur/sec even while idle. Closing on any of those is exactly what made
  // the custom menu flicker too. The menu is closed only by real user actions:
  // an outside mousedown, an option pick, a keypress, a scroll, or a resize.
  static const String _selectDropdownFix = r'''
    (function() {
      if (window.__lsfSelectFix) return;
      window.__lsfSelectFix = true;
      var menu = null, menuSel = null;
      function close() {
        if (!menu) return;
        menu.remove(); menu = null; menuSel = null;
        document.removeEventListener('mousedown', onDoc, true);
        document.removeEventListener('keydown', onKey, true);
        document.removeEventListener('scroll', onScroll, true);
        window.removeEventListener('resize', close, true);
      }
      function onDoc(e) { if (menu && !menu.contains(e.target)) close(); }
      function onKey() { if (menu) close(); }
      function onScroll(e) { if (menu && !menu.contains(e.target)) close(); }
      function build(sel) {
        var r = sel.getBoundingClientRect();
        menu = document.createElement('div');
        menu.setAttribute('data-lsf-select-menu', '1');
        menu.style.cssText = 'position:fixed;z-index:2147483647;background:Canvas;color:CanvasText;border:1px solid rgba(0,0,0,.25);border-radius:4px;box-shadow:0 4px 12px rgba(0,0,0,.25);max-height:50vh;overflow-y:auto;font:inherit;box-sizing:border-box;min-width:' + Math.round(r.width) + 'px;';
        for (var i = 0; i < sel.options.length; i++) {
          (function(i) {
            var opt = sel.options[i];
            var item = document.createElement('div');
            item.textContent = (opt.text && opt.text.trim()) ? opt.text : String.fromCharCode(160);
            var isSel = i === sel.selectedIndex;
            // min-height keeps empty options (e.g. the blank "no value" row) the
            // same height as text rows instead of collapsing to a thin strip.
            item.style.cssText = 'padding:5px 10px;min-height:1.2em;cursor:pointer;white-space:nowrap;' + (isSel ? 'background:Highlight;color:HighlightText;' : '');
            item.addEventListener('mouseenter', function() { if (i !== sel.selectedIndex) item.style.background = 'rgba(127,127,127,.2)'; });
            item.addEventListener('mouseleave', function() { if (i !== sel.selectedIndex) item.style.background = ''; });
            item.addEventListener('mousedown', function(e) {
              e.preventDefault(); e.stopPropagation();
              if (sel.selectedIndex !== i) {
                sel.selectedIndex = i;
                sel.dispatchEvent(new Event('input', { bubbles: true }));
                sel.dispatchEvent(new Event('change', { bubbles: true }));
              }
              close();
            });
            menu.appendChild(item);
          })(i);
        }
        document.body.appendChild(menu);
        var mr = menu.getBoundingClientRect();
        var top = r.bottom, left = r.left;
        if (top + mr.height > window.innerHeight) top = Math.max(0, r.top - mr.height);
        if (left + mr.width > window.innerWidth) left = Math.max(0, window.innerWidth - mr.width);
        menu.style.top = Math.round(top) + 'px';
        menu.style.left = Math.round(left) + 'px';
        menuSel = sel;
        var cur = menu.children[sel.selectedIndex];
        if (cur && cur.scrollIntoView) cur.scrollIntoView({ block: 'nearest' });
        setTimeout(function() {
          document.addEventListener('mousedown', onDoc, true);
          document.addEventListener('keydown', onKey, true);
          document.addEventListener('scroll', onScroll, true);
          window.addEventListener('resize', close, true);
        }, 0);
      }
      document.addEventListener('mousedown', function(e) {
        var sel = e.target && e.target.closest ? e.target.closest('select') : null;
        if (sel && !sel.multiple && !sel.disabled && sel.options.length) {
          e.preventDefault();
          if (menuSel === sel) { close(); }
          else { close(); try { sel.focus(); } catch (x) {} build(sel); }
        }
      }, true);
    })();
  ''';

  // lsFusion renders multi-line text / script properties
  // with the ACE editor. ACE sizes itself from its container's
  // height, which lsFusion sets via a percentage/flex chain. The older Android
  // System WebView resolves that height to 0 (same class of bug as the
  // `-webkit-fill-available` modal collapse), so `.ace_editor` becomes 0px tall:
  // its content is invisible and, crucially, a tap lands on the empty outer
  // container instead of ACE's hit area — so ACE's hidden <textarea> never gets
  // focus, the soft keyboard never opens, and the user cannot type at all.
  // (Works on desktop/WebView2 where the height resolves correctly.)
  // Fix (mobile only): give the editor a definite height by absolutely filling
  // its parent, then nudge ACE to re-measure. A MutationObserver catches editors
  // created later when forms open. Scoped per-editor so no global side effects.
  static const String _aceEditorHeightFix = r'''
    (function() {
      if (window.__lsfAceFix) return;
      window.__lsfAceFix = true;
      function fix(ed) {
        if (!ed || ed.__lsfAceFixed) return;
        ed.__lsfAceFixed = true;
        var box = ed.parentElement;
        if (box && getComputedStyle(box).position === 'static') box.style.position = 'relative';
        ed.style.position = 'absolute';
        ed.style.top = '0'; ed.style.left = '0'; ed.style.right = '0'; ed.style.bottom = '0';
        try { if (window.ace) window.ace.edit(ed).resize(true); } catch (e) {}
      }
      function scan(root) {
        if (root && root.classList && root.classList.contains('ace_editor')) fix(root);
        if (root && root.querySelectorAll) {
          var list = root.querySelectorAll('.ace_editor');
          for (var i = 0; i < list.length; i++) fix(list[i]);
        }
      }
      new MutationObserver(function(muts) {
        for (var i = 0; i < muts.length; i++) {
          var added = muts[i].addedNodes;
          for (var j = 0; j < added.length; j++) {
            if (added[j].nodeType === 1) scan(added[j]);
          }
        }
      }).observe(document.documentElement, { childList: true, subtree: true });
      document.addEventListener('DOMContentLoaded', function() { scan(document); });
      scan(document);
    })();
  ''';

  // The composition-mode plugin can't map Chromium's col-resize/row-resize
  // cursors to Flutter ones (no system equivalents exist), leaving a plain
  // arrow over lsFusion's splitters and grid column handles — see
  // windows_custom_cursor.dart. This script reports those CSS cursor values
  // to the host, which applies custom glyphs via the overlay MouseRegion in
  // build(). The '/dark' suffix (lsFusion mirrors its color theme into
  // data-bs-theme on <html>; absent before login = light) selects the white
  // variant.
  static const String _cursorOverrideReporter = '''
    (function() {
      if (window.__lsfCursorReporterInstalled) return;
      window.__lsfCursorReporterInstalled = true;
      var last = '';
      function report(v) {
        if (v !== last) {
          last = v;
          try { window.flutter_inappwebview.callHandler('cursorOverride', v); } catch (e) {}
        }
      }
      document.addEventListener('mousemove', function(e) {
        var c = '';
        try { c = getComputedStyle(e.target).cursor; } catch (e2) {}
        if (c === 'col-resize' || c === 'row-resize') {
          var dark = document.documentElement.getAttribute('data-bs-theme') === 'dark';
          report(c + (dark ? '/dark' : ''));
        } else {
          report('');
        }
      }, true);
      document.addEventListener('mouseleave', function() { report(''); });
    })();
  ''';

  // lsFusion mirrors its color theme into data-bs-theme on <html>
  // (MainFrame.changeColorTheme; absent = light) and fires no JS event, so
  // the attribute is watched with a MutationObserver. Observe document, not
  // documentElement: at document-start injection time <html> does not exist
  // yet, and observing null would silently kill this script. `send` is the
  // per-webview JS statement delivering `theme` ('dark'/'light') to Dart.
  static String _themeReporter(String send) => '''
    (function() {
      if (window.__lsfThemeReporterInstalled) return;
      window.__lsfThemeReporterInstalled = true;
      var last = '';
      function report() {
        var el = document.documentElement;
        var theme = el && el.getAttribute('data-bs-theme') === 'dark' ? 'dark' : 'light';
        if (theme === last) return;
        last = theme;
        $send;
      }
      new MutationObserver(report).observe(document, {
        attributes: true, attributeFilter: ['data-bs-theme'], subtree: true
      });
      // An absent attribute means "light" only once the page is done booting;
      // reporting it earlier would flip a persisted dark theme on every load.
      // Boot end is observable: main.jsp's #loadingWrapper is removed (from
      // body) right AFTER the boot flow has applied the color theme, and
      // pages that never had it (login and friends) don't set the attribute
      // at all — they really are light.
      function reportFinal() {
        if (document.getElementById('loadingWrapper')) {
          var mo = new MutationObserver(function() {
            if (!document.getElementById('loadingWrapper')) {
              mo.disconnect();
              report();
            }
          });
          mo.observe(document.body, { childList: true });
        } else {
          report();
        }
      }
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', reportFinal);
      } else {
        reportFinal();
      }
    })();
  ''';

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

    // Registered wherever the _fileOpenInterceptor user script is injected
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
      initialUserScripts: UnmodifiableListView<UserScript>([
        UserScript(
          source: _bridgeShim,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
        UserScript(
          source: _focusArtifactGuard,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
        UserScript(
          source: _themeReporter(
              "window.flutter_inappwebview.callHandler('themeChanged', theme)"),
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
        // The file-open interceptor is needed wherever the host opens generated
        // files via window.open / target=_blank: on Windows (WebView2 navigates
        // in place) and on mobile (Android WebView shows a "leave site" prompt
        // and then drops the file — there is no native download handling).
        if (Platform.isWindows || isMobile)
          UserScript(
            source: _fileOpenInterceptor,
            injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          ),
        if (Platform.isWindows) ...[
          UserScript(
            source: _cursorOverrideReporter,
            injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          ),
          UserScript(
            source: _selectDropdownFix,
            injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          ),
        ],
        if (isMobile)
          UserScript(
            source: _aceEditorHeightFix,
            injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          ),
      ]),
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
        // lsFusion renders context menus, tooltips and other popups inside
        // Tippy.js boxes whose `.tippy-box`/`.tippy-content` is
        // `pointer-events: none`. In a normal browser the interactive Tippy
        // instance re-enables pointer events, but under the WebView2 backend
        // that does not take effect: clicks fall through the popup to whatever
        // is behind it, so menu items do nothing and tooltips dismiss on click.
        // Force pointer events back on for Tippy popups (and GWT popups/menus)
        // so they stay clickable.
        controller.injectCSSCode(source: '''
          [data-tippy-root], [data-tippy-root] *,
          .tippy-box, .tippy-box *,
          .tippy-content, .tippy-content *,
          .gwt-PopupPanel, .gwt-PopupPanel *,
          .gwt-MenuBar, .gwt-MenuBar * { pointer-events: auto !important; }
        ''');
        // lsFusion sizes shrinkable elements with `max-height: -webkit-fill-available`
        // (the `.intr-shrink-height` class). The Android System WebView mis-computes
        // that inside a height-constrained `modal-fit-content` dialog, collapsing the
        // form's action-button row to ~0px — so a tall dialog (e.g. "Design") shows no
        // Save/Cancel buttons, while desktop Chrome renders them fine. Drop the cap on
        // those elements inside modals so the buttons keep their natural height.
        controller.injectCSSCode(source: '''
          .modal-content .intr-shrink-height { max-height: none !important; }
        ''');
        setState(() => _isLoading = false);
        _injectSwipeDetector();
        if (isMobile) _injectKeyboardScrollFix();
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

  // On Android the WebView never sees the soft keyboard (Flutter owns the IME),
  // so the browser's native "scroll the focused editable into view above the
  // keyboard" never fires — we only shrink the WebView (see build()). Replicate
  // the native behaviour: whenever the viewport resizes (keyboard shows/hides,
  // address bar toggles), if the focused field is now outside the visible area,
  // scroll it back into view. Centering also leaves room for lsFusion's own
  // suggestion/dropdown popups instead of letting them cover the field.
  void _injectKeyboardScrollFix() {
    _inAppController?.evaluateJavascript(source: '''
      (function() {
        if (window.__kbScrollFixInstalled) return;
        window.__kbScrollFixInstalled = true;

        function isEditable(el) {
          if (!el) return false;
          var t = el.tagName;
          return t === 'INPUT' || t === 'TEXTAREA' || el.isContentEditable;
        }

        function keepFocusedVisible() {
          var ae = document.activeElement;
          if (!isEditable(ae)) return;
          var vh = window.visualViewport ? window.visualViewport.height : window.innerHeight;
          var r = ae.getBoundingClientRect();
          if (r.top < 0 || r.bottom > vh) {
            try { ae.scrollIntoView({ block: 'center', inline: 'nearest' }); } catch (e) {}
          }
        }

        var timer = null;
        function onResize() {
          if (timer) clearTimeout(timer);
          // let the WebView resize / reflow settle before re-revealing the field
          timer = setTimeout(keepFocusedVisible, 100);
        }

        (window.visualViewport || window).addEventListener('resize', onResize);
      })();
    ''');
  }

  // webview_cef's own `Flutter` alias is a bare function (and is wiped on
  // navigation anyway); the web client expects `Flutter.postMessage(...)`
  // and decides at boot whether it runs under Flutter, so the shim must be
  // in place before the page scripts run (onLoadStart) — onLoadEnd again as
  // a fallback in case the start-time injection raced the navigation.
  static const String _cefFlutterShim =
      "window.Flutter = { postMessage: function(m) {"
      " external.JavaScriptChannel('Flutter', m, null); } };";

  void _initCefWebView() async {
    _cefHelper = CefWebViewHelper();
    await _cefHelper!.initialize(
      _currentUrl,
      onLoadStart: () {
        setState(() => _isLoading = true);
        _cefHelper!.executeJavaScript(_cefFlutterShim);
      },
      onLoadEnd: () {
        setState(() => _isLoading = false);
        _checkHideAddressBar();
        _cefHelper!.executeJavaScript(_cefFlutterShim);
        // CEF has no document-start user scripts, so (re)install per load.
        // `external` is a persistent CEF V8 extension, unlike the channel
        // alias globals, which are wiped on navigation.
        _cefHelper!.executeJavaScript(_themeReporter(
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
              child: webViewContent,
            ),
            // Applies the cursors reported by _cursorOverrideReporter.
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
