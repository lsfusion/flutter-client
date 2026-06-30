// Intentionally empty.
//
// This stub stands in for the real `flutter_inappwebview_linux` package via a
// dependency_overrides entry in the root pubspec.yaml. The real package is the
// WPE-WebKit backend of flutter_inappwebview and forces a libwpewebkit build
// dependency. On Linux this app renders its webview through webview_cef
// (see lib/cef_webview_impl.dart), so the WPE backend is not needed at all.
//
// Because this package declares no `flutter.plugin.platforms.linux`, the
// Flutter tool does not register it as a Linux plugin, so it never appears in
// linux/flutter/generated_plugins.cmake and CMake never looks for WPE WebKit.
