// Workarounds for gaps in the embedded webview backends, injected into the
// page. Most patch the composition-mode WebView2 backend on Windows (input,
// focus and drag-and-drop all arrive through the host there, and the plugin
// leaves several of those paths unwired); the rest cover Android WebView
// quirks and API differences between backends. Each script documents the
// quirk it patches; the platform gating lives in workaroundUserScripts().

import 'dart:collection';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

// Compatibility shim injected before any page script runs. The lsFusion web
// client talks to the host through `Flutter.postMessage`,
// `FlutterAddressBar.postMessage` and `window.chrome.webview.postMessage`
// (the APIs exposed by the previous webview_flutter / webview_windows
// backends). flutter_inappwebview instead exposes
// `window.flutter_inappwebview.callHandler(name, ...)`, so we recreate the
// old global names and route them to the new bridge. This keeps the
// server-side web client working unchanged.
const String bridgeShim = '''
  (function() {
    if (window.__lsfBridgeInstalled) return;
    window.__lsfBridgeInstalled = true;
    function call(name, msg) {
      try { window.flutter_inappwebview.callHandler(name, msg); } catch (e) {}
    }
    window.Flutter = { postMessage: function(m) { call('Flutter', m); } };
    window.FlutterAddressBar = { postMessage: function(m) { call('FlutterAddressBar', m); } };
    window.chrome = window.chrome || {};
    window.chrome.webview = window.chrome.webview || {};
    // On Windows WebView2 already provides a native chrome.webview.postMessage
    // that the flutter_inappwebview plugin's own bridge uses (envelope
    // {name:'callHandler',...}). But the lsFusion web client ALSO posts here, in
    // its own {command,arguments,id} format (getFlutterObject() returns
    // chrome.webview on Windows) — and the plugin drops anything that isn't its
    // callHandler envelope, so every client bridge action (WRITE/READ CLIENT,
    // getAvailablePrinters, PRINT ... NOPREVIEW TO, sockets, ...) was silently
    // lost. So always wrap postMessage and route by message type: lsFusion's
    // JSON-string messages go to the Flutter handler, everything else (incl. the
    // plugin's own object messages) passes through to the native postMessage.
    // Routing by type keeps this safe regardless of script-injection order — no
    // recursion even if the plugin captured this wrapper as its _postMessage.
    var _nativePM = null;
    try {
      if (typeof window.chrome.webview.postMessage === 'function')
        _nativePM = window.chrome.webview.postMessage.bind(window.chrome.webview);
    } catch (e) {}
    window.chrome.webview.postMessage = function(m) {
      if (typeof m === 'string') { call('Flutter', m); return; }
      if (_nativePM) return _nativePM(m);
    };
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
const String focusArtifactGuard = '''
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
const String fileOpenInterceptor = r'''
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
const String selectDropdownFix = r'''
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

// Drag-and-drop under the composition-mode WebView2 backend, which lacks
// all the drag plumbing that mode requires from the host (no IDropTarget /
// CompositionController3 forwarding, no DragStarting). Two broken flows,
// two drivers on shared machinery:
//
// 1) In-page drags: dragstart fires, the system drag dies ~10ms later,
//    dragover/drop never follow. Driver 1 cancels the native dragstart
//    (which keeps the mouse stream alive) and replays the whole HTML5
//    chain from mouse events: shared constructed DataTransfer, ghost under
//    the cursor (setDragImage honored), ESC cancels; raw mousemove/mouseup
//    are hidden and the trailing click swallowed, as in a native drag.
//
// 2) Explorer-to-page file drags: no OLE drop target in the process, so an
//    OS drag never reaches the page (and delivers no mouse events either).
//    The Dart side wraps the webview in a desktop_drop DropTarget and
//    relays hover positions and dropped files into window.__lsfExtDrag,
//    which replays them as dragenter/dragover/drop with real File objects.
//
// Dragging content out of the app stays unsupported (needs drag-source
// work in the plugin).
const String dragAndDropSupport = r'''
  (function() {
    if (window.__lsfDndInstalled) return;
    window.__lsfDndInstalled = true;

    // ---------- shared machinery ----------

    function synth(type, target, x, y, dt, related) {
      var ev = new DragEvent(type, {
        bubbles: true, composed: true, view: window,
        cancelable: type !== 'dragleave' && type !== 'dragend',
        dataTransfer: dt, clientX: x, clientY: y,
        relatedTarget: related || null
      });
      ev.__lsfSynth = true;
      return !target.dispatchEvent(ev); // true = defaultPrevented = accepted
    }

    function hit(x, y) {
      return document.elementFromPoint(x, y) || document.documentElement;
    }

    // the native effectAllowed/dropEffect setters are inert on a
    // constructed DataTransfer — shadow them with plain instance properties
    function shadowDt(dt, effectAllowed, dropEffect) {
      Object.defineProperty(dt, 'effectAllowed', { value: effectAllowed, writable: true });
      Object.defineProperty(dt, 'dropEffect', { value: dropEffect, writable: true });
    }

    // Tracks the drop target through one drag: enter/leave on target
    // change, dragover (after resetEffect) on every move, whether the
    // target accepted; finish() fires drop or dragleave accordingly.
    function makeTracker(dt, resetEffect) {
      return {
        dt: dt, cur: null, allowed: false,
        move: function(x, y) {
          var t = hit(x, y);
          if (t !== this.cur) {
            if (this.cur) synth('dragleave', this.cur, x, y, this.dt, t);
            var prev = this.cur;
            this.cur = t;
            this.allowed = false;
            synth('dragenter', t, x, y, this.dt, prev);
          }
          resetEffect(this.dt);
          this.allowed = synth('dragover', t, x, y, this.dt);
        },
        finish: function(x, y, mayDrop) {
          if (mayDrop && this.cur && this.allowed) {
            synth('drop', this.cur, x, y, this.dt);
          } else {
            this.dt.dropEffect = 'none';
            if (this.cur) synth('dragleave', this.cur, x, y, this.dt);
          }
        }
      };
    }

    // ---------- driver 1: in-page drags ----------

    var session = null; // {src, tr, x, y} + ghost/gdx/gdy/timer once created
    var clickGuardUntil = 0;
    var swallowRelease = false; // ESC canceled the drag with the button down

    function defaultDropEffect(dt) {
      var ea = dt.effectAllowed;
      dt.dropEffect = (ea === 'copy' || ea === 'copyLink') ? 'copy'
        : (ea === 'link' || ea === 'linkMove') ? 'link'
        : ea === 'none' ? 'none' : 'move';
    }

    function moveGhost(x, y) {
      if (session.ghost) {
        session.ghost.style.transform =
          'translate(' + (x - session.gdx) + 'px,' + (y - session.gdy) + 'px)';
      }
    }

    function makeGhost(e) {
      var s = session, img = s.tr.dt.__lsfDragImage, el, dx, dy;
      if (img) {
        el = img.el; dx = img.x; dy = img.y;
      } else {
        el = s.src.closest('[draggable="true"]');
        if (!el) return;
        var p = el.getBoundingClientRect();
        dx = e.clientX - p.left; dy = e.clientY - p.top;
      }
      var g = el.cloneNode(true);
      g.removeAttribute('id');
      var r = el.getBoundingClientRect();
      g.style.cssText += ';position:fixed;left:0;top:0;margin:0;z-index:2147483647;'
        + 'pointer-events:none;opacity:.7;width:' + r.width + 'px;height:' + r.height + 'px;';
      s.ghost = g; s.gdx = dx; s.gdy = dy;
      document.body.appendChild(g);
      moveGhost(e.clientX, e.clientY);
    }

    function endDrag(e, mayDrop) {
      var s = session;
      if (!s) return;
      session = null;
      if (s.ghost) s.ghost.remove();
      clearInterval(s.timer);
      var x = e ? e.clientX : s.x, y = e ? e.clientY : s.y;
      s.tr.finish(x, y, mayDrop);
      synth('dragend', s.src, x, y, s.tr.dt);
    }

    document.addEventListener('dragstart', function(e) {
      if (e.__lsfSynth) return;
      e.preventDefault();            // abort the doomed system drag
      e.stopImmediatePropagation();  // the page must not see the native event
      var dt = new DataTransfer();
      shadowDt(dt, 'uninitialized', 'none');
      dt.setDragImage = function(el, x, y) {
        dt.__lsfDragImage = { el: el, x: x || 0, y: y || 0 };
      };
      var src = e.target; // native dragstart already targets the draggable root
      if (synth('dragstart', src, e.clientX, e.clientY, dt)) return; // page canceled
      session = { src: src, tr: makeTracker(dt, defaultDropEffect),
                  x: e.clientX, y: e.clientY };
      makeGhost(e);
      // native re-fires drag/dragover ~350ms apart while the cursor is idle
      session.timer = setInterval(function() {
        var s = session;
        if (hit(s.x, s.y) !== s.tr.cur) return;
        synth('drag', s.src, s.x, s.y, s.tr.dt);
        s.tr.move(s.x, s.y);
      }, 300);
    }, true);

    document.addEventListener('mousemove', function(e) {
      if (!session) return;
      if (e.buttons !== 1) { endDrag(e, false); return; } // release was missed
      e.stopImmediatePropagation();
      var s = session;
      s.x = e.clientX; s.y = e.clientY;
      moveGhost(e.clientX, e.clientY);
      synth('drag', s.src, e.clientX, e.clientY, s.tr.dt);
      s.tr.move(e.clientX, e.clientY);
    }, true);

    document.addEventListener('mouseup', function(e) {
      if (session) {
        e.stopImmediatePropagation(); // native drags swallow the release too
        clickGuardUntil = performance.now() + 100;
        endDrag(e, true);
      } else if (swallowRelease) {
        // the release of an ESC-canceled drag: still not the page's business
        swallowRelease = false;
        e.stopImmediatePropagation();
        clickGuardUntil = performance.now() + 100;
      }
    }, true);

    // a completed drag must not degenerate into a click
    document.addEventListener('click', function(e) {
      if (performance.now() < clickGuardUntil) {
        clickGuardUntil = 0;
        e.preventDefault();
        e.stopImmediatePropagation();
      }
    }, true);

    document.addEventListener('mousedown', function(e) {
      swallowRelease = false;
      if (session) endDrag(null, false); // stale session: a new press arrived
    }, true);

    document.addEventListener('selectstart', function(e) {
      if (session) e.preventDefault(); // native drags suppress text selection
    }, true);

    document.addEventListener('keydown', function(e) {
      if (session && e.key === 'Escape') {
        e.stopImmediatePropagation();
        swallowRelease = true; // the button is still down; eat its release
        endDrag(null, false);
      }
    }, true);

    // ---------- driver 2: Explorer-to-page file drags ----------

    var hover = null;   // tracker while an OS drag hovers over the window
    var pending = [];   // per-file {name, parts: [base64...]}, filled before drop

    function copyEffect(dt) { dt.dropEffect = 'copy'; }

    function hoverDt() {
      var dt = new DataTransfer();
      // during hover browsers expose only that files are coming
      dt.items.add(new File([''], ''));
      shadowDt(dt, 'all', 'copy');
      return dt;
    }

    window.__lsfExtDrag = {
      enter: function(x, y) {
        hover = makeTracker(hoverDt(), copyEffect);
        hover.move(x, y);
      },
      move: function(x, y) {
        if (hover) hover.move(x, y);
      },
      leave: function(x, y) {
        var h = hover; hover = null;
        if (h) h.finish(x, y, false);
      },
      file: function(i, name) {
        pending[i] = { name: name, parts: [] };
      },
      chunk: function(i, part) {
        pending[i].parts.push(part);
      },
      drop: function(x, y) {
        var files = pending; pending = [];
        var h = hover; hover = null;
        var dt = new DataTransfer();
        for (var i = 0; i < files.length; i++) {
          // each part is standalone base64 (see chunkBytes on the Dart side)
          dt.items.add(new File(files[i].parts.map(function(p) {
            return Uint8Array.fromBase64(p);
          }), files[i].name));
        }
        shadowDt(dt, 'all', 'copy');
        // re-decide acceptance at the drop point with the real payload
        var tr = h || makeTracker(dt, copyEffect);
        tr.dt = dt;
        tr.move(x, y);
        tr.finish(x, y, true);
      }
    };
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
const String aceEditorHeightFix = r'''
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
// main.dart's build(). The '/dark' suffix (lsFusion mirrors its color theme
// into data-bs-theme on <html>; absent before login = light) selects the
// white variant.
const String cursorOverrideReporter = '''
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
String themeReporter(String send) => '''
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

// webview_cef's own `Flutter` alias is a bare function (and is wiped on
// navigation anyway); the web client expects `Flutter.postMessage(...)`
// and decides at boot whether it runs under Flutter, so the shim must be
// in place before the page scripts run (onLoadStart) — onLoadEnd again as
// a fallback in case the start-time injection raced the navigation.
const String cefFlutterShim =
    "window.Flutter = { postMessage: function(m) {"
    " external.JavaScriptChannel('Flutter', m, null); } };";

// Shows/hides the address bar on vertical swipes that land on
// non-scrollable page areas (mobile).
const String swipeDetector = '''
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
''';

// On Android the WebView never sees the soft keyboard (Flutter owns the IME),
// so the browser's native "scroll the focused editable into view above the
// keyboard" never fires — the host only shrinks the WebView (see main.dart's
// build()). Replicate the native behaviour: whenever the viewport resizes
// (keyboard shows/hides, address bar toggles), if the focused field is now
// outside the visible area, scroll it back into view. Centering also leaves
// room for lsFusion's own suggestion/dropdown popups instead of letting them
// cover the field.
const String keyboardScrollFix = '''
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
''';

// lsFusion renders context menus, tooltips and other popups inside Tippy.js
// boxes whose `.tippy-box`/`.tippy-content` is `pointer-events: none`. In a
// normal browser the interactive Tippy instance re-enables pointer events,
// but under the WebView2 backend that does not take effect: clicks fall
// through the popup to whatever is behind it, so menu items do nothing and
// tooltips dismiss on click. Force pointer events back on for Tippy popups
// (and GWT popups/menus) so they stay clickable.
const String popupPointerEventsCss = '''
  [data-tippy-root], [data-tippy-root] *,
  .tippy-box, .tippy-box *,
  .tippy-content, .tippy-content *,
  .gwt-PopupPanel, .gwt-PopupPanel *,
  .gwt-MenuBar, .gwt-MenuBar * { pointer-events: auto !important; }
''';

// lsFusion sizes shrinkable elements with `max-height: -webkit-fill-available`
// (the `.intr-shrink-height` class). The Android System WebView mis-computes
// that inside a height-constrained `modal-fit-content` dialog, collapsing the
// form's action-button row to ~0px — so a tall dialog (e.g. "Design") shows no
// Save/Cancel buttons, while desktop Chrome renders them fine. Drop the cap on
// those elements inside modals so the buttons keep their natural height.
const String modalShrinkHeightCss = '''
  .modal-content .intr-shrink-height { max-height: none !important; }
''';

UserScript _atDocumentStart(String source) => UserScript(
    source: source, injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START);

/// The workaround scripts the flutter_inappwebview backends need, gated by
/// platform. All run at document start, before any page script.
UnmodifiableListView<UserScript> workaroundUserScripts({
  required bool windows,
  required bool mobile,
}) =>
    UnmodifiableListView([
      _atDocumentStart(bridgeShim),
      _atDocumentStart(focusArtifactGuard),
      _atDocumentStart(themeReporter(
          "window.flutter_inappwebview.callHandler('themeChanged', theme)")),
      // The file-open interceptor is needed wherever the host opens generated
      // files via window.open / target=_blank: on Windows (WebView2 navigates
      // in place) and on mobile (Android WebView shows a "leave site" prompt
      // and then drops the file — there is no native download handling).
      if (windows || mobile) _atDocumentStart(fileOpenInterceptor),
      if (windows) ...[
        _atDocumentStart(cursorOverrideReporter),
        _atDocumentStart(selectDropdownFix),
        _atDocumentStart(dragAndDropSupport),
      ],
      if (mobile) _atDocumentStart(aceEditorHeightFix),
    ]);
