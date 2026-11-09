// Material theme that forwards to the Prism design system.
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/services.dart';

import 'prism/prism.dart';

export 'prism/prism.dart';

class PrismTheme {
  PrismTheme._();

  static ThemeData dark() => _build(
        brightness: Brightness.dark,
        bg: P.bg,
        text: P.text,
        text2: P.text2,
        surface: P.glassStrong,
        hair: P.hair,
      );

  static ThemeData light() => _build(
        brightness: Brightness.light,
        bg: PLight.bg,
        text: PLight.text,
        text2: PLight.text2,
        surface: PLight.glassStrong,
        hair: PLight.hair,
      );

  static ThemeData _build({
    required Brightness brightness,
    required Color bg,
    required Color text,
    required Color text2,
    required Color surface,
    required Color hair,
  }) {
    final scheme = ColorScheme.fromSeed(
      seedColor: P.spectrumMac[0],
      brightness: brightness,
    ).copyWith(
      surface: bg,
      onSurface: text,
      primary: P.spectrumMac[0],
      secondary: P.spectrumMac[2],
      error: P.bad,
      outline: hair,
    );
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      canvasColor: bg,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      dividerColor: hair,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: CupertinoPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
    );
    final body = PT.body.copyWith(color: text);
    return base.copyWith(
      textTheme: base.textTheme.copyWith(
        displayLarge: PT.display(40).copyWith(color: text),
        titleLarge: PT.title.copyWith(color: text),
        bodyLarge: body,
        bodyMedium: body,
        bodySmall: body.copyWith(fontSize: 13, color: text2),
        labelLarge: PT.label.copyWith(color: text),
        labelSmall: PT.cap.copyWith(color: text2),
      ),
      iconTheme: IconThemeData(color: text, size: 20),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.transparent,
        modalBackgroundColor: Colors.transparent,
        elevation: 0,
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: P.spectrumMac[3],
        selectionColor: alpha(P.spectrumMac[0], 0.35),
        selectionHandleColor: P.spectrumMac[3],
      ),
    );
  }

  static SystemUiOverlayStyle overlayFor(Brightness b) => SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
        statusBarIconBrightness:
            b == Brightness.dark ? Brightness.light : Brightness.dark,
        statusBarBrightness: b,
        systemNavigationBarIconBrightness:
            b == Brightness.dark ? Brightness.light : Brightness.dark,
      );
}
