import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:google_fonts/google_fonts.dart';

import 'page_transitions.dart';

/// Raw palette. Prefer reading [QuizzleTokens] off the theme inside widgets —
/// these constants exist so the tokens (and tests) have a single source.
///
/// The four structural colours are supplied and must not be altered. The accent
/// extensions are contrast-verified (ratios in the comments, asserted in
/// `test/design_system_test.dart`).
class QuizzleColors {
  const QuizzleColors._();

  // Structural (supplied — do not alter).
  static const Color navy = Color(0xFF26374D);
  static const Color slate = Color(0xFF536D82);
  static const Color dustyBlue = Color(0xFF9DB3BF);
  static const Color iceMist = Color(0xFFDDE6ED);

  // Derived neutrals.
  static const Color paper = Color(0xFFFFFFFF);
  static const Color navyDeep = Color(0xFF1A2735);
  static const Color navySurface = Color(0xFF2F4459);

  // Answer tiles — white bold text on all four, identical in both themes.
  static const Color answerRed = Color(0xFFB3262A); // 6.51:1  triangle
  static const Color answerBlue = Color(0xFF1B4F9C); // 7.94:1  diamond
  static const Color answerAmber = Color(0xFF8A6100); // 5.54:1  circle
  static const Color answerGreen = Color(0xFF1B6B4A); // 6.46:1  square

  /// Answer fills in tile order: triangle, diamond, circle, square.
  static const List<Color> answerFills = [
    answerRed,
    answerBlue,
    answerAmber,
    answerGreen,
  ];

  // Semantic fills (verified against the ice ground; white text on all three).
  static const Color correct = Color(0xFF137445); // 4.60:1 on ice
  static const Color wrong = Color(0xFFA81F23); // 5.76:1 on ice
  static const Color warn = Color(0xFF7A5500); // 5.31:1 on ice

  // Dark-theme *text* variants of the semantics. The fills above are far too
  // dark to read as type on --navy-deep (correct is only 2.58:1 there), so each
  // is lifted 50% toward --ice-mist. Same hue family, no new palette.
  static const Color correctInkDark = Color(0xFF78AD99); // 5.88:1 on navy-deep
  static const Color wrongInkDark = Color(0xFFC38388); // 4.95:1 on navy-deep
  static const Color warnInkDark = Color(0xFFAC9E77); // 5.66:1 on navy-deep
}

/// Back-compat shim for `lib/features/live_session/option_grid.dart`, which
/// reads `OptionPalette.fill` / `.shapes`. New code should use
/// [QuizzleTokens.answerFills] and the `AnswerTile` widget, which paints the
/// four Bauhaus shapes as geometry rather than icon-font glyphs.
@Deprecated('Use AnswerTile / QuizzleTokens.answerFills instead.')
class OptionPalette {
  const OptionPalette._();

  static const List<Color> fill = QuizzleColors.answerFills;

  static const List<IconData> shapes = [
    Icons.change_history, // triangle
    Icons.diamond_outlined, // diamond
    Icons.circle_outlined, // circle
    Icons.square_outlined, // square
  ];
}

/// Every design-system value a screen is allowed to reach for, hung off the
/// theme so nothing has to import colour constants:
///
/// ```dart
/// final t = Theme.of(context).extension<QuizzleTokens>()!;
/// // or, tolerant of a bare ThemeData:
/// final t = QuizzleTokens.of(context);
/// ```
@immutable
class QuizzleTokens extends ThemeExtension<QuizzleTokens> {
  const QuizzleTokens({
    required this.ground,
    required this.surface,
    required this.surfaceMuted,
    required this.ink,
    required this.inkSecondary,
    required this.inkMuted,
    required this.line,
    required this.lineMuted,
    required this.inverseGround,
    required this.inverseInk,
    required this.focusRing,
    required this.correct,
    required this.wrong,
    required this.warn,
    required this.correctInk,
    required this.wrongInk,
    required this.warnInk,
    this.answerFills = QuizzleColors.answerFills,
    this.onAnswer = QuizzleColors.paper,
    this.borderWidth = 2.0,
    this.focusRingWidth = 2.0,
    this.focusRingOffset = 2.0,
    this.blockShadowOffset = const Offset(4, 4),
    this.pressScale = 0.97,
    this.gutterCompact = 16.0,
    this.gutterExpanded = 24.0,
    this.minTouchTarget = 48.0,
    this.proseMaxWidth = 640.0,
  });

  /// Page ground: `--ice-mist` / `--navy-deep`.
  final Color ground;

  /// Raised plane a card sits on: `--paper` / `--navy-surf`.
  final Color surface;

  /// A second, quieter plane (list rows, inset wells).
  final Color surfaceMuted;

  /// Primary ink. Safe on [ground] and [surface] at any size (>= 9.5:1).
  final Color ink;

  /// Secondary ink. Safe at **any size on [surface]**; on [ground] it is
  /// large-text-only in the light theme (slate on ice is 4.29:1). When in
  /// doubt on the ground, use [ink].
  final Color inkSecondary;

  /// Muted fill — dividers, disabled chrome, decorative geometry.
  /// **Never** use as text on [ground] (dusty-blue on ice fails).
  final Color inkMuted;

  /// The 2px border that carries all elevation in this system.
  final Color line;

  /// Hairline dividers and disabled borders.
  final Color lineMuted;

  /// Inverted plane (navy block in light, ice block in dark).
  final Color inverseGround;

  /// Ink for [inverseGround].
  final Color inverseInk;

  /// Focus outline colour — 2px, offset 2px, on everything focusable.
  final Color focusRing;

  /// Semantic fills. White text on all three in both themes.
  final Color correct;
  final Color wrong;
  final Color warn;

  /// Semantic *text/icon* colours for the current theme's ground.
  final Color correctInk;
  final Color wrongInk;
  final Color warnInk;

  /// Answer tile fills, in shape order (triangle, diamond, circle, square).
  final List<Color> answerFills;

  /// Ink used on top of [answerFills] and the semantic fills.
  final Color onAnswer;

  final double borderWidth;
  final double focusRingWidth;
  final double focusRingOffset;

  /// Block-print offset used for the locked-in answer tile.
  final Offset blockShadowOffset;

  /// Scale a pressed control snaps to at `durInstant`.
  final double pressScale;

  final double gutterCompact;
  final double gutterExpanded;

  /// Minimum touch target on every interactive element.
  final double minTouchTarget;

  /// ~68ch reading measure for prose.
  final double proseMaxWidth;

  /// Hard 90° corners are the default everywhere.
  static const BorderRadius radius = BorderRadius.zero;

  /// The only permitted pill: chips, badges and the join-code field.
  static const BorderRadius pillRadius = BorderRadius.all(Radius.circular(999));

  /// The 2px plane border.
  Border get border => Border.all(color: line, width: borderWidth);

  /// A flat Bauhaus plane: solid fill, 2px border, hard corners, no blur.
  BoxDecoration plane({Color? fill, Color? borderColor, double? width}) =>
      BoxDecoration(
        color: fill ?? surface,
        border: Border.all(
          color: borderColor ?? line,
          width: width ?? borderWidth,
        ),
      );

  /// Gutter for the current form factor.
  double gutterFor(double screenWidth) =>
      screenWidth < 600 ? gutterCompact : gutterExpanded;

  static QuizzleTokens of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<QuizzleTokens>() ??
        (theme.brightness == Brightness.dark ? dark : light);
  }

  static const QuizzleTokens light = QuizzleTokens(
    ground: QuizzleColors.iceMist,
    surface: QuizzleColors.paper,
    surfaceMuted: QuizzleColors.iceMist,
    ink: QuizzleColors.navy,
    inkSecondary: QuizzleColors.slate,
    inkMuted: QuizzleColors.dustyBlue,
    line: QuizzleColors.navy,
    lineMuted: QuizzleColors.dustyBlue,
    inverseGround: QuizzleColors.navy,
    inverseInk: QuizzleColors.iceMist,
    focusRing: QuizzleColors.navy,
    correct: QuizzleColors.correct,
    wrong: QuizzleColors.wrong,
    warn: QuizzleColors.warn,
    correctInk: QuizzleColors.correct,
    wrongInk: QuizzleColors.wrong,
    warnInk: QuizzleColors.warn,
  );

  static const QuizzleTokens dark = QuizzleTokens(
    ground: QuizzleColors.navyDeep,
    surface: QuizzleColors.navySurface,
    surfaceMuted: QuizzleColors.navy,
    ink: QuizzleColors.iceMist,
    inkSecondary: QuizzleColors.dustyBlue,
    inkMuted: QuizzleColors.slate,
    line: QuizzleColors.dustyBlue,
    lineMuted: QuizzleColors.slate,
    inverseGround: QuizzleColors.iceMist,
    inverseInk: QuizzleColors.navy,
    focusRing: QuizzleColors.iceMist,
    correct: QuizzleColors.correct,
    wrong: QuizzleColors.wrong,
    warn: QuizzleColors.warn,
    correctInk: QuizzleColors.correctInkDark,
    wrongInk: QuizzleColors.wrongInkDark,
    warnInk: QuizzleColors.warnInkDark,
  );

  @override
  QuizzleTokens copyWith({
    Color? ground,
    Color? surface,
    Color? surfaceMuted,
    Color? ink,
    Color? inkSecondary,
    Color? inkMuted,
    Color? line,
    Color? lineMuted,
    Color? inverseGround,
    Color? inverseInk,
    Color? focusRing,
    Color? correct,
    Color? wrong,
    Color? warn,
    Color? correctInk,
    Color? wrongInk,
    Color? warnInk,
    List<Color>? answerFills,
    Color? onAnswer,
    double? borderWidth,
    double? focusRingWidth,
    double? focusRingOffset,
    Offset? blockShadowOffset,
    double? pressScale,
    double? gutterCompact,
    double? gutterExpanded,
    double? minTouchTarget,
    double? proseMaxWidth,
  }) {
    return QuizzleTokens(
      ground: ground ?? this.ground,
      surface: surface ?? this.surface,
      surfaceMuted: surfaceMuted ?? this.surfaceMuted,
      ink: ink ?? this.ink,
      inkSecondary: inkSecondary ?? this.inkSecondary,
      inkMuted: inkMuted ?? this.inkMuted,
      line: line ?? this.line,
      lineMuted: lineMuted ?? this.lineMuted,
      inverseGround: inverseGround ?? this.inverseGround,
      inverseInk: inverseInk ?? this.inverseInk,
      focusRing: focusRing ?? this.focusRing,
      correct: correct ?? this.correct,
      wrong: wrong ?? this.wrong,
      warn: warn ?? this.warn,
      correctInk: correctInk ?? this.correctInk,
      wrongInk: wrongInk ?? this.wrongInk,
      warnInk: warnInk ?? this.warnInk,
      answerFills: answerFills ?? this.answerFills,
      onAnswer: onAnswer ?? this.onAnswer,
      borderWidth: borderWidth ?? this.borderWidth,
      focusRingWidth: focusRingWidth ?? this.focusRingWidth,
      focusRingOffset: focusRingOffset ?? this.focusRingOffset,
      blockShadowOffset: blockShadowOffset ?? this.blockShadowOffset,
      pressScale: pressScale ?? this.pressScale,
      gutterCompact: gutterCompact ?? this.gutterCompact,
      gutterExpanded: gutterExpanded ?? this.gutterExpanded,
      minTouchTarget: minTouchTarget ?? this.minTouchTarget,
      proseMaxWidth: proseMaxWidth ?? this.proseMaxWidth,
    );
  }

  @override
  QuizzleTokens lerp(ThemeExtension<QuizzleTokens>? other, double t) {
    if (other is! QuizzleTokens) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return QuizzleTokens(
      ground: c(ground, other.ground),
      surface: c(surface, other.surface),
      surfaceMuted: c(surfaceMuted, other.surfaceMuted),
      ink: c(ink, other.ink),
      inkSecondary: c(inkSecondary, other.inkSecondary),
      inkMuted: c(inkMuted, other.inkMuted),
      line: c(line, other.line),
      lineMuted: c(lineMuted, other.lineMuted),
      inverseGround: c(inverseGround, other.inverseGround),
      inverseInk: c(inverseInk, other.inverseInk),
      focusRing: c(focusRing, other.focusRing),
      correct: c(correct, other.correct),
      wrong: c(wrong, other.wrong),
      warn: c(warn, other.warn),
      correctInk: c(correctInk, other.correctInk),
      wrongInk: c(wrongInk, other.wrongInk),
      warnInk: c(warnInk, other.warnInk),
      answerFills: [
        for (var i = 0; i < answerFills.length; i++)
          c(
            answerFills[i],
            i < other.answerFills.length ? other.answerFills[i] : answerFills[i],
          ),
      ],
      onAnswer: c(onAnswer, other.onAnswer),
      borderWidth: lerpDouble(borderWidth, other.borderWidth, t),
      focusRingWidth: lerpDouble(focusRingWidth, other.focusRingWidth, t),
      focusRingOffset: lerpDouble(focusRingOffset, other.focusRingOffset, t),
      blockShadowOffset:
          Offset.lerp(blockShadowOffset, other.blockShadowOffset, t)!,
      pressScale: lerpDouble(pressScale, other.pressScale, t),
      gutterCompact: lerpDouble(gutterCompact, other.gutterCompact, t),
      gutterExpanded: lerpDouble(gutterExpanded, other.gutterExpanded, t),
      minTouchTarget: lerpDouble(minTouchTarget, other.minTouchTarget, t),
      proseMaxWidth: lerpDouble(proseMaxWidth, other.proseMaxWidth, t),
    );
  }

  static double lerpDouble(double a, double b, double t) => a + (b - a) * t;
}

/// Type: two faces, three roles, one scale — 56 / 40 / 28 / 22 / 17 / 15 / 13 / 11.
///
/// Fonts are bundled under `assets/fonts/` and declared in `pubspec.yaml`, so
/// resolution is synchronous and offline. Nothing here calls the network.
class QuizzleType {
  const QuizzleType._();

  /// Archivo Black — screen titles, join code, scores, podium.
  static const String display = 'Archivo Black';

  /// Archivo w400/500/600/700 — body, labels, UI.
  static const String body = 'Archivo';

  static const List<String> fallback = <String>[
    'Archivo',
    'Helvetica Neue',
    'Helvetica',
    'Arial',
  ];

  static const List<FontFeature> tabular = <FontFeature>[
    FontFeature.tabularFigures(),
  ];

  static TextStyle _style({
    required double size,
    required FontWeight weight,
    required double height,
    required Color color,
    bool isDisplay = false,
    double? letterSpacing,
    bool tabularFigures = false,
  }) {
    return TextStyle(
      fontFamily: isDisplay ? display : body,
      fontFamilyFallback: fallback,
      fontSize: size,
      fontWeight: weight,
      height: height,
      letterSpacing: letterSpacing,
      color: color,
      fontFeatures: tabularFigures ? tabular : null,
      // Type is structure: never let the platform nudge the baseline.
      leadingDistribution: TextLeadingDistribution.even,
    );
  }

  /// Stencilled uppercase label — eyebrows, stat labels, metadata.
  static TextStyle eyebrow(Color color) => _style(
    size: 11,
    weight: FontWeight.w600,
    height: 1.2,
    color: color,
    letterSpacing: 11 * 0.12,
  );

  /// The full scale. [ink] is the primary text colour for the theme; every
  /// slot lands on it so that *anything* rendered with a default style is
  /// contrast-safe on both the ground and a surface.
  static TextTheme textTheme(Color ink) {
    return TextTheme(
      // 56 — the join code, the final score.
      displayLarge: _style(
        size: 56,
        weight: FontWeight.w400,
        height: 1.0,
        color: ink,
        isDisplay: true,
        letterSpacing: 56 * -0.02,
        tabularFigures: true,
      ),
      // 40 — screen hero titles.
      displayMedium: _style(
        size: 40,
        weight: FontWeight.w400,
        height: 1.0,
        color: ink,
        isDisplay: true,
        letterSpacing: 40 * -0.02,
        tabularFigures: true,
      ),
      // 28 — section heroes, question text on the projector.
      displaySmall: _style(
        size: 28,
        weight: FontWeight.w400,
        height: 1.05,
        color: ink,
        isDisplay: true,
        letterSpacing: 28 * -0.02,
      ),
      headlineLarge: _style(
        size: 28,
        weight: FontWeight.w400,
        height: 1.05,
        color: ink,
        isDisplay: true,
        letterSpacing: 28 * -0.02,
      ),
      // 22 — screen titles / card headings.
      headlineMedium: _style(
        size: 22,
        weight: FontWeight.w700,
        height: 1.15,
        color: ink,
        letterSpacing: -0.2,
      ),
      headlineSmall: _style(
        size: 22,
        weight: FontWeight.w700,
        height: 1.15,
        color: ink,
        letterSpacing: -0.2,
      ),
      titleLarge: _style(
        size: 22,
        weight: FontWeight.w700,
        height: 1.2,
        color: ink,
        letterSpacing: -0.2,
      ),
      // 17 — prominent body / list titles.
      titleMedium: _style(
        size: 17,
        weight: FontWeight.w600,
        height: 1.3,
        color: ink,
      ),
      // 15 — dense titles.
      titleSmall: _style(
        size: 15,
        weight: FontWeight.w600,
        height: 1.3,
        color: ink,
      ),
      bodyLarge: _style(
        size: 17,
        weight: FontWeight.w400,
        height: 1.45,
        color: ink,
      ),
      bodyMedium: _style(
        size: 15,
        weight: FontWeight.w400,
        height: 1.45,
        color: ink,
      ),
      bodySmall: _style(
        size: 13,
        weight: FontWeight.w400,
        height: 1.4,
        color: ink,
      ),
      labelLarge: _style(
        size: 15,
        weight: FontWeight.w600,
        height: 1.2,
        color: ink,
        letterSpacing: 0.2,
      ),
      labelMedium: _style(
        size: 13,
        weight: FontWeight.w600,
        height: 1.2,
        color: ink,
        letterSpacing: 13 * 0.04,
      ),
      // 11 — the stencilled label.
      labelSmall: _style(
        size: 11,
        weight: FontWeight.w600,
        height: 1.2,
        color: ink,
        letterSpacing: 11 * 0.12,
      ),
    );
  }
}

/// Light and dark `ThemeData` built from the tokens above.
class AppTheme {
  const AppTheme._();

  static bool _fontsPinned = false;

  /// Belt and braces: even if some other code path calls `GoogleFonts.*`, it
  /// must never hit the network — the faces are in the bundle.
  static void ensureOfflineFonts() {
    if (_fontsPinned) return;
    _fontsPinned = true;
    GoogleFonts.config.allowRuntimeFetching = false;
  }

  static ThemeData get light => _build(Brightness.light);
  static ThemeData get dark => _build(Brightness.dark);

  static ColorScheme _scheme(Brightness brightness) {
    if (brightness == Brightness.light) {
      return const ColorScheme(
        brightness: Brightness.light,
        primary: QuizzleColors.navy,
        onPrimary: QuizzleColors.paper,
        primaryContainer: QuizzleColors.dustyBlue,
        onPrimaryContainer: QuizzleColors.navy,
        secondary: QuizzleColors.slate,
        onSecondary: QuizzleColors.paper,
        secondaryContainer: QuizzleColors.iceMist,
        onSecondaryContainer: QuizzleColors.navy,
        tertiary: QuizzleColors.warn,
        onTertiary: QuizzleColors.paper,
        tertiaryContainer: QuizzleColors.iceMist,
        onTertiaryContainer: QuizzleColors.navy,
        error: QuizzleColors.wrong,
        onError: QuizzleColors.paper,
        errorContainer: QuizzleColors.wrong,
        onErrorContainer: QuizzleColors.paper,
        surface: QuizzleColors.paper,
        onSurface: QuizzleColors.navy,
        surfaceDim: QuizzleColors.iceMist,
        surfaceBright: QuizzleColors.paper,
        surfaceContainerLowest: QuizzleColors.paper,
        surfaceContainerLow: QuizzleColors.paper,
        surfaceContainer: QuizzleColors.iceMist,
        surfaceContainerHigh: QuizzleColors.iceMist,
        surfaceContainerHighest: QuizzleColors.iceMist,
        onSurfaceVariant: QuizzleColors.slate,
        outline: QuizzleColors.navy,
        outlineVariant: QuizzleColors.dustyBlue,
        inverseSurface: QuizzleColors.navy,
        onInverseSurface: QuizzleColors.iceMist,
        inversePrimary: QuizzleColors.dustyBlue,
        shadow: QuizzleColors.navy,
        scrim: QuizzleColors.navy,
        surfaceTint: Color(0x00000000),
      );
    }
    return const ColorScheme(
      brightness: Brightness.dark,
      primary: QuizzleColors.iceMist,
      onPrimary: QuizzleColors.navy,
      primaryContainer: QuizzleColors.navy,
      onPrimaryContainer: QuizzleColors.iceMist,
      secondary: QuizzleColors.dustyBlue,
      onSecondary: QuizzleColors.navyDeep,
      secondaryContainer: QuizzleColors.navy,
      onSecondaryContainer: QuizzleColors.iceMist,
      tertiary: QuizzleColors.warnInkDark,
      onTertiary: QuizzleColors.navyDeep,
      tertiaryContainer: QuizzleColors.navy,
      onTertiaryContainer: QuizzleColors.iceMist,
      error: QuizzleColors.wrongInkDark,
      onError: QuizzleColors.navyDeep,
      errorContainer: QuizzleColors.wrong,
      onErrorContainer: QuizzleColors.paper,
      surface: QuizzleColors.navySurface,
      onSurface: QuizzleColors.iceMist,
      surfaceDim: QuizzleColors.navyDeep,
      surfaceBright: QuizzleColors.navySurface,
      surfaceContainerLowest: QuizzleColors.navyDeep,
      surfaceContainerLow: QuizzleColors.navyDeep,
      surfaceContainer: QuizzleColors.navy,
      surfaceContainerHigh: QuizzleColors.navySurface,
      surfaceContainerHighest: QuizzleColors.navySurface,
      onSurfaceVariant: QuizzleColors.dustyBlue,
      outline: QuizzleColors.dustyBlue,
      outlineVariant: QuizzleColors.slate,
      inverseSurface: QuizzleColors.iceMist,
      onInverseSurface: QuizzleColors.navy,
      inversePrimary: QuizzleColors.navy,
      shadow: Color(0xFF000000),
      scrim: Color(0xFF000000),
      surfaceTint: Color(0x00000000),
    );
  }

  static ThemeData _build(Brightness brightness) {
    ensureOfflineFonts();

    final bool isLight = brightness == Brightness.light;
    final QuizzleTokens t = isLight ? QuizzleTokens.light : QuizzleTokens.dark;
    final ColorScheme scheme = _scheme(brightness);
    final TextTheme text = QuizzleType.textTheme(t.ink);

    // Hard corners, 2px border. Used by every component theme below.
    RoundedRectangleBorder hard([Color? side, double width = 2]) =>
        RoundedRectangleBorder(
          borderRadius: QuizzleTokens.radius,
          side: side == null
              ? BorderSide.none
              : BorderSide(color: side, width: width),
        );

    OutlineInputBorder field(Color color, [double width = 2]) =>
        OutlineInputBorder(
          borderRadius: QuizzleTokens.radius,
          borderSide: BorderSide(color: color, width: width),
        );

    final ButtonStyle sharedButton = ButtonStyle(
      minimumSize: WidgetStatePropertyAll(Size(0, t.minTouchTarget)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      ),
      shape: WidgetStatePropertyAll(hard(t.line, t.borderWidth)),
      elevation: const WidgetStatePropertyAll(0),
      shadowColor: const WidgetStatePropertyAll(Color(0x00000000)),
      surfaceTintColor: const WidgetStatePropertyAll(Color(0x00000000)),
      textStyle: WidgetStatePropertyAll(text.labelLarge),
      // 2px ring at 2px offset — Material draws the overlay, the widgets in
      // shared_widgets/ draw a true offset ring.
      side: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return BorderSide(color: t.lineMuted, width: t.borderWidth);
        }
        return BorderSide(color: t.line, width: t.borderWidth);
      }),
      visualDensity: VisualDensity.standard,
      splashFactory: InkRipple.splashFactory,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      extensions: <ThemeExtension<dynamic>>[t],
      scaffoldBackgroundColor: t.ground,
      canvasColor: t.ground,
      dividerColor: t.lineMuted,
      splashColor: t.line.withValues(alpha: 0.10),
      highlightColor: t.line.withValues(alpha: 0.06),
      focusColor: t.focusRing.withValues(alpha: 0.16),
      hoverColor: t.line.withValues(alpha: 0.05),
      visualDensity: VisualDensity.standard,
      fontFamily: QuizzleType.body,
      fontFamilyFallback: QuizzleType.fallback,
      textTheme: text,
      primaryTextTheme: text,
      pageTransitionsTheme: quizzlePageTransitionsTheme,

      iconTheme: IconThemeData(color: t.ink, size: 22),
      primaryIconTheme: IconThemeData(color: t.ink, size: 22),

      appBarTheme: AppBarTheme(
        backgroundColor: t.ground,
        foregroundColor: t.ink,
        surfaceTintColor: const Color(0x00000000),
        shadowColor: const Color(0x00000000),
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: 16,
        // Elevation by line, not blur.
        shape: Border(bottom: BorderSide(color: t.line, width: t.borderWidth)),
        titleTextStyle: text.headlineMedium,
        toolbarTextStyle: text.bodyMedium,
        iconTheme: IconThemeData(color: t.ink, size: 22),
        actionsIconTheme: IconThemeData(color: t.ink, size: 22),
        systemOverlayStyle: isLight
            ? SystemUiOverlayStyle.dark
            : SystemUiOverlayStyle.light,
      ),

      cardTheme: CardThemeData(
        color: t.surface,
        surfaceTintColor: const Color(0x00000000),
        shadowColor: const Color(0x00000000),
        elevation: 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.none,
        shape: hard(t.line, t.borderWidth),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: sharedButton.copyWith(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) return t.inkMuted;
            return t.inverseGround;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) return t.ink;
            return t.inverseInk;
          }),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: sharedButton.copyWith(
          backgroundColor: WidgetStatePropertyAll(t.surface),
          foregroundColor: WidgetStatePropertyAll(t.ink),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: sharedButton.copyWith(
          backgroundColor: const WidgetStatePropertyAll(Color(0x00000000)),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) return t.inkMuted;
            return t.ink;
          }),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: sharedButton.copyWith(
          backgroundColor: const WidgetStatePropertyAll(Color(0x00000000)),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) return t.inkMuted;
            return t.ink;
          }),
          side: const WidgetStatePropertyAll(BorderSide.none),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          minimumSize: WidgetStatePropertyAll(
            Size(t.minTouchTarget, t.minTouchTarget),
          ),
          shape: WidgetStatePropertyAll(hard()),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) return t.inkMuted;
            return t.ink;
          }),
          overlayColor: WidgetStatePropertyAll(t.line.withValues(alpha: 0.10)),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: t.inverseGround,
        foregroundColor: t.inverseInk,
        elevation: 0,
        focusElevation: 0,
        hoverElevation: 0,
        highlightElevation: 0,
        shape: hard(t.line, t.borderWidth),
        extendedTextStyle: text.labelLarge,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(hard(t.line, t.borderWidth)),
          minimumSize: WidgetStatePropertyAll(Size(0, t.minTouchTarget)),
          textStyle: WidgetStatePropertyAll(text.labelLarge),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return t.inverseGround;
            return const Color(0x00000000);
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return t.inverseInk;
            return t.ink;
          }),
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: t.surface,
        isDense: false,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        border: field(t.line),
        enabledBorder: field(t.line),
        disabledBorder: field(t.lineMuted),
        focusedBorder: field(t.focusRing, 3),
        errorBorder: field(t.wrongInk),
        focusedErrorBorder: field(t.wrongInk, 3),
        labelStyle: text.bodyMedium?.copyWith(color: t.inkSecondary),
        floatingLabelStyle: text.labelMedium?.copyWith(color: t.ink),
        hintStyle: text.bodyMedium?.copyWith(color: t.inkSecondary),
        helperStyle: text.bodySmall?.copyWith(color: t.inkSecondary),
        errorStyle: text.bodySmall?.copyWith(color: t.wrongInk),
        prefixIconColor: t.inkSecondary,
        suffixIconColor: t.inkSecondary,
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: t.ink,
        selectionColor: t.inkMuted.withValues(alpha: 0.5),
        selectionHandleColor: t.ink,
      ),

      // Chips and badges are the only pills in the system.
      chipTheme: ChipThemeData(
        showCheckmark: false,
        backgroundColor: t.surface,
        selectedColor: t.inverseGround,
        disabledColor: t.surfaceMuted,
        side: BorderSide(color: t.line, width: t.borderWidth),
        shape: const StadiumBorder(),
        labelStyle: text.labelMedium,
        secondaryLabelStyle: text.labelMedium?.copyWith(color: t.inverseInk),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        elevation: 0,
        pressElevation: 0,
        surfaceTintColor: const Color(0x00000000),
      ),
      badgeTheme: BadgeThemeData(
        backgroundColor: t.wrong,
        textColor: QuizzleColors.paper,
        textStyle: text.labelSmall?.copyWith(color: QuizzleColors.paper),
      ),

      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: t.surface,
        surfaceTintColor: const Color(0x00000000),
        shadowColor: const Color(0x00000000),
        elevation: 0,
        height: 68,
        indicatorColor: t.inverseGround,
        indicatorShape: hard(),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? text.labelSmall?.copyWith(color: t.ink)
              : text.labelSmall?.copyWith(color: t.inkSecondary),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? IconThemeData(color: t.inverseInk, size: 22)
              : IconThemeData(color: t.ink, size: 22),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: t.surface,
        elevation: 0,
        indicatorColor: t.inverseGround,
        indicatorShape: hard(),
        useIndicator: true,
        selectedLabelTextStyle: text.labelSmall?.copyWith(color: t.ink),
        unselectedLabelTextStyle: text.labelSmall?.copyWith(
          color: t.inkSecondary,
        ),
        selectedIconTheme: IconThemeData(color: t.inverseInk, size: 22),
        unselectedIconTheme: IconThemeData(color: t.ink, size: 22),
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: t.surface,
        surfaceTintColor: const Color(0x00000000),
        elevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: QuizzleTokens.radius),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: t.ink,
        unselectedLabelColor: t.inkSecondary,
        labelStyle: text.labelLarge,
        unselectedLabelStyle: text.labelLarge,
        indicatorColor: t.ink,
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: t.lineMuted,
        overlayColor: WidgetStatePropertyAll(t.line.withValues(alpha: 0.08)),
      ),

      dividerTheme: DividerThemeData(
        color: t.lineMuted,
        thickness: 1,
        space: 1,
      ),
      listTileTheme: ListTileThemeData(
        shape: hard(),
        iconColor: t.ink,
        textColor: t.ink,
        titleTextStyle: text.titleMedium,
        subtitleTextStyle: text.bodySmall?.copyWith(color: t.inkSecondary),
        minVerticalPadding: 12,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: t.surface,
        surfaceTintColor: const Color(0x00000000),
        elevation: 0,
        shape: hard(t.line, t.borderWidth),
        titleTextStyle: text.headlineMedium,
        contentTextStyle: text.bodyMedium,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: t.surface,
        surfaceTintColor: const Color(0x00000000),
        elevation: 0,
        modalElevation: 0,
        shape: hard(t.line, t.borderWidth),
        showDragHandle: true,
        dragHandleColor: t.inkMuted,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: t.inverseGround,
        contentTextStyle: text.bodyMedium?.copyWith(color: t.inverseInk),
        actionTextColor: t.inverseInk,
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: QuizzleTokens.radius),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: t.inverseGround,
          border: Border.all(color: t.line, width: 1),
        ),
        textStyle: text.bodySmall?.copyWith(color: t.inverseInk),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        waitDuration: const Duration(milliseconds: 400),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: t.surface,
        surfaceTintColor: const Color(0x00000000),
        elevation: 0,
        shape: hard(t.line, t.borderWidth),
        textStyle: text.bodyMedium,
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(t.surface),
          surfaceTintColor: const WidgetStatePropertyAll(Color(0x00000000)),
          elevation: const WidgetStatePropertyAll(0),
          shape: WidgetStatePropertyAll(hard(t.line, t.borderWidth)),
        ),
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: t.ink,
        linearTrackColor: t.inkMuted,
        circularTrackColor: t.inkMuted,
        linearMinHeight: 6,
      ),
      checkboxTheme: CheckboxThemeData(
        shape: hard(),
        side: BorderSide(color: t.line, width: t.borderWidth),
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? t.inverseGround
              : const Color(0x00000000),
        ),
        checkColor: WidgetStatePropertyAll(t.inverseInk),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStatePropertyAll(t.ink),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? t.inverseInk : t.ink,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? t.inverseGround : t.ground,
        ),
        trackOutlineColor: WidgetStatePropertyAll(t.line),
        trackOutlineWidth: WidgetStatePropertyAll(t.borderWidth),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: t.ink,
        inactiveTrackColor: t.inkMuted,
        thumbColor: t.ink,
        overlayColor: t.line.withValues(alpha: 0.12),
      ),
    );
  }
}
