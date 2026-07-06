import 'package:flutter/material.dart';

import 'src/app_services.dart';
import 'src/screens/world_select_screen.dart';

void main() {
  runApp(LivingWorldsApp(services: AppServices()));
}

class LivingWorldsApp extends StatelessWidget {
  const LivingWorldsApp({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      services: services,
      child: MaterialApp(
        title: 'Living Worlds',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF3A5F4B),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        home: const WorldSelectScreen(),
      ),
    );
  }
}
