// lib/screens/digital_playground_screen.dart

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../viewmodels/playground_viewmodel.dart';

class DigitalPlaygroundScreen extends StatefulWidget {
  const DigitalPlaygroundScreen({super.key});

  @override
  State<DigitalPlaygroundScreen> createState() =>
      _DigitalPlaygroundScreenState();
}

class _DigitalPlaygroundScreenState extends State<DigitalPlaygroundScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<PlaygroundViewModel>(
        context,
        listen: false,
      ).initializeAndConnect();
    });
  }

  @override
  void dispose() {
    Provider.of<PlaygroundViewModel>(context, listen: false).dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Digital Playground'),
        backgroundColor: Colors.black26,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            Navigator.of(context).pop();
          },
        ),
      ),
      body: Consumer<PlaygroundViewModel>(
        builder: (context, viewModel, child) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Animated icon to show the current state
                _buildStatusIcon(viewModel),
                const SizedBox(height: 40),
                // Status text
                Text(
                  viewModel.statusMessage,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 18, color: Colors.white70),
                ),
                const SizedBox(height: 40),
                // Loading indicator
                if (viewModel.isLoading) const CircularProgressIndicator(),
              ],
            ),
          );
        },
      ),
    );
  }

  // Widget to show a status icon that changes based on the conversation state
  Widget _buildStatusIcon(PlaygroundViewModel viewModel) {
    IconData icon;
    Color color;

    if (viewModel.isLoading) {
      icon = Icons.cloud_sync;
      color = Colors.blueAccent;
    } else if (viewModel.isTtsPlaying) {
      icon = Icons.volume_up;
      color = Colors.greenAccent;
    } else if (viewModel.isRecording) {
      icon = Icons.mic;
      color = Colors.redAccent;
    } else {
      icon = Icons.pause_circle_filled;
      color = Colors.white70;
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      transitionBuilder: (child, animation) {
        return ScaleTransition(scale: animation, child: child);
      },
      child: Icon(
        icon,
        key: ValueKey<IconData>(icon), // Key for smooth animation
        color: color,
        size: 100,
      ),
    );
  }
}
