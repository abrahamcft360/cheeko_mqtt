import 'dart:developer';

import 'package:cheeko_mqtt/digital_playground.dart';
import 'package:flutter/material.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;
import 'package:permission_handler/permission_handler.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Request microphone permission
  final microphoneStatus = await Permission.microphone.request();
  if (microphoneStatus.isDenied || microphoneStatus.isPermanentlyDenied) {
    log('WARNING: Microphone permission denied. Audio recording will not work.');
  }
  
  // Initialize Opus library
  try {
    await _initializeOpus();
  } catch (e) {
    log('Warning: Failed to initialize Opus library: $e');
  }
  
  runApp(MyApp(microphonePermissionGranted: microphoneStatus.isGranted));
}

Future<void> _initializeOpus() async {
  // Use opus_flutter for easy cross-platform loading
  final lib = await opus_flutter.load();
  initOpus(lib);
}

class MyApp extends StatelessWidget {
  final bool microphonePermissionGranted;
  
  const MyApp({super.key, required this.microphonePermissionGranted});

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
      home: HomeScreen(microphonePermissionGranted: microphonePermissionGranted),
    );
  }
}

class HomeScreen extends StatelessWidget {
  final bool microphonePermissionGranted;
  
  const HomeScreen({super.key, required this.microphonePermissionGranted});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Flutter Voice Integration'),
        backgroundColor: Colors.black26,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (!microphonePermissionGranted) ...[
              const Icon(
                Icons.mic_off,
                size: 64,
                color: Colors.red,
              ),
              const SizedBox(height: 16),
              const Text(
                'Microphone permission is required',
                style: TextStyle(color: Colors.red, fontSize: 18),
              ),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: () => openAppSettings(),
                child: const Text('Open Settings'),
              ),
              const SizedBox(height: 32),
            ],
            ElevatedButton.icon(
              icon: const Icon(Icons.play_circle_fill),
              label: const Text('Digital Playground'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 15),
                textStyle: const TextStyle(fontSize: 18),
                backgroundColor: microphonePermissionGranted ? Colors.blueAccent : Colors.grey,
                foregroundColor: Colors.white,
              ),
              onPressed: microphonePermissionGranted
                  ? () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const DigitalPlayground(),
                        ),
                      );
                    }
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}