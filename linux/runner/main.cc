#include "my_application.h"

int main(int argc, char** argv) {
  // Set environment variable to avoid conflicts between Flutter and Webview GL contexts.
  // This is often needed when using webview_flutter_linux or similar plugins on Linux.
  g_setenv("WEBKIT_DISABLE_COMPOSITING_MODE", "1", FALSE);

  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
