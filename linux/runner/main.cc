#include "my_application.h"

int main(int argc, char** argv) {
  // Set environment variables to avoid conflicts between Flutter and Webview GL contexts
  // and to improve compatibility with various Linux graphics drivers.
  
  // Use TRUE to overwrite existing values to ensure they are applied.
  g_setenv("WEBKIT_DISABLE_COMPOSITING_MODE", "1", TRUE);
  
  // Disable DMABUF renderer in WebKit as it often causes issues with certain drivers.
  g_setenv("WEBKIT_DISABLE_DMABUF_RENDERER", "1", TRUE);

  // Force X11 backend for better OpenGL stability with Flutter and Webview.
  // Wayland can sometimes have issues with shared OpenGL contexts.
  g_setenv("GDK_BACKEND", "x11", TRUE);

  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
