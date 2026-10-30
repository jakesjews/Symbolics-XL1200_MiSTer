// Symbolics keyboard key numbers (the byte after a key-down/up message), from
// the :symbolics layout in sys.sct/embedding/keyboards/keyboards.lisp.
#pragma once
#include <cstdint>

enum SymKey : uint8_t {
  K_LOCAL = 000, K_CAPS_LOCK = 001, K_LEFT_HYPER = 002, K_LEFT_META = 003, K_RIGHT_CONTROL = 004,
  K_RIGHT_SUPER = 005, K_SCROLL = 006, K_MODE_LOCK = 007, K_SELECT = 010, K_LEFT_SYMBOL = 011,
  K_LEFT_SUPER = 012, K_LEFT_CONTROL = 013, K_SPACE = 014, K_RIGHT_META = 015, K_RIGHT_HYPER = 016,
  K_END = 017, K_ABORT = 027, K_LEFT_SHIFT = 030, K_RIGHT_SHIFT = 025, K_RIGHT_SYMBOL = 036,
  K_REPEAT = 026, K_HELP = 037, K_RUBOUT = 040, K_RETURN = 046, K_COMPLETE = 047, K_NETWORK = 050,
  K_LINE = 057, K_FUNCTION = 060, K_PAGE = 067, K_TAB = 070, K_BACKSPACE = 077, K_ESCAPE = 0120,
  K_REFRESH = 0121, K_SQUARE = 0122, K_CIRCLE = 0123, K_TRIANGLE = 0124, K_CLEAR_INPUT = 0125,
  K_SUSPEND = 0126, K_RESUME = 0127,
};

// ASCII to (key, shifted).  Returns false for characters with no key.
static inline bool ascii_to_key(char c, uint8_t& key, bool& shift) {
  static const uint8_t letter_keys[26] = {051, 022, 021, 052, 072, 042, 053, 043, 064, 054, 044, 055, 023,
                                          033, 075, 065, 071, 062, 041, 073, 074, 032, 061, 031, 063, 020};
  // Unshifted / shifted characters on the remaining keys.
  static const struct { uint8_t key; char plain, shifted; } others[] = {
      {0110, '1', '!'}, {0101, '2', '@'}, {0111, '3', '#'}, {0102, '4', '$'}, {0112, '5', '%'},
      {0103, '6', '^'}, {0113, '7', '&'}, {0104, '8', '*'}, {0114, '9', '('}, {0105, '0', ')'},
      {0115, '-', '_'}, {0106, '=', '+'}, {0116, '`', '~'}, {0107, '\\', '{'}, {0117, '|', '}'},
      {0076, '(', '['}, {0066, ')', ']'}, {0045, ';', ':'}, {0056, '\'', '"'}, {0034, ',', '<'},
      {0024, '.', '>'}, {0035, '/', '?'}, {0100, ':', 0},
  };
  shift = false;
  if (c >= 'a' && c <= 'z') { key = letter_keys[c - 'a']; return true; }
  if (c >= 'A' && c <= 'Z') { key = letter_keys[c - 'A']; shift = true; return true; }
  switch (c) {
  case ' ': key = K_SPACE; return true;
  case '\r': case '\n': key = K_RETURN; return true;
  case '\t': key = K_TAB; return true;
  case '\b': case 0x7F: key = K_RUBOUT; return true;
  default: break;
  }
  for (auto& o : others)   // prefer an unshifted key, e.g. ( is its own key
    if (o.plain == c) { key = o.key; return true; }
  for (auto& o : others)
    if (o.shifted && o.shifted == c) { key = o.key; shift = true; return true; }
  return false;
}
