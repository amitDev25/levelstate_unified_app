import 'dart:io';
import 'package:flutter/material.dart';
import 'edli/main.dart' as edli;
import 'els/main.dart' as els;

// ─────────────────────────────────────────────────────────────
// ENTRY POINT
// ─────────────────────────────────────────────────────────────
void main() {
  // Set up HTTP overrides for EDLI app
  HttpOverrides.global = edli.MyHttpOverrides();
  runApp(const UnifiedApp());
}

class UnifiedApp extends StatelessWidget {
  const UnifiedApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Device Selector',
      theme: ThemeData(
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00E5FF),
          secondary: Color(0xFFFF6D00),
          surface: Color(0xFF1A1A2E),
        ),
        scaffoldBackgroundColor: const Color(0xFF0D0D1A),
        useMaterial3: true,
      ),
      home: const DeviceSelectionScreen(),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// DEVICE SELECTION SCREEN
// ─────────────────────────────────────────────────────────────
class DeviceSelectionScreen extends StatefulWidget {
  const DeviceSelectionScreen({super.key});

  @override
  State<DeviceSelectionScreen> createState() => _DeviceSelectionScreenState();
}

class _DeviceSelectionScreenState extends State<DeviceSelectionScreen> {
  String? selectedDevice;

  void _navigateToApp() {
    if (selectedDevice == null) return;

    Widget targetScreen;
    if (selectedDevice == 'EDLI') {
      targetScreen = const edli.BLEAsciiApp();
    } else {
      targetScreen = const els.HMSoftApp();
    }

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (context) => targetScreen),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              const Color(0xFF0D0D1A),
              const Color(0xFF1A1A2E),
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Title
                  const Icon(
                    Icons.devices,
                    size: 80,
                    color: Color(0xFF00E5FF),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Select Device Type',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Choose your device to continue',
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.white60,
                    ),
                  ),
                  const SizedBox(height: 48),

                  // EDLI Option
                  _DeviceOptionCard(
                    title: 'EDLI',
                    description: 'EDLI Device',
                    icon: Icons.bluetooth,
                    isSelected: selectedDevice == 'EDLI',
                    onTap: () {
                      setState(() {
                        selectedDevice = 'EDLI';
                      });
                    },
                  ),
                  const SizedBox(height: 20),

                  // ELS Option
                  _DeviceOptionCard(
                    title: 'ELS',
                    description: 'ELS300 Device',
                    icon: Icons.settings_remote,
                    isSelected: selectedDevice == 'ELS',
                    onTap: () {
                      setState(() {
                        selectedDevice = 'ELS';
                      });
                    },
                  ),
                  const SizedBox(height: 48),

                  // Continue Button
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton(
                      onPressed: selectedDevice != null ? _navigateToApp : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00E5FF),
                        disabledBackgroundColor: Colors.grey.shade800,
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 8,
                      ),
                      child: Text(
                        selectedDevice != null 
                            ? 'Continue to $selectedDevice'
                            : 'Select a device',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// DEVICE OPTION CARD
// ─────────────────────────────────────────────────────────────
class _DeviceOptionCard extends StatelessWidget {
  final String title;
  final String description;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  const _DeviceOptionCard({
    required this.title,
    required this.description,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: isSelected 
              ? const Color(0xFF00E5FF).withOpacity(0.15)
              : const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected 
                ? const Color(0xFF00E5FF)
                : Colors.transparent,
            width: 2,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: const Color(0xFF00E5FF).withOpacity(0.3),
                    blurRadius: 12,
                    spreadRadius: 2,
                  ),
                ]
              : null,
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: isSelected
                    ? const Color(0xFF00E5FF)
                    : Colors.white12,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                icon,
                size: 32,
                color: isSelected ? Colors.black : Colors.white70,
              ),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: isSelected 
                          ? const Color(0xFF00E5FF)
                          : Colors.white,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: const TextStyle(
                      fontSize: 14,
                      color: Colors.white60,
                    ),
                  ),
                ],
              ),
            ),
            if (isSelected)
              const Icon(
                Icons.check_circle,
                color: Color(0xFF00E5FF),
                size: 28,
              ),
          ],
        ),
      ),
    );
  }
}
