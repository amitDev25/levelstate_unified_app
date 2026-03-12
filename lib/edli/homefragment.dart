import 'package:flutter/material.dart';
import 'dart:async';
import 'main.dart';

class HomeFragment extends StatefulWidget {
  final BLEManager bleManager;

  const HomeFragment({super.key, required this.bleManager});

  @override
  State<HomeFragment> createState() => _HomeFragmentState();
}

class _HomeFragmentState extends State<HomeFragment> {
  int _totalChannels = 0;
  List<int> _channelValues = [];
  bool _isLoading = false;
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();
    widget.bleManager.addListener(_onBLEUpdate);
    
    // Set up Modbus response callback
    widget.bleManager.onModbusResponse = _handleModbusResponse;
    
    // Auto-load data when the fragment is opened
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.bleManager.isConnected) {
        _sendCommand();
      }
    });
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    widget.bleManager.removeListener(_onBLEUpdate);
    widget.bleManager.onModbusResponse = null;
    super.dispose();
  }

  void _onBLEUpdate() {
    if (!mounted) return;
    setState(() {});
  }

  void _handleModbusResponse() {
    print('[HomeFragment] _handleModbusResponse called, mounted=$mounted, _isLoading=$_isLoading');
    if (!mounted || !_isLoading) return;
    
    final response = widget.bleManager.lastModbusResponse;
    print('[HomeFragment] Response length: ${response.length}, FC: ${response.length > 1 ? response[1] : "N/A"}');
    
    // Check if this is a read response (FC 3)
    if (response.length < 2 || response[1] != 0x03) {
      return;
    }
    
    final values = widget.bleManager.parseReadResponse(response);
    print('[HomeFragment] Parsed values: $values');
    if (values.isEmpty) {
      setState(() {
        _isLoading = false;
      });
      return;
    }
    
    // Cancel timeout timer since we got data
    _timeoutTimer?.cancel();
    
    setState(() {
      // First value is FIELD_1 (Register 2) = total channels
      if (values.isNotEmpty) {
        _totalChannels = values[0];
      }
      
      // Remaining values (after skipping 2 reserved regs) are channel data from FIELD_4 (Register 5)
      _channelValues.clear();
      // Skip indices 1 and 2 (FIELD_2 and FIELD_3 which are reserved)
      // Start from index 3 which is Register 5 (FIELD_4)
      for (int i = 3; i < values.length; i++) {
        // Take first 3 hex digits (12 bits) for channel value
        final channelValue = values[i] >> 4; // Use upper 12 bits
        _channelValues.add(channelValue);
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

    // Re-register callback in case another fragment overwrote it
    widget.bleManager.onModbusResponse = _handleModbusResponse;

    setState(() {
      _isLoading = true;
      _totalChannels = 0;
      _channelValues.clear();
    });

    // Write 3 to register 0
    await widget.bleManager.writeRegisters(startRegister: 0, values: [3]);
    
    // Wait 3 seconds
    await Future.delayed(const Duration(seconds: 3));
    
    // Re-register callback right before reading to ensure it's still active
    widget.bleManager.onModbusResponse = _handleModbusResponse;
    
    // Read all registers in one operation:
    // Register 2: FIELD_1 (total channels)
    // Registers 3-4: Reserved/unused (FIELD_2, FIELD_3)
    // Registers 5+: FIELD_4+ (channel data)
    // Read 35 registers total (1 channel count + 2 reserved + 32 channel values)
    await widget.bleManager.readRegisters(startRegister: 2, quantity: 35);
    
    // Timeout handler - longer timeout for large register reads
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(const Duration(seconds: 8), () {
      if (_isLoading && mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    });
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
                  : const Icon(Icons.refresh, color: Colors.black, size: 20),
              label: Text(
                _isLoading ? 'Loading...' : 'Refresh Home Data',
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
          
          const SizedBox(height: 20),
          
          // Total channels info
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A2E),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: const Color(0xFF00E5FF).withOpacity(0.3),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.timeline,
                  color: Color(0xFF00E5FF),
                  size: 24,
                ),
                const SizedBox(width: 12),
                Text(
                  'Total Channels: $_totalChannels',
                  style: const TextStyle(
                    color: Color(0xFF00E5FF),
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          
          const SizedBox(height: 20),
          
          // Channel values grid
          Expanded(
            child: _channelValues.isEmpty
                ? Center(
                    child: Text(
                      _isLoading ? 'Loading...' : 'No channel data',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 16,
                      ),
                    ),
                  )
                : GridView.builder(
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: 1.2,
                    ),
                    itemCount: _channelValues.length,
                    itemBuilder: (context, index) {
                      return Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1A1A2E),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: const Color(0xFF00E5FF).withOpacity(0.3),
                          ),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              'Channel ${index + 1}',
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '${_channelValues[index]}',
                              style: const TextStyle(
                                color: Color(0xFF00E5FF),
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
