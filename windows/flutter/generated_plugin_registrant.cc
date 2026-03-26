//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <flutter_libserialport/flutter_libserialport_plugin.h>
#include <lsf_webview_windows/lsf_webview_windows.h>
#include <printing/printing_plugin.h>
#include <webview_cef/webview_cef_plugin_c_api.h>
#include <webview_windows/webview_windows_plugin.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  FlutterLibserialportPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FlutterLibserialportPlugin"));
  LsfWebviewWindowsRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("LsfWebviewWindows"));
  PrintingPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("PrintingPlugin"));
  WebviewCefPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("WebviewCefPluginCApi"));
  WebviewWindowsPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("WebviewWindowsPlugin"));
}
