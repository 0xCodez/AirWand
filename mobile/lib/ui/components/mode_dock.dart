// Mode dock (Prism `.dock`): a 62 pt strong-glass capsule with four modes.
// The active mode sits in a raised "well" whose x and width ride separate
// springs (0.42/0.74 and 0.42/0.86 like the prototype) with a spectral glow
// bleeding out of its bottom edge.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import '../prism/prism.dart';

class ModeDockItem {
  const ModeDockItem({required this.icon, required this.label});

  final IconData icon;
  final String label;
}

class ModeDock extends StatefulWidget {
  const ModeDock({
    super.key,
    required this.index,
    required this.onChanged,
    required this.spectrum,
    this.items = defaultItems,
  });

  static const List<ModeDockItem> defaultItems = <ModeDockItem>[
    ModeDockItem(icon: Icons.touch_app_outlined, label: 'Trackpad'),
    ModeDockItem(icon: Icons.near_me_outlined, label: 'Air'),
    ModeDockItem(icon: Icons.keyboard_outlined, label: 'Keys'),
    ModeDockItem(icon: Icons.play_circle_outline_rounded, label: 'Media'),
  ];

  final int index;
  final ValueChanged<int> onChanged;
  final List<Color> spectrum;
  final List<ModeDockItem> items;

  @override
  State<ModeDock> createState() => _ModeDockState();
}

class _ModeDockState extends State<ModeDock>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  final SpringValue _x = SpringValue(0, response: 0.42, damping: 0.74);
  final SpringValue _w = SpringValue(80, response: 0.42, damping: 0.86);
  double _cell = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
  }

  @override
  void didUpdateWidget(ModeDock old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) _retarget(animate: true);
  }

  void _retarget({required bool animate}) {
    if (_cell <= 0) return;
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final x = widget.index * _cell;
    if (!animate || reduce) {
      _x.snap(x);
      _w.snap(_cell);
      return;
    }
    _x.target = x;
    _w.target = _cell;
    if (!_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  void _tick(Duration elapsed) {
    final dt = _last == Duration.zero
        ? 1 / 60
        : ((elapsed - _last).inMicroseconds / 1e6).clamp(0.0, 0.05);
    _last = elapsed;
    _x.step(dt);
    _w.step(dt);
    setState(() {});
    if (_x.settled && _w.settled) _ticker.stop();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final spec = widget.spectrum;
    return PrismGlass(
      radius: 999,
      strong: true,
      padding: const EdgeInsets.all(5),
      child: SizedBox(
        height: 52,
        child: LayoutBuilder(
          builder: (context, c) {
            final cell = c.maxWidth / widget.items.length;
            if (cell != _cell) {
              _cell = cell;
              _x.snap(widget.index * cell);
              _w.snap(cell);
            }
            return Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                // The well.
                Positioned(
                  left: _x.value,
                  top: 0,
                  bottom: 0,
                  width: _w.value.clamp(0.0, c.maxWidth),
                  child: _Well(spectrum: spec),
                ),
                Row(
                  children: <Widget>[
                    for (var i = 0; i < widget.items.length; i++)
                      Expanded(
                        child: _DockButton(
                          item: widget.items[i],
                          on: i == widget.index,
                          onTap: () => widget.onChanged(i),
                        ),
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Well extends StatelessWidget {
  const _Well({required this.spectrum});

  final List<Color> spectrum;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        // Glow bleeding under the well's bottom edge.
        Positioned(
          left: 0,
          right: 0,
          bottom: -4,
          height: 9,
          child: FractionallySizedBox(
            widthFactor: 0.6,
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(
                sigmaX: 6,
                sigmaY: 6,
                tileMode: ui.TileMode.decal,
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(99),
                  gradient: LinearGradient(colors: spectrum),
                ),
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[Color(0x2EFFFFFF), Color(0x0FFFFFFF)],
              ),
              border: Border.all(color: P.hair, width: 1),
              boxShadow: const <BoxShadow>[
                BoxShadow(
                  color: Color(0x99000000),
                  blurRadius: 18,
                  offset: Offset(0, 8),
                  spreadRadius: -8,
                ),
              ],
            ),
          ),
        ),
        // Hairline spectral underline.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 1,
          child: FractionallySizedBox(
            widthFactor: 0.44,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: <Color>[
                    spectrum.first.fade(0),
                    if (spectrum.length > 2)
                      ...spectrum.sublist(1, spectrum.length - 1)
                    else
                      ...spectrum,
                    spectrum.last.fade(0),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _DockButton extends StatelessWidget {
  const _DockButton({required this.item, required this.on, required this.onTap});

  final ModeDockItem item;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = on ? P.text : P.text3;
    return Semantics(
      button: true,
      selected: on,
      label: item.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: TweenAnimationBuilder<Color?>(
          tween: ColorTween(end: color),
          duration: const Duration(milliseconds: 220),
          builder: (context, c, _) => Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(item.icon, size: 19, color: c),
              const SizedBox(height: 3),
              Text(
                item.label,
                style: PT.display(10.5).copyWith(
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.1,
                  color: c,
                  height: 1.1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
