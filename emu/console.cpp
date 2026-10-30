#include "console.h"
#include <algorithm>
#include "keyboard.h"

// Status messages: header 1011SSSD, data 0DDDDDDD, where SSS is the status
// subtype and D the top bit of the 8-bit value (decoded by the FEP's
// KEYBOARD-PROCESS-RAW-BYTE).  Subtype 0 = brightness, 1 = volume, 2 = switchpack.
void Console::status(int subtype, uint8_t value) {
  out.push_back((uint8_t)(0xB0 | (subtype << 1) | (value >> 7)));
  out.push_back(value & 0x7F);
}

// Commands from the CPU (as sent by the FEP's CONSOLE-SWITCHPACK):
//   0x80        report the switchpack
//   0x90 v      set brightness, console reports it back
//   0x92 v      set volume, console reports it back
void Console::from_cpu(uint8_t b) {
  if (cmd.empty() && b == 0x80) { status(2, switchpack); return; }
  cmd.push_back(b);
  if (cmd.size() < 2) return;
  uint8_t c = cmd[0], v = cmd[1];
  cmd.clear();
  switch (c) {
  case 0x90: if (v) brightness = v; status(0, brightness); break;
  case 0x92: volume = v & 0x3F; status(1, volume); break;
  default: break;
  }
}

void Console::key(uint8_t code, bool down) {
  auto it = std::find(keys_down.begin(), keys_down.end(), code);
  if (down) {
    if (it == keys_down.end()) keys_down.push_back(code);
    out.push_back(0xC0);
    out.push_back(code);
  } else {
    if (it != keys_down.end()) keys_down.erase(it);
    if (keys_down.empty()) {
      out.push_back(0xA0);
      out.push_back(0x00);
    } else {
      out.push_back(0xD0);
      out.push_back(code);
    }
  }
}

void Console::type(const char* text) {
  for (; *text; text++) {
    uint8_t k;
    bool shift;
    if (!ascii_to_key(*text, k, shift)) continue;
    if (shift) key(K_LEFT_SHIFT, true);
    key(k, true);
    key(k, false);
    if (shift) key(K_LEFT_SHIFT, false);
  }
}

// 1000 0LMR (wired-console.lisp WIRED-SLB-CONSOLE-PROCESS-COMMAND reverses the
// three bits into Genera's left = bit 0 order).
void Console::mouse_buttons(bool l, bool m, bool r) {
  out.push_back((uint8_t)(0x80 | (l ? 4 : 0) | (m ? 2 : 0) | (r ? 1 : 0)));
}

// One message per unit of motion: 1001LRUD.
void Console::mouse_move(int dx, int dy) {
  while (dx || dy) {
    uint8_t b = 0x90;
    if (dx < 0) { b |= 8; dx++; } else if (dx > 0) { b |= 4; dx--; }
    if (dy < 0) { b |= 2; dy++; } else if (dy > 0) { b |= 1; dy--; }
    out.push_back(b);
  }
}
