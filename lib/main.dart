import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'edli/main.dart' as edli;
import 'els/main.dart' as els;
import 'device_preferences.dart';

// ─────────────────────────────────────────────────────────────
// ENTRY POINT
// ─────────────────────────────────────────────────────────────
void main() {
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
  String _selectedEdliVariant = 'EDLI';
  bool _isCheckingPreferences = true;
  bool _hasSavedDevice = false;
  Map<String, String?> _savedDeviceInfo = {};

  String _resolveEdliVariant(String? savedName) {
    if (savedName == 'EDLI' || savedName == 'ELS (8 Channel)') {
      return savedName!;
    }
    return 'EDLI';
  }

  @override
  void initState() {
    super.initState();
    _checkSavedDevice();
  }

  Future<void> _checkSavedDevice() async {
    final hasSaved = await DevicePreferences.hasSavedDevice();
    
    if (hasSaved && mounted) {
      final deviceInfo = await DevicePreferences.getSavedDevice();
      final deviceType = deviceInfo['type'];
      final deviceId = deviceInfo['id'];
      
      if (deviceType != null && deviceId != null) {
        // Show saved device page instead of auto-connecting
        setState(() {
          _hasSavedDevice = true;
          _savedDeviceInfo = deviceInfo;
          _isCheckingPreferences = false;
        });
        return;
      }
    }
    
    setState(() {
      _isCheckingPreferences = false;
    });
  }

  Future<void> _autoConnectAndNavigate(String deviceType, String deviceId) async {
    try {
      // Show loading dialog
      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => Center(
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A2E),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(
                  color: Color(0xFF00E5FF),
                ),
                const SizedBox(height: 16),
                Text(
                  'Connecting to $deviceType...',
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                ),
              ],
            ),
          ),
        ),
      );

      // Start scanning for the saved device
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
      
      BluetoothDevice? targetDevice;
      
      // Listen for scan results
      final subscription = FlutterBluePlus.scanResults.listen((results) {
        for (var result in results) {
          if (result.device.remoteId.toString() == deviceId) {
            targetDevice = result.device;
            break;
          }
        }
      });
      
      // Wait for scan to complete
      await Future.delayed(const Duration(seconds: 10));
      await FlutterBluePlus.stopScan();
      await subscription.cancel();
      
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop(); // Close loading dialog
      
      if (targetDevice != null) {
        // Navigate to the appropriate app with the device
        Widget targetScreen;
        if (deviceType == 'EDLI') {
          final edliVariant = _resolveEdliVariant(_savedDeviceInfo['name']);
          targetScreen = edli.BLEAsciiApp(
            autoConnectDevice: targetDevice,
            deviceDisplayName: edliVariant,
          );
        } else {
          targetScreen = els.HMSoftApp(autoConnectDevice: targetDevice);
        }
        
        if (mounted) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (context) => targetScreen),
          );
        }
      } else {
        // Device not found, show error and stay on selection screen
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Saved device not found. Please select manually.'),
              backgroundColor: Colors.red,
            ),
          );
          setState(() {
            _isCheckingPreferences = false;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop(); // Close loading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Auto-connect failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
        setState(() {
          _isCheckingPreferences = false;
        });
      }
    }
  }

  void _navigateToApp() {
    if (selectedDevice == null) return;

    Widget targetScreen;
    if (selectedDevice == 'EDLI') {
      targetScreen = edli.BLEAsciiApp(deviceDisplayName: _selectedEdliVariant);
    } else {
      targetScreen = const els.HMSoftApp();
    }

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (context) => targetScreen),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isCheckingPreferences) {
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
          child: const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(
                  color: Color(0xFF00E5FF),
                ),
                SizedBox(height: 16),
                Text(
                  'Loading...',
                  style: TextStyle(color: Colors.white, fontSize: 16),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Show saved device page if device is saved
    if (_hasSavedDevice) {
      return _buildSavedDevicePage();
    }

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
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                padding: const EdgeInsets.all(24.0),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight - 48),
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
                    title: 'EDLI / ELS',
                    description: 'EDLI Device',
                    icon: Icons.bluetooth,
                    isSelected: selectedDevice == 'EDLI',
                    onTap: () {
                      setState(() {
                        selectedDevice = 'EDLI';
                      });
                    },
                  ),
                  if (selectedDevice == 'EDLI') ...[
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A1A2E),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Select EDLI Profile',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 8),
                          RadioListTile<String>(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            activeColor: const Color(0xFF00E5FF),
                            title: const Text('EDLI', style: TextStyle(color: Colors.white)),
                            value: 'EDLI',
                            groupValue: _selectedEdliVariant,
                            onChanged: (value) {
                              if (value == null) return;
                              setState(() => _selectedEdliVariant = value);
                            },
                          ),
                          RadioListTile<String>(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            activeColor: const Color(0xFF00E5FF),
                            title: const Text('ELS (8 Channel)', style: TextStyle(color: Colors.white)),
                            value: 'ELS (8 Channel)',
                            groupValue: _selectedEdliVariant,
                            onChanged: (value) {
                              if (value == null) return;
                              setState(() => _selectedEdliVariant = value);
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
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
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildSavedDevicePage() {
    final deviceType = _savedDeviceInfo['type'] ?? 'Unknown';
    final displayDeviceType = deviceType == 'EDLI' ? 'EDLI / ELS' : deviceType;
    final deviceName = _savedDeviceInfo['name'] ?? 'Unknown Device';
    final deviceId = _savedDeviceInfo['id'] ?? 'Unknown';

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
                  // Saved device icon
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00E5FF).withOpacity(0.1),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: const Color(0xFF00E5FF),
                        width: 2,
                      ),
                    ),
                    child: const Icon(
                      Icons.bookmark,
                      size: 60,
                      color: Color(0xFF00E5FF),
                    ),
                  ),
                  const SizedBox(height: 24),
                  
                  // Title
                  const Text(
                    'Saved Device Found',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Connect to your previously saved device',
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.white60,
                    ),
                  ),
                  const SizedBox(height: 48),

                  // Device info card
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A1A2E),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: const Color(0xFF00E5FF).withOpacity(0.3),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              deviceType == 'EDLI' ? Icons.bluetooth : Icons.settings_remote,
                              color: const Color(0xFF00E5FF),
                              size: 28,
                            ),
                            const SizedBox(width: 12),
                            Text(
                              displayDeviceType,
                              style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF00E5FF),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        _buildInfoRow('Device Name:', deviceName),
                        const SizedBox(height: 8),
                        _buildInfoRow('Device ID:', deviceId),
                      ],
                    ),
                  ),
                  const SizedBox(height: 48),

                  // Connect Button
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        await _autoConnectAndNavigate(deviceType, deviceId);
                      },
                      icon: const Icon(Icons.bluetooth_connected),
                      label: const Text(
                        'Connect to Saved Device',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00E5FF),
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 8,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Select Different Device Button
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        setState(() {
                          _hasSavedDevice = false;
                        });
                      },
                      icon: const Icon(Icons.devices),
                      label: const Text(
                        'Select Different Device',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white70,
                        side: const BorderSide(
                          color: Colors.white30,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Clear Saved Device Button
                  TextButton.icon(
                    onPressed: () async {
                      await DevicePreferences.clearDevice();
                      setState(() {
                        _hasSavedDevice = false;
                      });
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Saved device cleared'),
                            backgroundColor: Colors.orange,
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.bookmark_remove, size: 18),
                    label: const Text('Clear Saved Device'),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white38,
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

  Widget _buildInfoRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 14,
            color: Colors.white60,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              fontSize: 14,
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
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
