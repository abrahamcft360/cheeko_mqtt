// File: lib/screens/digital_playground_screen.dart
// ---
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
    // Use addPostFrameCallback to ensure the context is available
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Start the connection process as soon as the screen is built
      Provider.of<PlaygroundViewModel>(
        context,
        listen: false,
      ).initializeAndConnect();
    });
  }

  @override
  void dispose() {
    // Ensure cleanup is called when the screen is disposed
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
          return Stack(
            children: [
              Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      viewModel.statusMessage,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 18,
                        color: Colors.white70,
                      ),
                    ),
                    const SizedBox(height: 40),
                    if (viewModel.isLoading)
                      const CircularProgressIndicator()
                    else
                      _buildControlButtons(context, viewModel),
                  ],
                ),
              ),
              if (viewModel.isRecording)
                Positioned(
                  top: 20,
                  left: 0,
                  right: 0,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.mic, color: Colors.red.shade400),
                      const SizedBox(width: 8),
                      const Text(
                        "Listening...",
                        style: TextStyle(fontSize: 16, color: Colors.white),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildControlButtons(
    BuildContext context,
    PlaygroundViewModel viewModel,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Volume Control Button
          _buildVolumeButton(viewModel),
          // Speak/Abort Button
          _buildSpeakButton(viewModel),
        ],
      ),
    );
  }

  Widget _buildVolumeButton(PlaygroundViewModel viewModel) {
    return GestureDetector(
      onTap: () =>
          viewModel.adjustVolume(increase: false), // Single tap to decrease
      onDoubleTap: () =>
          viewModel.adjustVolume(increase: true), // Double tap to increase
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: viewModel.areButtonsEnabled
              ? Colors.blueGrey.shade800
              : Colors.grey.shade800,
          border: Border.all(
            color: viewModel.areButtonsEnabled
                ? Colors.blueAccent
                : Colors.grey,
            width: 2,
          ),
        ),
        child: Column(
          children: [
            Icon(
              Icons.volume_up,
              color: viewModel.areButtonsEnabled ? Colors.white : Colors.grey,
              size: 40,
            ),
            const SizedBox(height: 8),
            Text(
              'Vol ${(viewModel.volume * 100).toInt()}%',
              style: TextStyle(
                color: viewModel.areButtonsEnabled
                    ? Colors.white70
                    : Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSpeakButton(PlaygroundViewModel viewModel) {
    bool isSpeakingAction = viewModel.isTtsPlaying;
    IconData icon = isSpeakingAction
        ? Icons.stop_circle_outlined
        : (viewModel.isRecording ? Icons.mic_off : Icons.mic);
    Color buttonColor = isSpeakingAction
        ? Colors.orange.shade700
        : (viewModel.isRecording ? Colors.red.shade700 : Colors.green.shade600);

    return GestureDetector(
      onTap: viewModel.areButtonsEnabled
          ? () => viewModel.handleRightButtonTap()
          : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: viewModel.areButtonsEnabled
              ? buttonColor
              : Colors.grey.shade800,
          border: Border.all(
            color: viewModel.areButtonsEnabled ? Colors.white : Colors.grey,
            width: 2,
          ),
          boxShadow: viewModel.isRecording
              ? [
                  BoxShadow(
                    color: Colors.red.withOpacity(0.7), // FIX: Was withValues
                    blurRadius: 20.0,
                    spreadRadius: 5.0,
                  ),
                ]
              : [],
        ),
        child: Column(
          children: [
            Icon(
              icon,
              color: viewModel.areButtonsEnabled ? Colors.white : Colors.grey,
              size: 40,
            ),
            const SizedBox(height: 8),
            Text(
              isSpeakingAction ? 'Abort' : 'Speak',
              style: TextStyle(
                color: viewModel.areButtonsEnabled
                    ? Colors.white70
                    : Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
