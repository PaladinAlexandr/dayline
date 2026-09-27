#include "flutter_window.h"
#include <flutter/standard_method_codec.h>
#include <shobjidl.h>
#include <wrl/client.h>
#include <optional>
#include "flutter/generated_plugin_registrant.h"
#include "resource.h"
#include "utils.h"

namespace {
constexpr UINT kTray = WM_APP + 40;
constexpr UINT kExit = WM_APP + 41;
const UINT kShow = RegisterWindowMessageW(L"DaylineDesktop.Show");
const UINT kTaskbarCreated = RegisterWindowMessageW(L"TaskbarCreated");
using Value = flutter::EncodableValue;
std::wstring Wide(const std::string& text) {
  if (text.empty()) return L"";
  const int size = MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0);
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), result.data(), size);
  return result;
}
std::string Field(const Value* value, const char* name) {
  if (!value) return "";
  const auto* map = std::get_if<flutter::EncodableMap>(value);
  if (!map) return "";
  const auto it = map->find(Value(name));
  if (it == map->end()) return "";
  const auto* str = std::get_if<std::string>(&it->second);
  return str ? *str : "";
}
}

FlutterWindow::FlutterWindow(const flutter::DartProject& project) : project_(project) {}
FlutterWindow::~FlutterWindow() {}
bool FlutterWindow::HandleDesktopMessage(MSG* message) {
  return desktop_widget_ && desktop_widget_->HandleKeyboard(message);
}
void FlutterWindow::ShowPlanner() {
  ShowWindow(GetHandle(), IsIconic(GetHandle()) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(GetHandle());
}
void FlutterWindow::AddTrayIcon() {
  tray_ = {};
  tray_.cbSize = sizeof(tray_);
  tray_.hWnd = GetHandle(); tray_.uID = 1; tray_.uCallbackMessage = kTray;
  tray_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
  tray_.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(tray_.szTip, L"Dayline — календарь и Obsidian");
  tray_added_ = Shell_NotifyIconW(NIM_ADD, &tray_) != FALSE;
  if (tray_added_) { tray_.uVersion = NOTIFYICON_VERSION_4; Shell_NotifyIconW(NIM_SETVERSION, &tray_); }
}
bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) return false;
  RECT frame = GetClientArea();
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) return false;
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  AddTrayIcon();
  channel_ = std::make_unique<flutter::MethodChannel<Value>>(flutter_controller_->engine()->messenger(), "app.dayline/windows", &flutter::StandardMethodCodec::GetInstance());
  desktop_widget_ = std::make_unique<DesktopWidget>([this](const std::string& action, Value value) {
    if (action == "showPlanner" || action == "new" || action == "open") ShowPlanner();
    if (action != "showPlanner" && channel_) channel_->InvokeMethod(action, std::make_unique<Value>(std::move(value)));
  });
  channel_->SetMethodCallHandler([this](const flutter::MethodCall<Value>& call, std::unique_ptr<flutter::MethodResult<Value>> result) {
    const auto& method = call.method_name();
    if (method == "updateWidget") {
      if (desktop_widget_->Update(call.arguments())) result->Success();
      else result->Error("WIDGET", "Не удалось открыть виджет рабочего стола");
    } else if (method == "selectFolder") {
      Microsoft::WRL::ComPtr<IFileOpenDialog> dialog;
      HRESULT hr = CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
      if (FAILED(hr)) { result->Error("FOLDER", "Не удалось открыть выбор папки"); return; }
      DWORD options = 0; dialog->GetOptions(&options);
      dialog->SetOptions(options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST | FOS_NOCHANGEDIR);
      dialog->SetTitle(L"Выберите папку хранилища Obsidian");
      if (call.arguments()) {
        const auto* initial = std::get_if<std::string>(call.arguments());
        if (initial && !initial->empty()) {
          Microsoft::WRL::ComPtr<IShellItem> folder;
          if (SUCCEEDED(SHCreateItemFromParsingName(Wide(*initial).c_str(), nullptr, IID_PPV_ARGS(&folder)))) dialog->SetFolder(folder.Get());
        }
      }
      hr = dialog->Show(GetHandle());
      if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) { result->Success(); return; }
      if (FAILED(hr)) { result->Error("FOLDER", "Не удалось выбрать папку"); return; }
      Microsoft::WRL::ComPtr<IShellItem> selected; PWSTR path = nullptr;
      if (FAILED(dialog->GetResult(&selected)) || FAILED(selected->GetDisplayName(SIGDN_FILESYSPATH, &path))) { result->Error("FOLDER", "Не удалось прочитать путь папки"); return; }
      const auto utf8 = Utf8FromUtf16(path); CoTaskMemFree(path); result->Success(Value(utf8));
    } else if (method == "notify") {
      if (!tray_added_) AddTrayIcon();
      NOTIFYICONDATAW info = tray_; info.uFlags = NIF_INFO; info.dwInfoFlags = NIIF_INFO | NIIF_RESPECT_QUIET_TIME;
      wcsncpy_s(info.szInfoTitle, Wide(Field(call.arguments(), "title")).c_str(), _TRUNCATE);
      wcsncpy_s(info.szInfo, Wide(Field(call.arguments(), "body")).c_str(), _TRUNCATE);
      notification_item_ = Field(call.arguments(), "id");
      if (Shell_NotifyIconW(NIM_MODIFY, &info)) result->Success(); else result->Error("NOTIFICATION", "Windows не принял уведомление");
    } else if (method == "hideWindow") {
      ShowWindow(GetHandle(), tray_added_ ? SW_HIDE : SW_MINIMIZE); result->Success();
    } else if (method == "exitApp") {
      result->Success(); PostMessage(GetHandle(), kExit, 0, 0);
    } else if (method == "openFolder") {
      const auto* path = call.arguments() ? std::get_if<std::string>(call.arguments()) : nullptr;
      if (!path || path->empty()) { result->Error("FOLDER", "Папка не подключена"); return; }
      const auto code = reinterpret_cast<INT_PTR>(ShellExecuteW(GetHandle(), L"open", Wide(*path).c_str(), nullptr, nullptr, SW_SHOWNORMAL));
      if (code <= 32) result->Error("FOLDER", "Не удалось открыть папку"); else result->Success();
    } else { result->NotImplemented(); }
  });
  flutter_controller_->engine()->SetNextFrameCallback([this]() { Show(); });
  flutter_controller_->ForceRedraw(); return true;
}
void FlutterWindow::OnDestroy() {
  if (tray_added_) Shell_NotifyIconW(NIM_DELETE, &tray_);
  tray_added_ = false; desktop_widget_.reset(); channel_.reset(); flutter_controller_.reset(); Win32Window::OnDestroy();
}
LRESULT FlutterWindow::MessageHandler(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) noexcept {
  if (message == kShow) { ShowPlanner(); return 0; }
  if (message == kTaskbarCreated) { AddTrayIcon(); return 0; }
  if (message == WM_CLOSE) { ShowWindow(hwnd, tray_added_ ? SW_HIDE : SW_MINIMIZE); return 0; }
  if (message == kExit) { DestroyWindow(hwnd); return 0; }
  if (message == WM_GETMINMAXINFO) {
    auto* info = reinterpret_cast<MINMAXINFO*>(lparam); const UINT dpi = GetDpiForWindow(hwnd);
    info->ptMinTrackSize = {MulDiv(540, static_cast<int>(dpi), 96), MulDiv(600, static_cast<int>(dpi), 96)}; return 0;
  }
  if (message == kTray) {
    const auto event = LOWORD(lparam);
    if (event == NIN_SELECT || event == NIN_KEYSELECT || event == WM_LBUTTONDBLCLK || event == NIN_BALLOONUSERCLICK) {
      ShowPlanner();
      if (event == NIN_BALLOONUSERCLICK && !notification_item_.empty() && channel_) channel_->InvokeMethod("open", std::make_unique<Value>(notification_item_));
    } else if (event == WM_CONTEXTMENU || event == WM_RBUTTONUP) {
      POINT point; GetCursorPos(&point); HMENU menu = CreatePopupMenu();
      AppendMenuW(menu, MF_STRING, 1, L"Открыть Dayline"); AppendMenuW(menu, MF_STRING, 2, L"Новое дело");
      AppendMenuW(menu, MF_STRING, 4, desktop_widget_ && desktop_widget_->Visible() ? L"Скрыть виджет" : L"Показать виджет");
      AppendMenuW(menu, MF_SEPARATOR, 0, nullptr); AppendMenuW(menu, MF_STRING, 3, L"Завершить работу");
      SetForegroundWindow(hwnd);
      const UINT choice = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY, point.x, point.y, 0, hwnd, nullptr);
      DestroyMenu(menu);
      if (choice == 1 || choice == 2) ShowPlanner();
      if (choice == 2 && channel_) channel_->InvokeMethod("new", nullptr);
      if (choice == 3) PostMessage(hwnd, kExit, 0, 0);
      if (choice == 4 && desktop_widget_) desktop_widget_->Toggle();
      PostMessage(hwnd, WM_NULL, 0, 0);
    }
    return 0;
  }
  if (flutter_controller_) {
    const auto result = flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam, lparam);
    if (result) return *result;
    if (message == WM_FONTCHANGE) flutter_controller_->engine()->ReloadSystemFonts();
  }
  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
