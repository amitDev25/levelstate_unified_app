import 'dart:async';
import 'package:flutter/material.dart';
import 'main.dart';

class AdminFragment extends StatefulWidget {
  final BLEManager bleManager;
  
  const AdminFragment({super.key, required this.bleManager});

  @override
  State<AdminFragment> createState() => _AdminFragmentState();
}

class _AdminFragmentState extends State<AdminFragment> {
  Map<String, String> _values = {
    '4mA Channel 1 Value': '---',
    '20mA Channel 1 Value': '---',
    '4mA Channel 2 Value': '---',
    '20mA Channel 2 Value': '---',
    'Steam Level': '---',
    'Water Level': '---',
    'Short Level': '---',
  };
  
  // Text controllers for editable fields
  final Map<String, TextEditingController> _controllers = {
    '4mA Channel 1 Value': TextEditingController(text: '---'),
    '20mA Channel 1 Value': TextEditingController(text: '---'),
    '4mA Channel 2 Value': TextEditingController(text: '---'),
    '20mA Channel 2 Value': TextEditingController(text: '---'),
    'Steam Level': TextEditingController(text: '---'),
    'Water Level': TextEditingController(text: '---'),
    'Short Level': TextEditingController(text: '---'),
  };
  
  List<String> _fullArrayHex = []; // Store complete hex array from response
  bool _isLoading = false;
  bool _isWriting = false;
  bool _isResetting = false;
  bool _is4mAMode = false;
  bool _is20mAMode = false;
  int _lastLogCount = 0;
  
  // Define which fields belong to which mode
  final List<String> _4mAFields = ['4mA Channel 1 Value', '4mA Channel 2 Value'];
  final List<String> _20mAFields = ['20mA Channel 1 Value', '20mA Channel 2 Value'];
  final List<String> _alwaysEditableFields = ['Water Level', 'Steam Level', 'Short Level'];

  @override
  void initState() {
    super.initState();
    widget.bleManager.addListener(_onBLEUpdate);
    _lastLogCount = widget.bleManager.logs.length;
    
    // Auto-send command when tab is opened
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
      
      // Now extract and populate the 7 editable fields
      // Looking for: FIELD_3 (4mA Channel 1 Value), FIELD_4 (20mA Channel 1 Value), FIELD_5 (4mA Channel 2 Value), FIELD_6 (20mA Channel 2 Value),
      //              FIELD_11 (Steam Level), FIELD_12 (Water Level), FIELD_13 (Short Level)
      final fieldMap = {
        '4mA Channel 1 Value': 'FIELD_4',
        '20mA Channel 1 Value': 'FIELD_5',
        '4mA Channel 2 Value': 'FIELD_6',
        '20mA Channel 2 Value': 'FIELD_7',
        'Steam Level': 'FIELD_12',
        'Water Level': 'FIELD_13',
        'Short Level': 'FIELD_14',
      };
      
      for (final entry in fieldMap.entries) {
        final label = entry.key;
        final fieldName = entry.value;
        final pattern = '"$fieldName": "';
        
        final startIndex = jsonLog.indexOf(pattern);
        if (startIndex != -1) {
          final valueStart = startIndex + pattern.length;
          final valueEnd = jsonLog.indexOf('"', valueStart);
          if (valueEnd != -1) {
            try {
              final hexValue = jsonLog.substring(valueStart, valueEnd);
              // Look for decimal value in parentheses
              final decPattern = '(Dec: ';
              final decStart = jsonLog.indexOf(decPattern, valueEnd);
              if (decStart != -1) {
                final decValueStart = decStart + decPattern.length;
                final decValueEnd = jsonLog.indexOf(')', decValueStart);
                if (decValueEnd != -1) {
                  final decValue = jsonLog.substring(decValueStart, decValueEnd);
                  _values[label] = decValue;
                  _controllers[label]!.text = decValue;
                  continue;
                }
              }
              // Fallback: parse hex manually
              final cleanHex = hexValue.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
              final decValue = int.parse(cleanHex, radix: 16);
              final decStr = decValue.toString();
              _values[label] = decStr;
              _controllers[label]!.text = decStr;
            } catch (e) {
              _values[label] = 'Error';
              _controllers[label]!.text = 'Error';
            }
          } else {
            _values[label] = '---';
            _controllers[label]!.text = '---';
          }
        } else {
          _values[label] = '---';
          _controllers[label]!.text = '---';
        }
      }
      
      _isLoading = false;
    });
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
      _values = {
        '4mA Channel 1 Value': 'Wait...',
        '20mA Channel 1 Value': 'Wait...',
        '4mA Channel 2 Value': 'Wait...',
        '20mA Channel 2 Value': 'Wait...',
        'Steam Level': 'Wait...',
        'Water Level': 'Wait...',
        'Short Level': 'Wait...',
      };
    });

    await widget.bleManager.sendString('?0001!');
    
    Future.delayed(const Duration(seconds: 15), () {
      if (_isLoading && mounted) {
        setState(() {
          _isLoading = false;
          _values = {
            '4mA Channel 1 Value': 'Timeout',
            '20mA Channel 1 Value': 'Timeout',
            '4mA Channel 2 Value': 'Timeout',
            '20mA Channel 2 Value': 'Timeout',
            'Steam Level': 'Timeout',
            'Water Level': 'Timeout',
            'Short Level': 'Timeout',
          };
        });
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

      // Update the 7 editable fields with values from controllers
      // Map: label -> (field index in array, which is field number - 1)
      final editableFields = {
        '4mA Channel 1 Value': 3,   // FIELD_4 is at index 3
        '20mA Channel 1 Value': 4,   // FIELD_5 is at index 4
        '4mA Channel 2 Value': 5,   // FIELD_6 is at index 5
        '20mA Channel 2 Value': 6,   // FIELD_7 is at index 6
        'Steam Level': 11, // FIELD_12 is at index 11
        'Water Level': 12, // FIELD_13 is at index 12
        'Short Level': 13, // FIELD_14 is at index 13
      };

      // Update the array with edited values
      for (final entry in editableFields.entries) {
        final label = entry.key;
        final arrayIndex = entry.value;
        final controller = _controllers[label];

        if (controller != null && controller.text.isNotEmpty) {
          try {
            // Parse the decimal value from the text field
            final decValue = int.parse(controller.text.trim());
            // Convert to hex (uppercase, 4 digits with leading zeros)
            final hexValue = decValue.toRadixString(16).toUpperCase().padLeft(4, '0');
            modifiedArray[arrayIndex] = hexValue;
          } catch (e) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Invalid value in ${entry.key} field')),
            );
            setState(() {
              _isWriting = false;
            });
            return;
          }
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

      // Safety timeout: close dialog after 30 seconds
      final timeoutTimer = Timer(const Duration(seconds: 30), () {
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
            const SnackBar(content: Text('Write successful! Sent ?0002! and ?0005!')),
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

  void _factoryReset() async {
    if (!widget.bleManager.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not connected to device')),
      );
      return;
    }

    // Show confirmation dialog
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text(
          'Factory Reset',
          style: TextStyle(color: Colors.redAccent),
        ),
        content: const Text(
          'This will reset the device to factory settings. Are you sure?',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.white54),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
            ),
            child: const Text('Reset'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() {
      _isResetting = true;
    });

    try {
      // Send ?0004! command
      await widget.bleManager.sendString('?0004!');
      
      // Wait 3 seconds
      await Future.delayed(const Duration(seconds: 3));
      
      // Send ?0005! command
      await widget.bleManager.sendString('?0005!');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Factory reset commands sent successfully!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Factory reset failed: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isResetting = false;
        });
      }
    }
  }

  void _toggle4mAMode() async {
    if (!widget.bleManager.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not connected to device')),
      );
      return;
    }

    setState(() {
      _is4mAMode = !_is4mAMode;
      if (_is4mAMode) {
        _is20mAMode = false; // Turn off 20mA mode if it was on
      }
    });

    if (_is4mAMode) {
      try {
        await widget.bleManager.sendString('?0006!');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('4mA mode enabled - Sent ?0006!')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to enable 4mA mode: $e')),
          );
        }
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('4mA mode disabled')),
        );
      }
    }
  }

  void _toggle20mAMode() async {
    if (!widget.bleManager.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not connected to device')),
      );
      return;
    }

    setState(() {
      _is20mAMode = !_is20mAMode;
      if (_is20mAMode) {
        _is4mAMode = false; // Turn off 4mA mode if it was on
      }
    });

    if (_is20mAMode) {
      try {
        await widget.bleManager.sendString('?0007!');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('20mA mode enabled - Sent ?0007!')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to enable 20mA mode: $e')),
          );
        }
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('20mA mode disabled')),
        );
      }
    }
  }

  void _normalMode() async {
    if (!widget.bleManager.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not connected to device')),
      );
      return;
    }

    try {
      await widget.bleManager.sendString('?0008!');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Normal mode - Sent ?0008!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to send normal mode command: $e')),
        );
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
          // Mode buttons row
          Row(
            children: [
              // 4mA toggle button
              Expanded(
                child: ElevatedButton(
                  onPressed: widget.bleManager.isConnected
                      ? _toggle4mAMode
                      : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _is4mAMode
                        ? Colors.greenAccent
                        : const Color(0xFF1A1A2E),
                    foregroundColor: _is4mAMode ? Colors.black : Colors.white54,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: BorderSide(
                        color: _is4mAMode
                            ? Colors.greenAccent
                            : Colors.white24,
                      ),
                    ),
                  ),
                  child: Text(
                    '4mA',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      color: _is4mAMode ? Colors.black : Colors.white54,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // 20mA toggle button
              Expanded(
                child: ElevatedButton(
                  onPressed: widget.bleManager.isConnected
                      ? _toggle20mAMode
                      : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _is20mAMode
                        ? Colors.greenAccent
                        : const Color(0xFF1A1A2E),
                    foregroundColor: _is20mAMode ? Colors.black : Colors.white54,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: BorderSide(
                        color: _is20mAMode
                            ? Colors.greenAccent
                            : Colors.white24,
                      ),
                    ),
                  ),
                  child: Text(
                    '20mA',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      color: _is20mAMode ? Colors.black : Colors.white54,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Normal button
              Expanded(
                child: ElevatedButton(
                  onPressed: widget.bleManager.isConnected
                      ? _normalMode
                      : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFF9800),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Text(
                    'Normal',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            ],
          ),
          
          const SizedBox(height: 16),
          
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
                  : const Icon(Icons.send, color: Colors.black, size: 20),
              label: Text(
                _isLoading ? 'Sending ?0001!...' : 'Send ?0001!',
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
          
          const SizedBox(height: 12),
          
          // Factory Reset button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: widget.bleManager.isConnected && !_isResetting
                  ? _factoryReset
                  : null,
              icon: _isResetting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.restore, color: Colors.white, size: 20),
              label: Text(
                _isResetting ? 'Resetting...' : 'Factory Reset',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
          
          const SizedBox(height: 20),
          
          // Values in two separate cards
          Expanded(
            child: ListView(
              children: [
                // Card 1: Water Level, Steam Level, and Short Level
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A2E),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: const Color(0xFF00E5FF).withOpacity(0.3),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Level Settings',
                        style: TextStyle(
                          color: Color(0xFF00E5FF),
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: _buildEditableField(
                              'Water Level',
                              _alwaysEditableFields.contains('Water Level'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildEditableField(
                              'Steam Level',
                              _alwaysEditableFields.contains('Steam Level'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildEditableField(
                              'Short Level',
                              _alwaysEditableFields.contains('Short Level'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                
                const SizedBox(height: 16),
                
                // Card 2: Channel Calibration
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A2E),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: const Color(0xFF00E5FF).withOpacity(0.3),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Channel Calibration',
                        style: TextStyle(
                          color: Color(0xFF00E5FF),
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 16),
                      GridView.count(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        crossAxisCount: 2,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: 1.3,
                        children: [
                          _buildEditableField(
                            '4mA Channel 1 Value',
                            _is4mAMode && _4mAFields.contains('4mA Channel 1 Value'),
                          ),
                          _buildEditableField(
                            '20mA Channel 1 Value',
                            _is20mAMode && _20mAFields.contains('20mA Channel 1 Value'),
                          ),
                          _buildEditableField(
                            '4mA Channel 2 Value',
                            _is4mAMode && _4mAFields.contains('4mA Channel 2 Value'),
                          ),
                          _buildEditableField(
                            '20mA Channel 2 Value',
                            _is20mAMode && _20mAFields.contains('20mA Channel 2 Value'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildEditableField(String label, bool isEditable) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0D0D1A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isEditable
              ? const Color(0xFF00E5FF).withOpacity(0.6)
              : const Color(0xFF00E5FF).withOpacity(0.2),
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isEditable ? Colors.white : Colors.white54,
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _controllers[label],
            enabled: isEditable,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isEditable
                  ? const Color(0xFF00E5FF)
                  : Colors.white38,
              fontSize: 20,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
            ),
            decoration: const InputDecoration(
              border: InputBorder.none,
              isDense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
    );
  }
}
