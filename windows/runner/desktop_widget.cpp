#include "desktop_widget.h"
#include <dwmapi.h>
#include <windowsx.h>
#include <algorithm>
#include <utility>

namespace {
using Value = flutter::EncodableValue;
const COLORREF kBackground = RGB(18, 26, 24), kCard = RGB(31, 41, 37);
const COLORREF kText = RGB(239, 244, 232), kMuted = RGB(172, 187, 176);
const COLORREF kAccent = RGB(197, 242, 124);
const COLORREF kColors[] = {RGB(185,232,121),RGB(146,185,255),RGB(198,168,250),RGB(255,180,128),RGB(242,152,177)};
constexpr int kList = 101, kOpen = 102, kCreate = 103, kPin = 104;
const Value* Field(const Value* value, const char* key) {
  const auto* map = value ? std::get_if<flutter::EncodableMap>(value) : nullptr;
  if (!map) return nullptr;
  auto it = map->find(Value(key)); return it == map->end() ? nullptr : &it->second;
}
std::string String(const Value* value, const char* key) {
  const auto* field = Field(value, key);
  const auto* text = field ? std::get_if<std::string>(field) : nullptr;
  return text ? *text : "";
}
int Integer(const Value* value, const char* key, int fallback) {
  const auto* field = Field(value, key);
  const auto* number = field ? std::get_if<int32_t>(field) : nullptr;
  return number ? *number : fallback;
}
bool Boolean(const Value* value, const char* key, bool fallback) {
  const auto* field = Field(value, key);
  const auto* flag = field ? std::get_if<bool>(field) : nullptr;
  return flag ? *flag : fallback;
}
std::wstring Wide(const std::string& text) {
  const int size = MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0);
  std::wstring output(size, L'\0');
  if (size) MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), output.data(), size);
  return output;
}
void Fill(HDC dc, RECT rect, COLORREF color) {
  const auto brush = CreateSolidBrush(color); FillRect(dc, &rect, brush); DeleteObject(brush);
}
void Text(HDC dc, HFONT font, RECT rect, const std::wstring& text, COLORREF color, UINT flags = DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS) {
  const auto old = SelectObject(dc, font); SetTextColor(dc, color); SetBkMode(dc, TRANSPARENT);
  DrawTextW(dc, text.c_str(), static_cast<int>(text.size()), &rect, flags | DT_NOPREFIX); SelectObject(dc, old);
}
}

DesktopWidget::DesktopWidget(Callback callback) : callback_(std::move(callback)) {
  background_ = CreateSolidBrush(kBackground);
}
DesktopWidget::~DesktopWidget() {
  if (window_) DestroyWindow(window_);
  if (normal_) DeleteObject(normal_);
  if (bold_) DeleteObject(bold_);
  if (small_) DeleteObject(small_);
  DeleteObject(background_);
}
int DesktopWidget::Scale(int value) const { return MulDiv(value, static_cast<int>(dpi_), 96); }
bool DesktopWidget::Visible() const { return window_ && IsWindowVisible(window_); }
bool DesktopWidget::HandleKeyboard(MSG* message) {
  if (!window_ || (message->hwnd != window_ && !IsChild(window_, message->hwnd))) return false;
  if (message->message == WM_KEYDOWN && message->wParam == VK_RETURN && message->hwnd == list_) {
    OpenSelection(); return true;
  }
  return IsDialogMessageW(window_, message) != FALSE;
}

bool DesktopWidget::Update(const Value* value) {
  if (!window_) {
    dpi_ = GetDpiForSystem();
    WNDCLASSW type{}; type.lpfnWndProc = Proc; type.hInstance = GetModuleHandle(nullptr);
    type.hCursor = LoadCursor(nullptr, IDC_ARROW); type.lpszClassName = L"DAYLINE_DESKTOP_WIDGET";
    RegisterClassW(&type);
    RECT work{}; SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
    const int width = std::clamp(Integer(value, "width", Scale(380)), Scale(300), Scale(1000));
    const int height = std::clamp(Integer(value, "height", Scale(560)), Scale(340), Scale(1600));
    HWND created = CreateWindowExW(WS_EX_TOOLWINDOW, type.lpszClassName, L"Dayline — ближайшие дела",
      WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_CLIPCHILDREN,
      Integer(value, "x", work.right - width - 24), Integer(value, "y", work.top + 40), width, height,
      nullptr, nullptr, type.hInstance, this);
    if (!created) return false;
    ClampToScreen();
    BOOL dark = TRUE; DwmSetWindowAttribute(window_, 20, &dark, sizeof(dark));
  }
  date_ = Wide(String(value, "date"));
  const auto* field = Field(value, "entries");
  const auto* list = field ? std::get_if<flutter::EncodableList>(field) : nullptr;
  const int first = static_cast<int>(SendMessageW(list_, LB_GETTOPINDEX, 0, 0));
  const int selected = static_cast<int>(SendMessageW(list_, LB_GETCURSEL, 0, 0));
  const std::string selected_id = selected >= 0 && selected < static_cast<int>(entries_.size()) ? entries_[selected].id : "";
  SendMessageW(list_, WM_SETREDRAW, FALSE, 0);
  SendMessageW(list_, LB_RESETCONTENT, 0, 0); entries_.clear();
  if (list) for (const auto& row : *list) {
    Entry entry{String(&row, "id"), Wide(String(&row, "title")), Wide(String(&row, "detail")), Wide(String(&row, "category")), std::clamp(Integer(&row, "color", 0), 0, 4)};
    entries_.push_back(entry);
    const auto accessible = entry.detail + L". " + entry.title + L". " + entry.category;
    const auto index = SendMessageW(list_, LB_ADDSTRING, 0, reinterpret_cast<LPARAM>(accessible.c_str()));
    if (!selected_id.empty() && entry.id == selected_id) SendMessageW(list_, LB_SETCURSEL, index, 0);
  }
  SendMessageW(list_, LB_SETTOPINDEX, std::max(0, first), 0);
  SendMessageW(list_, WM_SETREDRAW, TRUE, 0); InvalidateRect(list_, nullptr, TRUE);
  ShowWindow(list_, entries_.empty() ? SW_HIDE : SW_SHOW);
  Pin(Boolean(value, "pinned", false));
  const bool enabled = Boolean(value, "enabled", true);
  if (enabled != Visible()) ShowWindow(window_, enabled ? SW_SHOWNOACTIVATE : SW_HIDE);
  InvalidateRect(window_, nullptr, FALSE); return true;
}
void DesktopWidget::Fonts() {
  if (normal_) DeleteObject(normal_); if (bold_) DeleteObject(bold_); if (small_) DeleteObject(small_);
  auto font = [this](int size, int weight) { return CreateFontW(-Scale(size), 0, 0, 0, weight, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI"); };
  normal_ = font(14, FW_NORMAL); bold_ = font(17, FW_SEMIBOLD); small_ = font(12, FW_NORMAL);
  if (list_) { SendMessageW(list_, WM_SETFONT, reinterpret_cast<WPARAM>(normal_), TRUE); SendMessageW(list_, LB_SETITEMHEIGHT, 0, Scale(94)); }
}
void DesktopWidget::Layout() {
  RECT area{}; GetClientRect(window_, &area);
  const int width = area.right, height = area.bottom, pad = Scale(16);
  if (list_) MoveWindow(list_, pad, Scale(76), width - pad * 2, std::max(Scale(70), height - Scale(155)), TRUE);
  if (pin_) MoveWindow(pin_, pad, height - Scale(69), width - pad * 2, Scale(24), TRUE);
  const int gap = Scale(8), button_width = (width - pad * 2 - gap) / 2;
  if (open_) MoveWindow(open_, pad, height - Scale(40), button_width, Scale(28), TRUE);
  if (create_) MoveWindow(create_, pad + button_width + gap, height - Scale(40), button_width, Scale(28), TRUE);
  InvalidateRect(window_, nullptr, TRUE);
}
void DesktopWidget::Pin(bool value) {
  const bool changed = pinned_ != value;
  pinned_ = value;
  if (changed) SetWindowPos(window_, pinned_ ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  if (pin_) SetWindowTextW(pin_, pinned_ ? L"✓ Поверх других окон" : L"Поверх других окон");
}
void DesktopWidget::SaveState() {
  RECT rect{}; GetWindowRect(window_, &rect);
  callback_("widgetState", Value(flutter::EncodableMap{
    {Value("enabled"), Value(Visible())}, {Value("pinned"), Value(pinned_)},
    {Value("x"), Value(static_cast<int32_t>(rect.left))}, {Value("y"), Value(static_cast<int32_t>(rect.top))},
    {Value("width"), Value(static_cast<int32_t>(rect.right - rect.left))}, {Value("height"), Value(static_cast<int32_t>(rect.bottom - rect.top))}
  }));
}
void DesktopWidget::Toggle() {
  if (!window_) return;
  ShowWindow(window_, Visible() ? SW_HIDE : SW_SHOWNOACTIVATE); SaveState();
}
void DesktopWidget::OpenSelection() {
  const int index = static_cast<int>(SendMessageW(list_, LB_GETCURSEL, 0, 0));
  if (index >= 0 && index < static_cast<int>(entries_.size())) callback_("open", Value(entries_[index].id));
}
void DesktopWidget::ClampToScreen() {
  RECT rect{}; GetWindowRect(window_, &rect);
  MONITORINFO monitor{sizeof(MONITORINFO)};
  GetMonitorInfoW(MonitorFromRect(&rect, MONITOR_DEFAULTTONEAREST), &monitor);
  const auto& work = monitor.rcWork;
  const int width = std::min(rect.right - rect.left, work.right - work.left);
  const int height = std::min(rect.bottom - rect.top, work.bottom - work.top);
  const int x = std::clamp(static_cast<int>(rect.left), static_cast<int>(work.left), static_cast<int>(work.right) - width);
  const int y = std::clamp(static_cast<int>(rect.top), static_cast<int>(work.top), static_cast<int>(work.bottom) - height);
  SetWindowPos(window_, nullptr, x, y, width, height, SWP_NOZORDER | SWP_NOACTIVATE);
}
void DesktopWidget::Paint(HDC dc) {
  RECT area{}; GetClientRect(window_, &area); Fill(dc, area, kBackground);
  Text(dc, bold_, {Scale(18), Scale(9), area.right - Scale(18), Scale(38)}, L"Ближайшие дела", kAccent);
  Text(dc, small_, {Scale(18), Scale(39), area.right - Scale(18), Scale(62)}, date_ + L"  ·  На 30 дней", kMuted);
  if (entries_.empty()) Text(dc, normal_, {Scale(22), Scale(105), area.right - Scale(22), Scale(180)}, L"Ближайших дел нет\nСоздайте задачу или событие", kMuted, DT_CENTER | DT_WORDBREAK);
}
void DesktopWidget::DrawItem(const DRAWITEMSTRUCT& draw) {
  if (draw.CtlID == kList) {
    if (draw.itemID >= entries_.size()) return;
    const auto& entry = entries_[draw.itemID]; RECT rect = draw.rcItem;
    Fill(draw.hDC, rect, kBackground); rect.bottom -= Scale(8);
    Fill(draw.hDC, rect, draw.itemState & ODS_SELECTED ? RGB(48, 65, 47) : kCard);
    RECT bar{rect.left, rect.top, rect.left + Scale(3), rect.bottom}; Fill(draw.hDC, bar, kColors[entry.color]);
    const int left = rect.left + Scale(13), right = rect.right - Scale(9);
    Text(draw.hDC, small_, {left, rect.top + Scale(6), right, rect.top + Scale(25)}, entry.detail, kAccent);
    Text(draw.hDC, bold_, {left, rect.top + Scale(27), right, rect.top + Scale(55)}, entry.title, kText);
    Text(draw.hDC, small_, {left, rect.top + Scale(58), right, rect.bottom - Scale(5)}, entry.category, kMuted);
    if (draw.itemState & ODS_FOCUS) DrawFocusRect(draw.hDC, &rect);
  } else {
    RECT rect = draw.rcItem; const bool pressed = (draw.itemState & ODS_SELECTED) != 0;
    Fill(draw.hDC, rect, pressed ? RGB(62, 80, 55) : kCard);
    wchar_t label[100]{}; GetWindowTextW(draw.hwndItem, label, 100);
    Text(draw.hDC, normal_, rect, label, draw.CtlID == kCreate ? kAccent : kText, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    if (draw.itemState & ODS_FOCUS) { InflateRect(&rect, -2, -2); DrawFocusRect(draw.hDC, &rect); }
  }
}
LRESULT CALLBACK DesktopWidget::Proc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  auto* self = reinterpret_cast<DesktopWidget*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    self = static_cast<DesktopWidget*>(reinterpret_cast<CREATESTRUCTW*>(lparam)->lpCreateParams);
    self->window_ = hwnd; SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
  }
  return self ? self->Handle(message, wparam, lparam) : DefWindowProcW(hwnd, message, wparam, lparam);
}
LRESULT DesktopWidget::Handle(UINT message, WPARAM wparam, LPARAM lparam) {
  switch (message) {
    case WM_CREATE: {
      dpi_ = GetDpiForWindow(window_); Fonts();
      list_ = CreateWindowExW(0, L"LISTBOX", L"Ближайшие события и задачи", WS_CHILD | WS_VISIBLE | WS_VSCROLL | WS_TABSTOP | LBS_NOTIFY | LBS_OWNERDRAWFIXED | LBS_HASSTRINGS | LBS_NOINTEGRALHEIGHT, 0, 0, 0, 0, window_, reinterpret_cast<HMENU>(static_cast<INT_PTR>(kList)), GetModuleHandle(nullptr), nullptr);
      auto button = [this](const wchar_t* text, int id) { return CreateWindowExW(0, L"BUTTON", text, WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW, 0, 0, 0, 0, window_, reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), GetModuleHandle(nullptr), nullptr); };
      open_ = button(L"Открыть календарь", kOpen); create_ = button(L"+ Создать", kCreate); pin_ = button(L"Поверх других окон", kPin);
      SendMessageW(list_, WM_SETFONT, reinterpret_cast<WPARAM>(normal_), FALSE);
      SendMessageW(list_, LB_SETITEMHEIGHT, 0, Scale(94)); Layout(); return 0;
    }
    case WM_MEASUREITEM: reinterpret_cast<MEASUREITEMSTRUCT*>(lparam)->itemHeight = Scale(94); return TRUE;
    case WM_DRAWITEM: DrawItem(*reinterpret_cast<DRAWITEMSTRUCT*>(lparam)); return TRUE;
    case WM_CTLCOLORLISTBOX: SetBkColor(reinterpret_cast<HDC>(wparam), kBackground); return reinterpret_cast<LRESULT>(background_);
    case WM_ERASEBKGND: return 1;
    case WM_PAINT: { PAINTSTRUCT paint{}; HDC dc = BeginPaint(window_, &paint); Paint(dc); EndPaint(window_, &paint); return 0; }
    case WM_SIZE: Layout(); return 0;
    case WM_CLOSE: ShowWindow(window_, SW_HIDE); SaveState(); return 0;
    case WM_EXITSIZEMOVE: ClampToScreen(); SaveState(); return 0;
    case WM_DISPLAYCHANGE: ClampToScreen(); return 0;
    case WM_DPICHANGED: {
      dpi_ = HIWORD(wparam); Fonts(); const auto* rect = reinterpret_cast<RECT*>(lparam);
      SetWindowPos(window_, nullptr, rect->left, rect->top, rect->right - rect->left, rect->bottom - rect->top, SWP_NOZORDER | SWP_NOACTIVATE); Layout(); return 0;
    }
    case WM_GETMINMAXINFO: {
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam); info->ptMinTrackSize = {Scale(300), Scale(340)}; return 0;
    }
    case WM_COMMAND:
      if (LOWORD(wparam) == kOpen) callback_("showPlanner", Value());
      if (LOWORD(wparam) == kCreate) callback_("new", Value());
      if (LOWORD(wparam) == kPin) { Pin(!pinned_); SaveState(); }
      if (LOWORD(wparam) == kList && HIWORD(wparam) == LBN_DBLCLK) OpenSelection();
      return 0;
    case WM_KEYDOWN: if (wparam == VK_RETURN) { OpenSelection(); return 0; } break;
  }
  return DefWindowProcW(window_, message, wparam, lparam);
}
