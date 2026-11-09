import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../net/hosts.dart';
import '../../net/protocol.dart';

/// [c] with its opacity set to [opacity] (0..1). Avoids the deprecated
/// `withOpacity` on newer Flutter while compiling on 3.22.
Color alpha(Color c, double opacity) =>
    c.withAlpha((opacity.clamp(0.0, 1.0) * 255).round());

/// `color.fade(0.4)`: same as [alpha], as an extension for chained use.
extension PrismColorFade on Color {
  Color fade(double opacity) => alpha(this, opacity);
}

/// Prism colour tokens (dark, the hero theme). Mirrors the prototype's :root.
class P {
  P._();

  static const Color bg = Color(0xFF010102);
  static const Color stage = Color(0xFF000000);
  static const Color pad = Color(0xFF030304);
  static const Color glass = Color(0x8016161A);
  static const Color glassStrong = Color(0xC70C0C0F);
  static const Color sheen = Color(0x0EFFFFFF);
  static const Color spec = Color(0x29FFFFFF);
  static const Color wellTop = Color(0x1CFFFFFF);
  static const Color wellBot = Color(0x09FFFFFF);
  static const Color hair = Color(0x16FFFFFF);
  static const Color hair2 = Color(0x26FFFFFF);
  static const Color text = Color(0xFFF4F4F6);
  static const Color text2 = Color(0x94F4F4F6);
  static const Color text3 = Color(0x57F4F4F6);
  static const Color text4 = Color(0x29F4F4F6);
  static const Color knob = Color(0xFFF4F4F6);
  static const Color scrim = Color(0x8C000000);
  static const Color shadow = Color(0xB8000000);
  static const Color ok = Color(0xFF3BE8A0);
  static const Color warn = Color(0xFFFFB547);
  static const Color bad = Color(0xFFFF4D6A);

  /// Mac hosts: cobalt, violet, magenta, cyan.
  static const List<Color> spectrumMac = <Color>[
    Color(0xFF2E5CFF),
    Color(0xFF9646FF),
    Color(0xFFFF3496),
    Color(0xFF26C8FF),
  ];

  /// Windows hosts: green, lime, orange, pink (prototype "desk").
  static const List<Color> spectrumWin = <Color>[
    Color(0xFF1CDC80),
    Color(0xFFBAFA3C),
    Color(0xFFFF8024),
    Color(0xFFFF4288),
  ];

  /// Extra spectra (prototype "air" and "office" hosts).
  static const List<Color> spectrumEmber = <Color>[
    Color(0xFFFF8830),
    Color(0xFFFF3A8C),
    Color(0xFF8254FF),
    Color(0xFF3C6EFF),
  ];
  static const List<Color> spectrumTide = <Color>[
    Color(0xFF26CEFF),
    Color(0xFF1CDC80),
    Color(0xFF4068FF),
    Color(0xFFFFB238),
  ];

  /// Seven prism bands used by the computer-switch sweep.
  static const List<Color> prismBands = <Color>[
    Color(0xFFFF3B4E),
    Color(0xFFFF8A2B),
    Color(0xFFFFE14A),
    Color(0xFF3BE8A0),
    Color(0xFF26C8FF),
    Color(0xFF2E5CFF),
    Color(0xFF9646FF),
  ];

  /// 'mac' / 'macos' gives the Mac spectrum, anything else the Windows one.
  static List<Color> spectrumFor(String os) =>
      os.toLowerCase().startsWith('mac') ? spectrumMac : spectrumWin;

  static List<Color> spectrumForOs(HostOs os) =>
      os == HostOs.mac ? spectrumMac : spectrumWin;

  /// Spectrum of a paired host (null: Mac spectrum, the brand default).
  static List<Color> spectrumForHost(PairedHost? host) =>
      host == null ? spectrumMac : spectrumForOs(host.os);

  /// s1 to s2 to s3 gradient used by switch and slider fills.
  static LinearGradient fill(List<Color> s) =>
      LinearGradient(colors: <Color>[s[0], s[1], s[2]]);
}

/// Light-theme counterparts (prototype [data-theme="light"]).
class PLight {
  PLight._();

  static const Color bg = Color(0xFFF2F2F4);
  static const Color glass = Color(0x8CFFFFFF);
  static const Color glassStrong = Color(0xD1FAFAFC);
  static const Color hair = Color(0x13000000);
  static const Color hair2 = Color(0x21000000);
  static const Color text = Color(0xFF0B0B0D);
  static const Color text2 = Color(0x8F0B0B0D);
  static const Color text3 = Color(0x610B0B0D);
}

/// Prism text styles: Instrument Sans for UI, Martian Mono for tiny caps.
class PT {
  PT._();

  static TextStyle _sans(TextStyle base) {
    try {
      return GoogleFonts.getFont('Instrument Sans', textStyle: base);
    } catch (_) {
      return base.copyWith(fontFamily: 'Instrument Sans');
    }
  }

  static TextStyle _mono(TextStyle base) {
    try {
      return GoogleFonts.getFont('Martian Mono', textStyle: base);
    } catch (_) {
      return base.copyWith(
        fontFamily: 'Martian Mono',
        fontFamilyFallback: const <String>['Menlo', 'Roboto Mono', 'monospace'],
      );
    }
  }

  /// Big titles: 700 weight with tight tracking, like `.title`.
  static TextStyle display(double size) => _sans(TextStyle(
        fontSize: size,
        fontWeight: FontWeight.w700,
        height: 0.98,
        letterSpacing: -0.035 * size,
        color: P.text,
      ));

  /// Section and sheet titles.
  static TextStyle get title => _sans(const TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        height: 1.1,
        letterSpacing: -0.5,
        color: P.text,
      ));

  /// Body copy (15px like the prototype root).
  static TextStyle get body => _sans(const TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w400,
        height: 1.35,
        letterSpacing: -0.1,
        color: P.text,
      ));

  /// Buttons, pill names, row labels.
  static TextStyle get label => _sans(const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        height: 1.2,
        letterSpacing: -0.14,
        color: P.text,
      ));

  /// Martian Mono tiny caps (`.cap`). Pass UPPERCASE text.
  static TextStyle mono(double size) => _mono(TextStyle(
        fontSize: size,
        fontWeight: FontWeight.w400,
        height: 1.4,
        letterSpacing: 0.07 * size,
        color: P.text3,
        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      ));

  /// The prototype's default `.cap` (8.5px, text3).
  static TextStyle get cap => mono(8.5);
}
