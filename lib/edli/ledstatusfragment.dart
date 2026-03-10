import 'package:flutter/material.dart';
import 'dart:async';
import 'main.dart';

class LedStatusFragment extends StatefulWidget {
  final BLEManager bleManager;

  const LedStatusFragment({super.key, required this.bleManager});

  @override
  State<LedStatusFragment> createState() => _LedStatusFragmentState();
}

class _LedStatusFragmentState extends State<LedStatusFragment> with AutomaticKeepAliveClientMixin {
  int _numChannels = 0;
  int _sfStatus = 0;
  int _pfStatus = 0;
  List<int> _channelStatuses = [];
  
  bool _isLoading = false;
  int _lastLogCount = 0;
  String? _errorMessage;
  
  final Map<String, bool> _blinkStates = {};
  Timer? _fastBlinkTimer;
  Timer? _slowBlinkTimer;
  Timer? _parseTimeoutTimer;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    widget.bleManager.addListener(_onBLEUpdate);
    _lastLogCount = widget.bleManager.logs.length;
    _startBlinkTimers();
  }

  @override
  void dispose() {
    _fastBlinkTimer?.cancel();
    _slowBlinkTimer?.cancel();
    _parseTimeoutTimer?.cancel();
    widget.bleManager.removeListener(_onBLEUpdate);
    super.dispose();
  }

  void _startBlinkTimers() {
    if (!mounted) return;
    
    try {
      _fastBlinkTimer?.cancel();
      _fastBlinkTimer = Timer.periodic(const Duration(milliseconds: 250), (timer) {
        if (mounted) {
          setState(() {
            _blinkStates['fast'] = !(_blinkStates['fast'] ?? false);
          });
        } else {
          timer.cancel();
        }
      });
      
      _slowBlinkTimer?.cancel();
      _slowBlinkTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
        if (mounted) {
          setState(() {
            _blinkStates['slow'] = !(_blinkStates['slow'] ?? false);
          });
        } else {
          timer.cancel();
        }
      });
    } catch (e) {
      _errorMessage = 'Timer error: $e';
    }
  }

  void _onBLEUpdate() {
    if (!mounted) return;
    
    try {
      if (widget.bleManager.logs.length > _lastLogCount) {
        final newLogs = widget.bleManager.logs.sublist(_lastLogCount);
        _lastLogCount = widget.bleManager.logs.length;
        
        for (final log in newLogs) {
          if (log.startsWith('RX: {') && _isLoading) {
            _parseJsonResponse(log);
            break;
          }
        }
      }
      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Update error: $e';
          _isLoading = false;
        });
      }
    }
  }

  void _parseJsonResponse(String jsonLog) {
    if (!_isLoading || !mounted) return;
    
    try {
      _parseTimeoutTimer?.cancel();
      
      setState(() {
        final field1Pattern = '"FIELD_1": "';
        final field1Start = jsonLog.indexOf(field1Pattern);
        if (field1Start != -1) {
          final valueStart = field1Start + field1Pattern.length;
          final valueEnd = jsonLog.indexOf('"', valueStart);
          if (valueEnd != -1) {
            final hexValue = jsonLog.substring(valueStart, valueEnd);
            final cleanHex = hexValue.replaceAll('|', '').replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
            if (cleanHex.isNotEmpty) {
              _numChannels = int.parse(cleanHex, radix: 16);
            }
          }
        }
        
        _sfStatus = _extractFieldValue(jsonLog, 'FIELD_2');
        _pfStatus = _extractFieldValue(jsonLog, 'FIELD_3');
        
        _channelStatuses.clear();
        for (int i = 0; i < _numChannels; i++) {
          final fieldNum = 4 + i;
          final status = _extractFieldValue(jsonLog, 'FIELD_$fieldNum');
          _channelStatuses.add(status);
        }
        
        _isLoading = false;
        _errorMessage = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Parse error: $e';
        });
      }
    }
  }

  int _extractFieldValue(String jsonLog, String fieldName) {
    try {
      final pattern = '"$fieldName": "';
      final startIndex = jsonLog.indexOf(pattern);
      if (startIndex != -1) {
        final valueStart = startIndex + pattern.length;
        final valueEnd = jsonLog.indexOf('"', valueStart);
        if (valueEnd != -1) {
          final hexValue = jsonLog.substring(valueStart, valueEnd);
          final cleanHex = hexValue.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
          return int.parse(cleanHex, radix: 16);
        }
      }
    } catch (e) {
      return 0;
    }
    return 0;
  }

  void _sendCommand() async {
    if (!mounted) return;
    
    if (!widget.bleManager.isConnected) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Not connected to device')),
        );
      }
      return;
    }

    try {
      if (mounted) {
        setState(() {
          _isLoading = true;
          _numChannels = 0;
          _sfStatus = 0;
          _pfStatus = 0;
          _channelStatuses.clear();
          _errorMessage = null;
        });
      }

      await widget.bleManager.sendString('?0003!');
      
      _parseTimeoutTimer?.cancel();
      _parseTimeoutTimer = Timer(const Duration(seconds: 15), () {
        if (_isLoading && mounted) {
          setState(() {
            _isLoading = false;
            _errorMessage = 'Response timeout';
          });
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Response timeout')),
            );
          }
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Send error: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    
    return Container(
      color: const Color(0xFF0D0D1A),
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
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
                _isLoading ? 'Loading...' : 'Refresh LED Status',
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
          
          if (_errorMessage != null)
            Container(
              padding: const EdgeInsets.all(8),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.redAccent.withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.redAccent),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline, color: Colors.redAccent, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _errorMessage!,
                      style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.redAccent, size: 18),
                    onPressed: () {
                      if (mounted) {
                        setState(() {
                          _errorMessage = null;
                        });
                      }
                    },
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
          
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(
                      color: Color(0xFF00E5FF),
                    ),
                  )
                : Center(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        // Calculate appropriate width based on screen size
                        final displayWidth = constraints.maxWidth < 500 
                            ? constraints.maxWidth * 0.85
                            : 400.0;
                        
                        return Container(
                          width: displayWidth,
                          height: constraints.maxHeight * 0.98,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFD4C5A0),
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.3),
                                blurRadius: 20,
                                spreadRadius: 5,
                              ),
                            ],
                          ),
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.black,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(vertical: 8),
                                  child: const Text(
                                    'EDLI',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 2,
                                    ),
                                  ),
                                ),
                                
                                Container(
                                  height: 1,
                                  color: Colors.grey[700],
                                  margin: const EdgeInsets.symmetric(horizontal: 20),
                                ),
                                
                                const SizedBox(height: 8),
                                
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 20),
                                    child: LayoutBuilder(
                                      builder: (context, constraints) {
                                        // Calculate LED size based on number of channels and available space
                                        double ledHeight = 40.0;
                                        double ledWidth = 50.0;
                                        
                                        if (_numChannels > 0) {
                                          // Calculate available height: total height - SF/PF section
                                          // SF/PF section = text (12) + spacing (4) + LED (ledHeight) + gap (4)
                                          final sfpfSectionHeight = 12 + 4 + ledHeight + 4;
                                          final availableForChannels = constraints.maxHeight - sfpfSectionHeight;
                                          
                                          // Each channel row needs: LED height + vertical padding (2)
                                          final requiredHeightPerChannel = ledHeight + 2;
                                          final totalRequired = requiredHeightPerChannel * _numChannels;
                                          
                                          // If it doesn't fit, reduce LED size
                                          if (totalRequired > availableForChannels) {
                                            ledHeight = ((availableForChannels / _numChannels) - 2).clamp(15.0, 40.0);
                                            ledWidth = (ledHeight * 1.25).clamp(25.0, 50.0);
                                          }
                                        }
                                        
                                        return Column(
                                          children: [
                                            // SF and PF row at the top
                                            Row(
                                              mainAxisAlignment: MainAxisAlignment.center,
                                              children: [
                                                _buildTopLED('SF', _sfStatus, ledWidth, ledHeight),
                                                const SizedBox(width: 12),
                                                _buildTopLED('PF', _pfStatus, ledWidth, ledHeight),
                                              ],
                                            ),
                                            
                                            const SizedBox(height: 4),
                                            
                                            // Channel LEDs Grid
                                            if (_numChannels > 0)
                                              Expanded(
                                                child: Column(
                                                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                                  children: List.generate(_numChannels, (index) {
                                                    final channelNum = _numChannels - index;
                                                    final channelStatus = (channelNum - 1) < _channelStatuses.length 
                                                        ? _channelStatuses[channelNum - 1] 
                                                        : 0;
                                                    
                                                    return _buildChannelRow(channelNum, channelStatus, ledWidth, ledHeight);
                                                  }),
                                                ),
                                              )
                                            else
                                              const Expanded(
                                                child: Center(
                                                  child: Text(
                                                    'No Data',
                                                    style: TextStyle(
                                                      color: Colors.white38,
                                                      fontSize: 14,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                          ],
                                        );
                                      },
                                    ),
                                  ),
                                ),
                                
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 8, top: 4),
                                  child: Container(
                                    width: 10,
                                    height: 10,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: widget.bleManager.isConnected 
                                          ? Colors.green 
                                          : Colors.red,
                                      boxShadow: [
                                        BoxShadow(
                                          color: (widget.bleManager.isConnected ? Colors.green : Colors.red).withOpacity(0.6),
                                          blurRadius: 8,
                                          spreadRadius: 2,
                                        ),
                                      ],
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
        ],
      ),
    );
  }
  
  Widget _buildTopLED(String label, int status, double width, double height) {
    bool isOn = false;
    const Color ledColor = Colors.yellow; // Always yellow for SF and PF
    
    if (status == 0) {
      isOn = false;
    } else if (status == 9) {
      isOn = _blinkStates['fast'] ?? false;
    } else if (status == 10) {
      isOn = _blinkStates['slow'] ?? false;
    } else {
      isOn = true;
    }
    
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: isOn ? ledColor : Colors.grey[850],
            border: Border.all(
              color: Colors.grey[700]!,
              width: 2,
            ),
            boxShadow: isOn ? [
              BoxShadow(
                color: ledColor.withOpacity(0.8),
                blurRadius: 12,
                spreadRadius: 2,
              ),
            ] : null,
          ),
        ),
      ],
    );
  }
  
  Widget _buildChannelRow(int channelNum, int channelStatus, double ledWidth, double ledHeight) {
    final lsb = channelStatus & 0xF;
    
    bool leftOn = false;
    bool rightOn = false;
    
    switch (lsb) {
      case 0:
      case 1:
        leftOn = false;
        rightOn = false;
        break;
      case 2:
        leftOn = false;
        rightOn = _blinkStates['fast'] ?? false;
        break;
      case 3:
        leftOn = _blinkStates['fast'] ?? false;
        rightOn = false;
        break;
      case 4:
        leftOn = _blinkStates['fast'] ?? false;
        rightOn = _blinkStates['fast'] ?? false;
        break;
      case 5:
        leftOn = false;
        rightOn = true;
        break;
      case 6:
        leftOn = true;
        rightOn = false;
        break;
      case 7:
        leftOn = false;
        rightOn = _blinkStates['slow'] ?? false;
        break;
      case 8:
        leftOn = _blinkStates['slow'] ?? false;
        rightOn = false;
        break;
    }
    
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          // Left spacer for centering
          Expanded(
            flex: 2,
            child: Container(),
          ),
          
          // Left LED (Green)
          Container(
            width: ledWidth,
            height: ledHeight,
            decoration: BoxDecoration(
              color: leftOn ? Colors.green : Colors.grey[850],
              border: Border.all(
                color: Colors.grey[700]!,
                width: 2,
              ),
              boxShadow: leftOn ? [
                BoxShadow(
                  color: Colors.green.withOpacity(0.8),
                  blurRadius: 10,
                  spreadRadius: 2,
                ),
              ] : null,
            ),
          ),
          
          const SizedBox(width: 12),
          
          // Right LED (Red)
          Container(
            width: ledWidth,
            height: ledHeight,
            decoration: BoxDecoration(
              color: rightOn ? Colors.red : Colors.grey[850],
              border: Border.all(
                color: Colors.grey[700]!,
                width: 2,
              ),
              boxShadow: rightOn ? [
                BoxShadow(
                  color: Colors.red.withOpacity(0.8),
                  blurRadius: 10,
                  spreadRadius: 2,
                ),
              ] : null,
            ),
          ),
          
          // Right spacer with channel number
          Expanded(
            flex: 2,
            child: Container(
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                '$channelNum',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
