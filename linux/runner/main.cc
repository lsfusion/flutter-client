#include "my_application.h"

int main(int argc, char** argv) {
  // Set environment variables to avoid conflicts between Flutter and Webview GL contexts
  // and to improve compatibility with various Linux graphics drivers.
  
  // Use TRUE to overwrite existing values to ensure they are applied.
  
  // Disable GPU process in WebKit completely to prevent conflicts.
  // This forces WebKit to render in the same process or use software fallbacks.
  g_setenv("WEBKIT_DISABLE_GPU_PROCESS", "1", TRUE);
  
  // Disable accelerated compositing for WebKit to avoid "Failed to setup compositor shaders" errors.
  g_setenv("WEBKIT_DISABLE_COMPOSITING_MODE", "1", TRUE);
  g_setenv("WEBKIT_DISABLE_ACCELERATED_COMPOSITING", "1", TRUE);
  
  // Disable DMABUF renderer in WebKit as it often causes issues with certain drivers (especially NVIDIA).
  g_setenv("WEBKIT_DISABLE_DMABUF_RENDERER", "1", TRUE);

  // Disable accelerated 2D canvas in WebKit to reduce GPU contention.
  g_setenv("WEBKIT_DISABLE_ACCELERATED_2D_CANVAS", "1", TRUE);

  // Force X11 backend for better OpenGL stability with Flutter and Webview.
  // Wayland can sometimes have issues with shared OpenGL contexts between widgets.
  g_setenv("GDK_BACKEND", "x11", TRUE);

  // Use GLX for WebKit when on X11 for better compatibility with standard drivers.
  g_setenv("WEBKIT_USE_GLX", "1", TRUE);

  // Use desktop OpenGL for GDK to avoid EGL/GLX mixing issues on X11.
  g_setenv("GDK_GL", "gl", TRUE);

  // Sandbox can sometimes interfere with GPU drivers access within the container or host.
  g_setenv("WEBKIT_FORCE_SANDBOX", "0", TRUE);

  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
