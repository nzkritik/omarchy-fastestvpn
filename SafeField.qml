import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Ui

// Omarchy's text field with Qt's own editing switched off, so the shell never
// reads the clipboard unless the user explicitly pastes.
//
// Every QQuickTextInput subscribes to QClipboard::dataChanged and, unless it
// is readOnly, answers each new offer by pulling the whole text just to
// refresh canPaste (Qt 6.12 qquicktextinput.cpp, q_canPasteChanged). On
// Wayland that is a synchronous, unbounded read from whichever client owns
// the selection, with no Paste involved, and it happens even while the field
// is hidden. readOnly gates that read, and canPaste(), paste(), Ctrl+V and
// middle-click as well. So this field stays readOnly and does its own editing
// from key events. Paste is explicit (Ctrl+V, Ctrl+Shift+V, Shift+Insert) and
// goes through wl-paste with a byte cap and a deadline.
//
// The cost: with readOnly the item takes no input-method events, so dead-key
// composition does not reach it. Keys that type a character directly work.
TextField {
  id: field

  // The most a paste may carry. Anything longer is refused whole rather than
  // cut short, because a truncated password or path is worse than none.
  property int maxPasteBytes: 1024
  readonly property int pasteTimeoutSec: 2

  readOnly: true
  maximumLength: 1024
  // Qt's default context menu offers Paste; readOnly already disables it, but
  // there is nothing in it this field needs.
  ContextMenu.menu: null

  function _replaceSelection(s) {
    var a = selectionStart, b = selectionEnd
    if (a === b) a = b = cursorPosition
    var next = text.slice(0, a) + s + text.slice(b)
    if (next.length > maximumLength) return
    text = next
    cursorPosition = a + s.length
  }

  // Delete back to the start of the previous word; in a password field that
  // would reveal where the spaces are, so it clears to the start instead.
  function _wordStartBefore(pos) {
    if (echoMode !== TextInput.Normal) return 0
    var i = pos
    while (i > 0 && /\s/.test(text[i - 1])) i--
    while (i > 0 && !/\s/.test(text[i - 1])) i--
    return i
  }

  function _printable(s) {
    if (s.length === 0) return false
    for (var i = 0; i < s.length; i++) {
      var c = s.charCodeAt(i)
      if (c < 0x20 || c === 0x7f) return false
    }
    return true
  }

  function _utf8Length(s) { return unescape(encodeURIComponent(s)).length }

  // The exit code and the output arrive separately; act once both are in.
  property var _pasteOut: null
  property var _pasteCode: null

  function _finishPaste() {
    if (_pasteOut === null || _pasteCode === null) return
    var out = _pasteOut, code = _pasteCode
    _pasteOut = _pasteCode = null
    // 124/137: timeout fired, so whatever arrived may be a fragment.
    if (code !== 0) {
      console.warn("FastestVPN: paste failed (exit " + code + ")")
      return
    }
    var s = out.replace(/\r?\n$/, "")       // wl-paste may end with a newline
    if (s === "") return
    if (_utf8Length(s) > maxPasteBytes) {
      console.warn("FastestVPN: paste refused, longer than " + maxPasteBytes + " bytes")
      return
    }
    if (!_printable(s)) {
      console.warn("FastestVPN: paste refused, it holds line breaks or control characters")
      return
    }
    _replaceSelection(s)
  }

  function _paste() {
    if (pasteProcess.running) return
    pasteProcess.running = true
  }

  Keys.onPressed: function (event) {
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    var hasSel = selectionStart !== selectionEnd

    if (event.matches(StandardKey.Paste)
        || (event.key === Qt.Key_Insert && (event.modifiers & Qt.ShiftModifier))
        || (ctrl && event.key === Qt.Key_V)) {
      _paste()
      event.accepted = true
    } else if (event.matches(StandardKey.Cut)) {
      if (hasSel) {
        copy()                    // Qt refuses to copy out of a password field
        _replaceSelection("")
      }
      event.accepted = true
    } else if (event.key === Qt.Key_Backspace) {
      if (hasSel) {
        _replaceSelection("")
      } else if (cursorPosition > 0) {
        var end = cursorPosition
        var start = ctrl ? _wordStartBefore(end) : end - 1
        // Keep a surrogate pair together.
        if (!ctrl && start > 0 && /[\uDC00-\uDFFF]/.test(text[start])) start--
        text = text.slice(0, start) + text.slice(end)
        cursorPosition = start
      }
      event.accepted = true
    } else if (event.key === Qt.Key_Delete) {
      if (hasSel) {
        _replaceSelection("")
      } else if (cursorPosition < text.length) {
        var at = cursorPosition
        var n = /[\uD800-\uDBFF]/.test(text[at]) ? 2 : 1
        text = text.slice(0, at) + text.slice(at + n)
        cursorPosition = at
      }
      event.accepted = true
    } else if (!ctrl && !(event.modifiers & (Qt.AltModifier | Qt.MetaModifier))
               && _printable(event.text)) {
      _replaceSelection(event.text)
      event.accepted = true
    }
    // Anything else (arrows, Home/End, Ctrl+A, Ctrl+C, Return, Tab, Escape)
    // falls through to Qt, whose readOnly handling of those never reads the
    // clipboard, or on up to the panel.
  }

  // readOnly also hides Qt's caret and keeps the arrow pointer, which makes
  // the field look uneditable, so draw both back.
  HoverHandler { cursorShape: Qt.IBeamCursor }

  Rectangle {
    id: caret
    property bool blinkOn: true
    x: field.cursorRectangle.x
    y: field.cursorRectangle.y
    width: Math.max(1, field.cursorRectangle.width)
    height: field.cursorRectangle.height
    color: field.color
    visible: field.activeFocus && blinkOn

    // Show solid after every move or edit, then blink.
    Connections {
      target: field
      function onCursorPositionChanged() { caret.restart() }
      function onTextChanged() { caret.restart() }
      function onActiveFocusChanged() { caret.restart() }
    }
    function restart() { blinkOn = true; blink.restart() }

    Timer {
      id: blink
      interval: Math.max(250, Qt.styleHints.cursorFlashTime / 2)
      repeat: true
      running: field.activeFocus
      onTriggered: caret.blinkOn = !caret.blinkOn
    }
  }

  Process {
    id: pasteProcess
    clearEnvironment: true
    // wl-paste needs only the compositor socket. `null` passes the session's
    // value through (Quickshell semantics).
    environment: ({ PATH: "/usr/bin", XDG_RUNTIME_DIR: null, WAYLAND_DISPLAY: null })
    running: false
    // timeout signals the whole process group, so a wl-paste stuck on a
    // client that never finishes its offer is killed with it. head stops
    // after one byte past the cap, which is enough to tell "too long" apart.
    command: ["/usr/bin/timeout", "-k", "1", String(field.pasteTimeoutSec),
              "/usr/bin/bash", "-c",
              "/usr/bin/wl-paste --type text 2>/dev/null | /usr/bin/head -c \"$1\"",
              "fvpn-paste", String(field.maxPasteBytes + 1)]
    onStarted: { field._pasteOut = null; field._pasteCode = null }
    onExited: function (code) { field._pasteCode = code; field._finishPaste() }
    stdout: StdioCollector {
      onStreamFinished: { field._pasteOut = text; field._finishPaste() }
    }
  }
}
