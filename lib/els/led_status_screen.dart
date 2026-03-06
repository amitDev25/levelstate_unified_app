import 'dart:async';
import 'package:flutter/material.dart';
import 'main.dart' show BLEManager, BLEHeader;

// ─────────────────────────────────────────────────────────────
// TAB 1: LED STATUS SCREEN
// Layout:
//   ELS200+ title bar (black)
//   SF [yellow] [yellow] PF   ← reg[9], reg[8]
//   Row 4: [green reg7] [red reg6]  4
//   Row 3: [green reg5] [red reg4]  3
//   Row 2: [green reg3] [red reg2]  2
//   Row 1: [green reg1] [red reg0]  1
// ─────────────────────────────────────────────────────────────
class LEDStatusScreen extends StatefulWidget {
  final BLEManager ble;
  const LEDStatusScreen({super.key, required this.ble});

  @override
  State<LEDStatusScreen> createState() => _LEDStatusScreenState();
}

class _LEDStatusScreenState extends State<LEDStatusScreen> {
  Timer? _countdownTimer;
  int _secondsUntilPoll = 5;

  @override
  void initState() {
    super.initState();
    widget.ble.addListener(_onBLEUpdate);
    _startCountdown();
  }

  @override
  void dispose() {
    widget.ble.removeListener(_onBLEUpdate);
    _countdownTimer?.cancel();
    super.dispose();
  }

  void _onBLEUpdate() {
    if (mounted) setState(() => _secondsUntilPoll = 5);
  }

  void _startCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() { if (_secondsUntilPoll > 0) _secondsUntilPoll--; });
    });
  }

  @override
  Widget build(BuildContext context) {
    final ble = widget.ble;
    return Column(children: [
      BLEHeader(ble: ble, title: 'LED STATUS'),

      // Poll status bar
      if (ble.isConnected)
        Container(
          width: double.infinity,
          color: const Color(0xFF12121F),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(children: [
            if (ble.isPolling) ...[
              SizedBox(
                width: 10, height: 10,
                child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: Colors.greenAccent.withOpacity(0.8)),
              ),
              const SizedBox(width: 8),
              Text(
                _secondsUntilPoll == 0
                    ? 'Polling...'
                    : 'Next poll in ${_secondsUntilPoll}s',
                style: const TextStyle(
                    color: Colors.greenAccent, fontSize: 11, letterSpacing: 0.5),
              ),
            ] else
              const Text('Polling stopped',
                  style: TextStyle(color: Colors.white38, fontSize: 11)),
            const Spacer(),
            GestureDetector(
              onTap: () {
                ble.startLEDPolling();
                setState(() => _secondsUntilPoll = 5);
              },
              child: const Icon(Icons.refresh_rounded,
                  size: 16, color: Color(0xFF00E5FF)),
            ),
          ]),
        ),

      // Main LED panel
      Expanded(
        child: Container(
          color: Colors.white,
          child: Column(children: [
            // ELS200+ title
            Container(
              width: double.infinity,
              color: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: const Text('ELS300+',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                      letterSpacing: 1.5)),
            ),

            // LED grid
            Expanded(
              child: Container(
                color: Colors.black,
                margin: const EdgeInsets.fromLTRB(30, 20, 30, 20),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: [
                    const SizedBox(height: 30),

                    // SF / PF (yellow)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const _LEDLabel('SF'),
                        const SizedBox(width: 12),
                        _LEDCell(
                          key: ValueKey('sf_${ble.ledRegisters[9]}'),
                          value: ble.ledRegisters[9],
                          color: Colors.yellow,
                        ),
                        const SizedBox(width: 12),
                        _LEDCell(
                          key: ValueKey('pf_${ble.ledRegisters[8]}'),
                          value: ble.ledRegisters[8],
                          color: Colors.yellow,
                        ),
                        const SizedBox(width: 12),
                        const _LEDLabel('PF'),
                      ],
                    ),

                    const SizedBox(height: 20),

                    // Channel rows 4 → 1
                    for (int row = 0; row < 4; row++) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const SizedBox(width: 40),
                            _LEDCell(
                              key: ValueKey('g${row}_${ble.ledRegisters[7 - row * 2]}'),
                              value: ble.ledRegisters[7 - row * 2],
                              color: Colors.green,
                            ),
                            const SizedBox(width: 12),
                            _LEDCell(
                              key: ValueKey('r${row}_${ble.ledRegisters[6 - row * 2]}'),
                              value: ble.ledRegisters[6 - row * 2],
                              color: Colors.red,
                            ),
                            const SizedBox(width: 12),
                            SizedBox(
                              width: 40,
                              child: Text('${4 - row}',
                                  style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w500,
                                      color: Colors.white)),
                            ),
                          ],
                        ),
                      ),
                    ],

                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ),
          ]),
        ),
      ),
    ]);
  }
}

// ── LED label (SF / PF) ──
class _LEDLabel extends StatelessWidget {
  final String text;
  const _LEDLabel(this.text);

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 40,
        child: Text(text,
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 14, fontWeight: FontWeight.w500, color: Colors.white)),
      );
}

// ── LED cell wrapper — key forces recreation on value change ──
class _LEDCell extends StatelessWidget {
  final int value;
  final Color color;
  const _LEDCell({super.key, required this.value, required this.color});

  @override
  Widget build(BuildContext context) =>
      _BlinkingLED(value: value, color: color);
}

// ── Blinking LED
//   0 → OFF dark gray
//   1 → ON solid color
//   2 → BLINK slow 1 Hz (500 ms)
//   3 → BLINK fast 2 Hz (250 ms)
class _BlinkingLED extends StatefulWidget {
  final int value;
  final Color color;
  const _BlinkingLED({required this.value, required this.color});

  @override
  State<_BlinkingLED> createState() => _BlinkingLEDState();
}

class _BlinkingLEDState extends State<_BlinkingLED>
    with SingleTickerProviderStateMixin {
  AnimationController? _ctrl;
  Animation<double>? _anim;

  @override
  void initState() {
    super.initState();
    _startAnimation();
  }

  @override
  void didUpdateWidget(_BlinkingLED old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) {
      _ctrl?.dispose();
      _ctrl = null;
      _anim = null;
      _startAnimation();
    }
  }

  void _startAnimation() {
    final blink = widget.value == 2 || widget.value == 3;
    if (!blink) return;
    final ms = widget.value == 2 ? 500 : 250;
    _ctrl = AnimationController(
        vsync: this, duration: Duration(milliseconds: ms))
      ..repeat(reverse: true);
    _anim = Tween<double>(begin: 1.0, end: 0.15)
        .animate(CurvedAnimation(parent: _ctrl!, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  Color get _ledColor {
    switch (widget.value) {
      case 0:  return const Color(0xFF4D4D4D);
      case 1:  return widget.color;
      case 2:
      case 3:  return widget.color;
      default: return Colors.red;
    }
  }

  @override
  Widget build(BuildContext context) {
    final blink = widget.value == 2 || widget.value == 3;
    final cell = Container(
      width: 50, height: 50,
      decoration: BoxDecoration(
        color: _ledColor,
        borderRadius: BorderRadius.circular(4),
        boxShadow: widget.value != 0
            ? [BoxShadow(
                color: _ledColor.withOpacity(0.6),
                blurRadius: 8, spreadRadius: 1)]
            : null,
      ),
    );
    if (blink && _anim != null) {
      return FadeTransition(opacity: _anim!, child: cell);
    }
    return cell;
  }
}
