#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  const wchar_t* run_mutex = L"Local\\MyFinances.Desktop.Running";
  const wchar_t* setup_mutex = L"Local\\MyFinances.Desktop.Setup";
  const wchar_t* window_title = L"ApriFinance";
#ifndef NDEBUG
  // Native integration tests use temporary databases and a separate identity.
  wchar_t test_mode[2] = {};
  if (::GetEnvironmentVariableW(L"APRIFINANCE_NATIVE_TEST", test_mode, 2) == 1 &&
      test_mode[0] == L'1') {
    run_mutex = L"Local\\ApriFinance.NativeTest.Running";
    setup_mutex = L"Local\\ApriFinance.NativeTest.Setup";
    window_title = L"ApriFinance - Test";
  }
#endif
  auto setup_in_progress = [setup_mutex]() {
    HANDLE handle = ::OpenMutexW(SYNCHRONIZE, FALSE, setup_mutex);
    if (handle == nullptr) return false;
    ::CloseHandle(handle);
    return true;
  };
  if (setup_in_progress()) {
    ::MessageBoxW(nullptr, L"Установка или удаление ещё выполняется. Повторите запуск после завершения.",
                  window_title, MB_OK | MB_ICONINFORMATION);
    return EXIT_FAILURE;
  }
  // Keep one writer UI per Windows session and preserve installer compatibility.
  HANDLE running = ::CreateMutexW(nullptr, FALSE, run_mutex);
  const DWORD mutex_error = ::GetLastError();
  if (running == nullptr) return EXIT_FAILURE;
  struct MutexGuard {
    HANDLE handle;
    ~MutexGuard() { ::CloseHandle(handle); }
  } running_guard{running};
  if (mutex_error == ERROR_ALREADY_EXISTS) {
    HWND existing = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", window_title);
    if (existing != nullptr) {
      if (::IsIconic(existing)) ::ShowWindow(existing, SW_RESTORE);
      ::SetForegroundWindow(existing);
    }
    return EXIT_SUCCESS;
  }
  // Setup may have begun between the initial check and publishing our handle.
  if (setup_in_progress()) return EXIT_FAILURE;
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
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(window_title, origin, size)) {
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

