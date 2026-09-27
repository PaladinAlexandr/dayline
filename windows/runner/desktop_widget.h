#ifndef DAYLINE_DESKTOP_WIDGET_H_
#define DAYLINE_DESKTOP_WIDGET_H_
#include <windows.h>
#include <flutter/encodable_value.h>
#include <functional>
#include <string>
#include <vector>

class DesktopWidget {
 public:
  using Value = flutter::EncodableValue;
  using Callback = std::function<void(const std::string&, Value)>;
  explicit DesktopWidget(Callback callback);
  ~DesktopWidget();
  bool Update(const Value* arguments);
  void Toggle();
  bool Visible() const;
  bool HandleKeyboard(MSG* message);
 private:
  struct Entry { std::string id; std::wstring title, detail, category; int color = 0; };
  Callback callback_;
  HWND window_ = nullptr, list_ = nullptr, open_ = nullptr, create_ = nullptr, pin_ = nullptr;
  HFONT normal_ = nullptr, bold_ = nullptr, small_ = nullptr;
  HBRUSH background_ = nullptr;
  bool pinned_ = false;
  UINT dpi_ = 96;
  std::wstring date_;
  std::vector<Entry> entries_;
  int Scale(int value) const;
  void Layout();
  void Fonts();
  void SaveState();
  void Pin(bool pinned);
  void OpenSelection();
  void Paint(HDC dc);
  void DrawItem(const DRAWITEMSTRUCT& draw);
  void ClampToScreen();
  LRESULT Handle(UINT message, WPARAM wparam, LPARAM lparam);
  static LRESULT CALLBACK Proc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);
};
#endif
