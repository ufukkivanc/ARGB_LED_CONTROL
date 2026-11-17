#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  // Başlangıç penceresi: ~550x750 mantıksal px, çalışma alanının ortasında. Küçük ekranlarda ekrana sığdırılır.
  // Pencere kullanıcı tarafından büyütülüp küçültülebilir (en az 420x560: win32_window.cpp WM_GETMINMAXINFO).
  RECT work = {0, 0, 1920, 1080};
  ::SystemParametersInfo(SPI_GETWORKAREA, 0, &work, 0);
  UINT system_dpi = ::GetDpiForSystem();
  double scale = (system_dpi == 0 ? 96 : system_dpi) / 96.0;
  int work_w = static_cast<int>((work.right - work.left) / scale);
  int work_h = static_cast<int>((work.bottom - work.top) / scale);
  int win_w = work_w - 40 < 550 ? work_w - 40 : 550;
  int win_h = work_h - 40 < 750 ? work_h - 40 : 750;
  Win32Window::Point origin(static_cast<int>(work.left / scale) + (work_w - win_w) / 2,
                            static_cast<int>(work.top / scale) + (work_h - win_h) / 2);
  Win32Window::Size size(win_w, win_h);
  if (!window.Create(L"ARGB Controller", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
