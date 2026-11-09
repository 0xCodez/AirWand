// Home (Prism `.shell`): top bar (find computers · host pill · settings),
// the active mode view, and the mode dock. Owns the link lifecycle, the
// spectral light of the trackpad (so a host switch can sweep and retint
// it) and the remote mirror model.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import '../../net/discovery.dart';
import '../../net/hosts.dart';
import '../../state/scope.dart';
import '../components/host_pill.dart';
import '../components/mode_dock.dart';
import '../components/remote_preview.dart';
import '../prism/prism.dart';
import 'air_view.dart';
import 'discovery_screen.dart';
import 'host_switcher_sheet.dart';
import 'keys_view.dart';
import 'media_view.dart';
import 'settings_screen.dart';
import 'trackpad_view.dart';

class ControlScreen extends StatefulWidget {
  const ControlScreen({super.key});

  @override
  State<ControlScreen> createState() => _ControlScreenState();
}

class _ControlScreenState extends State<ControlScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late AirWandServices _s;
  bool _init = false;
  final HostDiscovery _background = HostDiscovery();
  final SpectralController _spectral = SpectralController();
  final RemoteModel _remote = RemoteModel();

  late final Ticker _ticker;
  Duration _last = Duration.zero;

  /// Trackpad stage shove on host switch (prototype tpX: 0.5 / 0.7).
  final SpringValue _shove = SpringValue(0, response: 0.5, damping: 0.7);

  /// Mode view entrance (prototype: 0.46 / 0.86, 26 px slide, 0.985 scale).
  final SpringValue _enter = SpringValue(1, response: 0.46, damping: 0.86);
  int _enterDir = 1;

  int _mode = 0;
  int _pillDir = 1;
  int? _pendingDir;
  String? _activeId;

  String? _toast;
  Timer? _toastTimer;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_init) return;
    _init = true;
    _s = AirWandScope.of(context);
    WidgetsBinding.instance.addObserver(this);
    _s.hosts.addListener(_onHosts);
    _s.control.addListener(_onControl);
    _background.addListener(_onDiscovered);
    _background.start();
    final h = _s.hosts.active;
    if (h != null) {
      _activeId = h.id;
      _spectral.spectrum = _spectrumOf(h);
      _remote.setHost(h);
      _s.control.connect(h);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _s.hosts.removeListener(_onHosts);
    _s.control.removeListener(_onControl);
    _background.removeListener(_onDiscovered);
    _background.dispose();
    _s.control.disconnect();
    _toastTimer?.cancel();
    _ticker.dispose();
    _spectral.dispose();
    _remote.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _s.control.resume();
        _background.start();
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _s.control.suspend();
        _background.stop();
      default:
        // inactive / hidden: keep the link (e.g. Control Center pulled down).
        break;
    }
  }

  static List<Color> _spectrumOf(PairedHost? h) => P.spectrumForHost(h);

  bool get _reduce => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  // ---------------------------------------------------------------- hosts

  void _onControl() => _remote.pong(_s.control.latencyMs);

  void _onHosts() {
    final h = _s.hosts.active;
    if (h == null) {
      _s.control.disconnect();
      if (mounted) setState(() => _activeId = null);
      return;
    }
    if (h.id == _activeId) {
      _s.control.retarget(h);
      return;
    }
    // Active host changed (three-finger swipe, chevrons or the switcher).
    final hosts = _s.hosts.hosts;
    final from = hosts.indexWhere((x) => x.id == _activeId);
    final to = hosts.indexWhere((x) => x.id == h.id);
    final dir = _pendingDir ?? (to >= from ? 1 : -1);
    _pendingDir = null;
    final hadHost = _activeId != null;
    _activeId = h.id;

    _spectral.spectrum = _spectrumOf(h);
    _remote.setHost(h);
    if (hadHost) {
      _s.haptics.medium();
      _remote.hello();
      _remote.action('→ ${h.name}');
      if (!_reduce) {
        _spectral.sweep(dir);
        _shove.velocity += -dir * 520;
        _shove.target = 0;
        _wake();
      }
    }
    _s.control.connect(h);
    if (mounted) setState(() => _pillDir = dir);
  }

  void _onDiscovered() {
    for (final d in _background.hosts) {
      final paired = _s.hosts.byId(d.id);
      if (paired == null) continue;
      if (paired.address != d.address ||
          paired.port != d.port ||
          paired.os != d.os) {
        _s.hosts.updateEndpoint(d.id, address: d.address, port: d.port, os: d.os);
      }
    }
  }

  /// Three-finger swipe or remote-card chevrons: +1 next, -1 previous.
  void _switchBy(int dir) {
    final target = _s.hosts.neighbor(dir);
    if (target == null || target.id == _activeId) {
      _s.haptics.light();
      _showToast('Only one computer paired');
      if (!_reduce) {
        _shove.velocity += -dir * 260;
        _shove.target = 0;
        _wake();
      }
      return;
    }
    _pendingDir = dir;
    _s.hosts.setActive(target.id);
  }

  // ---------------------------------------------------------------- modes

  void _setMode(int i) {
    if (i == _mode) return;
    _s.haptics.light();
    if (_mode == 2 || i == 2) FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _enterDir = i > _mode ? 1 : -1;
      _mode = i;
    });
    if (_reduce) {
      _enter.snap(1);
    } else {
      _enter.snap(0);
      _enter.target = 1;
      _wake();
    }
  }

  // -------------------------------------------------------------- frames

  void _wake() {
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
    _shove.step(dt);
    _enter.step(dt);
    setState(() {});
    if (_shove.settled && _enter.settled) _ticker.stop();
  }

  // ----------------------------------------------------------- navigation

  void _openSwitcher() {
    _s.haptics.light();
    showHostSwitcher(context);
  }

  void _openDiscovery() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => const DiscoveryScreen(canClose: true),
      ),
    );
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
    );
  }

  void _showToast(String message) {
    _toastTimer?.cancel();
    setState(() => _toast = message);
    _toastTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  // ---------------------------------------------------------------- build

  Widget _view(PairedHost host) {
    switch (_mode) {
      case 1:
        return AirView(key: const ValueKey<String>('air'));
      case 2:
        return KeysView(key: const ValueKey<String>('keys'));
      case 3:
        return MediaView(key: const ValueKey<String>('media'));
      default:
        final hosts = _s.hosts;
        return Transform.translate(
          offset: Offset(_shove.value, 0),
          child: TrackpadView(
            key: const ValueKey<String>('trackpad'),
            host: host,
            hostIndex: hosts.activeIndex < 0 ? 0 : hosts.activeIndex,
            hostCount: hosts.length,
            spectral: _spectral,
            model: _remote,
            onSwitchHost: _switchBy,
          ),
        );
    }
  }

  Widget _entering(Widget child) {
    final q = _enter.value;
    if ((q - 1).abs() < 0.001) return child;
    return Opacity(
      opacity: (q * 1.3).clamp(0.0, 1.0),
      child: Transform.translate(
        offset: Offset(_enterDir * 26 * (1 - q), 0),
        child: Transform.scale(scale: 0.985 + 0.015 * q, child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    return ListenableBuilder(
      listenable: _s.hosts,
      builder: (context, _) {
        final host = _s.hosts.active;
        final spec = _spectrumOf(host);
        return Scaffold(
          backgroundColor: P.bg,
          resizeToAvoidBottomInset: _mode == 2,
          body: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Padding(
                padding: EdgeInsets.only(top: pad.top),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _topBar(host),
                    Expanded(
                      child: host == null
                          ? _empty()
                          : _entering(KeyedSubtree(
                              key: ValueKey<String>('mode-$_mode'),
                              child: _view(host),
                            )),
                    ),
                    Padding(
                      padding: EdgeInsets.fromLTRB(14, 10, 14, pad.bottom + 12),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 440),
                          child: ModeDock(
                            index: _mode,
                            onChanged: _setMode,
                            spectrum: spec,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              _toastLayer(pad),
            ],
          ),
        );
      },
    );
  }

  Widget _topBar(PairedHost? host) {
    return SizedBox(
      height: 54,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: <Widget>[
            _RoundGlassButton(
              icon: Icons.radar_rounded,
              label: 'Find computers',
              onTap: _openDiscovery,
            ),
            Expanded(
              child: Center(
                child: ListenableBuilder(
                  listenable: Listenable.merge(<Listenable>[_s.control, _remote]),
                  builder: (context, _) => HostPill(
                    host: host,
                    state: _s.control.state,
                    latencyMs: _s.control.latencyMs,
                    direction: _pillDir,
                    activity: _remote.activity,
                    onTap: host == null ? _openDiscovery : _openSwitcher,
                  ),
                ),
              ),
            ),
            _RoundGlassButton(
              icon: Icons.tune_rounded,
              label: 'Settings',
              onTap: _openSettings,
            ),
          ],
        ),
      ),
    );
  }

  Widget _empty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              'NO COMPUTER',
              style: PT.mono(9).copyWith(color: P.text3),
            ),
            const SizedBox(height: 10),
            Text(
              'Pair a Mac or PC to start',
              textAlign: TextAlign.center,
              style: PT.display(22).copyWith(
                fontWeight: FontWeight.w600,
                letterSpacing: -0.5,
                color: P.text,
              ),
            ),
            const SizedBox(height: 20),
            GestureDetector(
              onTap: _openDiscovery,
              child: PrismGlass(
                radius: 999,
                strong: true,
                glow: 0.6,
                spectrum: _spectrumOf(null),
                padding: const EdgeInsets.symmetric(horizontal: 22),
                child: SizedBox(
                  height: 44,
                  child: Center(
                    child: Text(
                      'Find computers',
                      style: PT.display(15).copyWith(
                        fontWeight: FontWeight.w600,
                        color: P.text,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _toastLayer(EdgeInsets pad) {
    final on = _toast != null;
    return Positioned(
      left: 40,
      right: 40,
      bottom: pad.bottom + 96,
      child: IgnorePointer(
        child: Center(
          child: AnimatedOpacity(
            opacity: on ? 1 : 0,
            duration: const Duration(milliseconds: 220),
            child: AnimatedSlide(
              offset: on ? Offset.zero : const Offset(0, 0.3),
              duration: const Duration(milliseconds: 420),
              curve: Curves.easeOutBack,
              child: PrismGlass(
                radius: 999,
                strong: true,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Icon(Icons.laptop_mac_rounded, size: 15, color: P.text2),
                    const SizedBox(width: 8),
                    Text(
                      _toast ?? '',
                      style: PT.display(13).copyWith(
                        fontWeight: FontWeight.w500,
                        color: P.text,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Prototype `.rbtn.glass`: a 38 pt round glass button.
class _RoundGlassButton extends StatefulWidget {
  const _RoundGlassButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  State<_RoundGlassButton> createState() => _RoundGlassButtonState();
}

class _RoundGlassButtonState extends State<_RoundGlassButton> {
  bool _down = false;

  void _set(bool v) {
    if (v != _down) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.label,
      child: GestureDetector(
        onTapDown: (_) => _set(true),
        onTapUp: (_) => _set(false),
        onTapCancel: () => _set(false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _down ? 0.92 : 1,
          duration: Duration(milliseconds: _down ? 120 : 380),
          curve: _down ? Curves.easeOut : Curves.easeOutBack,
          child: SizedBox(
            width: 40,
            height: 40,
            child: PrismGlass(
              radius: 20,
              child: Center(
                child: Icon(
                  widget.icon,
                  size: 19,
                  color: _down ? P.text : P.text2,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
