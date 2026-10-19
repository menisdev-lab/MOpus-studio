// =============================================================================
// MOpus Studio - lib/theme/mopus_theme.dart
// -----------------------------------------------------------------------------
// Design system (single source of truth for the app's visual language).
//
// Palette (strict):
//   Jet Black        #050505
//   Pure White       #FFFFFF
//   Electric Orange  #FF6B00
//
// All other tones are alpha/lightness derivatives of the three brand colors
// so the UI can never drift away from the identity.
// =============================================================================

import 'package:flutter/material.dart';

/// Brand colors. All values are `const` so they can be used inside `const`
/// widgets and painters without allocation cost (important for 2GB devices).
abstract final class MopusColors {
  // --- Brand ---------------------------------------------------------------
  static const Color jetBlack = Color(0xFF050505);
  static const Color pureWhite = Color(0xFFFFFFFF);
  static const Color electricOrange = Color(0xFFFF6B00);

  // --- Surfaces (derived from Jet Black) ------------------------------------
  static const Color surface = Color(0xFF0A0A0A);
  static const Color surfaceElevated = Color(0xFF101010);
  static const Color surfaceHighlight = Color(0xFF161616);
  static const Color surfaceActive = Color(0xFF1D1D1D);
  static const Color hairline = Color(0xFF232323);

  // --- Text (derived from Pure White) ---------------------------------------
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xB3FFFFFF); // 70%
  static const Color textTertiary = Color(0x73FFFFFF); // 45%
  static const Color textDisabled = Color(0x38FFFFFF); // 22%

  // --- Orange alpha ramp -----------------------------------------------------
  static const Color orangeGlow = Color(0x40FF6B00); // 25%
  static const Color orangeSoft = Color(0x59FF6B00); // 35%
  static const Color orangeMuted = Color(0x24FF6B00); // 14%
  static const Color orangeFaint = Color(0x14FF6B00); // 8%

  // --- Misc ------------------------------------------------------------------
  static const Color whiteFaint = Color(0x12FFFFFF); // 7%
  static const Color whiteGhost = Color(0x0AFFFFFF); // 4%
}

/// Layout metrics shared by the editor surface.
abstract final class MopusMetrics {
  static const double trackHeaderWidth = 148.0;
  static const double laneHeight = 64.0;
  static const double rulerHeight = 30.0;
  static const double toolbarHeight = 44.0;
  static const double clipInsetY = 8.0;
  static const double cornerRadius = 8.0;
  static const double handleSize = 9.0;
}

/// Reusable text styles (kept minimal to avoid theme bloat).
abstract final class MopusText {
  static const TextStyle label = TextStyle(
    fontSize: 11,
    height: 1.2,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.2,
    color: MopusColors.textPrimary,
  );

  static const TextStyle caption = TextStyle(
    fontSize: 9,
    height: 1.2,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.3,
    color: MopusColors.textTertiary,
  );

  static const TextStyle sectionTitle = TextStyle(
    fontSize: 11,
    height: 1.2,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.6,
    color: MopusColors.textSecondary,
  );
}

/// Builds the global dark theme. The app is dark-only by design.
ThemeData buildMopusTheme() {
  const scheme = ColorScheme.dark(
    primary: MopusColors.electricOrange,
    onPrimary: MopusColors.jetBlack,
    secondary: MopusColors.electricOrange,
    onSecondary: MopusColors.jetBlack,
    surface: MopusColors.jetBlack,
    onSurface: MopusColors.pureWhite,
    error: Color(0xFFFF3B30),
    onError: MopusColors.pureWhite,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: MopusColors.jetBlack,
    canvasColor: MopusColors.jetBlack,
    dividerColor: MopusColors.hairline,
    splashColor: MopusColors.orangeMuted,
    highlightColor: MopusColors.whiteFaint,
    iconTheme: const IconThemeData(
      color: MopusColors.textSecondary,
      size: 18,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: MopusColors.jetBlack,
      surfaceTintColor: Colors.transparent,
      foregroundColor: MopusColors.pureWhite,
      elevation: 0,
      centerTitle: false,
      toolbarHeight: 48,
      titleTextStyle: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        letterSpacing: 2.0,
        color: MopusColors.pureWhite,
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: MopusColors.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(MopusMetrics.cornerRadius),
        side: const BorderSide(color: MopusColors.hairline),
      ),
      textStyle: MopusText.label,
    ),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 500),
      decoration: BoxDecoration(
        color: MopusColors.surfaceActive,
        borderRadius: BorderRadius.all(Radius.circular(4)),
      ),
      textStyle: TextStyle(
        fontSize: 10,
        color: MopusColors.textSecondary,
      ),
    ),
  );
}
