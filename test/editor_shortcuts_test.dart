// キーボードショートカットの対応表のテスト。
//   flutter test test/editor_shortcuts_test.dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gsnpaint/editor_shortcuts.dart';

EditorShortcut? press(LogicalKeyboardKey key,
        {bool meta = false, bool control = false, bool shift = false, bool alt = false}) =>
    editorShortcutFor(key, meta: meta, control: control, shift: shift, alt: alt);

void main() {
  test('⌘ と Ctrl のどちらでも同じ操作になる', () {
    for (final mod in [
      (meta: true, control: false),
      (meta: false, control: true),
    ]) {
      EditorShortcut? p(LogicalKeyboardKey k, {bool shift = false}) =>
          press(k, meta: mod.meta, control: mod.control, shift: shift);
      expect(p(LogicalKeyboardKey.keyZ), EditorShortcut.undo);
      expect(p(LogicalKeyboardKey.keyZ, shift: true), EditorShortcut.redo);
      expect(p(LogicalKeyboardKey.keyY), EditorShortcut.redo);
      expect(p(LogicalKeyboardKey.keyC), EditorShortcut.copy);
      expect(p(LogicalKeyboardKey.keyV), EditorShortcut.paste);
      expect(p(LogicalKeyboardKey.keyA), EditorShortcut.selectAll);
      expect(p(LogicalKeyboardKey.keyS), EditorShortcut.save);
    }
  });

  test('修飾キーなしでは Esc と Delete / Backspace だけ', () {
    expect(press(LogicalKeyboardKey.escape), EditorShortcut.escape);
    expect(press(LogicalKeyboardKey.delete), EditorShortcut.delete);
    expect(press(LogicalKeyboardKey.backspace), EditorShortcut.delete);
    expect(press(LogicalKeyboardKey.keyZ), isNull);
    expect(press(LogicalKeyboardKey.keyC), isNull);
  });

  test('余計な修飾キーが付いたものは拾わない', () {
    expect(press(LogicalKeyboardKey.keyZ, meta: true, alt: true), isNull);
    expect(press(LogicalKeyboardKey.keyC, meta: true, shift: true), isNull);
    expect(press(LogicalKeyboardKey.keyS, control: true, shift: true), isNull);
    expect(press(LogicalKeyboardKey.backspace, shift: true), isNull);
    expect(press(LogicalKeyboardKey.backspace, meta: true), isNull);
    expect(press(LogicalKeyboardKey.keyQ, meta: true), isNull);
  });

  test('ツールチップの表記は Mac とそれ以外で変わる', () {
    expect(shortcutLabel(EditorShortcut.undo, mac: true), '⌘Z');
    expect(shortcutLabel(EditorShortcut.redo, mac: true), '⇧⌘Z');
    expect(shortcutLabel(EditorShortcut.undo, mac: false), 'Ctrl+Z');
    expect(shortcutLabel(EditorShortcut.redo, mac: false), 'Ctrl+Y');
  });
}
