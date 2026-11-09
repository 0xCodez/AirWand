import 'dart:async';

import 'package:flutter/material.dart';

import '../../net/control.dart';
import '../../net/hosts.dart';
import '../../state/scope.dart';
import '../../state/settings.dart';
import '../prism/prism.dart';
import 'discovery_screen.dart';
import 'mode_kit.dart';

/// Settings: pointer, gestures, feedback, this phone, paired computers.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = OrbitScope.of(context);
    return Scaffold(
      backgroundColor: P.bg,
      body: SafeArea(
        bottom: false,
        child: ListenableBuilder(
          listenable: Listenable.merge(<Listenable>[s.settings, s.hosts, s.control]),
          builder: (context, _) => _Body(s: s),
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.s});
  final OrbitServices s;

  static const List<(double, String)> _accel = <(double, String)>[
    (0.0, 'Off'),
    (0.6, 'Natural'),
    (1.0, 'Strong'),
  ];

  double _nearestAccel(double v) {
    var best = _accel.first.$1;
    for (final o in _accel) {
      if ((o.$1 - v).abs() < (best - v).abs()) best = o.$1;
    }
    return best;
  }

  double _norm(double v, double lo, double hi) => ((v - lo) / (hi - lo)).clamp(0.0, 1.0);
  double _denorm(double t, double lo, double hi) => lo + (hi - lo) * t;

  @override
  Widget build(BuildContext context) {
    final st = s.settings;
    final spectrum = activeSpectrum(s);
    final bottom = MediaQuery.paddingOf(context).bottom;
    return ListView(
      padding: EdgeInsets.fromLTRB(16, 4, 16, bottom + 16),
      children: <Widget>[
        SizedBox(
          height: 44,
          child: Row(children: <Widget>[
            const Cap('Orbit · v1'),
            const Spacer(),
            Pressable(
              onTap: () => Navigator.of(context).maybePop(),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                child: Text('Done', style: uiText(15, weight: FontWeight.w600)),
              ),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 18),
          child: Text('Settings',
              style: uiText(34, weight: FontWeight.w700, tracking: -0.035)),
        ),
        const _GroupH('Pointer'),
        _Group(children: <Widget>[
          _SliderRow(
            label: 'Pointer speed',
            value: '${st.pointerSpeed.toStringAsFixed(1)}×',
            t: _norm(st.pointerSpeed, AppSettings.minPointerSpeed, AppSettings.maxPointerSpeed),
            spectrum: spectrum,
            onChanged: (t) => st.pointerSpeed =
                _denorm(t, AppSettings.minPointerSpeed, AppSettings.maxPointerSpeed),
          ),
          _Row(
            label: 'Acceleration',
            trailing: ModeSegmented<double>(
              options: _accel,
              value: _nearestAccel(st.acceleration),
              onChanged: (v) {
                s.haptics.selection();
                st.acceleration = v;
              },
            ),
          ),
          _SliderRow(
            label: 'Scroll speed',
            value: '${st.scrollSpeed.toStringAsFixed(1)}×',
            t: _norm(st.scrollSpeed, AppSettings.minScrollSpeed, AppSettings.maxScrollSpeed),
            spectrum: spectrum,
            onChanged: (t) => st.scrollSpeed =
                _denorm(t, AppSettings.minScrollSpeed, AppSettings.maxScrollSpeed),
          ),
        ]),
        const _GroupH('Gestures'),
        _Group(children: <Widget>[
          _Row(
            label: 'Natural scrolling',
            hint: 'Content follows your fingers',
            trailing: ModeSwitch(
              value: st.naturalScroll,
              spectrum: spectrum,
              onChanged: (v) {
                s.haptics.selection();
                st.naturalScroll = v;
              },
            ),
          ),
          _Row(
            label: 'Tap to click',
            trailing: ModeSwitch(
              value: st.tapToClick,
              spectrum: spectrum,
              onChanged: (v) {
                s.haptics.selection();
                st.tapToClick = v;
              },
            ),
          ),
        ]),
        const _GroupH('Feedback'),
        _Group(children: <Widget>[
          _Row(
            label: 'Haptics',
            hint: 'Taps, clicks and computer switches',
            trailing: ModeSwitch(
              value: st.haptics,
              spectrum: spectrum,
              onChanged: (v) {
                st.haptics = v;
                s.haptics.selection();
              },
            ),
          ),
          _Row(
            label: 'Appearance',
            trailing: ModeSegmented<ThemeMode>(
              options: const <(ThemeMode, String)>[
                (ThemeMode.dark, 'Dark'),
                (ThemeMode.light, 'Light'),
                (ThemeMode.system, 'System'),
              ],
              value: st.themeMode,
              onChanged: (v) {
                s.haptics.selection();
                st.themeMode = v;
              },
            ),
          ),
        ]),
        const _GroupH('This phone'),
        _Group(children: <Widget>[
          _EditableRow(
            key: const ValueKey<String>('device-name'),
            icon: Icons.smartphone_rounded,
            name: st.deviceName,
            caption: 'Shown on your computers',
            onRename: (v) => st.deviceName = v,
          ),
        ]),
        const _GroupH('Paired computers'),
        _Group(children: <Widget>[
          if (s.hosts.isEmpty)
            const _Row(label: 'No computers paired', muted: true, trailing: SizedBox()),
          for (final h in s.hosts.hosts) _HostRow(key: ValueKey<String>(h.id), s: s, host: h),
          Pressable(
            scale: 0.98,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const DiscoveryScreen(canClose: true)),
            ),
            child: const _Row(
              label: 'Add computer',
              icon: Icons.add_rounded,
              trailing: Icon(Icons.chevron_right_rounded, color: P.text3),
            ),
          ),
        ]),
        const Padding(
          padding: EdgeInsets.fromLTRB(6, 22, 6, 0),
          child: Cap('Protocol v1 · X25519 pairing · ChaCha20-Poly1305 over UDP 47821'),
        ),
      ],
    );
  }
}

class _GroupH extends StatelessWidget {
  const _GroupH(this.text);
  final String text;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.fromLTRB(6, 20, 6, 8), child: Cap(text));
}

/// A glass group whose rows are separated by inset hairlines.
class _Group extends StatelessWidget {
  const _Group({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(const Padding(
          padding: EdgeInsets.only(left: 14),
          child: SizedBox(height: 1, child: ColoredBox(color: P.hair)),
        ));
      }
      rows.add(children[i]);
    }
    return PrismGlass(radius: 22, child: Column(children: rows));
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.label,
    required this.trailing,
    this.hint,
    this.icon,
    this.muted = false,
  });

  final String label;
  final String? hint;
  final IconData? icon;
  final Widget trailing;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 54),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(children: <Widget>[
          if (icon != null) ...<Widget>[
            _HostIcon(icon!),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(label, style: uiText(15, color: muted ? P.text3 : P.text, tracking: -0.005)),
                if (hint != null) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(hint!, style: uiText(12, color: P.text3, tracking: 0)),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          trailing,
        ]),
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.t,
    required this.spectrum,
    required this.onChanged,
  });

  final String label;
  final String value;
  final double t;
  final List<Color> spectrum;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      child: Column(children: <Widget>[
        Row(children: <Widget>[
          Expanded(child: Text(label, style: uiText(15))),
          Cap(value),
        ]),
        const SizedBox(height: 2),
        ModeSlider(value: t, spectrum: spectrum, onChanged: onChanged),
      ]),
    );
  }
}

class _HostIcon extends StatelessWidget {
  const _HostIcon(this.icon);
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(color: P.hair, borderRadius: BorderRadius.circular(12)),
      child: Icon(icon, size: 19, color: P.text2),
    );
  }
}

class _PillBtn extends StatelessWidget {
  const _PillBtn(this.label, this.onTap, {this.danger = false});
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(left: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(color: P.hair, borderRadius: BorderRadius.circular(999)),
        child: Text(label,
            style: uiText(12.5, weight: FontWeight.w600, color: danger ? P.bad : P.text2)),
      ),
    );
  }
}

/// Row with an inline name field: Rename → edit in place → Save.
class _EditableRow extends StatefulWidget {
  const _EditableRow({
    super.key,
    required this.icon,
    required this.name,
    required this.caption,
    required this.onRename,
    this.extra,
  });

  final IconData icon;
  final String name;
  final String caption;
  final ValueChanged<String> onRename;
  final Widget? extra;

  @override
  State<_EditableRow> createState() => _EditableRowState();
}

class _EditableRowState extends State<_EditableRow> {
  late final TextEditingController _c = TextEditingController(text: widget.name);
  final FocusNode _f = FocusNode();
  bool _editing = false;

  @override
  void didUpdateWidget(_EditableRow old) {
    super.didUpdateWidget(old);
    if (!_editing && widget.name != _c.text) _c.text = widget.name;
  }

  @override
  void dispose() {
    _c.dispose();
    _f.dispose();
    super.dispose();
  }

  void _toggle() {
    if (_editing) {
      final v = _c.text.trim();
      if (v.isNotEmpty && v != widget.name) widget.onRename(v);
      _c.text = v.isEmpty ? widget.name : v;
      _f.unfocus();
      setState(() => _editing = false);
    } else {
      setState(() => _editing = true);
      _f.requestFocus();
      _c.selection = TextSelection(baseOffset: 0, extentOffset: _c.text.length);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = P.spectrumMac[2];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(children: <Widget>[
        _HostIcon(widget.icon),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                        color: _editing ? withA(accent, 0.9) : const Color(0x00000000)),
                  ),
                ),
                child: TextField(
                  controller: _c,
                  focusNode: _f,
                  readOnly: !_editing,
                  onSubmitted: (_) => _toggle(),
                  keyboardAppearance: Brightness.dark,
                  cursorColor: accent,
                  style: uiText(15, weight: FontWeight.w600),
                  decoration: const InputDecoration(
                    isCollapsed: true,
                    border: InputBorder.none,
                  ),
                ),
              ),
              const SizedBox(height: 3),
              Cap(widget.caption),
            ],
          ),
        ),
        _PillBtn(_editing ? 'Save' : 'Rename', _toggle),
        if (widget.extra != null) widget.extra!,
      ]),
    );
  }
}

class _HostRow extends StatefulWidget {
  const _HostRow({super.key, required this.s, required this.host});
  final OrbitServices s;
  final PairedHost host;

  @override
  State<_HostRow> createState() => _HostRowState();
}

class _HostRowState extends State<_HostRow> {
  bool _armed = false;
  Timer? _t;

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  Future<void> _forget() async {
    final s = widget.s;
    if (!_armed) {
      s.haptics.light();
      setState(() => _armed = true);
      _t = Timer(const Duration(milliseconds: 2400), () {
        if (mounted) setState(() => _armed = false);
      });
      return;
    }
    _t?.cancel();
    final wasActive = s.hosts.active?.id == widget.host.id;
    if (wasActive) s.control.disconnect();
    final nav = Navigator.of(context);
    // ControlScreen listens to the HostStore and connects the next host.
    await s.hosts.forget(widget.host.id);
    s.haptics.medium();
    if (s.hosts.isEmpty) nav.popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    final h = widget.host;
    final isActive = s.hosts.active?.id == h.id;
    final connected = isActive && s.control.host?.id == h.id && s.control.state == LinkState.connected;
    final status = connected ? 'Connected' : (isActive ? 'Active' : 'Paired');
    return _EditableRow(
      icon: h.isMac ? Icons.laptop_mac_rounded : Icons.desktop_windows_rounded,
      name: h.name,
      caption: '${h.osLabel} · $status',
      onRename: (v) => s.hosts.rename(h.id, v),
      extra: _PillBtn(_armed ? 'Tap to confirm' : 'Forget', _forget, danger: true),
    );
  }
}
