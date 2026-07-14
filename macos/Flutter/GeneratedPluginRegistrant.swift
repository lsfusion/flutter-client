//
//  Generated file. Do not edit.
//

import FlutterMacOS
import Foundation

import desktop_drop
import flutter_inappwebview_macos
import flutter_libserialport
import printing
import shared_preferences_foundation
import webview_cef

func RegisterGeneratedPlugins(registry: FlutterPluginRegistry) {
  DesktopDropPlugin.register(with: registry.registrar(forPlugin: "DesktopDropPlugin"))
  InAppWebViewFlutterPlugin.register(with: registry.registrar(forPlugin: "InAppWebViewFlutterPlugin"))
  FlutterLibserialportPlugin.register(with: registry.registrar(forPlugin: "FlutterLibserialportPlugin"))
  PrintingPlugin.register(with: registry.registrar(forPlugin: "PrintingPlugin"))
  SharedPreferencesPlugin.register(with: registry.registrar(forPlugin: "SharedPreferencesPlugin"))
  WebviewCefPlugin.register(with: registry.registrar(forPlugin: "WebviewCefPlugin"))
}
