import 'package:flutter/material.dart';
import 'dart:async';
import 'main.dart';

class LedStatusFragment extends StatefulWidget {
  final BLEManager bleManager;
  final TabController tabController;
  final String deviceDisplayName;

  const LedStatusFragment({
    super.key,
    required this.bleManager,
    required this.tabController,
    this.deviceDisplayName = 'EDLI',
  });

  @override
  State<LedStatusFragment> createState() => _LedStatusFragmentState();
}

class _LedStatusFragmentState extends State<LedStatusFragment> with AutomaticKeepAliveClientMixin {
  int _numChannels = 0;
  int _sfStatus = 0;
  int _pfStatus = 0;
  List<int> _channelStatuses = [];
  
  bool _isLoading = false;
  String? _errorMessage;
  bool _wasConnected = false;  // Track previous connection state
  bool _wasCheckingActivation = false;  // Track previous activation check state
  bool _isPageActive = false;  // Track if LED Status tab is currently active
  bool _isSilentRefresh = false;  // Track if current operation is a silent refresh
  
  final Map<String, bool> _blinkStates = {};
  Timer? _fastBlinkTimer;
  Timer? _slowBlinkTimer;
  Timer? _parseTimeoutTimer;
  Timer? _autoRefreshTimer;  // Timer for auto-refreshing LED status every 5 seconds

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    
    // Initialize connection state tracking
    _wasConnected = widget.bleManager.isConnected;
    _wasCheckingActivation = widget.bleManager.isCheckingActivation;
    
    widget.bleManager.addListener(_onBLEUpdate);
    
    // Set up Modbus response callback
    widget.bleManager.onModbusResponse = _handleModbusResponse;
    
    // Listen to tab changes
    widget.tabController.addListener(_onTabChanged);
    
    // Check initial tab state (LED Status is tab 0)
    _isPageActive = widget.tabController.index == 0;
    
    _startBlinkTimers();
    
    // Start auto-refresh timer for real-time monitoring
    _startAutoRefreshTimer();
    
    // Auto-load data when the fragment is opened (with small delay to ensure stable initialization)
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (widget.bleManager.isConnected) {
        // Small delay to ensure callback is properly registered after tab switch
        await Future.delayed(const Duration(milliseconds: 200));
        if (mounted) {
          _sendCommand();
        }
      }
    });
  }

  @override
  void dispose() {
    widget.tabController.removeListener(_onTabChanged);
    _fastBlinkTimer?.cancel();
    _slowBlinkTimer?.cancel();
    _parseTimeoutTimer?.cancel();
    _autoRefreshTimer?.cancel();
    widget.bleManager.removeListener(_onBLEUpdate);
    widget.bleManager.onModbusResponse = null;
    super.dispose();
  }

  void _onTabChanged() {
    if (!mounted) return;
    
    // LED Status tab is index 0
    final bool isOnLedStatusTab = widget.tabController.index == 0;
    
    if (isOnLedStatusTab != _isPageActive) {
      setState(() {
        _isPageActive = isOnLedStatusTab;
      });
      
      if (isOnLedStatusTab) {
        print('[LedStatusFragment] Switched to LED Status tab (index ${widget.tabController.index}) - resuming auto-refresh');
        // Optionally do an immediate refresh when returning to the page
        if (widget.bleManager.isConnected && 
            widget.bleManager.isDeviceActivated && 
            !widget.bleManager.isCheckingActivation) {
          _silentRefresh();
        }
      } else {
        print('[LedStatusFragment] Switched away from LED Status tab to index ${widget.tabController.index} - pausing auto-refresh');
      }
    }
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

  void _startAutoRefreshTimer() {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      
      // Only refresh if on LED Status tab AND device is ready AND not already busy
      if (_isPageActive && 
          widget.bleManager.isConnected && 
          widget.bleManager.isDeviceActivated && 
          !widget.bleManager.isCheckingActivation &&
          !_isLoading &&
          !_isSilentRefresh) {
        print('[LedStatusFragment] Auto-refreshing LED status (every 5 seconds)');
        _silentRefresh();
      } else {
        print('[LedStatusFragment] Skipping auto-refresh - Page active: $_isPageActive, Connected: ${widget.bleManager.isConnected}, Activated: ${widget.bleManager.isDeviceActivated}, Loading: $_isLoading, Silent refresh in progress: $_isSilentRefresh');
      }
    });
  }

  void _silentRefresh() async {
    if (!mounted) return;
    
    if (!widget.bleManager.isConnected) {
      return;
    }

    // Re-register callback in case another fragment overwrote it
    widget.bleManager.onModbusResponse = _handleModbusResponse;

    try {
      // Mark as silent refresh (don't show loading indicator)
      _isSilentRefresh = true;

      // Write 3 to register 0
      await widget.bleManager.writeRegisters(startRegister: 0, values: [3]);
      
      // Wait 3 seconds
      await Future.delayed(const Duration(seconds: 3));
      
      // Re-register callback right before reading to ensure it's still active
      widget.bleManager.onModbusResponse = _handleModbusResponse;
      
      // Read registers (same as _sendCommand)
      await widget.bleManager.readRegisters(startRegister: 2, quantity: 35);
      
      // Timeout handler
      _parseTimeoutTimer?.cancel();
      _parseTimeoutTimer = Timer(const Duration(seconds: 8), () {
        if (_isSilentRefresh && mounted) {
          setState(() {
            _isSilentRefresh = false;
            _errorMessage = 'Silent refresh timeout';
          });
        }
      });
    } catch (e) {
      print('[LedStatusFragment] Silent refresh error: $e');
      if (mounted) {
        setState(() {
          _isSilentRefresh = false;
        });
      }
    }
  }

  void _onBLEUpdate() {
    if (!mounted) return;
    
    // Check if we just connected
    final isConnectedNow = widget.bleManager.isConnected;
    final isCheckingActivationNow = widget.bleManager.isCheckingActivation;
    
    if (isConnectedNow && !_wasConnected && !_isLoading && 
        !widget.bleManager.isCheckingActivation) {
      // Connection just established and not checking activation, trigger auto-load
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted && widget.bleManager.isConnected && 
            !widget.bleManager.isCheckingActivation &&
            widget.bleManager.isDeviceActivated) {
          _sendCommand();
        }
      });
    }
    
    // Check if activation check just completed successfully
    if (_wasCheckingActivation && !isCheckingActivationNow && 
        widget.bleManager.isDeviceActivated && !_isLoading) {
      // Activation check just completed successfully, auto-reload LED status
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted && widget.bleManager.isConnected && 
            widget.bleManager.isDeviceActivated) {
          _sendCommand();
        }
      });
    }

    // If disconnected, clear LED data so stale blinking/status does not remain
    if (_wasConnected && !isConnectedNow) {
      setState(() {
        _numChannels = 0;
        _sfStatus = 0;
        _pfStatus = 0;
        _channelStatuses.clear();
        _isLoading = false;
        _isSilentRefresh = false;
        _errorMessage = null;
      });
    }
    
    _wasConnected = isConnectedNow;
    _wasCheckingActivation = isCheckingActivationNow;
    
    setState(() {});
  }

  void _handleModbusResponse() {
    print('[LedStatusFragment] _handleModbusResponse called, mounted=$mounted, _isLoading=$_isLoading, _isSilentRefresh=$_isSilentRefresh');
    
    // For silent refresh, we don't check _isLoading
    // For regular load, we check _isLoading
    if (!mounted) return;
    if (!_isLoading && !_isSilentRefresh) return;
    
    final response = widget.bleManager.lastModbusResponse;
    print('[LedStatusFragment] Response length: ${response.length}, FC: ${response.length > 1 ? response[1] : "N/A"}');
    
    // Check if this is a read response (FC 3)
    if (response.length < 2 || response[1] != 0x03) {
      return;
    }
    
    final values = widget.bleManager.parseReadResponse(response);
    print('[LedStatusFragment] Parsed values: $values');
    if (values.isEmpty) {
      setState(() {
        _isLoading = false;
        _isSilentRefresh = false;
      });
      return;
    }
    
    // Cancel timeout timer since we got data
    _parseTimeoutTimer?.cancel();
    
    setState(() {
      // First value is FIELD_1 (Register 2) = num channels
      if (values.isNotEmpty) {
        _numChannels = values[0];
      }
      
      // Second value is FIELD_2 (Register 3) = SF status
      if (values.length > 1) {
        _sfStatus = values[1];
      }
      
      // Third value is FIELD_3 (Register 4) = PF status
      if (values.length > 2) {
        _pfStatus = values[2];
      }
      
      // Remaining values are FIELD_4+ (Register 5+) = channel LED statuses
      _channelStatuses.clear();
      for (int i = 3; i < values.length && (i - 3) < _numChannels; i++) {
        _channelStatuses.add(values[i]);
      }
      
      _isLoading = false;
      _isSilentRefresh = false;
      _errorMessage = null;
    });
    
    if (_isSilentRefresh) {
      print('[LedStatusFragment] Silent refresh completed successfully');
    }
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

    // Re-register callback in case another fragment overwrote it
    widget.bleManager.onModbusResponse = _handleModbusResponse;

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

      // Write 3 to register 0
      await widget.bleManager.writeRegisters(startRegister: 0, values: [3]);
      
      // Wait 3 seconds
      await Future.delayed(const Duration(seconds: 3));
      
      // Re-register callback right before reading to ensure it's still active
      widget.bleManager.onModbusResponse = _handleModbusResponse;
      
      // Read registers:
      // FIELD_1 (Register 2) = num channels
      // FIELD_2 (Register 3) = SF status
      // FIELD_3 (Register 4) = PF status
      // FIELD_4+ (Register 5+) = channel statuses
      // Read up to 35 registers (3 status + 32 channel statuses max)
      await widget.bleManager.readRegisters(startRegister: 2, quantity: 35);
      
      // Timeout handler - longer timeout for large register reads
      _parseTimeoutTimer?.cancel();
      _parseTimeoutTimer = Timer(const Duration(seconds: 8), () {
        if (_isLoading && mounted) {
          setState(() {
            _isLoading = false;
            _errorMessage = 'Response timeout - device did not respond';
          });
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
                : _buildLedPanel(),
          ),
        ],
      ),
    );
  }

  Widget _buildLedPanel() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final displayWidth = constraints.maxWidth < 500
            ? constraints.maxWidth * 0.85
            : 400.0;

        const maxLedSize = 35.0;
        const minLedSize = 12.0;
        const rowGap = 0.5;

        double ledSize = maxLedSize;

        if (_numChannels > 0) {
          final fixedSectionHeight = 95.0;
          final availableChannelHeight = (constraints.maxHeight * 0.98) - fixedSectionHeight;
          final fitSize = ((availableChannelHeight / _numChannels) - rowGap).clamp(minLedSize, maxLedSize);
          ledSize = fitSize;
        }

        final panel = Container(
          width: displayWidth,
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
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                      Container(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Text(
                          widget.deviceDisplayName,
                          style: const TextStyle(
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
                        margin: const EdgeInsets.symmetric(horizontal: 8),
                      ),

                      const SizedBox(height: 4),

                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _buildTopLED('SF', _sfStatus, ledSize),
                          const SizedBox(width: 3),
                          _buildTopLED(
                            'PF',
                            _pfStatus,
                            ledSize,
                            showLabel: widget.deviceDisplayName == 'ELS',
                          ),
                        ],
                      ),

                      const SizedBox(height: 0.5),

                      if (_numChannels > 0)
                        Column(
                          mainAxisAlignment: MainAxisAlignment.start,
                          children: List.generate(_numChannels, (index) {
                            final channelNum = _numChannels - index;
                            final channelStatus = (channelNum - 1) < _channelStatuses.length
                                ? _channelStatuses[channelNum - 1]
                                : 0;

                            return _buildChannelRow(
                              channelNum,
                              channelStatus,
                              ledSize,
                              rowGap / 2,
                            );
                          }),
                        )
                      else
                        const SizedBox(
                          height: 120,
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

                      Padding(
                        padding: const EdgeInsets.only(bottom: 6, top: 2),
                        child: Text(
                          'Levelstate',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                ],
              ),
            ),
          ),
        );

        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(child: panel),
          ),
        );
      },
    );
  }
  
  Widget _buildTopLED(String label, int status, double size, {bool showLabel = true}) {
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
        Visibility(
          visible: showLabel,
          maintainSize: true,
          maintainAnimation: true,
          maintainState: true,
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        const SizedBox(height: 2),
        Container(
          width: size,
          height: size,
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
  
  Widget _buildChannelRow(
    int channelNum,
    int channelStatus,
    double ledSize,
    double verticalPadding,
  ) {
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
    
    final channelFontSize = ledSize < 14 ? ledSize : 14.0;

    return Padding(
      padding: EdgeInsets.symmetric(vertical: verticalPadding),
      child: Row(
        children: [
          // Left spacer for centering
          Expanded(
            flex: 2,
            child: Container(),
          ),
          
          // Left LED (Green) - Square
          Container(
            width: ledSize,
            height: ledSize,
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
          
          const SizedBox(width: 3),
          
          // Right LED (Red) - Square
          Container(
            width: ledSize,
            height: ledSize,
            decoration: BoxDecoration(
              color: rightOn ? Color(0xFFFC1303) : Colors.grey[850],
              border: Border.all(
                color: Colors.grey[700]!,
                width: 2,
              ),
              boxShadow: rightOn ? [
                BoxShadow(
                  color: Color(0xFFFC1303).withOpacity(0.9),
                  blurRadius: 10,
                  spreadRadius: 2,
                ),
              ] : null,
            ),
          ),
          
          // Right spacer with channel number
          Expanded(
            flex: 2,
            child: SizedBox(
              height: ledSize,
              child: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  '$channelNum',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: channelFontSize,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
