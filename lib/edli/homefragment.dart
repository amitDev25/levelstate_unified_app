import 'package:flutter/material.dart';
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
  int _lastLogCount = 0;

  @override
  void initState() {
    super.initState();
    widget.bleManager.addListener(_onBLEUpdate);
    _lastLogCount = widget.bleManager.logs.length;
    
    // Auto-send ?0003! when the fragment is opened
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.bleManager.isConnected) {
        _sendCommand();
      }
    });
  }

  @override
  void dispose() {
    widget.bleManager.removeListener(_onBLEUpdate);
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
      _channelValues.clear();
      
      // Extract FIELD_1 (total channels)
      final field1Pattern = '"FIELD_1": "';
      final field1Start = jsonLog.indexOf(field1Pattern);
      if (field1Start != -1) {
        final valueStart = field1Start + field1Pattern.length;
        final valueEnd = jsonLog.indexOf('"', valueStart);
        if (valueEnd != -1) {
          try {
            final hexValue = jsonLog.substring(valueStart, valueEnd);
            // Remove pipe character if present
            final cleanHex = hexValue.replaceAll('|', '');
            _totalChannels = int.parse(cleanHex, radix: 16);
          } catch (e) {
            _totalChannels = 0;
          }
        }
      }
      
      // Parse channel values starting from FIELD_4 onwards
      // Number of channels = _totalChannels
      for (int i = 4; i <= 3 + _totalChannels; i++) {
        final fieldName = 'FIELD_$i';
        final pattern = '"$fieldName": "';
        
        final startIndex = jsonLog.indexOf(pattern);
        if (startIndex != -1) {
          final valueStart = startIndex + pattern.length;
          final valueEnd = jsonLog.indexOf('"', valueStart);
          if (valueEnd != -1) {
            try {
              final hexValue = jsonLog.substring(valueStart, valueEnd);
              // Remove any non-hex characters (like pipe)
              final cleanHex = hexValue.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
              // Take first 3 digits of hex value
              final first3Digits = cleanHex.length >= 3 ? cleanHex.substring(0, 3) : cleanHex;
              // Convert to decimal
              final decValue = int.parse(first3Digits, radix: 16);
              _channelValues.add(decValue);
            } catch (e) {
              _channelValues.add(0);
            }
          } else {
            _channelValues.add(0);
          }
        } else {
          _channelValues.add(0);
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
      _totalChannels = 0;
      _channelValues.clear();
    });

    await widget.bleManager.sendString('?0003!');
    
    Future.delayed(const Duration(seconds: 15), () {
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
                _isLoading ? 'Sending ?0003!...' : 'Refresh (?0003!)',
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
