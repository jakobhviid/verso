#!/bin/bash
# In-VM, as root: synthesize input in the headless shell through Clutter virtual
# devices created by org.gnome.Shell.Eval (needs --unsafe-mode).
#
#   input.sh click <x> <y>       left click at screen coordinates
#   input.sh rclick <x> <y>      right click there
#   input.sh drag <x> <y> <x2> <y2>   press at x y, move to x2 y2 in steps, release
#   input.sh repeat <keysym-name> <count> <ms>   one key pressed and released <count> times, <ms> apart (a held key)
#   input.sh type <text>         type ASCII text (letters, digits, space, . _ - @ : /)
#   input.sh key <keysym-name>   one key, e.g. Return, Escape, BackSpace
#   input.sh scroll <x> <y> <steps> <dy> <ms>   a touchpad scroll, as below
#   input.sh swipe <x> <y> <steps> <dx> <ms>    the same sideways (negative dx moves the content right)
#
# What made it work on GNOME 50 (each found the hard way):
#  - the Eval scope has no Clutter global: use imports.gi
#  - timestamps: Clutter.CURRENT_TIME; made-up monotonic times dropped the clicks
#  - one Eval per event, with the devices kept on the shell's global object
set -euo pipefail
ev() {
  local out
  out=$(/usr/local/bin/in-session gdbus call --session --dest org.gnome.Shell \
    --object-path /org/gnome/Shell --method org.gnome.Shell.Eval \
    "const {Clutter} = imports.gi; const seat = Clutter.get_default_backend().get_default_seat();
     global._labPointer ??= seat.create_virtual_device(Clutter.InputDeviceType.POINTER_DEVICE);
     global._labKeyboard ??= seat.create_virtual_device(Clutter.InputDeviceType.KEYBOARD_DEVICE);
     $1; true")
  case "$out" in "(true, "*) ;; *) echo "$out" >&2; exit 1 ;; esac
}
key() {
  ev "global._labKeyboard.notify_keyval(Clutter.CURRENT_TIME, Clutter.KEY_$1, Clutter.KeyState.PRESSED)"
  ev "global._labKeyboard.notify_keyval(Clutter.CURRENT_TIME, Clutter.KEY_$1, Clutter.KeyState.RELEASED)"
}
case ${1:?click|type|key} in
click)
  ev "global._labPointer.notify_absolute_motion(Clutter.CURRENT_TIME, $2, $3)"
  ev "global._labPointer.notify_button(Clutter.CURRENT_TIME, Clutter.BUTTON_PRIMARY, Clutter.ButtonState.PRESSED)"
  ev "global._labPointer.notify_button(Clutter.CURRENT_TIME, Clutter.BUTTON_PRIMARY, Clutter.ButtonState.RELEASED)"
  ;;
drag)
  ev "global._labPointer.notify_absolute_motion(Clutter.CURRENT_TIME, $2, $3)"
  ev "global._labPointer.notify_button(Clutter.CURRENT_TIME, Clutter.BUTTON_PRIMARY, Clutter.ButtonState.PRESSED)"
  for step in 1 2 3 4 5 6 7 8 9 10; do
    ev "global._labPointer.notify_absolute_motion(Clutter.CURRENT_TIME, $2 + ($4 - $2) * $step / 10, $3 + ($5 - $3) * $step / 10)"
    sleep 0.05
  done
  sleep 0.3
  ev "global._labPointer.notify_button(Clutter.CURRENT_TIME, Clutter.BUTTON_PRIMARY, Clutter.ButtonState.RELEASED)"
  ;;
repeat)
  ev "const GLib = imports.gi.GLib; let left = $3;
      GLib.timeout_add(GLib.PRIORITY_DEFAULT, $4, () => {
        global._labKeyboard.notify_keyval(Clutter.CURRENT_TIME, Clutter.KEY_$2, Clutter.KeyState.PRESSED);
        global._labKeyboard.notify_keyval(Clutter.CURRENT_TIME, Clutter.KEY_$2, Clutter.KeyState.RELEASED);
        return --left > 0; })"
  ;;
rclick)
  ev "global._labPointer.notify_absolute_motion(Clutter.CURRENT_TIME, $2, $3)"
  ev "global._labPointer.notify_button(Clutter.CURRENT_TIME, Clutter.BUTTON_SECONDARY, Clutter.ButtonState.PRESSED)"
  ev "global._labPointer.notify_button(Clutter.CURRENT_TIME, Clutter.BUTTON_SECONDARY, Clutter.ButtonState.RELEASED)"
  ;;
type)
  printf '%s' "$2" | sed 's/./&\n/g' | while IFS= read -r c; do
    case "$c" in
      ' ') key space ;; .) key period ;; _) key underscore ;; -) key minus ;;
      @) key at ;; :) key colon ;; /) key slash ;;
      [A-Za-z0-9]) key "$c" ;;
      *) echo "input.sh: cannot type '$c'" >&2; exit 1 ;;
    esac
  done
  ;;
key) key "$2" ;;
# A touchpad's two-finger scroll: <steps> events of <dy> pixels each, <ms> apart, at x y (negative dy scrolls up),
# then the end of the gesture (which starts GTK's kinetic scrolling). Run in the shell, so the timing is its own.
scroll)
  ev "global._labPointer.notify_absolute_motion(Clutter.CURRENT_TIME, $2, $3)"
  ev "const GLib = imports.gi.GLib; let left = $4;
      GLib.timeout_add(GLib.PRIORITY_DEFAULT, $6, () => {
        if (left-- > 0) { global._labPointer.notify_scroll_continuous(Clutter.CURRENT_TIME, 0, $5, Clutter.ScrollSource.FINGER, Clutter.ScrollFinishFlags.NONE); return true; }
        global._labPointer.notify_scroll_continuous(Clutter.CURRENT_TIME, 0, 0, Clutter.ScrollSource.FINGER, Clutter.ScrollFinishFlags.VERTICAL);
        return false; })"
  ;;
swipe)
  ev "global._labPointer.notify_absolute_motion(Clutter.CURRENT_TIME, $2, $3)"
  ev "const GLib = imports.gi.GLib; let left = $4;
      GLib.timeout_add(GLib.PRIORITY_DEFAULT, $6, () => {
        if (left-- > 0) { global._labPointer.notify_scroll_continuous(Clutter.CURRENT_TIME, $5, 0, Clutter.ScrollSource.FINGER, Clutter.ScrollFinishFlags.NONE); return true; }
        global._labPointer.notify_scroll_continuous(Clutter.CURRENT_TIME, 0, 0, Clutter.ScrollSource.FINGER, Clutter.ScrollFinishFlags.HORIZONTAL);
        return false; })"
  ;;
esac
