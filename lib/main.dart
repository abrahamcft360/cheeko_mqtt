// File: lib/main.dart
// ---
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/digital_playground_screen.dart';
import 'viewmodels/playground_viewmodel.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Digital Playground',
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.blue,
        scaffoldBackgroundColor: const Color(0xFF121212),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Flutter Voice Integration'),
        backgroundColor: Colors.black26,
      ),
      body: Center(
        child: ElevatedButton.icon(
          icon: const Icon(Icons.play_circle_fill),
          label: const Text('Digital Playground'),
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 15),
            textStyle: const TextStyle(fontSize: 18),
            backgroundColor: Colors.blueAccent,
            foregroundColor: Colors.white,
          ),
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => ChangeNotifierProvider(
                  create: (_) => PlaygroundViewModel(),
                  child: const DigitalPlaygroundScreen(),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}