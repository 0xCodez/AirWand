import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../net/protocol.dart';
import '../../state/scope.dart';
import '../prism/prism.dart';
import 'mode_kit.dart';

/// What to send to turn [sent] into [now]: backspaces for every rune after
/// the common prefix, then the new tail. Rune-based, so one emoji is one
/// backspace.
({int backspaces, String insert}) diffTyping(String sent, String now) {
  final a = sent.runes.toList(), b = now.runes.toList();
  var p = 0;
  while (p < a.length && p < b.length && a[p] == b[p]) {
    p++;
  }
  return (backspaces: a.length - p, insert: String.fromCharCodes(b.sublist(p)));
}

/// Keyboard: a live text field that streams every character, special keys,
/// OS-aware shortcuts and a log of what was sent.
class KeysView extends StatefulWidget {
  const KeysView({
    super.key,
    this.os,
    this.hostName,
    this.topInset = 0,
    this.bottomInset = 0,
  });

  final HostOs? os;
  final String? hostName;
  final double topInset;
  final double bottomInset;

  @override
  State<KeysView> createState() => _KeysViewState();
}

class _Shortcut {
  const _Shortcut(this.name, this.caps, this.usage, this.mods);
  final String name;
  final List<String> caps;
  final int usage;
  final int mods;
}

const int _cmd = KeyMods.meta;
const int _ctrl = KeyMods.ctrl;
const int _sh = KeyMods.shift;

const List<_Shortcut> _mac = <_Shortcut>[
  _Shortcut('Copy', <String>['⌘', 'C'], Hid.c, _cmd),
  _Shortcut('Paste', <String>['⌘', 'V'], Hid.v, _cmd),
  _Shortcut('Undo', <String>['⌘', 'Z'], Hid.z, _cmd),
  _Shortcut('Select all', <String>['⌘', 'A'], Hid.a, _cmd),
  _Shortcut('Spotlight', <String>['⌘', 'Space'], Hid.space, _cmd),
  _Shortcut('Screenshot', <String>['⇧', '⌘', '4'], Hid.digit4, _cmd | _sh),
  _Shortcut('New tab', <String>['⌘', 'T'], Hid.t, _cmd),
  _Shortcut('Close', <String>['⌘', 'W'], Hid.w, _cmd),
];

const List<_Shortcut> _win = <_Shortcut>[
  _Shortcut('Copy', <String>['Ctrl', 'C'], Hid.c, _ctrl),
  _Shortcut('Paste', <String>['Ctrl', 'V'], Hid.v, _ctrl),
  _Shortcut('Undo', <String>['Ctrl', 'Z'], Hid.z, _ctrl),
  _Shortcut('Select all', <String>['Ctrl', 'A'], Hid.a, _ctrl),
  _Shortcut('Search', <String>['Win', 'S'], Hid.s, KeyMods.meta),
  _Shortcut('Screenshot', <String>['Win', '⇧', 'S'], Hid.s, KeyMods.meta | _sh),
  _Shortcut('New tab', <String>['Ctrl', 'T'], Hid.t, _ctrl),
  _Shortcut('Close', <String>['Ctrl', 'W'], Hid.w, _ctrl),
];

class _Special {
  const _Special(this.label, this.usage, {this.icon, this.repeat = false});
  final String label;
  final int usage;
  final IconData? icon;
  final bool repeat;
}

const List<_Special> _keys = <_Special>[
  _Special('esc', Hid.escape),
  _Special('tab', Hid.tab),
  _Special('delete', Hid.backspace, icon: Icons.backspace_outlined, repeat: true),
  _Special('return', Hid.enter, icon: Icons.keyboard_return_rounded),
  _Special('left', Hid.left, icon: Icons.arrow_back_rounded, repeat: true),
  _Special('up', Hid.up, icon: Icons.arrow_upward_rounded, repeat: true),
  _Special('down', Hid.down, icon: Icons.arrow_downward_rounded, repeat: true),
  _Special('right', Hid.right, icon: Icons.arrow_forward_rounded, repeat: true),
];

class _Log {
  _Log(this.tag, this.text) : at = DateTime.now(), id = _seq++;
  static int _seq = 0;
  final String tag;
  final String text;
  final DateTime at;
  final int id;
}

class _Ch {
  _Ch(this.ch) : id = _seq++;
  static int _seq = 0;
  final String ch;
  final int id;
}

/// Zero-width sentinel kept at the start of the field so a backspace on an
/// empty buffer is still observable.
const String _sentinel = '​';

class _KeysViewState extends State<KeysView> {
  final TextEditingController _field =
      TextEditingController(text: _sentinel);
  final FocusNode _focus = FocusNode();
  String _sent = '';
  final List<_Log> _log = <_Log>[];
  final List<_Ch> _stream = <_Ch>[];
  Timer? _clock;
  Timer? _repeat;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _log.isNotEmpty) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    _repeat?.cancel();
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  AirWandServices get _s => AirWandScope.of(context);

  void _addLog(String tag, String text) {
    _log.insert(0, _Log(tag, text));
    if (_log.length > 6) _log.removeLast();
  }

  void _streamText(String t) {
    for (final r in t.runes) {
      _stream.add(_Ch(String.fromCharCode(r)));
    }
    while (_stream.length > 36) {
      _stream.removeAt(0);
    }
  }

  void _onChanged(String value) {
    final s = _s;
    final hadSentinel = value.startsWith(_sentinel);
    final visible = value.replaceAll(_sentinel, '');
    final diff = diffTyping(_sent, visible);
    var backspaces = diff.backspaces;
    final insert = diff.insert;
    if (!hadSentinel && backspaces == 0 && insert.isEmpty) backspaces = 1;
    for (var i = 0; i < backspaces; i++) {
      s.control.key(Hid.backspace);
      if (_stream.isNotEmpty) _stream.removeLast();
    }
    if (backspaces > 0) {
      _addLog('KEY', 'delete${backspaces > 1 ? ' ×$backspaces' : ''} · usage 0x2A');
    }
    if (insert.isNotEmpty) {
      final lines = insert.split('\n');
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].isNotEmpty) s.control.text(lines[i]);
        if (i < lines.length - 1) s.control.key(Hid.enter);
      }
      _streamText(insert);
      _addLog('TEXT', '“$insert” · ${utf8.encode(insert).length} B');
    }
    s.haptics.selection();
    _sent = visible;
    if (!hadSentinel) {
      final t = _sentinel + visible;
      _field.value = TextEditingValue(
        text: t,
        selection: TextSelection.collapsed(offset: t.length),
      );
    }
    setState(() {});
  }

  void _enter() {
    _sendKey(_keys[3]);
    _sent = '';
    _field.value = const TextEditingValue(
      text: _sentinel,
      selection: TextSelection.collapsed(offset: 1),
    );
    _focus.requestFocus();
  }

  void _sendKey(_Special k) {
    final s = _s;
    s.control.key(k.usage);
    s.haptics.selection();
    if (k.usage == Hid.backspace && _stream.isNotEmpty) _stream.removeLast();
    if (k.usage == Hid.enter) _streamText(' ⏎ ');
    _addLog('KEY',
        '${k.label} · usage 0x${k.usage.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    setState(() {});
  }

  void _holdKey(_Special k, bool down) {
    _repeat?.cancel();
    _repeat = null;
    if (!down || !k.repeat) return;
    _repeat = Timer(const Duration(milliseconds: 420), () {
      _repeat = Timer.periodic(const Duration(milliseconds: 70), (_) {
        if (!mounted) return;
        _s.control.key(k.usage);
        if (k.usage == Hid.backspace && _stream.isNotEmpty) {
          setState(() => _stream.removeLast());
        }
      });
    });
  }

  void _shortcut(_Shortcut sc, bool mac) {
    final s = _s;
    s.control.key(sc.usage, mods: sc.mods);
    s.haptics.selection();
    setState(() => _addLog('KEY', '${sc.caps.join(mac ? '' : '+')} · ${sc.name}'));
  }

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t).inSeconds;
    if (d < 2) return 'now';
    if (d < 60) return '${d}s';
    return '${d ~/ 60}m';
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final host = activeHost(s);
    final os = widget.os ?? host?.os ?? HostOs.mac;
    final mac = os == HostOs.mac;
    final name = widget.hostName ?? host?.name ?? 'your computer';
    final spectrum = P.spectrumFor(os.wire);
    final shortcuts = mac ? _mac : _win;

    return ListView(
      padding: EdgeInsets.fromLTRB(14, widget.topInset + 2, 14, widget.bottomInset + 12),
      children: <Widget>[
        SizedBox(
          height: 54,
          child: PrismGlass(
            radius: 20,
            spectrum: spectrum,
            glow: _focus.hasFocus ? 0.35 : 0,
            padding: const EdgeInsets.fromLTRB(18, 0, 8, 0),
            child: Row(children: <Widget>[
              Expanded(
                child: Focus(
                  onFocusChange: (_) => setState(() {}),
                  child: TextField(
                    controller: _field,
                    focusNode: _focus,
                    onChanged: _onChanged,
                    onSubmitted: (_) => _enter(),
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.send,
                    keyboardAppearance: Brightness.dark,
                    cursorColor: spectrum[0],
                    style: uiText(17),
                    decoration: InputDecoration(
                      isCollapsed: true,
                      border: InputBorder.none,
                      hintText: 'Type on $name',
                      hintStyle: uiText(17, color: P.text3),
                    ),
                  ),
                ),
              ),
              Pressable(
                onTap: _enter,
                child: const SizedBox.square(
                  dimension: 40,
                  child: Icon(Icons.keyboard_return_rounded, size: 18, color: P.text2),
                ),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 34,
          child: Row(children: <Widget>[
            const SizedBox(width: 4),
            const Cap('Live'),
            const SizedBox(width: 10),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                reverse: true,
                physics: const NeverScrollableScrollPhysics(),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    for (final c in _stream) _StreamChar(key: ValueKey<int>(c.id), ch: c.ch),
                  ],
                ),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: 4,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 1.7,
          padding: EdgeInsets.zero,
          children: <Widget>[
            for (final k in _keys)
              Semantics(
                button: true,
                label: k.label,
                child: Pressable(
                  onTap: () => _sendKey(k),
                  onDown: (d) => _holdKey(k, d),
                  child: PrismGlass(
                    radius: 16,
                    child: Center(
                      child: k.icon == null
                          ? Cap(k.label, color: P.text2, size: 9.5)
                          : Icon(k.icon, size: 20, color: P.text),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Cap('Shortcuts · ${mac ? 'macOS' : 'Windows'}'),
        ),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 3.3,
          padding: EdgeInsets.zero,
          children: <Widget>[
            for (final sc in shortcuts)
              Pressable(
                onTap: () => _shortcut(sc, mac),
                child: PrismGlass(
                  radius: 16,
                  padding: const EdgeInsets.fromLTRB(14, 0, 12, 0),
                  child: Row(children: <Widget>[
                    Expanded(
                      child: Text(sc.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: uiText(14, weight: FontWeight.w600)),
                    ),
                    for (final c in sc.caps) _Kbd(c),
                  ]),
                ),
              ),
          ],
        ),
        const SizedBox(height: 20),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 4),
          child: Cap('Sent'),
        ),
        const SizedBox(height: 8),
        if (_log.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
            child: Text('Nothing sent yet', style: uiText(13, color: P.text3)),
          ),
        for (final r in _log)
          TweenAnimationBuilder<double>(
            key: ValueKey<int>(r.id),
            tween: Tween<double>(begin: 0, end: 1),
            duration: const Duration(milliseconds: 380),
            curve: Curves.easeOutCubic,
            builder: (context, v, child) => Opacity(
              opacity: v,
              child: Transform.translate(offset: Offset(0, -6 * (1 - v)), child: child),
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: P.hair)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  SizedBox(width: 42, child: Cap(r.tag)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(r.text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: uiText(13, color: P.text2)),
                  ),
                  const SizedBox(width: 10),
                  Cap(_ago(r.at)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _Kbd extends StatelessWidget {
  const _Kbd(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 3),
      height: 20,
      constraints: const BoxConstraints(minWidth: 20),
      padding: const EdgeInsets.symmetric(horizontal: 5),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: P.hair,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: P.hair),
      ),
      child: Text(label, style: PT.mono(9.5).copyWith(color: P.text2)),
    );
  }
}

/// A character entering the live stream: rises 7 px out of a blur.
class _StreamChar extends StatelessWidget {
  const _StreamChar({super.key, required this.ch});
  final String ch;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutBack,
      builder: (context, v, child) => Opacity(
        opacity: v.clamp(0.0, 1.0),
        child: Transform.translate(offset: Offset(0, 7 * (1 - v)), child: child),
      ),
      child: Text(ch, style: PT.mono(13).copyWith(color: P.text)),
    );
  }
}
