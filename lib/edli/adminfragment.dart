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
  
  Map<int, int> _registerData = {}; // Store register number -> value
  bool _isLoading = false;
  bool _isWriting = false;
  bool _isSaving = false;
  bool _isResetting = false;
  bool _is4mAMode = false;
  bool _is20mAMode = false;
  
  // Define which fields belong to which mode
  final List<String> _4mAFields = ['4mA Channel 1 Value', '4mA Channel 2 Value'];
  final List<String> _20mAFields = ['20mA Channel 1 Value', '20mA Channel 2 Value'];
  final List<String> _alwaysEditableFields = ['Water Level', 'Steam Level', 'Short Level'];

  @override
  void initState() {
    super.initState();
    widget.bleManager.addListener(_onBLEUpdate);
    
    // Set up Modbus response callback
    widget.bleManager.onModbusResponse = _handleModbusResponse;
    
    // Auto-send command when tab is opened (only if not checking activation)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.bleManager.isConnected && 
          !widget.bleManager.isCheckingActivation &&
          widget.bleManager.isDeviceActivated) {
        _sendCommand();
      }
    });
  }

  @override
  void dispose() {
    widget.bleManager.removeListener(_onBLEUpdate);
    widget.bleManager.onModbusResponse = null;
    // Dispose all text controllers
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _onBLEUpdate() {
    if (!mounted) return;
    setState(() {});
  }
  
  void _handleModbusResponse() {
    if (!mounted || !_isLoading) return;
    
    final response = widget.bleManager.lastModbusResponse;
    
    // Check if this is a read response (FC 3)
    if (response.length < 2 || response[1] != 0x03) {
      // Not a read response, ignore it
      return;
    }
    
    // Check byte count - we expect 22 bytes (11 registers * 2 bytes each)
    // This filters out register 0 poll responses which only have 2 bytes
    if (response.length < 3 || response[2] != 22) {
      // Not the main data read, ignore it
      return;
    }
    
    final values = widget.bleManager.parseReadResponse(response);
    
    if (values.isEmpty) {
      setState(() {
        _isLoading = false;
      });
      return;
    }
    
    // We read registers 5-15 (11 registers)
    // Store in _registerData map
    setState(() {
      for (int i = 0; i < values.length; i++) {
        _registerData[5 + i] = values[i];
      }
      
      // Update display values from registers
      // Register mapping: Field N → Register (N+1)
      _updateValueFromRegister('4mA Channel 1 Value', 5);    // FIELD_4 → Reg 5
      _updateValueFromRegister('20mA Channel 1 Value', 6);   // FIELD_5 → Reg 6
      _updateValueFromRegister('4mA Channel 2 Value', 7);    // FIELD_6 → Reg 7
      _updateValueFromRegister('20mA Channel 2 Value', 8);   // FIELD_7 → Reg 8
      _updateValueFromRegister('Steam Level', 13);           // FIELD_12 → Reg 13
      _updateValueFromRegister('Water Level', 14);           // FIELD_13 → Reg 14
      _updateValueFromRegister('Short Level', 15);           // FIELD_14 → Reg 15
      
      _isLoading = false;
    });
  }
  
  void _updateValueFromRegister(String label, int register) {
    if (_registerData.containsKey(register)) {
      final value = _registerData[register]!;
      _values[label] = value.toString();
      _controllers[label]!.text = value.toString();
    } else {
      _values[label] = 'Error';
      _controllers[label]!.text = 'Error';
    }
  }

  // Helper method to poll register 0 until it becomes 0
  Future<bool> _waitForRegister0ToBeZero({int maxAttempts = 30, int delayMs = 200}) async {
    for (int i = 0; i < maxAttempts; i++) {
      await Future.delayed(Duration(milliseconds: delayMs));
      
      // Read register 0
      await widget.bleManager.readRegisters(startRegister: 0, quantity: 1);
      
      // Wait a bit for response
      await Future.delayed(const Duration(milliseconds: 100));
      
      // Check the response
      final response = widget.bleManager.lastModbusResponse;
      if (response.length >= 5 && response[1] == 0x03) {
        final values = widget.bleManager.parseReadResponse(response);
        if (values.isNotEmpty && values[0] == 0) {
          return true; // Register 0 is now 0, device is ready
        }
      }
    }
    return false; // Timeout
  }

  void _sendCommand() async {
    if (!widget.bleManager.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not connected to device')),
      );
      return;
    }

    // Re-register callback in case another fragment overwrote it
    widget.bleManager.onModbusResponse = _handleModbusResponse;

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

    // Write 1 to register 0 before reading
    await widget.bleManager.writeRegisters(startRegister: 0, values: [1]);
    
    // Poll register 0 until it becomes 0 (device ready)
    final ready = await _waitForRegister0ToBeZero();
    if (!ready) {
      if (mounted) {
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Device not ready, timeout waiting for register 0')),
        );
      }
      return;
    }

    // Re-register callback after polling
    widget.bleManager.onModbusResponse = _handleModbusResponse;
    
    // Read registers 5-15 (11 registers) for all admin fields
    await widget.bleManager.readRegisters(startRegister: 5, quantity: 11);
    
    Future.delayed(const Duration(seconds: 5), () {
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

    setState(() {
      _isWriting = true;
    });

    try {
      // Prepare register values from controllers
      final registerWrites = <int, int>{};
      
      final fieldMap = {
        '4mA Channel 1 Value': 5,
        '20mA Channel 1 Value': 6,
        '4mA Channel 2 Value': 7,
        '20mA Channel 2 Value': 8,
        'Steam Level': 13,
        'Water Level': 14,
        'Short Level': 15,
      };

      // Parse all values
      for (final entry in fieldMap.entries) {
        final label = entry.key;
        final register = entry.value;
        final controller = _controllers[label];

        if (controller != null && controller.text.isNotEmpty) {
          try {
            final value = int.parse(controller.text.trim());
            if (value < 0 || value > 65535) {
              throw FormatException('Value out of range');
            }
            registerWrites[register] = value;
          } catch (e) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Invalid value in $label field')),
            );
            setState(() {
              _isWriting = false;
            });
            return;
          }
        }
      }

      if (registerWrites.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No values to write')),
        );
        setState(() {
          _isWriting = false;
        });
        return;
      }

      // Write registers 5-8 (4mA/20mA channels)
      if (registerWrites.containsKey(5) || registerWrites.containsKey(6) || 
          registerWrites.containsKey(7) || registerWrites.containsKey(8)) {
        final values = [
          registerWrites[5] ?? _registerData[5] ?? 0,
          registerWrites[6] ?? _registerData[6] ?? 0,
          registerWrites[7] ?? _registerData[7] ?? 0,
          registerWrites[8] ?? _registerData[8] ?? 0,
        ];
        await widget.bleManager.writeRegisters(startRegister: 5, values: values);
        await Future.delayed(const Duration(milliseconds: 200));
      }

      // Write registers 13-15 (levels)
      if (registerWrites.containsKey(13) || registerWrites.containsKey(14) || 
          registerWrites.containsKey(15)) {
        final values = [
          registerWrites[13] ?? _registerData[13] ?? 0,
          registerWrites[14] ?? _registerData[14] ?? 0,
          registerWrites[15] ?? _registerData[15] ?? 0,
        ];
        await widget.bleManager.writeRegisters(startRegister: 13, values: values);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Write successful! Data committed.')),
        );
        
        // Write 2 to register 0 to commit
        await widget.bleManager.writeRegisters(startRegister: 0, values: [2]);
        
        // Temporarily disable callback during polling
        widget.bleManager.onModbusResponse = null;
        
        // Poll register 0 until it becomes 0 (device ready)
        final ready = await _waitForRegister0ToBeZero();
        if (!ready) {
          if (mounted) {
            setState(() {
              _isWriting = false;
            });
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Write timeout - device not ready')),
            );
          }
          widget.bleManager.onModbusResponse = _handleModbusResponse;
          return;
        }
        
        // Re-register callback after polling
        widget.bleManager.onModbusResponse = _handleModbusResponse;
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Data committed. Press Save to finalize.')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Write failed: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isWriting = false;
        });
      }
    }
  }

  void _saveCommand() async {
    if (!widget.bleManager.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not connected to device')),
      );
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      // Write 5 to register 0 to finalize/save
      await widget.bleManager.writeRegisters(startRegister: 0, values: [5]);
      
      // Temporarily disable callback during polling
      widget.bleManager.onModbusResponse = null;
      
      // Poll register 0 until it becomes 0 (device ready)
      final ready = await _waitForRegister0ToBeZero();
      if (!ready) {
        if (mounted) {
          setState(() {
            _isSaving = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Save timeout - device not ready')),
          );
        }
        widget.bleManager.onModbusResponse = _handleModbusResponse;
        return;
      }
      
      // Re-register callback after polling
      widget.bleManager.onModbusResponse = _handleModbusResponse;
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Configuration saved to device!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
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
      // Write 4 to register 0 for factory reset
      await widget.bleManager.writeRegisters(startRegister: 0, values: [4]);
      
      // Poll register 0 until it becomes 0 (reset complete)
      final ready = await _waitForRegister0ToBeZero();
      if (!ready) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Timeout waiting for factory reset to complete')),
          );
        }
        return;
      }
      
      // Write 5 to register 0 to finalize
      await widget.bleManager.writeRegisters(startRegister: 0, values: [5]);
      
      // Temporarily disable callback during polling
      widget.bleManager.onModbusResponse = null;
      
      // Poll register 0 until it becomes 0 (device ready)
      final readyFinal = await _waitForRegister0ToBeZero();
      if (!readyFinal) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Timeout waiting for finalization')),
          );
        }
        widget.bleManager.onModbusResponse = _handleModbusResponse;
        return;
      }
      
      // Re-register callback after polling
      widget.bleManager.onModbusResponse = _handleModbusResponse;

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Factory reset completed successfully!')),
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
        // Write 6 to register 0 for 4mA calibration mode
        await widget.bleManager.writeRegisters(startRegister: 0, values: [6]);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('4mA calibration mode enabled')),
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
        // Write 7 to register 0 for 20mA calibration mode
        await widget.bleManager.writeRegisters(startRegister: 0, values: [7]);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('20mA calibration mode enabled')),
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
      // Write 8 to register 0 for normal mode
      await widget.bleManager.writeRegisters(startRegister: 0, values: [8]);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Normal mode enabled')),
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
                _isLoading ? 'Loading Admin Data...' : 'Load Admin Data',
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
              onPressed: widget.bleManager.isConnected && !_isWriting && _registerData.isNotEmpty
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
                _isWriting ? 'Writing...' : 'Write to Device',
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
          
          // Save button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: widget.bleManager.isConnected && !_isSaving
                  ? _saveCommand
                  : null,
              icon: _isSaving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.black,
                      ),
                    )
                  : const Icon(Icons.save, color: Colors.black, size: 20),
              label: Text(
                _isSaving ? 'Saving...' : 'Save Configuration',
                style: const TextStyle(
                  color: Colors.black,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4CAF50),
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
