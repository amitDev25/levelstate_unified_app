import 'dart:async';
import 'package:flutter/material.dart';
import 'main.dart';

class SettingFragment extends StatefulWidget {
  final BLEManager bleManager;

  const SettingFragment({super.key, required this.bleManager});

  @override
  State<SettingFragment> createState() => _SettingFragmentState();
}

class _SettingFragmentState extends State<SettingFragment> {
  int _totalChannels = 0;
  List<ChannelSettings> _channels = [];
  List<String> _fullArrayHex = [];
  bool _isLoading = false;
  bool _isWriting = false;
  int _lastLogCount = 0;

  @override
  void initState() {
    super.initState();
    widget.bleManager.addListener(_onBLEUpdate);
    _lastLogCount = widget.bleManager.logs.length;
    
    // Auto-send ?0001! when the fragment is opened
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.bleManager.isConnected) {
        _sendCommand();
      }
    });
  }

  @override
  void dispose() {
    widget.bleManager.removeListener(_onBLEUpdate);
    // Dispose all channel controllers
    for (final channel in _channels) {
      channel.dispose();
    }
    super.dispose();
  }

  void _onBLEUpdate() {
    if (!mounted) return;
    
    // Check if there are new logs
    if (widget.bleManager.logs.length > _lastLogCount) {
      final newLogs = widget.bleManager.logs.sublist(_lastLogCount);
      _lastLogCount = widget.bleManager.logs.length;
      
      // Look for JSON-formatted RX responses
      for (final log in newLogs) {
        if (log.startsWith('RX: {') && _isLoading) {
          _parseJsonResponse(log);
          break;
        }
      }
    }
    setState(() {});
  }

  void _parseJsonResponse(String jsonLog) {
    if (!_isLoading) return;
    
    setState(() {
      _channels.clear();
      _fullArrayHex.clear();
      
      // First, extract all hex values to store the complete array
      for (int i = 1; i <= 96; i++) {
        final fieldName = 'FIELD_$i';
        final pattern = '"$fieldName": "';
        
        final startIndex = jsonLog.indexOf(pattern);
        if (startIndex != -1) {
          final valueStart = startIndex + pattern.length;
          final valueEnd = jsonLog.indexOf('"', valueStart);
          if (valueEnd != -1) {
            final hexValue = jsonLog.substring(valueStart, valueEnd);
            // Remove pipe and other non-hex characters
            final cleanHex = hexValue.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
            _fullArrayHex.add(cleanHex.isNotEmpty ? cleanHex : '0000');
          } else {
            _fullArrayHex.add('0000');
          }
        } else {
          _fullArrayHex.add('0000');
        }
      }
      
      // Get total channels from FIELD_11 last 2 hex digits
      final field11Hex = _extractFieldHex(jsonLog, 'FIELD_11');
      if (field11Hex != null && field11Hex.length >= 4) {
        _totalChannels = int.parse(field11Hex.substring(2, 4), radix: 16);
      }
      
      // Now parse each channel's settings
      for (int i = 1; i <= _totalChannels; i++) {
        final channelSettings = ChannelSettings(channelNumber: i);
        
        // Get settings from FIELD_(14+i) for enable, steam, trip relay
        final settingsFieldNum = 14 + i;
        final settingsHex = _extractFieldHex(jsonLog, 'FIELD_$settingsFieldNum');
        if (settingsHex != null && settingsHex.length >= 4) {
          // Parse as hex digits: e.g., "0105" -> '0', '1', '0', '5'
          // 1st hex digit: enable/disable (0 = enabled, 1 = disabled)
          final enabledVal = int.parse(settingsHex[0], radix: 16);
          channelSettings.enabled = enabledVal == 0;
          channelSettings.enabledCtrl.text = enabledVal.toString();
          
          // 2nd hex digit: steam/water
          final steamVal = int.parse(settingsHex[1], radix: 16);
          channelSettings.isSteam = steamVal == 1;
          channelSettings.steamCtrl.text = steamVal.toString();
          
          // Last 2 hex digits: trip relay number
          channelSettings.tripRelayNumber = int.parse(settingsHex.substring(2, 4), radix: 16);
          channelSettings.tripRelayCtrl.text = channelSettings.tripRelayNumber.toString();
        }
        
        // Get energised and delay from FIELD_(63+i)
        final energisedFieldNum = 63 + i;
        final energisedHex = _extractFieldHex(jsonLog, 'FIELD_$energisedFieldNum');
        if (energisedHex != null && energisedHex.length >= 4) {
          // Parse as hex digits
          // 1st hex digit: energised/deenergised
          final energisedVal = int.parse(energisedHex[0], radix: 16);
          channelSettings.energised = energisedVal == 1;
          channelSettings.energisedCtrl.text = energisedVal.toString();
          
          // Last 3 hex digits: delay value
          channelSettings.delayValue = int.parse(energisedHex.substring(1, 4), radix: 16);
          channelSettings.delayCtrl.text = channelSettings.delayValue.toString();
        }
        
        _channels.add(channelSettings);
      }
      
      _isLoading = false;
    });
  }

  String? _extractFieldHex(String jsonLog, String fieldName) {
    final pattern = '"$fieldName": "';
    final startIndex = jsonLog.indexOf(pattern);
    if (startIndex != -1) {
      final valueStart = startIndex + pattern.length;
      final valueEnd = jsonLog.indexOf('"', valueStart);
      if (valueEnd != -1) {
        try {
          final hexValue = jsonLog.substring(valueStart, valueEnd);
          // Remove pipe and other non-hex characters
          final cleanHex = hexValue.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
          return cleanHex;
        } catch (e) {
          return null;
        }
      }
    }
    return null;
  }

  void _sendCommand() async {
    if (!widget.bleManager.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not connected to device')),
      );
      return;
    }

    setState(() {
      _isLoading = true;
      _totalChannels = 0;
      _channels.clear();
    });

    await widget.bleManager.sendString('?0001!');
    
    Future.delayed(const Duration(seconds: 5), () {
      if (_isLoading && mounted) {
        setState(() {
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Response timeout')),
        );
      }
    });
  }

  void _writeCommand() async {
    if (!widget.bleManager.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not connected to device')),
      );
      return;
    }

    if (_fullArrayHex.isEmpty || _fullArrayHex.length != 96) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No data to write. Please read first.')),
      );
      return;
    }

    setState(() {
      _isWriting = true;
    });

    try {
      // Create a copy of the full array
      final modifiedArray = List<String>.from(_fullArrayHex);

      // Update each channel's fields
      for (int i = 0; i < _channels.length; i++) {
        final channel = _channels[i];
        final channelNum = channel.channelNumber;

        // Reconstruct FIELD_(14+channelNum) from channel settings
        try {
          final enableVal = int.parse(channel.enabledCtrl.text.trim());
          final steamVal = int.parse(channel.steamCtrl.text.trim());
          final tripRelay = int.parse(channel.tripRelayCtrl.text.trim());
          
          final f_0 = enableVal.toRadixString(16).toUpperCase().padLeft(1, '0');
          final f_1 = steamVal.toRadixString(16).toUpperCase().padLeft(1, '0');
          final f_2_3 = tripRelay.toRadixString(16).toUpperCase().padLeft(2, '0');
          
          modifiedArray[14 + channelNum - 1] = '$f_0$f_1$f_2_3';
        } catch (e) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Invalid value in Channel $channelNum settings')),
          );
          setState(() => _isWriting = false);
          return;
        }

        // Reconstruct FIELD_(63+channelNum) from energised and delay
        try {
          final energisedVal = int.parse(channel.energisedCtrl.text.trim());
          final delayVal = int.parse(channel.delayCtrl.text.trim());
          
          final e_0 = energisedVal.toRadixString(16).toUpperCase().padLeft(1, '0');
          final e_1_3 = delayVal.toRadixString(16).toUpperCase().padLeft(3, '0');
          
          modifiedArray[63 + channelNum - 1] = '$e_0$e_1_3';
        } catch (e) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Invalid value in Channel $channelNum energised/delay')),
          );
          setState(() => _isWriting = false);
          return;
        }
      }

      // Reconstruct the command string with "|" prefix and "!" suffix
      final commandString = '|${modifiedArray.join(',')}!';

      // Show dialog with command being sent
      bool dialogShown = false;
      if (mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            backgroundColor: const Color(0xFF1A1A2E),
            title: const Text(
              'Sending Command',
              style: TextStyle(color: Color(0xFF00E5FF)),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Command String:',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0D0D1A),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: const Color(0xFF00E5FF).withOpacity(0.3),
                      ),
                    ),
                    child: Text(
                      commandString,
                      style: const TextStyle(
                        color: Color(0xFF00E5FF),
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Row(
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFF00E5FF),
                        ),
                      ),
                      SizedBox(width: 12),
                      Text(
                        'Sending in chunks...',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
        dialogShown = true;
      }

      // Safety timeout: close dialog after 5 seconds
      final timeoutTimer = Timer(const Duration(seconds: 5), () {
        if (mounted) {
          try {
            if (dialogShown) {
              Navigator.of(context, rootNavigator: true).pop();
              dialogShown = false;
            }
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Operation timeout - dialog auto-closed')),
            );
          } catch (_) {}
        }
      });

      try {
        // Send the write command
        await widget.bleManager.sendString(commandString);

        // Wait a moment, then send ?0002!
        await Future.delayed(const Duration(milliseconds: 500));
        await widget.bleManager.sendString('?0002!');
        await Future.delayed(const Duration(milliseconds: 500));
        await widget.bleManager.sendString('?0005!');

        // Small delay to ensure operations complete
        await Future.delayed(const Duration(milliseconds: 100));

        // Cancel timeout and close dialog
        timeoutTimer.cancel();
        if (mounted && dialogShown) {
          Navigator.of(context, rootNavigator: true).pop();
          dialogShown = false;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Write successful! Sent ?0002!')),
          );
        }
      } catch (e) {
        // Cancel timeout and close dialog on error
        timeoutTimer.cancel();
        if (mounted && dialogShown) {
          try {
            Navigator.of(context, rootNavigator: true).pop();
            dialogShown = false;
          } catch (_) {
            // Dialog might already be closed
          }
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Write failed: $e')),
          );
        }
      } finally {
        // Always cancel timer and close dialog in finally
        timeoutTimer.cancel();
        if (mounted && dialogShown) {
          try {
            Navigator.of(context, rootNavigator: true).pop();
            dialogShown = false;
          } catch (_) {}
        }
        if (mounted) {
          setState(() {
            _isWriting = false;
          });
        }
      }
    } catch (e) {
      // Outer catch for any validation errors
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
        setState(() {
          _isWriting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0D0D1A),
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // Send button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: widget.bleManager.isConnected && !_isLoading
                  ? _sendCommand
                  : null,
              icon: _isLoading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.black,
                      ),
                    )
                  : const Icon(Icons.tune, color: Colors.black, size: 20),
              label: Text(
                _isLoading ? 'Loading Settings...' : 'Load Channel Settings',
                style: const TextStyle(
                  color: Colors.black,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00E5FF),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
          
          const SizedBox(height: 12),
          
          // Write button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: widget.bleManager.isConnected && !_isWriting && _fullArrayHex.isNotEmpty
                  ? _writeCommand
                  : null,
              icon: _isWriting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.black,
                      ),
                    )
                  : const Icon(Icons.edit, color: Colors.black, size: 20),
              label: Text(
                _isWriting ? 'Writing...' : 'Write & Send ?0002!',
                style: const TextStyle(
                  color: Colors.black,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF6B35),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
          
          const SizedBox(height: 20),
          
          // Channels info header
          if (_totalChannels > 0 && !_isLoading)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A2E),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: const Color(0xFF00E5FF).withOpacity(0.3),
                ),
              ),
              child: Text(
                'Total Channels: $_totalChannels',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFF00E5FF),
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          
          // Channel cards
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(
                      color: Color(0xFF00E5FF),
                    ),
                  )
                : _channels.isEmpty
                    ? const Center(
                        child: Text(
                          'No channel data',
                          style: TextStyle(
                            color: Colors.white54,
                            fontSize: 16,
                          ),
                        ),
                      )
                    : ListView.builder(
                        itemCount: _channels.length,
                        itemBuilder: (context, index) {
                          final channel = _channels[index];
                          return _buildChannelCard(channel);
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildChannelCard(ChannelSettings channel) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFF00E5FF).withOpacity(0.3),
          width: 2,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Channel header
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF00E5FF),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Channel ${channel.channelNumber}',
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // Enable/Disable Toggle
              Row(
                children: [
                  Text(
                    channel.enabled ? 'Enabled' : 'Disabled',
                    style: TextStyle(
                      color: channel.enabled ? Colors.green : Colors.red,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Transform.scale(
                    scale: 0.75,
                    child: Switch(
                      value: channel.enabled,
                      onChanged: (value) {
                        setState(() {
                          channel.enabledCtrl.text = value ? '0' : '1';
                          channel.enabled = value;
                        });
                      },
                      activeColor: Colors.green,
                      activeTrackColor: Colors.green.withOpacity(0.5),
                      inactiveThumbColor: Colors.red,
                      inactiveTrackColor: Colors.red.withOpacity(0.3),
                    ),
                  ),
                ],
              ),
              const Spacer(),
            ],
          ),
          
          const SizedBox(height: 16),
          
          // Channel properties grid
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 2,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.7,
            children: [
              _buildSteamToggleTile(
                'Type',
                channel,
                Colors.orange,
                channel.enabled,
              ),
              _buildEditablePropertyTile(
                'Trip Relay',
                channel.tripRelayCtrl,
                const Color(0xFFFF6B35),
                channel.enabled,
              ),
              _buildEnergisedToggleTile(
                'Status',
                channel,
                Colors.green,
                channel.enabled,
              ),
              _buildEditablePropertyTile(
                'Delay',
                channel.delayCtrl,
                const Color(0xFFFFEB3B),
                channel.enabled,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSteamToggleTile(
      String label, ChannelSettings channel, Color color, bool enabled) {
    final isSteam = channel.steamCtrl.text == '1';
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0D0D1A),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: color.withOpacity(0.3),
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: enabled ? Colors.white54 : Colors.white24,
              fontSize: 10,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Transform.scale(
                scale: 0.8,
                child: Switch(
                  value: isSteam,
                  onChanged: enabled ? (value) {
                    setState(() {
                      channel.steamCtrl.text = value ? '1' : '0';
                      channel.isSteam = value;
                    });
                  } : null,
                  activeColor: color,
                  activeTrackColor: color.withOpacity(0.5),
                  inactiveThumbColor: Colors.blue,
                  inactiveTrackColor: Colors.blue.withOpacity(0.3),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  isSteam ? 'Steam' : 'Water',
                  style: TextStyle(
                    color: enabled ? color : color.withOpacity(0.3),
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEnergisedToggleTile(
      String label, ChannelSettings channel, Color color, bool enabled) {
    final isEnergised = channel.energisedCtrl.text == '1';
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0D0D1A),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: color.withOpacity(0.3),
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: enabled ? Colors.white54 : Colors.white24,
              fontSize: 10,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Transform.scale(
                scale: 0.8,
                child: Switch(
                  value: isEnergised,
                  onChanged: enabled ? (value) {
                    setState(() {
                      channel.energisedCtrl.text = value ? '1' : '0';
                      channel.energised = value;
                    });
                  } : null,
                  activeColor: color,
                  activeTrackColor: color.withOpacity(0.5),
                  inactiveThumbColor: Colors.grey,
                  inactiveTrackColor: Colors.grey.withOpacity(0.3),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  isEnergised ? 'Energised' : 'De-energised',
                  style: TextStyle(
                    color: enabled ? color : color.withOpacity(0.3),
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEditablePropertyTile(
      String label, TextEditingController controller, Color color, bool enabled) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0D0D1A),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: color.withOpacity(0.3),
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: enabled ? Colors.white54 : Colors.white24,
              fontSize: 10,
            ),
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              // Minus button
              InkWell(
                onTap: enabled ? () {
                  setState(() {
                    final currentValue = int.tryParse(controller.text.trim()) ?? 0;
                    if (currentValue > 0) {
                      controller.text = (currentValue - 1).toString();
                    }
                  });
                } : null,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: enabled ? color.withOpacity(0.2) : Colors.transparent,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Icon(
                    Icons.remove,
                    size: 16,
                    color: enabled ? color : color.withOpacity(0.3),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Text field
              Expanded(
                child: TextField(
                  controller: controller,
                  enabled: enabled,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: enabled ? color : color.withOpacity(0.3),
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                    border: InputBorder.none,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Plus button
              InkWell(
                onTap: enabled ? () {
                  setState(() {
                    final currentValue = int.tryParse(controller.text.trim()) ?? 0;
                    controller.text = (currentValue + 1).toString();
                  });
                } : null,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: enabled ? color.withOpacity(0.2) : Colors.transparent,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Icon(
                    Icons.add,
                    size: 16,
                    color: enabled ? color : color.withOpacity(0.3),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class ChannelSettings {
  final int channelNumber;
  bool enabled = false;
  bool isSteam = false;
  int tripRelayNumber = 0;
  bool energised = false;
  int delayValue = 0;
  
  // Text controllers for editable fields
  final TextEditingController enabledCtrl = TextEditingController(text: '0');
  final TextEditingController steamCtrl = TextEditingController(text: '0');
  final TextEditingController tripRelayCtrl = TextEditingController(text: '0');
  final TextEditingController energisedCtrl = TextEditingController(text: '0');
  final TextEditingController delayCtrl = TextEditingController(text: '0');

  ChannelSettings({required this.channelNumber});
  
  void dispose() {
    enabledCtrl.dispose();
    steamCtrl.dispose();
    tripRelayCtrl.dispose();
    energisedCtrl.dispose();
    delayCtrl.dispose();
  }
}
