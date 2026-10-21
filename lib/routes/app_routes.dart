import 'package:flutter/material.dart';

import '../auth_screen.dart';
import '../driving_card_screen.dart';
import '../screens/main_shell.dart';
import '../screens/home_screen.dart';
import '../screens/monitor_screen.dart';
import '../screens/history_screen.dart';
import '../screens/settings_screen.dart';

class AppRoutes {
  static const String initial = '/';
  static const String login = '/login';
  static const String main = '/main';
  static const String home = '/home';
  static const String cockpit = '/cockpit';
  static const String monitor = '/monitor';
  static const String history = '/history';
  static const String settings = '/settings';
  static const String drivingCard = '/driving-card';

  /// Named routes map for MaterialApp
  static Map<String, WidgetBuilder> get routes => {
    login: (context) => const LoginScreen(),
    main: (context) => const MainShell(),
    home: (context) => const MainShell(initialIndex: 0),
    cockpit: (context) => const MainShell(initialIndex: 0),
    monitor: (context) => const MainShell(initialIndex: 1),
    history: (context) => const MainShell(initialIndex: 2),
    settings: (context) => const AccountSettingsScreen(),
  };

  /// Dynamic route generator for parameterized routes like DrivingCardScreen
  static Route<dynamic>? onGenerateRoute(RouteSettings routeSettings) {
    switch (routeSettings.name) {
      case drivingCard:
        final args = routeSettings.arguments as Map<String, dynamic>?;
        if (args != null) {
          return MaterialPageRoute(
            builder: (_) => DrivingCardScreen(
              durationSeconds: args['durationSeconds'] as int? ?? 0,
              drivingScore: args['drivingScore'] as int? ?? 100,
              totalMicrosleeps: args['totalMicrosleeps'] as int? ?? 0,
              totalDrowsy: args['totalDrowsy'] as int? ?? 0,
              totalYawns: args['totalYawns'] as int? ?? 0,
              startedAt: args['startedAt'] as DateTime?,
            ),
            settings: routeSettings,
          );
        }
        return MaterialPageRoute(
          builder: (_) => const DrivingCardScreen(
            durationSeconds: 0,
            drivingScore: 100,
            totalMicrosleeps: 0,
            totalDrowsy: 0,
            totalYawns: 0,
          ),
          settings: routeSettings,
        );

      // Standalone direct page navigation if needed
      case '/home-standalone':
        return MaterialPageRoute(
          builder: (_) => const CockpitScreen(),
          settings: routeSettings,
        );

      case '/monitor-standalone':
        return MaterialPageRoute(
          builder: (_) => const MonitorScreen(isActive: true),
          settings: routeSettings,
        );

      case '/history-standalone':
        return MaterialPageRoute(
          builder: (_) => const HistoryScreen(),
          settings: routeSettings,
        );

      default:
        return null;
    }
  }
}
