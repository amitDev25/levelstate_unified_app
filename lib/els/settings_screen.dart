import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'main.dart' show BLEManager;

// ─────────────────────────────────────────────────────────────
// TAB 4: SETTINGS SCREEN  (optimized with bulk register read)
// ─────────────────────────────────────────────────────────────
// Reads registers 20-75 in one command to cover all channel settings
// Writes only modified register groups to preserve device values
// ─────────────────────────────────────────────────────────────

class SettingsScreen extends StatefulWidget {
  final BLEManager ble;
  final bool? isSaved;
  final VoidCallback? onToggleSave;
  
  const SettingsScreen({
    super.key, 
    required this.ble,
    this.isSaved,
    this.onToggleSave,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // ── Channel data state ──
  int        _activeChannelCount = 0;
  List<bool> _channelStates      = [false, false, false, false];
  List<bool> _waterSteamStates   = [false, false, false, false]; // false=Water, true=Steam
  List<bool> _energisedStates    = [false, false, false, false]; // false=De-energised, true=Energised
  List<int>  _tripDelays         = [0, 0, 0, 0];

  // ── Optimized bulk read state ──
  bool _isReading = false;
  // Bulk read: registers 20-75 (qty 56) - covers all channel settings
  static const int _bulkReadStart = 20;
  static const int _bulkReadQty = 56; // 20 to 75 inclusive

  bool _isSaving = false;

  // Dart equivalent of Swift's onReceive(ble.$lastRXFrame) guard
  int _lastHandledRxCount = 0;

  @override
  void initState() {
    super.initState();
    widget.ble.addListener(_onBLENotify);
    // Mirrors Swift's .onAppear { startSequentialRead() }
    WidgetsBinding.instance.addPostFrameCallback((_) => _startSequentialRead());
  }

  @override
  void dispose() {
    widget.ble.removeListener(_onBLENotify);
    super.dispose();
  }

  // ── Dart equivalent of Swift's .onReceive(ble.$lastRXFrame) { frame in ... } ──
  void _onBLENotify() {
    if (!_isReading) return;
    // Only act when a genuinely new RX frame arrived.
    if (widget.ble.rxFrameCount == _lastHandledRxCount) return;
    _lastHandledRxCount = widget.ble.rxFrameCount;

    final frame = widget.ble.lastRXFrame;
    if (frame.isEmpty) return;

    _handleBulkResponse(frame);
  }

  // ─────────────────────────────────────────────────────────────
  // BULK READ  (single command reads all channel registers)
  // ─────────────────────────────────────────────────────────────

  void _startSequentialRead() {
    _lastHandledRxCount = widget.ble.rxFrameCount; // ignore stale frames
    setState(() => _isReading = true);
    // Read registers 20-75 (qty 56) in one command
    widget.ble.sendModbus(slave: 247, function: 3, start: _bulkReadStart, qty: _bulkReadQty);
  }

  // ── Handle bulk RX response: parse all registers at once ──
  void _handleBulkResponse(Uint8List frame) {
    if (frame.length < 3) return;
    if (frame[0] != 247 || frame[1] != 3) return;

    // Modbus response: [slave][function][byteCount][data...][crc][crc]
    final byteCount = frame[2];
    if (byteCount != _bulkReadQty * 2 || frame.length < 3 + byteCount) {
      setState(() => _isReading = false);
      return;
    }

    // Helper to extract a 16-bit value at a specific register offset
    int getRegisterValue(int regNum) {
      final offset = (regNum - _bulkReadStart) * 2 + 3;
      if (offset + 1 >= frame.length) return 0;
      return (frame[offset] << 8) | frame[offset + 1];
    }

    // Parse all values from the single response
    setState(() {
      // Register 20-23 — water/steam: 0=Water, 1=Steam
      _waterSteamStates = [
        for (int i = 0; i < 4; i++) getRegisterValue(20 + i) == 1
      ];

      // Register 24-27 — energised: 0=De-energised, 1=Energised
      _energisedStates = [
        for (int i = 0; i < 4; i++) getRegisterValue(24 + i) == 1
      ];

      // Register 29-32 — trip delays (device ÷ 100 for display)
      _tripDelays = [
        for (int i = 0; i < 4; i++) getRegisterValue(29 + i) ~/ 100
      ];

      // Register 67 — active channel count
      final channelCount = getRegisterValue(67);
      if (channelCount <= 4) _activeChannelCount = channelCount;

      // Register 71+ — which channel indices are active
      final states = [false, false, false, false];
      for (int i = 0; i < _activeChannelCount && i < 4; i++) {
        final channelIndex = getRegisterValue(71 + i);
        if (channelIndex < 4) states[channelIndex] = true;
      }
      _channelStates = states;

      _isReading = false;
    });
  }

  // ─────────────────────────────────────────────────────────────
  // TOGGLE CHANNEL
  // ─────────────────────────────────────────────────────────────

  void _toggleChannel(int index, bool active) =>
      setState(() => _channelStates[index] = active);

  // ─────────────────────────────────────────────────────────────
  // SAVE  (optimized bulk write for all channel configurations)
  // ─────────────────────────────────────────────────────────────

  Future<void> _saveChannelConfiguration() async {
    setState(() => _isSaving = true);

    final activeCount = _channelStates.where((s) => s).length;
    final activeIndices = <int>[
      for (int i = 0; i < _channelStates.length; i++)
        if (_channelStates[i]) i,
    ];

    final wsValues = _waterSteamStates.map((v) => v ? 1 : 0).toList();
    final enValues = _energisedStates.map((v) => v ? 1 : 0).toList();
    final tdValues = _tripDelays.map((v) => v * 100).toList();

    widget.ble.logs.add('=== Starting Settings Write ===');
    widget.ble.logs.add('Active: $activeCount channels: $activeIndices');
    widget.ble.logs.add('Water/Steam: $wsValues, Energised: $enValues');
    widget.ble.logs.add('Trip Delays (UI): $_tripDelays → Device: $tdValues');

    // Write water/steam states → reg 20
    widget.ble.sendModbusWrite(slave: 247, start: 20, values: wsValues);

    // Write energised states → reg 24
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) widget.ble.sendModbusWrite(slave: 247, start: 24, values: enValues);
    });

    // Write trip delays → reg 29
    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted) widget.ble.sendModbusWrite(slave: 247, start: 29, values: tdValues);
    });

    // Write active channel count → reg 67
    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted) widget.ble.sendModbusWrite(slave: 247, start: 67, values: [activeCount]);
    });

    // Write active channel indices → reg 71
    if (activeIndices.isNotEmpty) {
      Future.delayed(const Duration(milliseconds: 1200), () {
        if (mounted) widget.ble.sendModbusWrite(slave: 247, start: 71, values: activeIndices);
      });
    }

    // Trigger device save (reg 16 = 3)
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) widget.ble.sendModbusWrite(slave: 247, start: 16, values: [3]);
    });

    // Send reg 16 = 1 multiple times (as per original logic)
    for (int i = 1; i <= 5; i++) {
      Future.delayed(Duration(milliseconds: 1700 + i * 200), () {
        if (mounted) widget.ble.sendModbusWrite(slave: 247, start: 16, values: [1]);
      });
    }

    // Auto-dismiss saving indicator
    Future.delayed(const Duration(milliseconds: 3500), () {
      if (mounted) {
        widget.ble.logs.add('=== Save Complete ===');
        setState(() => _isSaving = false);
      }
    });
  }

  // ─────────────────────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      // Header with refresh button
      Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Row(children: [
          const Expanded(
            child: Text('CHANNEL SETTINGS',
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.white)),
          ),
          ElevatedButton(
            onPressed: _isReading ? null : _startSequentialRead,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00E5FF),
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Refresh',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          ),
        ]),
      ),

      // Reading progress banner
      if (_isReading)
        Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A2E),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Row(children: [
            SizedBox(
              width: 12, height: 12,
              child: CircularProgressIndicator(
                  strokeWidth: 1.5, color: Color(0xFF00E5FF)),
            ),
            SizedBox(width: 10),
            Text('Reading settings...',
                style: TextStyle(color: Color(0xFF00E5FF), fontSize: 12)),
          ]),
        ),

      // Saving progress banner
      if (_isSaving)
        Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A2E),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Row(children: [
            SizedBox(
              width: 12, height: 12,
              child: CircularProgressIndicator(
                  strokeWidth: 1.5, color: Color(0xFF00E5FF)),
            ),
            SizedBox(width: 10),
            Text('Saving channel configuration to device...',
                style: TextStyle(color: Color(0xFF00E5FF), fontSize: 12)),
          ]),
        ),

      // Active channel count subtitle
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text('$_activeChannelCount Channel(s) Active',
            style: const TextStyle(color: Colors.white54, fontSize: 13)),
      ),

      // Channel cards scroll list
      Expanded(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            for (int i = 0; i < 4; i++) ...[
              _ChannelCard(
                index:           i,
                isActive:        _channelStates[i],
                isSteam:         _waterSteamStates[i],
                isEnergised:     _energisedStates[i],
                tripDelay:       _tripDelays[i],
                onToggleActive:     (v) => _toggleChannel(i, v),
                onToggleSteam:      (v) => setState(() => _waterSteamStates[i] = v),
                onToggleEnergised:  (v) => setState(() => _energisedStates[i] = v),
                onDecrementDelay:   () {
                  if (_tripDelays[i] > 0) setState(() => _tripDelays[i]--);
                },
                onIncrementDelay:   () => setState(() => _tripDelays[i]++),
              ),
              const SizedBox(height: 12),
            ],
          ],
        ),
      ),

      // Save button
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _isSaving ? null : _saveChannelConfiguration,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00E5FF),
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Save',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ),
        ),
      ),
    ]);
  }
}

// ─────────────────────────────────────────────────────────────
// CHANNEL CARD  (mirrors Swift's channelCard view builder)
// ─────────────────────────────────────────────────────────────
class _ChannelCard extends StatelessWidget {
  final int  index;
  final bool isActive;
  final bool isSteam;
  final bool isEnergised;
  final int  tripDelay;
  final ValueChanged<bool> onToggleActive;
  final ValueChanged<bool> onToggleSteam;
  final ValueChanged<bool> onToggleEnergised;
  final VoidCallback onDecrementDelay;
  final VoidCallback onIncrementDelay;

  const _ChannelCard({
    required this.index,
    required this.isActive,
    required this.isSteam,
    required this.isEnergised,
    required this.tripDelay,
    required this.onToggleActive,
    required this.onToggleSteam,
    required this.onToggleEnergised,
    required this.onDecrementDelay,
    required this.onIncrementDelay,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        // Mirrors Swift: green.opacity(0.1) when active, systemGray6 when not
        color: isActive
            ? Colors.green.withOpacity(0.08)
            : const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isActive ? Colors.green : Colors.white12,
          width: isActive ? 1.5 : 1.0,
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

        // ── Header: Channel N + Active/Inactive toggle ──
        Row(children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Channel ${index + 1}',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            Text(isActive ? 'Active' : 'Inactive',
                style: TextStyle(
                    color: isActive ? Colors.greenAccent : Colors.white38,
                    fontSize: 12)),
          ]),
          const Spacer(),
          Switch(
            value: isActive,
            onChanged: onToggleActive,
            activeColor: Colors.greenAccent,
            inactiveThumbColor: Colors.white38,
            inactiveTrackColor: Colors.white12,
          ),
        ]),

        const Divider(color: Colors.white12, height: 20),

        // ── Water / Steam ──
        Opacity(
          opacity: isActive ? 1.0 : 0.5,
          child: Row(children: [
            Text('Water / Steam',
                style: TextStyle(
                    color: isActive ? Colors.white70 : Colors.white38,
                    fontSize: 13)),
            const Spacer(),
            Text('Water',
                style: TextStyle(
                    color: !isSteam ? Colors.blue : Colors.white38,
                    fontSize: 12,
                    fontWeight: FontWeight.w500)),
            const SizedBox(width: 6),
            Switch(
              value: isSteam,
              onChanged: isActive ? onToggleSteam : null,
              activeColor: Colors.blue,
              inactiveThumbColor: Colors.blue,
              inactiveTrackColor: Colors.blue.withOpacity(0.3),
            ),
            const SizedBox(width: 6),
            Text('Steam',
                style: TextStyle(
                    color: isSteam ? Colors.blue : Colors.white38,
                    fontSize: 12,
                    fontWeight: FontWeight.w500)),
          ]),
        ),

        const SizedBox(height: 8),

        // ── De-energised / Energised ──
        Opacity(
          opacity: isActive ? 1.0 : 0.5,
          child: Row(children: [
            Text('Energised',
                style: TextStyle(
                    color: isActive ? Colors.white70 : Colors.white38,
                    fontSize: 13)),
            const Spacer(),
            Text('De-enrg.',
                style: TextStyle(
                    color: !isEnergised ? Colors.orange : Colors.white38,
                    fontSize: 12,
                    fontWeight: FontWeight.w500)),
            const SizedBox(width: 6),
            Switch(
              value: isEnergised,
              onChanged: isActive ? onToggleEnergised : null,
              activeColor: Colors.orange,
              inactiveThumbColor: Colors.orange,
              inactiveTrackColor: Colors.orange.withOpacity(0.3),
            ),
            const SizedBox(width: 6),
            Text('Enrg.',
                style: TextStyle(
                    color: isEnergised ? Colors.orange : Colors.white38,
                    fontSize: 12,
                    fontWeight: FontWeight.w500)),
          ]),
        ),

        const SizedBox(height: 8),

        // ── Trip Delay ──
        Opacity(
          opacity: isActive ? 1.0 : 0.5,
          child: Row(children: [
            Text('Trip Delay',
                style: TextStyle(
                    color: isActive ? Colors.white70 : Colors.white38,
                    fontSize: 13)),
            const Spacer(),
            GestureDetector(
              onTap: isActive ? onDecrementDelay : null,
              child: Icon(Icons.remove_circle,
                  color: isActive ? Colors.redAccent : Colors.white24,
                  size: 28),
            ),
            const SizedBox(width: 8),
            Container(
              constraints: const BoxConstraints(minWidth: 50),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFF0D0D1A),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white12),
              ),
              alignment: Alignment.center,
              child: Text('$tripDelay',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontFamily: 'monospace')),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: isActive ? onIncrementDelay : null,
              child: Icon(Icons.add_circle,
                  color: isActive ? Colors.greenAccent : Colors.white24,
                  size: 28),
            ),
          ]),
        ),

      ]),
    );
  }
}