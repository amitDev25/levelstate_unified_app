import 'dart:async';
import 'package:flutter/material.dart';
import 'main.dart';

class ConfigFragment extends StatefulWidget {
  final BLEManager bleManager;

  const ConfigFragment({super.key, required this.bleManager});

  @override
  State<ConfigFragment> createState() => _ConfigFragmentState();
}

class _ConfigFragmentState extends State<ConfigFragment> {
  // FIELD_8 bits - Dropdown fields (1=Yes, 0=No)
  String _levelChkEna = 'No';
  String _votingChkEna = 'No';
  String _autoAdjustEna = 'No';
  int _unused = 0;
  
  // FIELD_9 bits - Disable flags (1=Yes/Disabled, 0=No/Enabled)
  String _contDisable = 'No';  // No means enabled (not disabled)
  String _shortDisableSys = 'No';  // No means enabled (not disabled)
  String _fltDisable = 'No';  // No means enabled (not disabled)
  String _procFltDisable = 'No';  // No means enabled (not disabled)
  
  // FIELD_10 bits
  String _pwrFltDisable = 'No';  // No means enabled (not disabled)
  String _sensitivity = '0.5';  // Dropdown: 0.5, 1, 2 (writes 1, 2, 3 respectively)
  String _sel420SteamMode = 'No';
  int _lastRmtAdr = 0;
  
  // FIELD_11 bits
  int _numGroundConnections = 0;
  int _totalChannels = 0;
  
  // FIELD_63 - System Fault Time Delay (last 3 digits as decimal)
  int _sysFltTimeDelay = 0;
  
  // Text controllers for numeric fields only
  final Map<String, TextEditingController> _controllers = {
    'lastRmtAdr': TextEditingController(text: '0'),
    'numGroundConnections': TextEditingController(text: '0'),
    'totalChannels': TextEditingController(text: '0'),
    'sysFltTimeDelay': TextEditingController(text: '0'),
  };
  
  // Store full hex array for write operations
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
    // Dispose all text controllers
    for (final controller in _controllers.values) {
      controller.dispose();
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
      // First, extract all hex values to store the complete array
      _fullArrayHex.clear();
      
      // Parse all FIELD_X values in order (FIELD_1 to FIELD_96)
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
      
      // Parse FIELD_8 - each hex digit represents a value
      final field8Hex = _extractFieldHex(jsonLog, 'FIELD_8');
      if (field8Hex != null && field8Hex.length >= 4) {
        _levelChkEna = int.parse(field8Hex[0], radix: 16) == 1 ? 'Yes' : 'No';
        _votingChkEna = int.parse(field8Hex[1], radix: 16) == 1 ? 'Yes' : 'No';
        _autoAdjustEna = int.parse(field8Hex[2], radix: 16) == 1 ? 'Yes' : 'No';
        _unused = int.parse(field8Hex[3], radix: 16);
      }
      
      // Parse FIELD_9 - each hex digit represents a value (1=Yes/Disabled, 0=No/Enabled)
      final field9Hex = _extractFieldHex(jsonLog, 'FIELD_9');
      if (field9Hex != null && field9Hex.length >= 4) {
        _contDisable = int.parse(field9Hex[0], radix: 16) == 1 ? 'Yes' : 'No';
        _shortDisableSys = int.parse(field9Hex[1], radix: 16) == 1 ? 'Yes' : 'No';
        _fltDisable = int.parse(field9Hex[2], radix: 16) == 1 ? 'Yes' : 'No';
        _procFltDisable = int.parse(field9Hex[3], radix: 16) == 1 ? 'Yes' : 'No';
      }
      
      // Parse FIELD_10 - each hex digit represents a value
      final field10Hex = _extractFieldHex(jsonLog, 'FIELD_10');
      if (field10Hex != null && field10Hex.length >= 4) {
        _pwrFltDisable = int.parse(field10Hex[0], radix: 16) == 1 ? 'Yes' : 'No';
        // Map register values to display values: 1→0.5, 2→1, 3→2
        final sensValue = int.parse(field10Hex[1], radix: 16);
        if (sensValue == 1) {
          _sensitivity = '0.5';
        } else if (sensValue == 2) {
          _sensitivity = '1';
        } else if (sensValue == 3) {
          _sensitivity = '2';
        }
        _sel420SteamMode = int.parse(field10Hex[2], radix: 16) == 1 ? 'Yes' : 'No';
        _lastRmtAdr = int.parse(field10Hex[3], radix: 16);
        
        _controllers['lastRmtAdr']!.text = _lastRmtAdr.toString();
      }
      
      // Parse FIELD_11 - first 2 hex digits and last 2 hex digits
      final field11Hex = _extractFieldHex(jsonLog, 'FIELD_11');
      if (field11Hex != null && field11Hex.length >= 4) {
        _numGroundConnections = int.parse(field11Hex.substring(0, 2), radix: 16);
        _totalChannels = int.parse(field11Hex.substring(2, 4), radix: 16);
        
        _controllers['numGroundConnections']!.text = _numGroundConnections.toString();
        _controllers['totalChannels']!.text = _totalChannels.toString();
      }
      
      // Parse FIELD_63 - last 3 hex digits as decimal
      final field63Hex = _extractFieldHex(jsonLog, 'FIELD_63');
      if (field63Hex != null && field63Hex.length >= 3) {
        // Take last 3 digits (rightmost)
        final last3Digits = field63Hex.substring(field63Hex.length - 3);
        _sysFltTimeDelay = int.parse(last3Digits, radix: 16);
        _controllers['sysFltTimeDelay']!.text = _sysFltTimeDelay.toString();
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
      // Reset all values
      _levelChkEna = 'No';
      _votingChkEna = 'No';
      _autoAdjustEna = 'No';
      _unused = 0;
      _contDisable = 'No';
      _shortDisableSys = 'No';
      _fltDisable = 'No';
      _procFltDisable = 'No';
      _pwrFltDisable = 'No';
      _sensitivity = '0.5';
      _sel420SteamMode = 'No';
      _lastRmtAdr = 0;
      _numGroundConnections = 0;
      _totalChannels = 0;
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

      // Reconstruct FIELD_8 (index 7) from 4 hex digit values
      try {
        final f8_0 = (_levelChkEna == 'Yes' ? 1 : 0).toRadixString(16).toUpperCase().padLeft(1, '0');
        final f8_1 = (_votingChkEna == 'Yes' ? 1 : 0).toRadixString(16).toUpperCase().padLeft(1, '0');
        final f8_2 = (_autoAdjustEna == 'Yes' ? 1 : 0).toRadixString(16).toUpperCase().padLeft(1, '0');
        final f8_3 = _unused.toRadixString(16).toUpperCase().padLeft(1, '0');
        modifiedArray[7] = '$f8_0$f8_1$f8_2$f8_3';
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid value in FIELD_8')),
        );
        setState(() => _isWriting = false);
        return;
      }

      // Reconstruct FIELD_9 (index 8) from 4 hex digit values (Yes=1/Disabled, No=0/Enabled)
      try {
        final f9_0 = (_contDisable == 'Yes' ? 1 : 0).toRadixString(16).toUpperCase().padLeft(1, '0');
        final f9_1 = (_shortDisableSys == 'Yes' ? 1 : 0).toRadixString(16).toUpperCase().padLeft(1, '0');
        final f9_2 = (_fltDisable == 'Yes' ? 1 : 0).toRadixString(16).toUpperCase().padLeft(1, '0');
        final f9_3 = (_procFltDisable == 'Yes' ? 1 : 0).toRadixString(16).toUpperCase().padLeft(1, '0');
        modifiedArray[8] = '$f9_0$f9_1$f9_2$f9_3';
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid value in FIELD_9')),
        );
        setState(() => _isWriting = false);
        return;
      }

      // Reconstruct FIELD_10 (index 9) from 4 hex digit values
      try {
        final f10_0 = (_pwrFltDisable == 'Yes' ? 1 : 0).toRadixString(16).toUpperCase().padLeft(1, '0');
        // Map display values to register values: 0.5→1, 1→2, 2→3
        int sensRegValue = 1;
        if (_sensitivity == '0.5') {
          sensRegValue = 1;
        } else if (_sensitivity == '1') {
          sensRegValue = 2;
        } else if (_sensitivity == '2') {
          sensRegValue = 3;
        }
        final f10_1 = sensRegValue.toRadixString(16).toUpperCase().padLeft(1, '0');
        final f10_2 = (_sel420SteamMode == 'Yes' ? 1 : 0).toRadixString(16).toUpperCase().padLeft(1, '0');
        final f10_3 = int.parse(_controllers['lastRmtAdr']!.text.trim()).toRadixString(16).toUpperCase().padLeft(1, '0');
        modifiedArray[9] = '$f10_0$f10_1$f10_2$f10_3';
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid value in FIELD_10')),
        );
        setState(() => _isWriting = false);
        return;
      }

      // Update FIELD_12 and FIELD_13 (indices 11 and 12) based on sensitivity selection
      try {
        int field12Value, field13Value;
        if (_sensitivity == '0.5') {
          field12Value = 655;  // 0x28F
          field13Value = 651;  // 0x28B
        } else if (_sensitivity == '1') {
          field12Value = 665;  // 0x299
          field13Value = 660;  // 0x294
        } else {  // '2'
          field12Value = 420;  // 0x1A4
          field13Value = 415;  // 0x19F
        }
        modifiedArray[11] = field12Value.toRadixString(16).toUpperCase().padLeft(4, '0');
        modifiedArray[12] = field13Value.toRadixString(16).toUpperCase().padLeft(4, '0');
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to update FIELD_12 and FIELD_13')),
        );
        setState(() => _isWriting = false);
        return;
      }

      // Reconstruct FIELD_11 (index 10) from 2 hex values (2 digits each)
      try {
        final f11_0 = int.parse(_controllers['numGroundConnections']!.text.trim()).toRadixString(16).toUpperCase().padLeft(2, '0');
        final f11_1 = int.parse(_controllers['totalChannels']!.text.trim()).toRadixString(16).toUpperCase().padLeft(2, '0');
        modifiedArray[10] = '$f11_0$f11_1';
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid value in FIELD_11')),
        );
        setState(() => _isWriting = false);
        return;
      }

      // Reconstruct FIELD_63 (index 62) - update last 3 digits while preserving first digit
      try {
        final currentField63 = modifiedArray[62];
        final decValue = int.parse(_controllers['sysFltTimeDelay']!.text.trim());
        final hexValue = decValue.toRadixString(16).toUpperCase().padLeft(3, '0');
        
        // Preserve the first digit if field has 4 digits, otherwise just use the 3 digits
        if (currentField63.length >= 4) {
          final firstDigit = currentField63[0];
          modifiedArray[62] = '$firstDigit$hexValue';
        } else {
          modifiedArray[62] = hexValue;
        }
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid value in System Fault Time Delay')),
        );
        setState(() => _isWriting = false);
        return;
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

  Widget _buildConfigItem(String label, String controllerKey, {Color color = const Color(0xFF00E5FF)}) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: color.withOpacity(0.3),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
              ),
            ),
          ),
          Container(
            width: 80,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: color.withOpacity(0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: TextField(
              controller: _controllers[controllerKey],
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: color,
                fontSize: 18,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
              ),
              decoration: const InputDecoration(
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 6),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDropdownItem(String label, String currentValue, Function(String?) onChanged, {Color color = const Color(0xFF00E5FF)}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: color.withOpacity(0.3),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: color.withOpacity(0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: DropdownButton<String>(
              value: currentValue,
              dropdownColor: const Color(0xFF1A1A2E),
              underline: const SizedBox(),
              style: TextStyle(
                color: color,
                fontSize: 18,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
              ),
              items: ['Yes', 'No'].map((String value) {
                return DropdownMenuItem<String>(
                  value: value,
                  child: Text(value),
                );
              }).toList(),
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSensitivityDropdown() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFF4CAF50).withOpacity(0.3),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Expanded(
            child: Text(
              'SENSITIVITY',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 13,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF4CAF50).withOpacity(0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: DropdownButton<String>(
              value: _sensitivity,
              dropdownColor: const Color(0xFF1A1A2E),
              underline: const SizedBox(),
              style: const TextStyle(
                color: Color(0xFF4CAF50),
                fontSize: 18,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
              ),
              items: ['0.5', '1', '2'].map((String value) {
                return DropdownMenuItem<String>(
                  value: value,
                  child: Text(value),
                );
              }).toList(),
              onChanged: (value) {
                setState(() => _sensitivity = value!);
              },
            ),
          ),
        ],
      ),
    );
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
                  : const Icon(Icons.settings, color: Colors.black, size: 20),
              label: Text(
                _isLoading ? 'Sending ?0001!...' : 'Load Config (?0001!)',
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
          
          // Configuration items
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(
                      color: Color(0xFF00E5FF),
                    ),
                  )
                : ListView(
                    children: [
                      // FIELD_8 Section
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8, top: 4),
                        child: Text(
                          'FIELD 8 - System Checks',
                          style: TextStyle(
                            color: Color(0xFF00E5FF),
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      _buildDropdownItem('LEVEL CHK ENA', _levelChkEna, (value) {
                        setState(() => _levelChkEna = value!);
                      }),
                      const SizedBox(height: 8),
                      _buildDropdownItem('VOTING CHK ENA', _votingChkEna, (value) {
                        setState(() => _votingChkEna = value!);
                      }),
                      const SizedBox(height: 8),
                      _buildDropdownItem('AUTO ADJUST ENA', _autoAdjustEna, (value) {
                        setState(() => _autoAdjustEna = value!);
                      }),
                      
                      const SizedBox(height: 20),
                      
                      // FIELD_9 Section
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8, top: 4),
                        child: Text(
                          'FIELD 9 - Disable Flags',
                          style: TextStyle(
                            color: Color(0xFFFF6B35),
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      _buildDropdownItem('CONT DISABLE', _contDisable, (value) {
                        setState(() => _contDisable = value!);
                      }, color: const Color(0xFFFF6B35)),
                      const SizedBox(height: 8),
                      _buildDropdownItem('SHORT DISABLE', _shortDisableSys, (value) {
                        setState(() => _shortDisableSys = value!);
                      }, color: const Color(0xFFFF6B35)),
                      const SizedBox(height: 8),
                      _buildDropdownItem('SYS FLT DISABLE', _fltDisable, (value) {
                        setState(() => _fltDisable = value!);
                      }, color: const Color(0xFFFF6B35)),
                      const SizedBox(height: 8),
                      _buildDropdownItem('PROC FLT DISABLE', _procFltDisable, (value) {
                        setState(() => _procFltDisable = value!);
                      }, color: const Color(0xFFFF6B35)),
                      
                      const SizedBox(height: 20),
                      
                      // FIELD_10 Section
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8, top: 4),
                        child: Text(
                          'FIELD 10 - System Settings',
                          style: TextStyle(
                            color: Color(0xFF4CAF50),
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      _buildDropdownItem('PWR FLT DISABLE', _pwrFltDisable, (value) {
                        setState(() => _pwrFltDisable = value!);
                      }, color: const Color(0xFF4CAF50)),
                      const SizedBox(height: 8),
                      _buildSensitivityDropdown(),
                      const SizedBox(height: 8),
                      _buildDropdownItem('4 - 20 STEAM MODE', _sel420SteamMode, (value) {
                        setState(() => _sel420SteamMode = value!);
                      }, color: const Color(0xFF4CAF50)),
                      const SizedBox(height: 8),
                      _buildConfigItem('LAST RMT ADR', 'lastRmtAdr', color: const Color(0xFF4CAF50)),
                      
                      const SizedBox(height: 20),
                      
                      // FIELD_11 Section
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8, top: 4),
                        child: Text(
                          'FIELD 11 - Connection Info',
                          style: TextStyle(
                            color: Color(0xFFFFEB3B),
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      _buildConfigItem('NUMBER OF GROUND CONNECTIONS', 'numGroundConnections', color: const Color(0xFFFFEB3B)),
                      const SizedBox(height: 8),
                      _buildConfigItem('TOTAL NUMBER OF CHANNELS', 'totalChannels', color: const Color(0xFFFFEB3B)),
                      
                      const SizedBox(height: 20),
                      
                      // FIELD_63 Section
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8, top: 4),
                        child: Text(
                          'FIELD 63 - Fault Timing',
                          style: TextStyle(
                            color: Color(0xFFFF6B35),
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      _buildConfigItem('SYSTEM FAULT TIME DELAY', 'sysFltTimeDelay', color: const Color(0xFFFF6B35)),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
