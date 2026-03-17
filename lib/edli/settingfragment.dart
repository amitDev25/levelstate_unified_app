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
  Map<int, int> _registerData = {};  // Store register data
  bool _isLoading = false;
  bool _isWriting = false;
  bool _isSaving = false;
  bool _writeCompleted = false;  // Track if write was done
  Timer? _timeoutTimer;  // Timeout timer for read operations
  bool _readingChannelSettings = false;  // Track which read stage we're in
  bool _readingEnergisedDelay = false;

  @override
  void initState() {
    super.initState();
    widget.bleManager.addListener(_onBLEUpdate);
    
    // Set up Modbus response callback
    widget.bleManager.onModbusResponse = _handleModbusResponse;
    
    // Auto-load when the fragment is opened (only if not checking activation)
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
    _timeoutTimer?.cancel();
    widget.bleManager.removeListener(_onBLEUpdate);
    widget.bleManager.onModbusResponse = null;
    // Dispose all channel controllers
    for (final channel in _channels) {
      channel.dispose();
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
      _timeoutTimer?.cancel();
      setState(() {
        _isLoading = false;
      });
      return;
    }
    
    // Store all received register values
    final byteCount = response[2];
    
    // First read: Register 12 (FIELD_11) - 1 register = 2 bytes
    if (byteCount == 2 && values.length == 1 && !_readingChannelSettings && !_readingEnergisedDelay) {
      _timeoutTimer?.cancel();  // Cancel timeout for this read
      setState(() {
        _registerData[12] = values[0];
        _totalChannels = values[0] & 0xFF;  // Lower byte
      });
      
      // Now read channel settings based on _totalChannels (call outside setState)
      _readChannelSettingsRegisters();
      return;  // Wait for next read
    }
    
    // Second read: Channel settings registers (16 to 16+_totalChannels-1)
    if (_readingChannelSettings && byteCount == _totalChannels * 2) {
      _timeoutTimer?.cancel();  // Cancel timeout for this read
      setState(() {
        for (int i = 0; i < values.length && i < _totalChannels; i++) {
          _registerData[16 + i] = values[i];
        }
        _readingChannelSettings = false;
      });
      
      // Now read energised/delay registers (call outside setState)
      _readEnergisedDelayRegisters();
      return;  // Wait for next read
    }
    
    // Third read: Energised/delay registers (65 to 65+_totalChannels-1)
    if (_readingEnergisedDelay && byteCount == _totalChannels * 2 && _registerData.containsKey(16)) {
      _timeoutTimer?.cancel();  // Cancel timeout for this read
      setState(() {
        for (int i = 0; i < values.length && i < _totalChannels; i++) {
          _registerData[65 + i] = values[i];
        }
        _readingEnergisedDelay = false;
        
        // Now parse all channel data
        _parseChannelData();
        _isLoading = false;
      });
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

  void _parseChannelData() {
    _channels.clear();
    
    for (int i = 1; i <= _totalChannels && i <= 32; i++) {
      final channelSettings = ChannelSettings(channelNumber: i);
      
      // Parse FIELD_(14+i) from Register (15+i)
      final settingsReg = 14 + i + 1;  // field+1
      if (_registerData.containsKey(settingsReg)) {
        final regVal = _registerData[settingsReg]!;
        // Bit-packed: [enable][steam][tripRelay(2 bytes)]
        final enableVal = (regVal >> 12) & 0xF;
        channelSettings.enabled = enableVal == 0;
        channelSettings.enabledCtrl.text = enableVal.toString();
        
        final steamVal = (regVal >> 8) & 0xF;
        channelSettings.isSteam = steamVal == 1;
        channelSettings.steamCtrl.text = steamVal.toString();
        
        channelSettings.tripRelayNumber = regVal & 0xFF;
        channelSettings.tripRelayCtrl.text = channelSettings.tripRelayNumber.toString();
      }
      
      // Parse energised/delay using Trip Relay mapping.
      // If trip relay is valid (1.._totalChannels), use Register (64+tripRelay).
      // Fallback to channel-indexed register for compatibility when trip relay is 0/invalid.
      int energisedReg = 63 + i + 1;  // default fallback: register 64+i
      if (channelSettings.tripRelayNumber > 0 &&
          channelSettings.tripRelayNumber <= _totalChannels) {
        energisedReg = 64 + channelSettings.tripRelayNumber;
      }

      if (_registerData.containsKey(energisedReg)) {
        final regVal = _registerData[energisedReg]!;
        // Bit-packed: [energised(1 nibble)][delay(3 nibbles)]
        final energisedVal = (regVal >> 12) & 0xF;
        channelSettings.energised = energisedVal == 1;
        channelSettings.energisedCtrl.text = energisedVal.toString();
        
        channelSettings.delayValue = regVal & 0xFFF;
        channelSettings.delayCtrl.text = channelSettings.delayValue.toString();
      }
      
      _channels.add(channelSettings);
    }
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
      _writeCompleted = false;
      _totalChannels = 0;
      _channels.clear();
      _registerData.clear();
      _readingChannelSettings = false;
      _readingEnergisedDelay = false;
    });

    // Cancel any existing timeout timer
    _timeoutTimer?.cancel();

    // Write 1 to register 0 before reading
    await widget.bleManager.writeRegisters(startRegister: 0, values: [1]);
    
    
    // Wait 2 seconds for device to be ready
    await Future.delayed(const Duration(seconds: 2));
    
    // Re-register callback right before reading to ensure it's still active
    widget.bleManager.onModbusResponse = _handleModbusResponse;
    
    // Read Register 12 (FIELD_11) to get total channels
    await widget.bleManager.readRegisters(startRegister: 12, quantity: 1);
    
    // Start timeout timer for register 12 read
    _startTimeoutTimer();
  }
  
  void _readChannelSettingsRegisters() async {
    if (_totalChannels <= 0 || _totalChannels > 32) {
      setState(() {
        _isLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Invalid channel count: $_totalChannels')),
      );
      return;
    }
    
    await Future.delayed(const Duration(milliseconds: 500));
    
    if (!mounted) return;
    
    // Set flag and re-register callback BEFORE reading
    setState(() {
      _readingChannelSettings = true;
    });
    widget.bleManager.onModbusResponse = _handleModbusResponse;
    
    // Read only the required number of channel setting registers
    await widget.bleManager.readRegisters(startRegister: 16, quantity: _totalChannels);
    
    // Start timeout timer
    _startTimeoutTimer();
  }
  
  void _readEnergisedDelayRegisters() async {
    await Future.delayed(const Duration(milliseconds: 500));
    
    if (!mounted) return;
    
    // Set flag and re-register callback BEFORE reading
    setState(() {
      _readingEnergisedDelay = true;
    });
    widget.bleManager.onModbusResponse = _handleModbusResponse;
    
    // Read only the required number of energised/delay registers
    await widget.bleManager.readRegisters(startRegister: 65, quantity: _totalChannels);
    
    // Start timeout timer
    _startTimeoutTimer();
  }
  
  void _startTimeoutTimer() {
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(const Duration(seconds: 12), () {
      if (_isLoading && mounted) {
        setState(() {
          _isLoading = false;
          _readingChannelSettings = false;
          _readingEnergisedDelay = false;
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

    if (_registerData.isEmpty || _channels.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No data to write. Please read first.')),
      );
      return;
    }

    setState(() {
      _isWriting = true;
    });

    try {
      // Prepare register writes for each channel
      final channelSettingsWrites = <int, int>{};
      final relayDelayWrites = <int, int>{};

      for (final channel in _channels) {
        final channelNum = channel.channelNumber;
        
        // Build channel settings register (FIELD_(14+channelNum) → Register (15+channelNum))
        try {
          final enableVal = int.parse(channel.enabledCtrl.text.trim());
          final steamVal = int.parse(channel.steamCtrl.text.trim());
          final tripRelay = int.parse(channel.tripRelayCtrl.text.trim());
          
          final settingsReg = 14 + channelNum + 1;  // field+1
          channelSettingsWrites[settingsReg] = (enableVal << 12) | (steamVal << 8) | tripRelay;
        } catch (e) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Invalid value in Channel $channelNum settings')),
          );
          setState(() => _isWriting = false);
          return;
        }

        // Build energised/delay register by TRIP RELAY number
        // (FIELD_(63+tripRelay) → Register (64+tripRelay))
        try {
          final energisedVal = int.parse(channel.energisedCtrl.text.trim());
          final delayVal = int.parse(channel.delayCtrl.text.trim());
          final tripRelay = int.parse(channel.tripRelayCtrl.text.trim());

          if (tripRelay < 0 || tripRelay > _totalChannels) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Invalid Trip Relay $tripRelay in Channel $channelNum')),
            );
            setState(() => _isWriting = false);
            return;
          }

          // Trip Relay 0 is valid: keep channel trip relay as 0,
          // but do not map delay to any relay register.
          if (tripRelay == 0) {
            continue;
          }

          final relayReg = 64 + tripRelay; // register index for relay-based delay
          relayDelayWrites[relayReg] = (energisedVal << 12) | (delayVal & 0xFFF);
        } catch (e) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Invalid value in Channel $channelNum energised/delay')),
          );
          setState(() => _isWriting = false);
          return;
        }
      }

      // Write only the required number of channel settings registers
      final settingsValues = List<int>.filled(_totalChannels, 0);
      for (int i = 0; i < _totalChannels; i++) {
        settingsValues[i] = channelSettingsWrites[16 + i] ?? _registerData[16 + i] ?? 0;
      }
      
      // Write in chunks of 4 registers to stay under BLE 20-byte limit
      const chunkSize = 4;
      for (int i = 0; i < settingsValues.length; i += chunkSize) {
        final end = (i + chunkSize < settingsValues.length) ? i + chunkSize : settingsValues.length;
        final chunk = settingsValues.sublist(i, end);
        await widget.bleManager.writeRegisters(startRegister: 16 + i, values: chunk);
        await Future.delayed(const Duration(milliseconds: 300));
      }
      
      // Write energised/delay only to mapped relay registers
      // (more reliable than rebuilding a full 65..N block when relay mapping is sparse)
      if (relayDelayWrites.isNotEmpty) {
        final sortedRelayRegs = relayDelayWrites.keys.toList()..sort();

        int runStart = sortedRelayRegs.first;
        int previousReg = sortedRelayRegs.first;
        List<int> runValues = [relayDelayWrites[sortedRelayRegs.first]!];

        for (int i = 1; i < sortedRelayRegs.length; i++) {
          final reg = sortedRelayRegs[i];
          final value = relayDelayWrites[reg]!;

          final isContiguous = reg == previousReg + 1;
          final hasRoomInChunk = runValues.length < chunkSize;

          if (isContiguous && hasRoomInChunk) {
            runValues.add(value);
          } else {
            await widget.bleManager.writeRegisters(startRegister: runStart, values: runValues);
            await Future.delayed(const Duration(milliseconds: 300));

            runStart = reg;
            runValues = [value];
          }

          previousReg = reg;
        }

        // Flush remaining run
        await widget.bleManager.writeRegisters(startRegister: runStart, values: runValues);
        await Future.delayed(const Duration(milliseconds: 300));

        // Keep local cache in sync
        relayDelayWrites.forEach((reg, value) {
          _registerData[reg] = value;
        });
      }

      if (mounted) {
        // Write 2 to register 0 to commit
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
          
          // Write button (writes data + reg 0 = 2)
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: widget.bleManager.isConnected && !_isWriting && _channels.isNotEmpty
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
          
          // Save button (writes reg 0 = 5, enabled after write)
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: widget.bleManager.isConnected && !_isSaving && _writeCompleted
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
                backgroundColor: _writeCompleted 
                    ? Colors.green 
                    : Colors.grey,
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
                    if (label == 'Delay') {
                      if (currentValue > 2) {
                        controller.text = (currentValue - 1).toString();
                      } else {
                        controller.text = '2';
                      }
                    } else if (currentValue > 0) {
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
