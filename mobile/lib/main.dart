import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'state/scope.dart';
import 'ui/screens/control_screen.dart';
import 'ui/screens/discovery_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
  ]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  final prefs = await SharedPreferences.getInstance();
  final services = await AirWandServices.create(prefs);
  Haptic.bind(services.settings);
  runApp(AirWandApp(services: services));
}

class AirWandApp extends StatelessWidget {
  const AirWandApp({super.key, required this.services});

  final AirWandServices services;

  @override
  Widget build(BuildContext context) {
    return AirWandScope(
      services: services,
      child: ListenableBuilder(
        listenable: services.settings,
        builder: (context, _) => MaterialApp(
          title: 'AirWand',
          debugShowCheckedModeBanner: false,
          theme: PrismTheme.light(),
          darkTheme: PrismTheme.dark(),
          // Dark is the hero theme (AppSettings defaults to ThemeMode.dark).
          themeMode: services.settings.themeMode,
          builder: (context, child) {
            final b = Theme.of(context).brightness;
            return AnnotatedRegion<SystemUiOverlayStyle>(
              value: PrismTheme.overlayFor(b),
              child: ColoredBox(
                color: b == Brightness.dark ? P.bg : PLight.bg,
                child: child ?? const SizedBox.shrink(),
              ),
            );
          },
          home: const RootGate(),
        ),
      ),
    );
  }
}

/// No paired hosts: Discovery. Otherwise: Control with the active host.
class RootGate extends StatelessWidget {
  const RootGate({super.key});

  @override
  Widget build(BuildContext context) {
    final hosts = AirWandScope.of(context).hosts;
    return ListenableBuilder(
      listenable: hosts,
      builder: (context, _) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 620),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        child: hosts.isEmpty
            ? const DiscoveryScreen(key: ValueKey<String>('discovery'))
            : const ControlScreen(key: ValueKey<String>('control')),
      ),
    );
  }
}
