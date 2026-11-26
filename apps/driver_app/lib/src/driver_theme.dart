import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DriverThemeController {
  DriverThemeController._();

  static const _key = 'alvzyo_driver_theme_mode';
  static final ValueNotifier<ThemeMode> mode =
      ValueNotifier<ThemeMode>(ThemeMode.system);

  static Future<void> restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_key);
      mode.value = ThemeMode.values.firstWhere(
        (value) => value.name == stored,
        orElse: () => ThemeMode.system,
      );
    } catch (_) {
      mode.value = ThemeMode.system;
    }
  }

  static Future<void> set(ThemeMode value) async {
    mode.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, value.name);
  }
}
