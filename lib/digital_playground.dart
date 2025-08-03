import 'dart:developer' as developer;
import 'package:cheeko_mqtt/app_colors.dart';
import 'package:cheeko_mqtt/playground_provider.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class DigitalPlayground extends StatelessWidget {
  const DigitalPlayground({super.key});

  @override
  Widget build(BuildContext context) {
    developer.log('Building DigitalPlayground');
    return ChangeNotifierProvider(
      create: (context) => PlaygroundProvider(),
      child: Consumer<PlaygroundProvider>(
        builder: (context, provider, child) {
          developer.log('DigitalPlayground state: ${provider.state}');
          return Scaffold(
            body: Stack(
              fit: StackFit.expand,
              children: [
                Container(
                  decoration: const BoxDecoration(
                    image: DecorationImage(
                      image: AssetImage('assets/trial_screen_bg.png'),
                      fit: BoxFit.cover,
                    ),
                  ),
                  child: Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        stops: [0.1, 0.99],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Colors.black],
                      ),
                    ),
                  ),
                ),
                // Positioned(
                //   left: 0,
                //   right: 0,
                //   bottom: MediaQuery.of(context).size.height * 0.3,
                //   height: MediaQuery.of(context).size.height * 0.4,
                //   child: const ModelViewer(
                //     backgroundColor: Colors.transparent,
                //     src: 'assets/cheeko.glb',
                //     alt: 'A 3D model of an Cheeko',
                //     ar: true,
                //     autoRotate: false,
                //     iosSrc:
                //         'https://modelviewer.dev/shared-assets/models/Astronaut.usdz',
                //     disableZoom: true,
                //   ),
                // ),
                SafeArea(
                  child: Column(
                    children: [
                      Align(
                        alignment: Alignment.topLeft,
                        child: IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(
                            Icons.arrow_back,
                            color: AppColors.white,
                          ),
                        ),
                      ),
                      const Spacer(),
                      // *** NEW: Widget to display Cheeko's response text ***
                      _buildLiveResponseText(context, provider),
                      const SizedBox(height: 20),
                      _buildInteractionIndicator(context, provider),
                      const SizedBox(height: 30),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // *** NEW: Widget definition for the live text display ***
  Widget _buildLiveResponseText(
      BuildContext context, PlaygroundProvider provider) {
    // Only show the text box if Cheeko is speaking
    if (provider.state == PlaygroundState.playingWelcome ||
        provider.state == PlaygroundState.responding) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 40),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.blue.withValues(alpha: 0.5)),
        ),
        child: Text(
          provider.liveResponseText,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: AppColors.white,
            fontSize: 18,
            fontWeight: FontWeight.w500,
          ),
        ),
      );
    }
    // Return an empty container otherwise
    return const SizedBox.shrink();
  }

  Widget _buildInteractionIndicator(
      BuildContext context, PlaygroundProvider provider) {
    bool isListening = provider.state == PlaygroundState.listening;
    IconData icon;
    Color color;
    String message = provider.statusMessage;

    switch (provider.state) {
      case PlaygroundState.listening:
        icon = Icons.mic;
        color = AppColors.red;
        break;
      case PlaygroundState.processing:
      case PlaygroundState.responding:
      case PlaygroundState.playingWelcome:
        icon = Icons.waves; // Changed for a "speaking" visual
        color = AppColors.blue;
        break;
      default:
        icon = Icons.mic_off;
        color = AppColors.grey;
        message = "Connecting..."; // Default message
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          message,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 16,
          ),
        ),
        const SizedBox(height: 10),
        Container(
          width: 70,
          height: 70,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            boxShadow: (isListening ||
                    provider.state == PlaygroundState.playingWelcome)
                ? [
                    BoxShadow(
                      color: color.withValues(alpha: 0.6),
                      blurRadius: 16,
                      spreadRadius: 8,
                    ),
                  ]
                : null,
          ),
          child: Icon(
            icon,
            color: AppColors.white,
            size: 35,
          ),
        ),
      ],
    );
  }
}