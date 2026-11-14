#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <wchar.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

// One launcher at a time (per Windows session): two would fight over the
// antd port and the same settings and caches. A second start shows the
// window of the running launcher and exits. "--new-instance" skips this.
static bool ShowRunningInstance(const wchar_t* command_line) {
  if (command_line != nullptr && ::wcsstr(command_line, L"--new-instance") != nullptr) {
    return false;
  }
  // Kept open for the lifetime of the process: the name is taken until exit.
  ::CreateMutexW(nullptr, FALSE, L"Local\\SRB2AutonomiLauncher.SingleInstance");
  if (::GetLastError() != ERROR_ALREADY_EXISTS) {
    return false;
  }
  HWND existing = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"SRB2 Autonomi Launcher");
  if (existing != nullptr) {
    ::ShowWindow(existing, ::IsIconic(existing) ? SW_RESTORE : SW_SHOW);
    ::SetForegroundWindow(existing);
  }
  return true;
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  if (ShowRunningInstance(command_line)) {
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  // Dart (and with it the audio engine, miniaudio) runs on its own thread,
  // not on this window thread. Since Flutter merged the two threads by
  // default, miniaudio's CoInitializeEx(MULTITHREADED) failed here (this
  // thread is STA, see above) while its unconditional CoUninitialize still
  // ran, taking COM away from the window thread: the next file dialog
  // (IFileDialog) then hung the whole launcher.
  project.set_ui_thread_policy(flutter::UIThreadPolicy::RunOnSeparateThread);

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  // Rendering: Flutter's default (Impeller on Windows). The NVIDIA driver
  // crashes (nvwgf2umx.dll, 0xc0000005) came with Flutter 3.50.0, with Skia
  // too; builds are pinned to 3.47.9 again (.github/workflows/build.yml),
  // which ran fine with Impeller. "--skia" on the launcher's command line
  // switches to Skia, "--impeller" forces Impeller.
  bool skia = false, impeller = false;
  for (const auto& arg : command_line_arguments) {
    if (arg == "--skia") skia = true;
    if (arg == "--impeller") impeller = true;
  }
  if (skia) {
    project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);
  } else if (impeller) {
    project.set_impeller_switch(flutter::ImpellerSwitch::Enabled);
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"SRB2 Autonomi Launcher", origin, size)) {
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
