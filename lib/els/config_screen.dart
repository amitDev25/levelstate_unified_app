import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'main.dart' show BLEManager, BLEHeader;

// ─────────────────────────────────────────────────────────────
// TAB 3: CONFIG SCREEN  (optimized with bulk register read)
// ─────────────────────────────────────────────────────────────
// Reads all config registers (33-63) in one command
// Writes only modified register groups to preserve device values
// ─────────────────────────────────────────────────────────────

class ConfigScreen extends StatefulWidget {
  final BLEManager ble;
  final bool? isSaved;
  final VoidCallback? onToggleSave;
  
  const ConfigScreen({
    super.key, 
    required this.ble,
    this.isSaved,
    this.onToggleSave,
  });

  @override
  State<ConfigScreen> createState() => _ConfigScreenState();
}

class _ConfigScreenState extends State<ConfigScreen> {
  String? _conductivityValue;
  final _faultDelayCtrl   = TextEditingController();
  String _shortCircuit       = 'No';
  String _openCircuit        = 'No';
  String _verticalValidation = 'No';
  String _contamination      = 'No';

  // ── Optimized bulk read state ──
  bool _isReading        = false;
  // Tracks the rxFrameCount we last handled so we fire handleRX exactly
  // once per new frame — dart equivalent of Swift's onReceive(ble.$lastRXFrame).
  int  _lastHandledRxCount = 0;
  int? _pendingReg42Value;
  
  // Bulk read: registers 33-63 (qty 31) - covers all config registers
  static const int _bulkReadStart = 33;
  static const int _bulkReadQty = 31;

  bool _saving  = false;
  bool _writing = false;

  @override
  void initState() {
    super.initState();
    widget.ble.addListener(_onBLENotify);
    // Mirrors Swift's .onAppear { startSequentialRead() }
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => _startSequentialRead());
  }

  @override
  void dispose() {
    widget.ble.removeListener(_onBLENotify);
    _faultDelayCtrl.dispose();
    super.dispose();
  }

  // ── Dart equivalent of Swift's .onReceive(ble.$lastRXFrame) ──
  // Called on every BLEManager notifyListeners(). Guards ensure we only
  // act when (a) we are in a read session and (b) the frame is genuinely new.
  void _onBLENotify() {
    if (!_isReading) return;
    // Only proceed when rxFrameCount has advanced — a brand-new frame arrived.
    if (widget.ble.rxFrameCount == _lastHandledRxCount) return;
    _lastHandledRxCount = widget.ble.rxFrameCount;
    _handleRX(widget.ble.lastRXFrame);
  }

  // ── Optimized bulk read: single command reads all config registers ──
  void _startSequentialRead() {
    _lastHandledRxCount = widget.ble.rxFrameCount; // ignore any stale frame
    _pendingReg42Value = null;
    if (mounted) setState(() => _isReading = true);
    // Read registers 33-63 (qty 31) in one command
    widget.ble.sendModbus(slave: 247, function: 3, start: _bulkReadStart, qty: _bulkReadQty);
  }

  // ── Handle bulk RX response: parse all registers at once ──
  void _handleRX(Uint8List frame) {
    if (frame.length < 3) return;

    // Modbus response: [slave][function][byteCount][data...][crc][crc]
    final byteCount = frame[2];
    if (frame.length < 3 + byteCount) {
      if (mounted) setState(() => _isReading = false);
      return;
    }

    // Stage 1: Bulk response for registers 33-63
    if (byteCount == _bulkReadQty * 2) {
      int getRegisterValue(int regNum) {
        final offset = (regNum - _bulkReadStart) * 2 + 3;
        if (offset + 1 >= frame.length) return 0;
        return (frame[offset] << 8) | frame[offset + 1];
      }

      setState(() {
        // Fault Delay (reg 33)
        final fdValue = getRegisterValue(33);
        _faultDelayCtrl.text = '${fdValue ~/ 100}';

        // Save reg 42 temporarily; final mapping set after reading 109-111
        _pendingReg42Value = getRegisterValue(42);

        // Contamination (reg 47)
        _contamination = getRegisterValue(47) == 0 ? 'No' : 'No';

        // Open Circuit (reg 54) & Short Circuit (reg 58)
        final openVal  = getRegisterValue(54);
        final shortVal = getRegisterValue(58);
        _openCircuit  = openVal  == 50 ? 'Yes' : 'No';
        _shortCircuit = shortVal == 8 ? 'Yes' : 'No';

        // Vertical Validation (reg 63)
        _verticalValidation = getRegisterValue(63) == 1 ? 'Yes' : 'No';
      });

      // Stage 2 read: compare reg 42 with reg 109/110/111
      widget.ble.sendModbus(slave: 247, function: 3, start: 109, qty: 3);
      return;
    }

    // Stage 2 response for registers 109-111 (3 regs = 6 bytes)
    if (byteCount == 6) {
      final reg109 = (frame[3] << 8) | frame[4];
      final reg110 = (frame[5] << 8) | frame[6];
      final reg111 = (frame[7] << 8) | frame[8];
      final condValue = _pendingReg42Value;

      setState(() {
        if (condValue != null && condValue == reg109) {
          _conductivityValue = '0.5';
        } else if (condValue != null && condValue == reg110) {
          _conductivityValue = '1';
        } else if (condValue != null && condValue == reg111) {
          _conductivityValue = '2';
        } else {
          _conductivityValue = null;
        }
        _pendingReg42Value = null;
        _isReading = false;
      });
      return;
    }

    if (mounted) {
      setState(() {
        _pendingReg42Value = null;
        _isReading = false;
      });
    }
  }

  void _saveConfiguration() {
    setState(() => _saving = true);
    widget.ble.sendModbusWrite(slave: 247, start: 16, values: [3]);
    for(int i = 1; i <=5; i++) {
      Future.delayed(Duration(milliseconds: 1700 + i * 200), () {
        if (mounted) widget.ble.sendModbusWrite(slave: 247, start: 16, values: [1]);
      });
    }
    widget.ble.logs.add('=== Save Configuration ===');
    Future.delayed(const Duration(milliseconds: 1500),
        () { if (mounted) setState(() => _saving = false); });
  }

  void _factoryReset() {
    widget.ble.sendModbusWrite(slave: 247, start: 16, values: [4]);
    widget.ble.logs.add('=== Factory Reset ===');
  }

  void _deactivateDevice() {
    setState(() => _writing = true);
    widget.ble.logs.add('=== Deactivate Device ===');
    widget.ble.logs.add('Writing 0 to reg 93-108');

    const int chunkSize = 5; // keep BLE packet within characteristic write limit
    final List<int> allValues = List.filled(16, 0);
    int offset = 0;
    int delayMs = 0;

    while (offset < allValues.length) {
      final chunkEnd = (offset + chunkSize) > allValues.length
          ? allValues.length
          : (offset + chunkSize);
      final chunk = allValues.sublist(offset, chunkEnd);
      final startReg = 93 + offset;

      Future.delayed(Duration(milliseconds: delayMs), () {
        if (!mounted) return;
        widget.ble.sendModbusWrite(
          slave: 247,
          start: startReg,
          values: chunk,
        );
      });

      offset = chunkEnd;
      delayMs += 200;
    }

    Future.delayed(Duration(milliseconds: delayMs + 400), () {
      if (mounted) setState(() => _writing = false);
    });
  }

  Future<int?> _readSingleRegister(int reg,
      {Duration timeout = const Duration(seconds: 3)}) async {
    final completer = Completer<int?>();
    int observedRxCount = widget.ble.rxFrameCount;

    late VoidCallback listener;
    listener = () {
      if (widget.ble.rxFrameCount == observedRxCount) return;
      observedRxCount = widget.ble.rxFrameCount;

      final frame = widget.ble.lastRXFrame;
      if (frame.length < 7) return;
      if (frame[0] != 247 || frame[1] != 3 || frame[2] != 2) return;

      final value = (frame[3] << 8) | frame[4];
      if (!completer.isCompleted) completer.complete(value);
      widget.ble.removeListener(listener);
    };

    widget.ble.addListener(listener);
    widget.ble.sendModbus(slave: 247, function: 3, start: reg, qty: 1);
    await Future.delayed(const Duration(milliseconds: 220));

    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      widget.ble.removeListener(listener);
      return null;
    }
  }

  Future<void> _writeToDevice() async {
    setState(() => _writing = true);

    widget.ble.logs.add('=== Starting Config Write ===');

    int delayMs = 0;

    // Conductivity (reg 42-45)
    final condText = _conductivityValue?.trim() ?? '';
    if (condText.isNotEmpty) {
      int? sourceReg;
      switch (condText) {
        case '0.5':
          sourceReg = 109;
          break;
        case '1':
          sourceReg = 110;
          break;
        case '2':
          sourceReg = 111;
          break;
        default:
          sourceReg = null;
          break;
      }

      int cv = int.tryParse(condText) ?? 0;
      if (sourceReg != null) {
        widget.ble.logs.add('[2] Reading conductivity source from reg $sourceReg');
        final readValue = await _readSingleRegister(sourceReg);
        if (readValue == null) {
          widget.ble.logs.add('[2] ERROR: Failed to read reg $sourceReg');
        } else {
          cv = readValue;
          widget.ble.logs.add('[2] Read reg $sourceReg = $cv');
        }
      }

      if (cv > 0) {
        final cvLowRange = cv+20;

        Future.delayed(Duration(milliseconds: delayMs), () {
          if (!mounted) return;
          widget.ble.logs.add('[2] Conductivity formula value: $cvLowRange → reg 38-41');
          widget.ble.sendModbusWrite(
            slave: 247,
            start: 38,
            values: [cvLowRange, cvLowRange, cvLowRange, cvLowRange],
          );
        });
        delayMs += 300;

        Future.delayed(Duration(milliseconds: delayMs), () {
          if (!mounted) return;
          widget.ble.logs.add('[2] Conductivity: $cv (from $condText selection) → reg 42-45');
          widget.ble.sendModbusWrite(slave: 247, start: 42, values: [cv, cv, cv, cv]);
        });
        delayMs += 300;
      }
    }

    // Fault delay (reg 33) - keep after conductivity read to avoid read/write collision
    final dv = int.tryParse(_faultDelayCtrl.text.trim());
    if (dv != null) {
      Future.delayed(Duration(milliseconds: delayMs), () {
        if (!mounted) return;
        widget.ble.logs.add('[1] Fault Delay: ${dv * 100}ms → reg 33');
        widget.ble.sendModbusWrite(slave: 247, start: 33, values: [dv * 100]);
      });
      delayMs += 300;
    }

    // Contamination (reg 47)
    Future.delayed(Duration(milliseconds: delayMs), () {
      if (!mounted) return;
      final contValue = _contamination == 'No' ? 0 : 0;
      widget.ble.logs.add('[3] Contamination: $_contamination → reg 47');
      widget.ble.sendModbusWrite(slave: 247, start: 47, values: [contValue, contValue, contValue]);
    });
    delayMs += 300;

    // Open circuit (reg 54-57)
    final ov = _openCircuit == 'Yes' ? 50 : 2000;
    Future.delayed(Duration(milliseconds: delayMs), () {
      if (!mounted) return;
      widget.ble.logs.add('[4] Open Circuit: $_openCircuit → reg 54-57');
      widget.ble.sendModbusWrite(slave: 247, start: 54, values: [ov, ov, ov, ov]);
    });
    delayMs += 300;

    // Short circuit (reg 58-61)
    final sv = _shortCircuit == 'Yes' ? 8 : 0;
    Future.delayed(Duration(milliseconds: delayMs), () {
      if (!mounted) return;
      widget.ble.logs.add('[5] Short Circuit: $_shortCircuit → reg 58-61');
      widget.ble.sendModbusWrite(slave: 247, start: 58, values: [sv, sv, sv, sv]);
    });
    delayMs += 300;

    // Vertical validation (reg 63)
    final vv = _verticalValidation == 'Yes' ? 1 : 0;
    Future.delayed(Duration(milliseconds: delayMs), () {
      if (!mounted) return;
      widget.ble.logs.add('[6] Vertical Validation: $_verticalValidation → reg 63');
      widget.ble.sendModbusWrite(slave: 247, start: 63, values: [vv, vv, vv, vv]);
    });
    delayMs += 300;

    Future.delayed(Duration(milliseconds: delayMs), () {
      if (mounted) {
        widget.ble.logs.add('=== Write Complete ===');
        setState(() => _writing = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      BLEHeader(
        ble: widget.ble, 
        title: 'ELS',
        isSaved: widget.isSaved,
        onToggleSave: widget.onToggleSave,
      ),

      // Busy banner
      if (_isReading || _saving || _writing)
        Container(
          width: double.infinity,
          color: const Color(0xFF1A1A2E),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(children: [
            const SizedBox(
                width: 12, height: 12,
                child: CircularProgressIndicator(
                    strokeWidth: 1.5, color: Color(0xFF00E5FF))),
            const SizedBox(width: 10),
            Text(
              _isReading ? 'Reading configuration...'
                  : _saving  ? 'Saving to device...'
                  : 'Writing to device...',
              style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 12),
            ),
          ]),
        ),

      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            // Header row
            Row(children: [
              const Text('Configuration',
                  style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.white)),
              const Spacer(),
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
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ]),
            const SizedBox(height: 14),

            _FormCard(
              title: 'Conductivity (µ Siemens)',
              child: DropdownButtonFormField<String>(
                value: _conductivityValue,
                items: const [
                  DropdownMenuItem(value: '0.5', child: Text('0.5')),
                  DropdownMenuItem(value: '1', child: Text('1')),
                  DropdownMenuItem(value: '2', child: Text('2')),
                ],
                onChanged: (value) => setState(() => _conductivityValue = value),
                hint: const Text('Select'),
                style: const TextStyle(color: Colors.white),
                dropdownColor: const Color(0xFF1A1A2E),
                decoration: _fd('Select'),
              ),
            ),
            const SizedBox(height: 10),
            _FormCard(
              title: 'System Fault Time Delay (ms)',
              child: TextField(
                controller: _faultDelayCtrl,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: Colors.white),
                decoration: _fd('ms'),
              ),
            ),
            const SizedBox(height: 10),
            _FormCard(
              title: 'Short Circuit',
              child: _YesNoPicker(
                  value: _shortCircuit,
                  onChanged: (v) => setState(() => _shortCircuit = v)),
            ),
            const SizedBox(height: 10),
            _FormCard(
              title: 'Open Circuit',
              child: _YesNoPicker(
                  value: _openCircuit,
                  onChanged: (v) => setState(() => _openCircuit = v)),
            ),
            const SizedBox(height: 10),
            _FormCard(
              title: 'Vertical Validation',
              child: _YesNoPicker(
                  value: _verticalValidation,
                  onChanged: (v) => setState(() => _verticalValidation = v)),
            ),
            const SizedBox(height: 10),
            _FormCard(
              title: 'Contamination',
              child: _YesNoPicker(
                  value: _contamination,
                  onChanged: (v) => setState(() => _contamination = v)),
            ),
            const SizedBox(height: 20),

            // Action buttons
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _saving ? null : _saveConfiguration,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF00E5FF),
                    side: const BorderSide(color: Color(0xFF00E5FF)),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('Save'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: ElevatedButton(
                  onPressed: _writing ? null : _writeToDevice,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00E5FF),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('Write to Device',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: _factoryReset,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.orange,
                    side: const BorderSide(color: Colors.orange),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('Factory\nReset',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11)),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: _writing ? null : _deactivateDevice,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.redAccent,
                  side: const BorderSide(color: Colors.redAccent),
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: const Text('Deactivate',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 16),
          ]),
        ),
      ),
    ]);
  }

  InputDecoration _fd(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white38),
        filled: true,
        fillColor: const Color(0xFF0D0D1A),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Colors.white12)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Colors.white12)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF00E5FF))),
      );
}

// ── Form card ──
class _FormCard extends StatelessWidget {
  final String title;
  final Widget child;
  const _FormCard({required this.title, required this.child});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white10),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withOpacity(0.3),
                blurRadius: 4,
                offset: const Offset(0, 2))
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.white)),
            const SizedBox(height: 8),
            child,
          ],
        ),
      );
}

// ── Yes / No segmented picker ──
class _YesNoPicker extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _YesNoPicker({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: ['Yes', 'No'].map((opt) {
        final sel = value == opt;
        return Expanded(
          child: GestureDetector(
            onTap: () => onChanged(opt),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.symmetric(horizontal: 3),
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: sel ? const Color(0xFF00E5FF) : const Color(0xFF0D0D1A),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: sel ? const Color(0xFF00E5FF) : Colors.white24),
              ),
              alignment: Alignment.center,
              child: Text(opt,
                  style: TextStyle(
                      color: sel ? Colors.black : Colors.white70,
                      fontWeight: FontWeight.w600,
                      fontSize: 13)),
            ),
          ),
        );
      }).toList(),
    );
  }
}