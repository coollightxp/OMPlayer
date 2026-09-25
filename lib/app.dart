import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'services/player_controller.dart';
import 'screens/player_screen.dart';

class OMPlayerApp extends StatelessWidget {
  const OMPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => PlayerController(),
      child: MaterialApp(
        title: 'OMPlayer',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true).copyWith(
          scaffoldBackgroundColor: Colors.black,
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.blueAccent,
            brightness: Brightness.dark,
          ),
        ),
        home: const PlayerScreen(),
      ),
    );
  }
}
