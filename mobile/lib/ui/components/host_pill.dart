// Host pill (Prism `.pill`): a strong-glass capsule with the OS glyph, the
// computer's name and the live latency in Martian Mono behind a hairline.
// A spectral glow lives along its bottom edge; its strength follows link
// quality and packet activity. On a host switch the name slides out with a
// blur while the new one springs in from the swipe direction, and the
// capsule width springs to fit.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../net/control.dart';
import '../../net/hosts.dart';
import '../prism/prism.dart';

class HostPill extends StatelessWidget {
  const HostPill({
    super.key,
    required this.host,
    required this.state,
    required this.latencyMs,
    required this.onTap,
    this.direction = 1,
    this.activity = 0,
  });

  final PairedHost? host;
  final LinkState state;
  final int? latencyMs;
  final VoidCallback onTap;

  /// Direction of the last switch (+1 next, -1 previous) for the name swap.
  final int direction;

  /// 0..1 recent packet activity; brightens the glow.
  final double activity;

  Color get _dotColor {
    final ms = latencyMs;
    if (state != LinkState.connected || ms == null) {
      return state == LinkState.lost ? P.bad : P.warn;
    }
    if (ms < 15) return P.ok;
    if (ms < 40) return P.warn;
    return P.bad;
  }

  String get _latencyText {
    switch (state) {
      case LinkState.connected:
        final ms = latencyMs;
        return ms == null ? '— MS' : '$ms MS';
      case LinkState.connecting:
        return 'LINK';
      case LinkState.lost:
        return 'LOST';
      case LinkState.idle:
        return 'IDLE';
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = host;
    final ms = latencyMs ?? 40;
    final latK = state == LinkState.connected
        ? (1 - (ms - 4) / 36).clamp(0.25, 1.0)
        : 0.25;
    final glow = (0.22 + 0.38 * latK + 0.55 * activity).clamp(0.0, 1.0);
    final spectrum = P.spectrumForHost(h);
    final d = direction >= 0 ? 1.0 : -1.0;

    return Semantics(
      button: true,
      label: h == null
          ? 'No computer. Open computers'
          : 'Active computer ${h.name}. Open computers',
      child: GestureDetector(
        onTap: onTap,
        child: _Pressable(
          child: PrismGlass(
            radius: 999,
            strong: true,
            glow: glow,
            glowAt: Alignment.bottomCenter,
            spectrum: spectrum,
            padding: const EdgeInsets.fromLTRB(13, 0, 14, 0),
            child: SizedBox(
              height: 40,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  AnimatedSize(
                    duration: const Duration(milliseconds: 450),
                    curve: Curves.easeOutBack,
                    alignment: Alignment.centerLeft,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 460),
                      reverseDuration: const Duration(milliseconds: 320),
                      switchInCurve: Curves.easeOutBack,
                      switchOutCurve: Curves.easeOut,
                      layoutBuilder: (current, previous) => Stack(
                        alignment: Alignment.centerLeft,
                        children: <Widget>[
                          ...previous,
                          if (current != null) current,
                        ],
                      ),
                      transitionBuilder: (child, a) {
                        final incoming = child.key == ValueKey<String>(h?.id ?? '-');
                        return AnimatedBuilder(
                          animation: a,
                          child: child,
                          builder: (context, child) {
                            final q = a.value;
                            final dx = incoming ? d * 22 * (1 - q) : -d * 18 * (1 - q);
                            final blur = (1 - q).clamp(0.0, 1.0) * 4;
                            final op = incoming
                                ? (q * 1.4).clamp(0.0, 1.0)
                                : (q * 1.6 - 0.6).clamp(0.0, 1.0);
                            return Opacity(
                              opacity: op,
                              child: Transform.translate(
                                offset: Offset(dx, 0),
                                child: blur < 0.05
                                    ? child
                                    : ImageFiltered(
                                        imageFilter: ui.ImageFilter.blur(
                                          sigmaX: blur,
                                          sigmaY: blur,
                                        ),
                                        child: child,
                                      ),
                              ),
                            );
                          },
                        );
                      },
                      child: _Face(key: ValueKey<String>(h?.id ?? '-'), host: h),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Container(
                    height: 14,
                    padding: const EdgeInsets.only(left: 10),
                    decoration: const BoxDecoration(
                      border: Border(left: BorderSide(color: P.hair2, width: 1)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 280),
                          width: 5,
                          height: 5,
                          decoration: BoxDecoration(
                            color: _dotColor,
                            shape: BoxShape.circle,
                            boxShadow: <BoxShadow>[
                              BoxShadow(
                                color: _dotColor.fade(0.6),
                                blurRadius: 6,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _latencyText,
                          style: PT.mono(9).copyWith(color: P.text2, height: 1),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Face extends StatelessWidget {
  const _Face({super.key, required this.host});

  final PairedHost? host;

  @override
  Widget build(BuildContext context) {
    final h = host;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(
          h == null
              ? Icons.add_rounded
              : (h.isMac ? Icons.laptop_mac_rounded : Icons.desktop_windows_rounded),
          size: 17,
          color: P.text2,
        ),
        const SizedBox(width: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 170),
          child: Text(
            h?.name ?? 'Add a computer',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
            style: PT.display(14).copyWith(
              fontWeight: FontWeight.w600,
              letterSpacing: -0.14,
              color: P.text,
              height: 1,
            ),
          ),
        ),
      ],
    );
  }
}

/// Prototype `.press`: scale to 0.96 while held, spring back.
class _Pressable extends StatefulWidget {
  const _Pressable({required this.child});

  final Widget child;

  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: _down ? 0.96 : 1,
        duration: Duration(milliseconds: _down ? 120 : 380),
        curve: _down ? Curves.easeOut : Curves.easeOutBack,
        child: widget.child,
      ),
    );
  }
}
