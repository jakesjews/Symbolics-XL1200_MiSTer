#!/usr/bin/env python3
"""Type and move the mouse on the MiSTer through a virtual USB keyboard and
mouse (/dev/uinput), for testing.

usage: kbd.py TEXT        (run on the MiSTer)

TEXT is typed as on a PC keyboard; {name} presses a key: {enter}, {f1}..{f12},
{esc}, {backspace}, {tab}, {home}, {end}, {pageup}, {pagedown}, {insert},
{delete}, {up}, {down}, {left}, {right}, {pause} (the core's screen switch).  '(' and ')' are typed as '[' and ']',
which the core maps to the Symbolics ( and ) keys, and '|' as Insert, the
Symbolics | key (docs/keyboard.md).
{m DX DY} moves the mouse; {click L}, {click M}, {click R} click a button ({click R shift} with Shift);
{wait S} pauses S seconds.  {ctrl x}, {meta x}, {ctrl meta x} are chords
(Control is the left Control key, Meta the left Alt, Super the left Windows).
"""
import fcntl, os, struct, sys, time

UI_SET_EVBIT, UI_SET_KEYBIT, UI_SET_RELBIT = 0x40045564, 0x40045565, 0x40045566
UI_DEV_CREATE, UI_DEV_DESTROY = 0x5501, 0x5502
EV_SYN, EV_KEY, EV_REL = 0, 1, 2
BUTTONS = {"l": 0x110, "r": 0x111, "m": 0x112}
SHIFT = 42

KEYS = {c: k for k, c in zip(range(16, 26), "qwertyuiop")}
KEYS.update({c: k for k, c in zip(range(30, 39), "asdfghjkl")})
KEYS.update({c: k for k, c in zip(range(44, 51), "zxcvbnm")})
KEYS.update({c: k for k, c in zip(range(2, 12), "1234567890")})
KEYS.update({" ": 57, "-": 12, "=": 13, "[": 26, "]": 27, ";": 39, "'": 40, "`": 41, "\\": 43,
             ",": 51, ".": 52, "/": 53, "(": 26, ")": 27, "|": 110})
SHIFTED = {"!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8",
           "_": "-", "+": "=", "{": "[", "}": "]", ":": ";", '"': "'", "~": "`",
           "<": ",", ">": ".", "?": "/"}
NAMED = {"enter": 28, "esc": 1, "backspace": 14, "tab": 15, "home": 102, "end": 107, "pageup": 104,
         "pagedown": 109, "insert": 110, "delete": 111, "up": 103, "down": 108, "left": 105, "right": 106,
         "pause": 119}
NAMED.update({f"f{i}": 58 + i for i in range(1, 11)})
NAMED.update({"f11": 87, "f12": 88})
MODS = {"ctrl": 29, "meta": 56, "super": 125}   # Left Control, Left Alt (Meta), Left Windows (Super)


def emit(fd, etype, code, value):
    t = time.time()
    os.write(fd, struct.pack("llHHi", int(t), int(t % 1 * 1e6), etype, code, value))


def press(fd, code, shift=False):
    for c, v in ([(SHIFT, 1)] if shift else []) + [(code, 1), (code, 0)] + ([(SHIFT, 0)] if shift else []):
        emit(fd, EV_KEY, c, v)
        emit(fd, EV_SYN, 0, 0)
        time.sleep(0.03)


def main():
    text = sys.argv[1]
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    for code in list(range(1, 128)) + list(BUTTONS.values()):
        fcntl.ioctl(fd, UI_SET_KEYBIT, code)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_REL)
    for axis in (0, 1):   # REL_X, REL_Y
        fcntl.ioctl(fd, UI_SET_RELBIT, axis)
    # struct uinput_user_dev: name, id (bustype, vendor, product, version), ff_effects_max, abs arrays
    os.write(fd, struct.pack("80sHHHHi", b"xl1200-test-keyboard", 3, 0x1234, 0x5678, 1, 0) + bytes(4 * 64 * 4))
    fcntl.ioctl(fd, UI_DEV_CREATE)
    time.sleep(1.5)   # let MiSTer find the new keyboard
    i = 0
    while i < len(text):
        c = text[i]
        if c == "{" and "}" in text[i:]:
            j = text.index("}", i)
            word = text[i + 1:j].lower().split()
            if word[0] == "m":
                dx, dy = int(word[1]), int(word[2])
                while dx or dy:   # in steps, as a real mouse reports
                    sx, sy = max(-20, min(20, dx)), max(-20, min(20, dy))
                    emit(fd, EV_REL, 0, sx)
                    emit(fd, EV_REL, 1, sy)
                    emit(fd, EV_SYN, 0, 0)
                    dx, dy = dx - sx, dy - sy
                    time.sleep(0.01)
            elif word[0] == "click":   # {click R}, {click R shift}
                press(fd, BUTTONS[word[1]], len(word) > 2 and word[2] == "shift")
            elif word[0] == "wait":
                time.sleep(float(word[1]))
            elif word[0] in MODS:   # {ctrl x}, {meta x}, {ctrl meta x}: a chord
                held = [MODS[w] for w in word[:-1]]
                for m in held:
                    emit(fd, EV_KEY, m, 1)
                    emit(fd, EV_SYN, 0, 0)
                    time.sleep(0.03)
                k = word[-1]
                if k in NAMED:
                    press(fd, NAMED[k])
                elif k in SHIFTED:
                    press(fd, KEYS[SHIFTED[k]], True)
                else:
                    press(fd, KEYS[k])
                for m in reversed(held):
                    emit(fd, EV_KEY, m, 0)
                    emit(fd, EV_SYN, 0, 0)
                    time.sleep(0.03)
            else:
                press(fd, NAMED[word[0]])
            i = j + 1
            continue
        if c in SHIFTED:
            press(fd, KEYS[SHIFTED[c]], True)
        elif c.isupper():
            press(fd, KEYS[c.lower()], True)
        else:
            press(fd, KEYS[c])
        i += 1
    time.sleep(0.5)
    fcntl.ioctl(fd, UI_DEV_DESTROY)
    os.close(fd)


if __name__ == "__main__":
    main()
