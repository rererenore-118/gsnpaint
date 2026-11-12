// エディタのキーボードショートカット。押されたキーを操作に対応させるだけの部分を
// main.dart から分けて、ブラウザなしで単体テストできるようにしている
// （test/editor_shortcuts_test.dart）。実際の操作は main.dart 側で行う。
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum EditorShortcut {
  undo,
  redo,
  copy,
  paste,
  selectAll,
  save,
  delete,
  escape,
}

/// Mac なら ⌘、それ以外は Ctrl を修飾キーとして使う。
/// Mac でも Ctrl を受け付ける（外付けキーボードや慣れの違いに合わせる）。
EditorShortcut? editorShortcutFor(
  LogicalKeyboardKey key, {
  required bool meta,
  required bool control,
  required bool shift,
  required bool alt,
}) {
  if (alt) return null;
  final command = meta || control;
  if (!command) {
    if (shift) return null;
    if (key == LogicalKeyboardKey.escape) return EditorShortcut.escape;
    // Mac の delete キーは Backspace として届くので両方に反応する。
    if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      return EditorShortcut.delete;
    }
    return null;
  }
  if (key == LogicalKeyboardKey.keyZ) {
    return shift ? EditorShortcut.redo : EditorShortcut.undo;
  }
  if (shift) return null;
  if (key == LogicalKeyboardKey.keyY) return EditorShortcut.redo;
  if (key == LogicalKeyboardKey.keyC) return EditorShortcut.copy;
  if (key == LogicalKeyboardKey.keyV) return EditorShortcut.paste;
  if (key == LogicalKeyboardKey.keyA) return EditorShortcut.selectAll;
  if (key == LogicalKeyboardKey.keyS) return EditorShortcut.save;
  return null;
}

bool get _isMac =>
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// ツールチップに添えるキーの表記。Mac では「⌘Z」、それ以外では「Ctrl+Z」。
String shortcutLabel(EditorShortcut s, {bool? mac}) {
  final m = mac ?? _isMac;
  String cmd(String k) => m ? '⌘$k' : 'Ctrl+$k';
  switch (s) {
    case EditorShortcut.undo:
      return cmd('Z');
    case EditorShortcut.redo:
      return m ? '⇧⌘Z' : 'Ctrl+Y';
    case EditorShortcut.copy:
      return cmd('C');
    case EditorShortcut.paste:
      return cmd('V');
    case EditorShortcut.selectAll:
      return cmd('A');
    case EditorShortcut.save:
      return cmd('S');
    case EditorShortcut.delete:
      return m ? 'delete' : 'Delete';
    case EditorShortcut.escape:
      return 'Esc';
  }
}
