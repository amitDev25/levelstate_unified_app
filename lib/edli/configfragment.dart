import 'dart:async';
import 'package:flutter/material.dart';
import 'main.dart';

class ConfigFragment extends StatefulWidget {
  final BLEManager bleManager;
  final String deviceDisplayName;

  const ConfigFragment({
    super.key,
    required this.bleManager,
    required this.deviceDisplayName,
  });

  @override
  State<ConfigFragment> createState() => _ConfigFragmentState();
}

class _ConfigFragmentState extends State<ConfigFragment> {
  bool get _showSteamModeOption {
    final name = widget.deviceDisplayName.trim().toUpperCase();
    return name != 'ELS' && name != 'ELS (8 CHANNEL)';
  }

  // FIELD_8 (Register 9) - Dropdown fields (1=Yes, 0=No)
  String _levelChkEna = 'No';
  String _votingChkEna = 'No';
  String _autoAdjustEna = 'No';
  
  // FIELD_9 (Register 10) - Disable flags (1=Yes/Disabled, 0=No/Enabled)
  String _contDisable = 'No';  // No means enabled (not disabled)
  String _shortDisableSys = 'No';  // No means enabled (not disabled)
  String _fltDisable = 'No';  // No means enabled (not disabled)
  String _procFltDisable = 'No';  // No means enabled (not disabled)
  
  // FIELD_10 (Register 11)
  String _pwrFltDisable = 'No';  // No means enabled (not disabled)
  String _sensitivity = '0.5';  // Dropdown: 0.5, 1, 2 (writes 1, 2, 3 respectively)
  bool _enableSensitivityWrite = false;
  String _sel420SteamMode = 'No';
  int _lastRmtAdr = 0;
  
  // FIELD_11 (Register 12) - Ground connection number + interlock channel
  int _groundConnectionNumber = 0;
  int _interlockControlChannel = 0;
  
  // FIELD_63 (Register 64) - System Fault Time Delay
  int _sysFltTimeDelay = 0;
  
  // Text controllers for numeric fields only
  final Map<String, TextEditingController> _controllers = {
    'lastRmtAdr': TextEditingController(text: '0'),
    'interlockControlEnable': TextEditingController(text: '0'),
    'interlockControlChannel': TextEditingController(text: '0'),
    'sysFltTimeDelay': TextEditingController(text: '0'),
  };
  
  // Store register data for Modbus operations
  Map<int, int> _registerData = {};
  
  bool _isLoading = false;
  bool _isWriting = false;
  bool _isSaving = false;
  bool _writeCompleted = false;  // Track if write was done, to enable save button
  Timer? _timeoutTimer;
  
  // Track which responses we've received during a read operation
  bool _receivedConfigRegs = false;
  bool _receivedReg64 = false;
  bool _awaitingConfigRegsResponse = false;
  bool _awaitingReg64Response = false;

  @override
  void initState() {
    super.initState();
    widget.bleManager.addListener(_onBLEUpdate);
    
    // Auto-send read command when the fragment is opened (only if not checking activation)
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (widget.bleManager.isConnected && 
          !widget.bleManager.isCheckingActivation &&
          widget.bleManager.isDeviceActivated) {
        // Set up Modbus response callback
        widget.bleManager.onModbusResponse = _handleModbusResponse;
        // Small delay to ensure callback is ready
        await Future.delayed(const Duration(milliseconds: 100));
        _sendCommand();
      }
    });
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
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
      return;
    }
    
    final values = widget.bleManager.parseReadResponse(response);
    if (values.isEmpty) {
      setState(() {
        _isLoading = false;
      });
      return;
    }
    
    // Parse the config registers (9-12 = 4 registers = 8 bytes)
    // or FIELD_63 (register 64 = 1 register = 2 bytes)
    if (response.length >= 3) {
      final byteCount = response[2];
      
      if (byteCount == 8 && _awaitingConfigRegsResponse) {
        _awaitingConfigRegsResponse = false;
        _parseConfigRegisters(values);
        return;
      }
      
      if (byteCount == 2 && values.length == 1 && _awaitingReg64Response) {
        _awaitingReg64Response = false;
        _parseField63Register(values[0]);
        return;
      }
    }
  }
  
  void _parseConfigRegisters(List<int> values) {
    setState(() {
      // Store registers 9-12
      for (int i = 0; i < values.length && i < 4; i++) {
        _registerData[9 + i] = values[i];
      }
      
      // Parse FIELD_8 (Register 9) - bit-packed nibbles
      if (_registerData.containsKey(9)) {
        final reg9 = _registerData[9]!;
        _levelChkEna = ((reg9 >> 12) & 0xF) == 1 ? 'Yes' : 'No';
        _votingChkEna = ((reg9 >> 8) & 0xF) == 1 ? 'Yes' : 'No';
        _autoAdjustEna = ((reg9 >> 4) & 0xF) == 1 ? 'Yes' : 'No';
        // Ignore unused nibble at (reg9 & 0xF)
      }
      
      // Parse FIELD_9 (Register 10) - bit-packed nibbles
      if (_registerData.containsKey(10)) {
        final reg10 = _registerData[10]!;
        _contDisable = ((reg10 >> 12) & 0xF) == 1 ? 'Yes' : 'No';
        _shortDisableSys = ((reg10 >> 8) & 0xF) == 1 ? 'Yes' : 'No';
        _fltDisable = ((reg10 >> 4) & 0xF) == 1 ? 'Yes' : 'No';
        _procFltDisable = (reg10 & 0xF) == 1 ? 'Yes' : 'No';
      }
      
      // Parse FIELD_10 (Register 11) - bit-packed nibbles
      if (_registerData.containsKey(11)) {
        final reg11 = _registerData[11]!;
        _pwrFltDisable = ((reg11 >> 12) & 0xF) == 1 ? 'Yes' : 'No';
        
        // Map register values to display values: 1→0.5, 2→1, 3→2
        final sensValue = (reg11 >> 8) & 0xF;
        if (sensValue == 1) {
          _sensitivity = '0.5';
        } else if (sensValue == 2) {
          _sensitivity = '1';
        } else if (sensValue == 3) {
          _sensitivity = '2';
        }
        
        _sel420SteamMode = ((reg11 >> 4) & 0xF) == 1 ? 'Yes' : 'No';
        _lastRmtAdr = reg11 & 0xF;
        _controllers['lastRmtAdr']!.text = _lastRmtAdr.toString();
      }
      
      // Parse FIELD_11 (Register 12) - Ground connection number + interlock channel
      if (_registerData.containsKey(12)) {
        final reg12 = _registerData[12]!;
        _groundConnectionNumber = (reg12 >> 8) & 0xFF;
        _controllers['interlockControlEnable']!.text = _groundConnectionNumber.toString();
        _interlockControlChannel = reg12 & 0xFF;
        _controllers['interlockControlChannel']!.text = _interlockControlChannel.toString();
      }
      
      // Mark that we've received config registers
      _receivedConfigRegs = true;
      
      // Only stop loading if we've received both responses
      if (_receivedReg64) {
        _timeoutTimer?.cancel();
        _isLoading = false;
      }
    });
  }
  
  void _parseField63Register(int value) {
    setState(() {
      _registerData[64] = value;
      // Extract last 3 hex digits (12 bits) - if reg is 0x1001, take 0x001
      _sysFltTimeDelay = value & 0xFFF;
      _controllers['sysFltTimeDelay']!.text = _sysFltTimeDelay.toString();
      
      // Mark that we've received register 64
      _receivedReg64 = true;
      
      // Only stop loading if we've received both responses
      if (_receivedConfigRegs) {
        _timeoutTimer?.cancel();
        _isLoading = false;
      }
    });
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
      _writeCompleted = false;  // Reset write status when reading fresh data
      _registerData.clear();  // Clear old register data
      _receivedConfigRegs = false;  // Reset response tracking flags
      _receivedReg64 = false;
      _awaitingConfigRegsResponse = false;
      _awaitingReg64Response = false;
      // Reset all values to defaults (don't use 'Wait...' for dropdowns as it causes assertion error)
      _levelChkEna = 'No';
      _votingChkEna = 'No';
      _autoAdjustEna = 'No';
      _contDisable = 'No';
      _shortDisableSys = 'No';
      _fltDisable = 'No';
      _procFltDisable = 'No';
      _pwrFltDisable = 'No';
      _sensitivity = '0.5';
      _sel420SteamMode = 'No';
      _lastRmtAdr = 0;
      _groundConnectionNumber = 0;
      _interlockControlChannel = 0;
      _sysFltTimeDelay = 0;
      // Reset text controllers
      _controllers['lastRmtAdr']!.text = '0';
      _controllers['interlockControlEnable']!.text = '0';
      _controllers['interlockControlChannel']!.text = '0';
      _controllers['sysFltTimeDelay']!.text = '0';
    });

    // Write 1 to register 0 before reading
    await widget.bleManager.writeRegisters(startRegister: 0, values: [1]);
    
    // Temporarily unregister callback during polling to avoid incorrect parsing
    widget.bleManager.onModbusResponse = null;
    
    // Poll register 0 until it becomes 0 (device ready)
    final ready = await _waitForRegister0ToBeZero();
    if (!ready) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Device not ready - timeout')),
        );
      }
      _timeoutTimer?.cancel();  // Cancel timeout timer
      return;
    }
    
    // Re-register callback after polling
    widget.bleManager.onModbusResponse = _handleModbusResponse;
    
    // Small delay to ensure callback is ready
    await Future.delayed(const Duration(milliseconds: 100));
    
    // Read registers 9-12 (4 registers) for config fields
    _awaitingConfigRegsResponse = true;
    await widget.bleManager.readRegisters(startRegister: 9, quantity: 4);
    await Future.delayed(const Duration(milliseconds: 500));
    
    // Read register 64 (FIELD_63)
    _awaitingReg64Response = true;
    await widget.bleManager.readRegisters(startRegister: 64, quantity: 1);
    
    // Set up timeout handler with cancellable timer
    _timeoutTimer?.cancel();  // Cancel any existing timer
    _timeoutTimer = Timer(const Duration(seconds: 5), () {
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

    if (_registerData.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No data to write. Please read first.')),
      );
      return;
    }

    setState(() {
      _isWriting = true;
    });

    try {
      // Prepare register values
      final registerWrites = <int, int>{};

      // Build FIELD_8 (Register 9) - bit-packed nibbles (ignore unused nibble)
      try {
        final f8_0 = (_levelChkEna == 'Yes') ? 1 : 0;
        final f8_1 = (_votingChkEna == 'Yes') ? 1 : 0;
        final f8_2 = (_autoAdjustEna == 'Yes') ? 1 : 0;
        final f8_3 = 0;  // Unused nibble, always 0
        registerWrites[9] = (f8_0 << 12) | (f8_1 << 8) | (f8_2 << 4) | f8_3;
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid value in FIELD_8')),
        );
        setState(() => _isWriting = false);
        return;
      }

      // Build FIELD_9 (Register 10) - bit-packed nibbles
      try {
        final f9_0 = (_contDisable == 'Yes') ? 1 : 0;
        final f9_1 = (_shortDisableSys == 'Yes') ? 1 : 0;
        final previousReg10 = _registerData[10] ?? 0;
        final f9_2 = (previousReg10 >> 4) & 0xF; // Preserve SYS FLT DISABLE as previous value
        final f9_3 = (_procFltDisable == 'Yes') ? 1 : 0;
        registerWrites[10] = (f9_0 << 12) | (f9_1 << 8) | (f9_2 << 4) | f9_3;
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid value in FIELD_9')),
        );
        setState(() => _isWriting = false);
        return;
      }

      // Build FIELD_10 (Register 11) - bit-packed nibbles
      try {
        final f10_0 = (_pwrFltDisable == 'Yes') ? 1 : 0;
        final previousReg11 = _registerData[11] ?? 0;
        
        // Map display values to register values: 0.5→1, 1→2, 2→3
        // If sensitivity write is disabled, preserve existing sensitivity nibble.
        int sensRegValue = (previousReg11 >> 8) & 0xF;
        if (_enableSensitivityWrite) {
          if (_sensitivity == '0.5') {
            sensRegValue = 1;
          } else if (_sensitivity == '1') {
            sensRegValue = 2;
          } else if (_sensitivity == '2') {
            sensRegValue = 3;
          }
        }
        
        final f10_2 = (_sel420SteamMode == 'Yes') ? 1 : 0;
        final f10_3 = int.parse(_controllers['lastRmtAdr']!.text.trim());
        registerWrites[11] = (f10_0 << 12) | (sensRegValue << 8) | (f10_2 << 4) | f10_3;
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid value in FIELD_10')),
        );
        setState(() => _isWriting = false);
        return;
      }

      // Build FIELD_11 (Register 12) - Ground connection number + interlock channel
      try {
        final groundConnectionNumber = int.parse(_controllers['interlockControlEnable']!.text.trim());
        final interlockChannel = int.parse(_controllers['interlockControlChannel']!.text.trim());

        if (groundConnectionNumber < 0 || groundConnectionNumber > 255 ||
            interlockChannel < 0 || interlockChannel > 255) {
          throw Exception('Out of range');
        }

        registerWrites[12] = ((groundConnectionNumber & 0xFF) << 8) | (interlockChannel & 0xFF);
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid value in Ground Connection Number / Total Channel Number')),
        );
        setState(() => _isWriting = false);
        return;
      }

      // Write registers 9-12 (4 consecutive registers)
      final values9to12 = [
        registerWrites[9] ?? _registerData[9] ?? 0,
        registerWrites[10] ?? _registerData[10] ?? 0,
        registerWrites[11] ?? _registerData[11] ?? 0,
        registerWrites[12] ?? _registerData[12] ?? 0,
      ];
      await widget.bleManager.writeRegisters(startRegister: 9, values: values9to12);
      await Future.delayed(const Duration(milliseconds: 200));

      if (_enableSensitivityWrite) {
        // Also write FIELD_12-14 (Registers 13-15) based on selected sensitivity
        // 0.5 -> Reg13=655, Reg14=651, Reg15=40
        // 1   -> Reg13=665, Reg14=661, Reg15=40
        // 2   -> Reg13=420, Reg14=415, Reg15=40
        try {
          int reg13Value;
          int reg14Value;

          if (_sensitivity == '0.5') {
            reg13Value = 655;
            reg14Value = 651;
          } else if (_sensitivity == '1') {
            reg13Value = 665;
            reg14Value = 660;
          } else {
            reg13Value = 420;
            reg14Value = 415;
          }

          const reg15Value = 40;

          await widget.bleManager.writeRegisters(
            startRegister: 13,
            values: [reg13Value, reg14Value, reg15Value],
          );
          await Future.delayed(const Duration(milliseconds: 200));

          _registerData[13] = reg13Value;
          _registerData[14] = reg14Value;
          _registerData[15] = reg15Value;
        } catch (e) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to write sensitivity-linked values to Reg 13-15')),
          );
          setState(() => _isWriting = false);
          return;
        }
      }
      
      // Build FIELD_63 (Register 64) - write only lower 12 bits (last 3 hex digits)
      // Preserve the upper 4 bits from the original register value
      try {
        final decValue = int.parse(_controllers['sysFltTimeDelay']!.text.trim());
        final originalReg64 = _registerData[64] ?? 0;
        final upperNibble = originalReg64 & 0xF000;  // Preserve upper 4 bits
        registerWrites[64] = upperNibble | (decValue & 0xFFF);  // Combine upper 4 bits + lower 12 bits
        _registerData[64] = registerWrites[64]!;
        _sysFltTimeDelay = registerWrites[64]! & 0xFFF;
        _controllers['sysFltTimeDelay']!.text = _sysFltTimeDelay.toString();
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid value in System Fault Time Delay')),
        );
        setState(() => _isWriting = false);
        return;
      }
      
      // Write register 64 (FIELD_63)
      await widget.bleManager.writeRegisters(startRegister: 64, values: [registerWrites[64]!]);
      await Future.delayed(const Duration(milliseconds: 200));

      if (mounted) {
        // Write 2 to register 0 to commit
        await Future.delayed(const Duration(milliseconds: 300));
        await widget.bleManager.writeRegisters(startRegister: 0, values: [2]);
        
        // Temporarily unregister callback during polling
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
          return;
        }

        if (mounted) {
          setState(() {
            _writeCompleted = true;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Write successful! Now press SAVE to finalize.'),
              backgroundColor: Colors.green,
            ),
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

    if (!_writeCompleted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please write configuration first')),
      );
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      // Write 5 to register 0 to finalize/save
      await widget.bleManager.writeRegisters(startRegister: 0, values: [5]);
      
      // Temporarily unregister callback during polling
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
        return;
      }

      if (mounted) {
        setState(() {
          _writeCompleted = false;  // Reset after save
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Configuration saved successfully!'),
            backgroundColor: Colors.green,
          ),
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
          Expanded(
            child: Row(
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
                Transform.scale(
                  scale: 0.8,
                  child: Switch(
                    value: _enableSensitivityWrite,
                    onChanged: (value) {
                      setState(() => _enableSensitivityWrite = value);
                    },
                    activeColor: const Color(0xFF4CAF50),
                    activeTrackColor: const Color(0xFF4CAF50).withOpacity(0.5),
                    inactiveThumbColor: Colors.grey,
                    inactiveTrackColor: Colors.grey.withOpacity(0.5),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
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
                _isLoading ? 'Loading Config...' : 'Load Configuration',
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
              onPressed: widget.bleManager.isConnected && !_isWriting && !_isSaving && _registerData.isNotEmpty
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
              onPressed: widget.bleManager.isConnected && !_isWriting && !_isSaving && _writeCompleted
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
                backgroundColor: _writeCompleted ? const Color(0xFF4CAF50) : Colors.grey,
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
                          'System Checks',
                          style: TextStyle(
                            color: Color(0xFF00E5FF),
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      _buildDropdownItem('LEVEL CHECK ENABLE', _levelChkEna, (value) {
                        setState(() => _levelChkEna = value!);
                      }),
                      const SizedBox(height: 8),
                      _buildDropdownItem('VOTING CHECK ENABLE', _votingChkEna, (value) {
                        setState(() => _votingChkEna = value!);
                      }),
                      const SizedBox(height: 8),
                      _buildDropdownItem('AUTO ADJUST ENABLE', _autoAdjustEna, (value) {
                        setState(() => _autoAdjustEna = value!);
                      }),
                      
                      const SizedBox(height: 20),
                      
                      // FIELD_9 Section
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8, top: 4),
                        child: Text(
                          'Disable Flags',
                          style: TextStyle(
                            color: Color(0xFFFF6B35),
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      _buildDropdownItem('CONTAMINATION DISABLE', _contDisable, (value) {
                        setState(() => _contDisable = value!);
                      }, color: const Color(0xFFFF6B35)),
                      const SizedBox(height: 8),
                      _buildDropdownItem('SHORT DISABLE', _shortDisableSys, (value) {
                        setState(() => _shortDisableSys = value!);
                      }, color: const Color(0xFFFF6B35)),
                      const SizedBox(height: 8),
                      _buildDropdownItem('PROCESS FAULT DISABLE', _procFltDisable, (value) {
                        setState(() => _procFltDisable = value!);
                      }, color: const Color(0xFFFF6B35)),
                      
                      const SizedBox(height: 20),
                      
                      // FIELD_10 Section
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8, top: 4),
                        child: Text(
                          'System Settings',
                          style: TextStyle(
                            color: Color(0xFF4CAF50),
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      _buildDropdownItem('POWER FAULT DISABLE', _pwrFltDisable, (value) {
                        setState(() => _pwrFltDisable = value!);
                      }, color: const Color(0xFF4CAF50)),
                      const SizedBox(height: 8),
                      _buildSensitivityDropdown(),
                      if (_showSteamModeOption) ...[
                        const SizedBox(height: 8),
                        _buildDropdownItem('4 - 20 STEAM MODE', _sel420SteamMode, (value) {
                          setState(() => _sel420SteamMode = value!);
                        }, color: const Color(0xFF4CAF50)),
                      ],
                      const SizedBox(height: 8),
                      _buildConfigItem('LAST REMOTE ADDRESS', 'lastRmtAdr', color: const Color(0xFF4CAF50)),
                      
                      const SizedBox(height: 20),
                      
                      // FIELD_11 Section - Interlock Control
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8, top: 4),
                        child: Text(
                          'Channel Settings',
                          style: TextStyle(
                            color: Color(0xFFFFEB3B),
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      _buildConfigItem('GROUND CONNECTION NUMBER', 'interlockControlEnable', color: const Color(0xFFFFEB3B)),
                      const SizedBox(height: 8),
                      _buildConfigItem('TOTAL CHANNEL NUMBER', 'interlockControlChannel', color: const Color(0xFFFFEB3B)),
                      
                      const SizedBox(height: 20),
                      
                      // FIELD_63 Section
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8, top: 4),
                        child: Text(
                          'Fault Timing',
                          style: TextStyle(
                            color: Color(0xFFFF6B35),
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      _buildConfigItem('FAULT RELAY TRIP DELAY', 'sysFltTimeDelay', color: const Color(0xFFFF6B35)),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
