import 'package:flutter/services.dart';
import 'package:flutter_hbb/mobile/ime_input_diff.dart';
import 'package:flutter_test/flutter_test.dart';

const _reservoir = '11111111';

TextEditingValue _composing(String text, int start) => TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
      composing: TextRange(start: start, end: text.length),
    );

void main() {
  group('planAndroidImeEdit', () {
    test('hidden reservoir ends at a word boundary for first-word autocorrect',
        () {
      expect(androidImeInitialText.endsWith(' '), isTrue);
      expect(
          androidImeInitialText
              .substring(0, androidImeInitialText.length - 1)
              .split(''),
          everyElement(equals('1')));
    });

    test('streams append-only Gboard voice composition incrementally', () {
      final first = planAndroidImeEdit(
        sentValue: _reservoir,
        editingValue: _composing('${_reservoir}hello', _reservoir.length),
      );

      expect(first.deferred, isFalse);
      expect(first.deleteCount, 0);
      expect(first.insertText, 'hello');

      final second = planAndroidImeEdit(
        sentValue: first.nextSentValue,
        editingValue: _composing('${_reservoir}hello world', _reservoir.length),
      );

      // The old composing-length heuristic deferred this update because the
      // full 11-character composition was longer than the 6-character suffix.
      expect(second.deferred, isFalse);
      expect(second.deleteCount, 0);
      expect(second.insertText, ' world');
    });

    test('defers an autocorrect rewrite while composition is active', () {
      final sent = '${_reservoir}teh';
      final plan = planAndroidImeEdit(
        sentValue: sent,
        editingValue: _composing('${_reservoir}the', _reservoir.length),
      );

      expect(plan.deferred, isTrue);
      expect(plan.hasRemoteEdit, isFalse);
      expect(plan.nextSentValue, sent);
    });

    test('flushes a deferred autocorrect rewrite when the IME commits', () {
      final plan = planAndroidImeEdit(
        sentValue: '${_reservoir}teh',
        editingValue: const TextEditingValue(
          text: '${_reservoir}the',
          selection: TextSelection.collapsed(offset: 11),
        ),
      );

      expect(plan.deferred, isFalse);
      expect(plan.deleteCount, 2);
      expect(plan.insertText, 'he');
      expect(plan.nextSentValue, '${_reservoir}the');
    });

    test('defers composing deletions and flushes them on commit', () {
      final sent = '${_reservoir}word';
      final composing = planAndroidImeEdit(
        sentValue: sent,
        editingValue: _composing('${_reservoir}wor', _reservoir.length),
      );
      final committed = planAndroidImeEdit(
        sentValue: sent,
        editingValue: const TextEditingValue(
          text: '${_reservoir}wor',
          selection: TextSelection.collapsed(offset: 11),
        ),
      );

      expect(composing.deferred, isTrue);
      expect(committed.deleteCount, 1);
      expect(committed.insertText, isEmpty);
    });

    test('does not backspace the hidden reservoir when an IME replaces it', () {
      final plan = planAndroidImeEdit(
        sentValue: _reservoir,
        editingValue: _composing('dictated text', 0),
      );

      expect(plan.deferred, isFalse);
      expect(plan.deleteCount, 0);
      expect(plan.insertText, 'dictated text');
    });
  });
}
