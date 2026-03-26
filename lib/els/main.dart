import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import '../device_preferences.dart';
import 'led_status_screen.dart';
import 'config_screen.dart';
import 'settings_screen.dart';

// ─────────────────────────────────────────────────────────────
// ENTRY POINT
// ─────────────────────────────────────────────────────────────
void main() => runApp(const HMSoftApp());

class HMSoftApp extends StatelessWidget {
  final BluetoothDevice? autoConnectDevice;
  
  const HMSoftApp({super.key, this.autoConnectDevice});
  
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ELS300',
      theme: ThemeData(
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00E5FF),
          secondary: Color(0xFFFF6D00),
          surface: Color(0xFF1A1A2E),
          error: Color(0xFFCF6679),
        ),
        scaffoldBackgroundColor: const Color(0xFF0D0D1A),
        cardColor: const Color(0xFF1A1A2E),
        useMaterial3: true,
        fontFamily: 'monospace',
      ),
      home: MainScreen(autoConnectDevice: autoConnectDevice),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// RX INTENT
// Exactly one intent is active at a time.
// Activation reads get their own dedicated slots so they
// can never be confused with ledPoll, config, or custom frames.
// ─────────────────────────────────────────────────────────────
enum _RXIntent {
  idle,          // nothing sent yet, ignore stray bytes
  activation87,  // waiting for reg-87 response  (qty 6)
  activation93,  // waiting for reg-93 response  (qty 16)
  ledPoll,       // waiting for periodic LED poll response
  config,        // waiting for a config-read response
  custom,        // waiting for a user custom-command response
}

// ─────────────────────────────────────────────────────────────
// ACTIVATION STATUS
// ─────────────────────────────────────────────────────────────
enum ActivationStatus {
  unknown,         // freshly connected, check not run yet
  needsActivation, // reg-93 block is all zeros → show Activate button
  activating,      // API call + register writes in progress
  activated,       // hash present / just written → show normal UI
}

// ─────────────────────────────────────────────────────────────
// BLE MANAGER
// ─────────────────────────────────────────────────────────────
class BLEManager extends ChangeNotifier {
  // Same URL as Java postToHmacApi
  static const String hmacApiUrl   = 'https://hls-fv20.onrender.com/hmac';

  // ── BLE connection objects ──────────────────────────────────
  BluetoothDevice?           _device;
  BluetoothCharacteristic?   _writeChar;
  BluetoothCharacteristic?   _notifyChar;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<List<int>>?        _notifySub;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  bool   isConnected = false;
  String status      = 'Disconnected';
  
  // ── BLE device scanning ─────────────────────────────────────
  List<ScanResult> scannedDevices = [];
  bool isScanning = false;

  bool _isLsNamedDevice(BluetoothDevice device) {
    final platformName = device.platformName.trim().toUpperCase();
    final advertisedName = device.advName.trim().toUpperCase();
    return platformName.startsWith('LS') || advertisedName.startsWith('LS');
  }

  // ── RX reassembly ───────────────────────────────────────────
  final List<int> _rxBuffer = [];
  int?            _expectedLen;
  _RXIntent       _rxIntent = _RXIntent.idle;

  // Completers used to await individual activation reads
  // (replaces Java's blocking read_operation / delayRoutine loops)
  Completer<Uint8List>? _pendingCompleter;

  // ── Activation state ────────────────────────────────────────
  ActivationStatus activationStatus  = ActivationStatus.unknown;
  String           _reg87Data        = ''; // payload hex, no header, no CRC
  String           _reg93Data        = ''; // payload hex, no header, no CRC
  String           activationMessage = ''; // shown in UI on success/failure
  bool             activationError   = false;

  // ── LED registers (reg 4–13, qty 10) ───────────────────────
  List<int> ledRegisters = List.filled(10, 0);
  Timer?    _pollTimer;
  bool      _isPolling = false;
  bool get  isPolling  => _isPolling;

  // ── Config callback ─────────────────────────────────────────
  // ConfigScreen registers this; BLEManager calls it when a
  // _RXIntent.config frame arrives. Avoids polling the lastRXFrame.
  void Function(Uint8List)? onConfigFrame;

  // ── Logs + last raw frame (for custom tab) ──────────────────
  Uint8List  lastRXFrame  = Uint8List(0);
  // Incremented on every assembled RX frame. config_screen and
  // settings_screen compare their local copy to detect a genuinely
  // new frame — dart equivalent of Swift's @Published var lastRXFrame.
  int        rxFrameCount = 0;
  List<String> logs       = [];

  // ── Custom command fields ───────────────────────────────────
  String slaveID        = '';
  String functionCode   = '3';
  String startRegister  = '';
  String quantity       = '';
  String registerValues = '';
  String generatedHex   = '';

  // ─────────────────────────────────────────────────────────────
  // PUBLIC: connect / disconnect
  // ─────────────────────────────────────────────────────────────
  Future<void> connectManual() async {
    status           = 'Scanning...';
    activationStatus = ActivationStatus.unknown;
    scannedDevices.clear();
    isScanning = true;
    notifyListeners();
    await _startScan();
  }

  Future<void> disconnectManual() async {
    stopLEDPolling();
    _clearLEDRegisters();
    notifyListeners();
    await _device?.disconnect();
  }
  
  // ─────────────────────────────────────────────────────────────
  // LOCATION: Get device location with permission
  // ─────────────────────────────────────────────────────────────
  Future<String> _getDeviceLocation() async {
    try {
      // Check and request location permission
      var permission = await Permission.location.status;
      if (!permission.isGranted) {
        permission = await Permission.location.request();
        if (!permission.isGranted) {
          logs.add('Location permission denied');
          return 'Unknown'; // Return default if permission denied
        }
      }
      
      // Check if location service is enabled
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        logs.add('Location services are disabled');
        return 'Unknown';
      }
      
      // Get current position
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 5),
      );
      
      // Return lat,lon as string
      final location = '${position.latitude.toStringAsFixed(6)},${position.longitude.toStringAsFixed(6)}';
      logs.add('Location: $location');
      return location;
      
    } catch (e) {
      logs.add('Location error: $e');
      return 'Unknown';
    }
  }

  // ─────────────────────────────────────────────────────────────
  // PRIVATE: scan → show devices to user
  // ─────────────────────────────────────────────────────────────
  Future<void> _startScan() async {
    await FlutterBluePlus.stopScan();
    _scanSub?.cancel();
    
    scannedDevices.clear();
    
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      // Update scanned devices list
      scannedDevices = results
          .where((result) => _isLsNamedDevice(result.device))
          .toList();
      notifyListeners();
    });
    
    try {
      await FlutterBluePlus.startScan();
      await Future.delayed(const Duration(seconds: 3));
    } finally {
      await FlutterBluePlus.stopScan();
      _scanSub?.cancel();
      isScanning = false;
      status = 'Select Device';
      notifyListeners();
    }
  }
  
  // Called when user selects a device from the list
  Future<void> connectToDevice(BluetoothDevice device) async {
    await FlutterBluePlus.stopScan();
    _scanSub?.cancel();
    _device = device;
    status  = 'Connecting...';
    isScanning = false;
    notifyListeners();
    await _connectToDevice(device);
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    try {
      await device.connect(autoConnect: false);
      _connSub = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          isConnected      = false;
          status           = 'Disconnected';
          activationStatus = ActivationStatus.unknown;
          _writeChar       = null;
          _notifyChar      = null;
          _notifySub?.cancel();
          stopLEDPolling();
          _clearLEDRegisters();
          // Cancel any pending activation read
          _pendingCompleter?.completeError('disconnected');
          _pendingCompleter = null;
          notifyListeners();
        }
      });
      isConnected = true;
      status      = 'Connected';
      notifyListeners();
      await _discoverServices(device);
    } catch (e) {
      status = 'Connection Failed';
      logs.add('ERROR: $e');
      notifyListeners();
    }
  }

  Future<void> _discoverServices(BluetoothDevice device) async {
    final services = await device.discoverServices();

    for (final s in services) {
      for (final c in s.characteristics) {
        final p = c.properties;
        logs.add('CHAR ${c.uuid} '
            '${p.write ? "W " : ""}'
            '${p.writeWithoutResponse ? "WNR " : ""}'
            '${p.notify ? "N " : ""}'
            '${p.indicate ? "I " : ""}'
            '${p.read ? "R" : ""}');
      }
    }
    notifyListeners();

    // Pass 1 — single char that can both write and notify (HM-10 FFE1)
    for (final s in services) {
      for (final c in s.characteristics) {
        final canWrite  = c.properties.write || c.properties.writeWithoutResponse;
        final canNotify = c.properties.notify || c.properties.indicate;
        if (canWrite && canNotify) {
          _writeChar  = c;
          _notifyChar = c;
          await c.setNotifyValue(true);
          _notifySub = c.onValueReceived.listen(_handleRX);
          logs.add('TX+RX char: ${c.uuid}');
          notifyListeners();
          await Future.delayed(const Duration(milliseconds: 300));
          _runActivationCheck(); // fire-and-forget; result handled internally
          return;
        }
      }
    }

    // Pass 2 — separate write / notify characteristics
    for (final s in services) {
      for (final c in s.characteristics) {
        if ((c.properties.write || c.properties.writeWithoutResponse) &&
            _writeChar == null) {
          _writeChar = c;
          logs.add('TX char: ${c.uuid}');
        }
        if ((c.properties.notify || c.properties.indicate) &&
            _notifyChar == null) {
          _notifyChar = c;
          await c.setNotifyValue(true);
          _notifySub = c.onValueReceived.listen(_handleRX);
          logs.add('RX char: ${c.uuid}');
        }
      }
    }

    if (_writeChar != null) {
      notifyListeners();
      await Future.delayed(const Duration(milliseconds: 300));
      _runActivationCheck();
    } else {
      status = 'No writable characteristic found';
      logs.add('ERROR: No writable characteristic found');
      notifyListeners();
    }
  }

  // ─────────────────────────────────────────────────────────────
  // ACTIVATION CHECK
  // Mirrors Java connectToHC05() finally-block exactly:
  //   1. Read reg 0x0057 (87) qty 6  → strip header+CRC → _reg87Data
  //   2. Read reg 0x005D (93) qty 16 → strip header+CRC → _reg93Data
  //   3. isStringAllZerosOrEmpty(_reg93Data)
  //        true  → needsActivation (show Activate button)
  //        false → activated       (open home / start LED poll)
  // ─────────────────────────────────────────────────────────────
  Future<void> _runActivationCheck() async {
    logs.add('--- Activation check ---');
    notifyListeners();

    try {
      // ── Step 1: read register 87 ──────────────────────────
      _rxIntent = _RXIntent.activation87;
      _pendingCompleter = Completer<Uint8List>();
      await _sendFrame(
          _buildReadFrame(slave: 0xF7, start: 0x0057, qty: 6),
          logTX: true);

      final frame87 = await _pendingCompleter!.future
          .timeout(const Duration(seconds: 5));
      // Java: remove first 3 bytes (F7 03 0C) + last 2 CRC bytes, join
      _reg87Data = _stripHeaderAndCrc(frame87);
      logs.add('reg87 payload: $_reg87Data');

      // ── Step 2: read registers 93–108 ────────────────────
      await Future.delayed(const Duration(milliseconds: 200));
      _rxIntent = _RXIntent.activation93;
      _pendingCompleter = Completer<Uint8List>();
      await _sendFrame(
          _buildReadFrame(slave: 0xF7, start: 0x005D, qty: 16),
          logTX: true);

      final frame93 = await _pendingCompleter!.future
          .timeout(const Duration(seconds: 5));
      _reg93Data = _stripHeaderAndCrc(frame93);
      logs.add('reg93 payload: $_reg93Data');

    } catch (e) {
      logs.add('Activation read error: $e');
      // Treat timeout/error conservatively: assume needs activation
      activationStatus = ActivationStatus.needsActivation;
      notifyListeners();
      return;
    } finally {
      _pendingCompleter = null;
      _rxIntent = _RXIntent.idle;
    }

    // ── Step 3: decide — mirrors Java isStringAllZerosOrEmpty ─
    final isHashEmpty = _isAllZerosOrEmpty(_reg93Data);
    logs.add('Hash empty: $isHashEmpty');

    if (isHashEmpty) {
      activationStatus = ActivationStatus.needsActivation;
    } else {
      activationStatus = ActivationStatus.activated;
      startLEDPolling();
    }
    notifyListeners();
  }

  // ─────────────────────────────────────────────────────────────
  // ACTIVATE DEVICE  (called when user taps "Activate" button)
  // Mirrors Java onActivateButtonClicked → postToHmacApi
  //                                     → writeHmacToRegisters
  // ─────────────────────────────────────────────────────────────
  Future<void> activateDevice() async {
    if (_reg87Data.isEmpty) {
      activationMessage = 'No device data available (reg 87 empty)';
      activationError   = true;
      notifyListeners();
      return;
    }

    activationStatus  = ActivationStatus.activating;
    activationMessage = '';
    activationError   = false;
    notifyListeners();

    try {
      // ── Get device location ──────────────────────────────
      final location = await _getDeviceLocation();
      
      // ── Java: swapBytes(storedRegister87Data) then POST ──
      final swapped = _swapBytes(_reg87Data);
      logs.add('Posting to HMAC API, hex: $swapped, location: $location');

      final response = await http.post(
        Uri.parse(hmacApiUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'device_id': swapped,
          'bluetooth_name': (_device?.remoteId.toString() ?? 'unknown'),
          'location': "http://www.google.com/maps/search/?api=1&query="+location,
        }),
      ).timeout(const Duration(seconds: 20));

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      // ── Java: jsonResponse.getString("hmac_sha256") ──────
      final json     = jsonDecode(response.body) as Map<String, dynamic>;
      final hmacHash = (json['hmac_sha256'] as String).trim();
      logs.add('HMAC received: $hmacHash');

      // ── Java: writeHmacToRegisters ───────────────────────
      await _writeHmacToRegisters(hmacHash);

      activationStatus  = ActivationStatus.activated;
      activationMessage = 'Device activated!\nHMAC: $hmacHash';
      activationError   = false;
      notifyListeners();

      await Future.delayed(const Duration(milliseconds: 300));
      startLEDPolling();

    } catch (e) {
      activationStatus  = ActivationStatus.needsActivation;
      activationMessage = 'Activation failed: $e';
      activationError   = true;
      logs.add('Activation ERROR: $e');
      notifyListeners();
    }
  }

  // ─────────────────────────────────────────────────────────────
  // WRITE HMAC TO REGISTERS
  // Direct port of Java writeHmacToRegisters:
  //   swapBytes(hmacHash)
  //   → split into 4-char chunks
  //   → write each chunk to reg 93, 94, 95 …
  //   → write 0x0003 to reg 0x0010
  //   → write 0x0001 to reg 0x0010  (save to EEPROM)
  // ─────────────────────────────────────────────────────────────
  Future<void> _writeHmacToRegisters(String hmacHash) async {
    final swappedHash = _swapBytes(hmacHash);
    int   regOffset   = 0;

    for (int i = 0; i + 4 <= swappedHash.length; i += 4) {
      final chunk    = swappedHash.substring(i, i + 4).toUpperCase();
      final chunkVal = int.parse(chunk, radix: 16);
      final regAddr  = 0x005D + regOffset; // start = 93

      _rxIntent = _RXIntent.custom; // writes get a quick ack; just log it
      await _sendFrame(
          _buildWriteFrame(slave: 0xF7, start: regAddr, values: [chunkVal]),
          logTX: true);
      logs.add('Wrote $chunk → reg $regAddr');

      // Java: delayRoutine(100)
      await Future.delayed(const Duration(milliseconds: 100));
      regOffset++;
    }

    // Java: prepare_write_command("0010", "0003")
    await Future.delayed(const Duration(milliseconds: 100));
    _rxIntent = _RXIntent.custom;
    await _sendFrame(
        _buildWriteFrame(slave: 0xF7, start: 0x0010, values: [3]),
        logTX: true);
    logs.add('Write 3 → reg 16');

    // Java: prepare_write_command("0010", "0001")  — save to EEPROM
    await Future.delayed(const Duration(milliseconds: 100));
    await _sendFrame(
        _buildWriteFrame(slave: 0xF7, start: 0x0010, values: [1]),
        logTX: true);
    logs.add('Write 1 → reg 16 (EEPROM save)');

    _rxIntent = _RXIntent.idle;
  }

  // ─────────────────────────────────────────────────────────────
  // LED POLLING
  // Only starts after activation is confirmed.
  // Guards against firing during an activation read.
  // ─────────────────────────────────────────────────────────────
  void startLEDPolling() {
    if (_isPolling) return;
    _isPolling = true;
    _pollLED();
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) => _pollLED());
  }

  void stopLEDPolling() {
    _isPolling = false;
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  void _pollLED() {
    // Never fire during activation reads — those use their own completers
    if (_rxIntent == _RXIntent.activation87 ||
        _rxIntent == _RXIntent.activation93) return;
    _rxIntent = _RXIntent.ledPoll;
    _sendFrame(
        _buildReadFrame(slave: 0xF7, start: 4, qty: 10),
        logTX: false);
  }

  void _clearLEDRegisters() {
    ledRegisters = List.filled(10, 0);
  }

  // ─────────────────────────────────────────────────────────────
  // PUBLIC MODBUS HELPERS (used by ConfigScreen)
  // Sets intent to _RXIntent.config — never overwrites activation intents.
  // ─────────────────────────────────────────────────────────────
  void sendModbus({
    required int slave,
    required int function,
    required int start,
    required int qty,
  }) {
    _rxIntent = _RXIntent.config;
    _sendFrame(_buildReadFrame(slave: slave, start: start, qty: qty),
        logTX: true);
  }

  void sendModbusWrite({
    required int slave,
    required int start,
    required List<int> values,
  }) {
    _rxIntent = _RXIntent.custom;
    _sendFrame(_buildWriteFrame(slave: slave, start: start, values: values),
        logTX: true);
  }

  // ─────────────────────────────────────────────────────────────
  // CUSTOM COMMAND (Custom tab)
  // ─────────────────────────────────────────────────────────────
  void sendCustomCommand() {
    final sid = int.tryParse(slaveID);
    final fc  = int.tryParse(functionCode);
    final st  = int.tryParse(startRegister);

    if (sid == null || fc == null || st == null) {
      logs.add('ERROR: Invalid input'); notifyListeners(); return;
    }
    _rxIntent = _RXIntent.custom;

    if (fc == 3) {
      final qt = int.tryParse(quantity);
      if (qt == null) {
        logs.add('ERROR: Invalid quantity'); notifyListeners(); return;
      }
      final f = _buildReadFrame(slave: sid, start: st, qty: qt);
      generatedHex = _toHexString(f);
      _sendFrame(f, logTX: true);

    } else if (fc == 16) {
      final parts = registerValues
          .split('+')
          .map((s) => int.tryParse(s.trim()))
          .whereType<int>()
          .toList();
      if (parts.isEmpty) {
        logs.add('ERROR: No values (use + separator)'); notifyListeners(); return;
      }
      final f = _buildWriteFrame(slave: sid, start: st, values: parts);
      generatedHex = _toHexString(f);
      _sendFrame(f, logTX: true);

    } else {
      logs.add('ERROR: FC must be 3 or 16'); notifyListeners();
    }
  }

  // ─────────────────────────────────────────────────────────────
  // MODBUS FRAME BUILDERS
  // ─────────────────────────────────────────────────────────────

  /// FC 03 read request
  Uint8List _buildReadFrame({
    required int slave,
    required int start,
    required int qty,
  }) {
    final d = <int>[
      slave, 0x03,
      (start >> 8) & 0xFF, start & 0xFF,
      (qty   >> 8) & 0xFF, qty   & 0xFF,
    ];
    _appendCRC(d);
    return Uint8List.fromList(d);
  }

  /// FC 16 write multiple registers
  Uint8List _buildWriteFrame({
    required int slave,
    required int start,
    required List<int> values,
  }) {
    final qty = values.length;
    final d = <int>[
      slave, 0x10,
      (start >> 8) & 0xFF, start & 0xFF,
      (qty   >> 8) & 0xFF, qty   & 0xFF,
      qty * 2,
    ];
    for (final v in values) {
      d.add((v >> 8) & 0xFF);
      d.add( v       & 0xFF);
    }
    _appendCRC(d);
    return Uint8List.fromList(d);
  }

  void _appendCRC(List<int> d) {
    final crc = _crc16(d);
    d.add( crc       & 0xFF); // CRC low
    d.add((crc >> 8) & 0xFF); // CRC high
  }

  int _crc16(List<int> data) {
    int crc = 0xFFFF;
    for (final b in data) {
      crc ^= b & 0xFF;
      for (int i = 0; i < 8; i++) {
        crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xA001 : crc >> 1;
      }
    }
    return crc;
  }

  // ─────────────────────────────────────────────────────────────
  // SEND
  // ─────────────────────────────────────────────────────────────
  Future<void> _sendFrame(Uint8List data, {required bool logTX}) async {
    if (_writeChar == null) {
      logs.add('ERROR: Not connected'); notifyListeners(); return;
    }
    try {
      final noResp = _writeChar!.properties.writeWithoutResponse;
      await _writeChar!.write(data, withoutResponse: noResp);
      if (logTX) { logs.add('TX: ${_toHexString(data)}'); notifyListeners(); }
    } catch (e) {
      logs.add('TX ERROR: $e'); notifyListeners();
    }
  }

  // ─────────────────────────────────────────────────────────────
  // RX HANDLER
  // Reassembles multi-chunk BLE notifications into complete
  // Modbus frames, then dispatches by current _rxIntent.
  // ─────────────────────────────────────────────────────────────
  void _handleRX(List<int> incoming) {
    _rxBuffer.addAll(incoming);

    // Determine expected frame length from byte-count field (byte index 2)
    if (_rxBuffer.length >= 3 && _expectedLen == null) {
      _expectedLen = 3 + _rxBuffer[2] + 2; // header(3) + data + CRC(2)
    }
    if (_expectedLen == null || _rxBuffer.length < _expectedLen!) return;

    final frame = Uint8List.fromList(_rxBuffer.sublist(0, _expectedLen!));
    _rxBuffer.clear();
    _expectedLen = null;

    lastRXFrame = frame;
    rxFrameCount++;          // signals config/settings listeners that a fresh frame arrived
    logs.add('RX: ${_toHexString(frame)}');

    switch (_rxIntent) {
      // ── Activation reads: resolve the pending Completer ──
      case _RXIntent.activation87:
      case _RXIntent.activation93:
        if (_pendingCompleter != null && !_pendingCompleter!.isCompleted) {
          _pendingCompleter!.complete(frame);
        }
        break;

      // ── LED poll ──────────────────────────────────────────
      case _RXIntent.ledPoll:
        _parseLEDFrame(frame);
        break;

      // ── Config reads: forward to ConfigScreen callback ───
      case _RXIntent.config:
        onConfigFrame?.call(frame);
        break;

      // ── Custom command / write acks: just logged above ───
      case _RXIntent.custom:
      case _RXIntent.idle:
        break;
    }

    notifyListeners();
  }

  // ─────────────────────────────────────────────────────────────
  // PARSERS
  // ─────────────────────────────────────────────────────────────

  void _parseLEDFrame(Uint8List f) {
    if (f.length < 25) return;
    for (int i = 0; i < 10; i++) {
      ledRegisters[i] = (f[3 + i * 2] << 8) | f[3 + i * 2 + 1];
    }
  }

  // ─────────────────────────────────────────────────────────────
  // ACTIVATION HELPERS — direct ports from Java
  // ─────────────────────────────────────────────────────────────

  /// Java: remove first 3 bytes (slave / FC / byteCount) +
  ///       last 2 bytes (CRC) then join without spaces.
  /// Mirrors the StringBuilder loop in Java's finally-block.
  String _stripHeaderAndCrc(Uint8List frame) {
    if (frame.length <= 5) return '';
    final payload = frame.sublist(3, frame.length - 2);
    return payload
        .map((b) => b.toRadixString(16).padLeft(2, '0').toLowerCase())
        .join();
  }

  /// Java: isStringAllZerosOrEmpty — true if null/empty or only '0'/' '
  bool _isAllZerosOrEmpty(String s) {
    if (s.trim().isEmpty) return true;
    return s.split('').every((c) => c == '0');
  }

  /// Java: swapBytes — swap MSB and LSB for every 4-char group
  /// e.g. "0085" → "8500",  "00F7" → "F700"
  String _swapBytes(String hex) {
    final sb = StringBuffer();
    for (int i = 0; i + 4 <= hex.length; i += 4) {
      final chunk = hex.substring(i, i + 4);
      sb.write(chunk.substring(2, 4)); // low byte first
      sb.write(chunk.substring(0, 2)); // then high byte
    }
    // Any leftover chars (< 4) appended unchanged — matches Java's else branch
    final rem = hex.length % 4;
    if (rem != 0) sb.write(hex.substring(hex.length - rem));
    return sb.toString();
  }

  // ─────────────────────────────────────────────────────────────
  // UTILITY
  // ─────────────────────────────────────────────────────────────
  String _toHexString(Uint8List data) => data
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(' ');
}

// ─────────────────────────────────────────────────────────────
// MAIN SCREEN
// ─────────────────────────────────────────────────────────────
class MainScreen extends StatefulWidget {
  final BluetoothDevice? autoConnectDevice;
  
  const MainScreen({super.key, this.autoConnectDevice});
  
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final BLEManager _ble = BLEManager();
  int _selectedTab = 0;
  bool _isSaved = false;
  bool _wasConnected = false;
  bool _isDisconnectDialogVisible = false;

  @override
  void initState() {
    super.initState();
    _ble.addListener(_onBLEUpdate);
    _checkSavedStatus();
    
    // Auto-connect if device is provided
    if (widget.autoConnectDevice != null) {
      Future.delayed(Duration.zero, () {
        _ble.connectToDevice(widget.autoConnectDevice!);
      });
    }
  }

  Future<void> _checkSavedStatus() async {
    final saved = await DevicePreferences.hasSavedDevice();
    setState(() {
      _isSaved = saved;
    });
  }

  @override
  void dispose() {
    _ble.removeListener(_onBLEUpdate);
    _ble.dispose();
    super.dispose();
  }

  void _onBLEUpdate() {
    if (_wasConnected && !_ble.isConnected && !_isDisconnectDialogVisible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _showDisconnectDialog();
        }
      });
    }
    _wasConnected = _ble.isConnected;
    _syncPolling();
    setState(() {});
  }

  Future<void> _showDisconnectDialog() async {
    if (_isDisconnectDialogVisible) return;
    _isDisconnectDialogVisible = true;

    bool isReconnecting = false;
    String errorMessage = '';

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return PopScope(
          canPop: false,
          child: StatefulBuilder(
            builder: (context, setDialogState) {
              return AlertDialog(
                backgroundColor: const Color(0xFF1A1A2E),
                title: const Text(
                  'Device Disconnected',
                  style: TextStyle(color: Colors.white),
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'The Bluetooth connection was lost.',
                      style: TextStyle(color: Colors.white70),
                    ),
                    if (isReconnecting) ...[
                      const SizedBox(height: 14),
                      const Row(
                        children: [
                          SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(width: 10),
                          Text(
                            'Reconnecting...',
                            style: TextStyle(color: Colors.white70),
                          ),
                        ],
                      ),
                    ],
                    if (errorMessage.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        errorMessage,
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                    ],
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: isReconnecting
                        ? null
                        : () async {
                            final targetDevice = _ble._device;
                            if (targetDevice == null) {
                              setDialogState(() {
                                errorMessage = 'Device not found';
                              });
                              return;
                            }

                            setDialogState(() {
                              isReconnecting = true;
                              errorMessage = '';
                            });

                            await _ble.connectToDevice(targetDevice);

                            if (!mounted) return;

                            if (_ble.isConnected) {
                              if (Navigator.of(dialogContext).canPop()) {
                                Navigator.of(dialogContext).pop();
                              }
                            } else {
                              setDialogState(() {
                                isReconnecting = false;
                                errorMessage = 'Device not found';
                              });
                            }
                          },
                    child: const Text('Reconnect'),
                  ),
                  TextButton(
                    onPressed: isReconnecting
                        ? null
                        : () {
                            SystemNavigator.pop();
                          },
                    child: const Text('Exit'),
                  ),
                ],
              );
            },
          ),
        );
      },
    );

    _isDisconnectDialogVisible = false;
  }

  Future<bool> _isInternetAvailable() async {
    try {
      final response = await http
          .get(Uri.parse('https://www.msftconnecttest.com/connecttest.txt'))
          .timeout(const Duration(seconds: 5));
      return response.statusCode == 204 || response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<void> _showLocationRequiredDialog() async {
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1A1A2E),
          title: const Text(
            'Location Required',
            style: TextStyle(color: Colors.white),
          ),
          content: const Text(
            'Please turn on Location and allow location permission to activate the device.',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                Navigator.of(dialogContext).pop();
                await _handleActivatePressed();
              },
              child: const Text('Try Again'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showInternetRequiredDialog() async {
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1A1A2E),
          title: const Text(
            'Internet Required',
            style: TextStyle(color: Colors.white),
          ),
          content: const Text(
            'Please turn on internet connection to activate the device.',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                Navigator.of(dialogContext).pop();
                await _handleActivatePressed();
              },
              child: const Text('Try Again'),
            ),
          ],
        );
      },
    );
  }

  Future<bool> _ensureActivationRequirements() async {
    final locationEnabled = await Geolocator.isLocationServiceEnabled();
    if (!locationEnabled) {
      await _showLocationRequiredDialog();
      return false;
    }

    var permission = await Permission.location.status;
    if (!permission.isGranted) {
      permission = await Permission.location.request();
      if (!permission.isGranted) {
        await _showLocationRequiredDialog();
        return false;
      }
    }

    final internetAvailable = await _isInternetAvailable();
    if (!internetAvailable) {
      await _showInternetRequiredDialog();
      return false;
    }

    return true;
  }

  Future<void> _handleActivatePressed() async {
    if (_ble.activationStatus == ActivationStatus.activating) return;
    final ready = await _ensureActivationRequirements();
    if (!ready) return;
    await _ble.activateDevice();
  }

  Future<void> _toggleSaveDevice() async {
    if (_isSaved) {
      // Unsave the device
      await DevicePreferences.clearDevice();
      setState(() {
        _isSaved = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Device connection cleared'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } else {
      // Save the device
      if (_ble._device != null) {
        await DevicePreferences.saveDevice(
          deviceType: 'ELS',
          deviceId: _ble._device!.remoteId.toString(),
          deviceName: _ble._device!.platformName.isNotEmpty 
              ? _ble._device!.platformName 
              : 'ELS Device',
        );
        setState(() {
          _isSaved = true;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Device connection saved! App will auto-connect on next launch.'),
              backgroundColor: Colors.green,
            ),
          );
        }
      }
    }
  }

  // Start LED poll only when connected + activated + on LED tab
  void _syncPolling() {
    final ready = _ble.isConnected &&
        _ble.activationStatus == ActivationStatus.activated &&
        _selectedTab == 0;
    ready ? _ble.startLEDPolling() : _ble.stopLEDPolling();
  }

  void _onTabTapped(int index) {
    setState(() => _selectedTab = index);
    _syncPolling();
  }

  @override
  Widget build(BuildContext context) {
    final isLocked = _ble.isConnected &&
        (_ble.activationStatus == ActivationStatus.needsActivation ||
         _ble.activationStatus == ActivationStatus.activating);

    return Scaffold(
      body: Stack(children: [
        // Main UI — dimmed and blocked when activation gate is showing
        AnimatedOpacity(
          opacity: isLocked ? 0.1 : 1.0,
          duration: const Duration(milliseconds: 300),
          child: AbsorbPointer(
            absorbing: isLocked,
            child: _buildBody(),
          ),
        ),
        if (isLocked)
          _ActivationGate(
            ble: _ble,
            onActivatePressed: _handleActivatePressed,
          ),
      ]),
      bottomNavigationBar: isLocked ? null : _buildBottomNav(),
    );
  }

  Widget _buildBody() {
    switch (_selectedTab) {
      case 0:  return LEDStatusScreen(
          ble: _ble, 
          isSaved: _isSaved, 
          onToggleSave: _toggleSaveDevice,
        );
      case 1:  return CustomCommandScreen(
          ble: _ble,
          isSaved: _isSaved,
          onToggleSave: _toggleSaveDevice,
        );
      case 2:  return ConfigScreen(
          ble: _ble,
          isSaved: _isSaved,
          onToggleSave: _toggleSaveDevice,
        );
      case 3:  return SettingsScreen(
          ble: _ble,
          isSaved: _isSaved,
          onToggleSave: _toggleSaveDevice,
        );
      default: return LEDStatusScreen(
          ble: _ble,
          isSaved: _isSaved,
          onToggleSave: _toggleSaveDevice,
        );
    }
  }

  Widget _buildBottomNav() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF12121F),
        border: Border(top: BorderSide(color: Colors.cyan.withOpacity(0.2))),
      ),
      child: BottomNavigationBar(
        currentIndex: _selectedTab,
        onTap: _onTabTapped,
        backgroundColor: Colors.transparent,
        elevation: 0,
        type: BottomNavigationBarType.fixed,
        selectedItemColor:   const Color(0xFF00E5FF),
        unselectedItemColor: Colors.white38,
        selectedFontSize:   11,
        unselectedFontSize: 11,
        items: const [
          BottomNavigationBarItem(
              icon: Icon(Icons.lightbulb_outline),
              activeIcon: Icon(Icons.lightbulb),
              label: 'LED'),
          BottomNavigationBarItem(
              icon: Icon(Icons.terminal_outlined),
              activeIcon: Icon(Icons.terminal),
              label: 'Custom'),
          BottomNavigationBarItem(
              icon: Icon(Icons.tune_outlined),
              activeIcon: Icon(Icons.tune),
              label: 'Config'),
          BottomNavigationBarItem(
              icon: Icon(Icons.settings_outlined),
              activeIcon: Icon(Icons.settings),
              label: 'Settings'),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// ACTIVATION GATE OVERLAY
// Mirrors Java btnActivate logic:
//   isHashEmpty  → show Activate button (needsActivation)
//   activating   → show spinner while API + writes run
// ─────────────────────────────────────────────────────────────
class _ActivationGate extends StatelessWidget {
  final BLEManager ble;
  final Future<void> Function() onActivatePressed;

  const _ActivationGate({
    required this.ble,
    required this.onActivatePressed,
  });

  @override
  Widget build(BuildContext context) {
    final isActivating = ble.activationStatus == ActivationStatus.activating;

    return Center(
      child: Container(
        margin:  const EdgeInsets.symmetric(horizontal: 32),
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.orange.withOpacity(0.5), width: 1.5),
          boxShadow: [BoxShadow(
              color: Colors.orange.withOpacity(0.15),
              blurRadius: 40, spreadRadius: 5)],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Icon
            Icon(
              isActivating ? Icons.sync_rounded : Icons.lock_outline_rounded,
              size: 64, color: Colors.orange,
            ),
            const SizedBox(height: 16),

            // Title
            Text(
              isActivating ? 'Activating Device...' : 'Device Not Activated',
              style: const TextStyle(
                  fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            const SizedBox(height: 12),

            if (isActivating) ...[
              // Spinner + explanation
              const SizedBox(height: 8),
              const CircularProgressIndicator(color: Colors.orange),
              const SizedBox(height: 16),
              const Text(
                'Contacting HMAC server\nand writing hash to device…',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54, height: 1.6),
              ),
            ] else ...[
              // Explanation
              Text(                
                'Tap Activate to register this device.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Colors.white.withOpacity(0.6), height: 1.6),
              ),

              // Error message (if previous attempt failed)
              if (ble.activationError && ble.activationMessage.isNotEmpty) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.redAccent.withOpacity(0.4)),
                  ),
                  child: Text(
                    ble.activationMessage,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                  ),
                ),
              ],

              const SizedBox(height: 24),

              // Activate button — mirrors Java btnActivate.setOnClickListener
              ElevatedButton.icon(
                onPressed: isActivating ? null : onActivatePressed,
                icon:  const Icon(Icons.bolt_rounded, color: Colors.black),
                label: const Text('Activate',
                    style: TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.bold,
                        fontSize: 16)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 40, vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// SHARED: BLE HEADER BAR
// ─────────────────────────────────────────────────────────────
class BLEHeader extends StatefulWidget {
  final BLEManager ble;
  final String     title;
  final bool? isSaved;
  final VoidCallback? onToggleSave;
  
  const BLEHeader({
    super.key, 
    required this.ble, 
    required this.title,
    this.isSaved,
    this.onToggleSave,
  });

  @override
  State<BLEHeader> createState() => _BLEHeaderState();
}

class _BLEHeaderState extends State<BLEHeader> {
  bool _wasScanning = false;

  @override
  void initState() {
    super.initState();
    widget.ble.addListener(_onBLEUpdate);
  }

  @override
  void dispose() {
    widget.ble.removeListener(_onBLEUpdate);
    super.dispose();
  }

  void _onBLEUpdate() {
    _wasScanning = widget.ble.isScanning;
    if (mounted) setState(() {});
  }

  void _showDeviceSelector(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) {
          return DeviceSelectorSheet(
            ble: widget.ble,
            scrollController: scrollController,
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 48, 16, 12),
      decoration: BoxDecoration(
        color: const Color(0xFF12121F),
        border: Border(bottom:
            BorderSide(color: Colors.cyan.withOpacity(0.15))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title on top
          Text(widget.title,
              style: const TextStyle(
                  fontSize: 18, fontWeight: FontWeight.bold,
                  color: Colors.white, letterSpacing: 1.2)),
          const SizedBox(height: 12),
          // Status and button on second row
          Row(children: [
            // Status dot
            AnimatedContainer(
              duration: const Duration(milliseconds: 400),
              width: 8, height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.ble.isConnected ? Colors.greenAccent : Colors.redAccent,
                boxShadow: [BoxShadow(
                    color: (widget.ble.isConnected ? Colors.green : Colors.red)
                        .withOpacity(0.5),
                    blurRadius: 6)],
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(widget.ble.status,
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.6), fontSize: 13)),
            ),
            const SizedBox(width: 12),
            // Connect / Disconnect button
            GestureDetector(
              onTap: () {
                if (widget.ble.isConnected) {
                  widget.ble.disconnectManual();
                } else {
                  _showDeviceSelector(context);
                }
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  border: Border.all(
                      color: widget.ble.isConnected
                          ? Colors.redAccent
                          : const Color(0xFF00E5FF)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  widget.ble.isConnected 
                      ? 'Disconnect' 
                      : (widget.ble.isScanning 
                          ? 'Scanning...' 
                          : (widget.ble.scannedDevices.isNotEmpty ? 'Select Device' : 'Scan')),
                  style: TextStyle(
                      color: widget.ble.isConnected
                          ? Colors.redAccent
                          : const Color(0xFF00E5FF),
                      fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            // Save/Unsave button (only show when connected and activated)
            if (widget.ble.isConnected && 
                widget.ble.activationStatus == ActivationStatus.activated &&
                widget.onToggleSave != null &&
                widget.isSaved != null)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: GestureDetector(
                  onTap: widget.onToggleSave,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: widget.isSaved! 
                          ? Colors.orange.withOpacity(0.2)
                          : Colors.green.withOpacity(0.2),
                      border: Border.all(
                        color: widget.isSaved! ? Colors.orange : Colors.green,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          widget.isSaved! ? Icons.bookmark : Icons.bookmark_border,
                          size: 16,
                          color: widget.isSaved! ? Colors.orange : Colors.green,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          widget.isSaved! ? 'Unsave' : 'Save',
                          style: TextStyle(
                            color: widget.isSaved! ? Colors.orange : Colors.green,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ]),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// DEVICE SELECTOR BOTTOM SHEET
// ─────────────────────────────────────────────────────────────
class DeviceSelectorSheet extends StatefulWidget {
  final BLEManager ble;
  final ScrollController scrollController;
  
  const DeviceSelectorSheet({
    super.key,
    required this.ble,
    required this.scrollController,
  });

  @override
  State<DeviceSelectorSheet> createState() => _DeviceSelectorSheetState();
}

class _DeviceSelectorSheetState extends State<DeviceSelectorSheet> {
  @override
  void initState() {
    super.initState();
    widget.ble.addListener(_onBLEUpdate);
    // Start scanning if not already
    if (!widget.ble.isScanning && widget.ble.scannedDevices.isEmpty) {
      widget.ble.connectManual();
    }
  }

  @override
  void dispose() {
    widget.ble.removeListener(_onBLEUpdate);
    super.dispose();
  }

  void _onBLEUpdate() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1A1A2E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          // Handle bar
          Container(
            margin: const EdgeInsets.only(top: 12, bottom: 8),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Title
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const Icon(Icons.bluetooth_searching, color: Color(0xFF00E5FF)),
                const SizedBox(width: 10),
                const Text(
                  'Select Device',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: widget.ble.isScanning
                      ? null
                      : () => widget.ble.connectManual(),
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Refresh'),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF00E5FF),
                  ),
                ),
                const SizedBox(width: 8),
                if (widget.ble.isScanning)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Color(0xFF00E5FF),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(color: Colors.white10, height: 1),
          // Device list
          Expanded(
            child: widget.ble.scannedDevices.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (widget.ble.isScanning) ...[
                          const CircularProgressIndicator(color: Color(0xFF00E5FF)),
                          const SizedBox(height: 16),
                          const Text(
                            'Scanning for devices...',
                            style: TextStyle(color: Colors.white70),
                          ),
                        ] else ...[
                          const Icon(
                            Icons.bluetooth_disabled,
                            size: 64,
                            color: Colors.white24,
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'No devices found',
                            style: TextStyle(color: Colors.white70),
                          ),
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed: () => widget.ble.connectManual(),
                            child: const Text('Scan Again'),
                          ),
                        ],
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: widget.scrollController,
                    padding: const EdgeInsets.all(8),
                    itemCount: widget.ble.scannedDevices.length,
                    itemBuilder: (context, index) {
                      final result = widget.ble.scannedDevices[index];
                      final device = result.device;
                      final rssi = result.rssi;
                      final name = device.advName.isNotEmpty
                          ? device.advName
                          : (device.platformName.isNotEmpty
                              ? device.platformName
                              : 'Unknown Device');

                      return Card(
                        color: const Color(0xFF0D0D1A),
                        margin: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        child: ListTile(
                          leading: Icon(
                            Icons.bluetooth,
                            color: _getSignalColor(rssi),
                          ),
                          title: Text(
                            name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                device.remoteId.toString(),
                                style: const TextStyle(
                                  color: Colors.white54,
                                  fontSize: 11,
                                  fontFamily: 'monospace',
                                ),
                              ),
                              const SizedBox(height: 2),
                              Row(
                                children: [
                                  Icon(
                                    Icons.signal_cellular_alt,
                                    size: 14,
                                    color: _getSignalColor(rssi),
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    '$rssi dBm',
                                    style: TextStyle(
                                      color: _getSignalColor(rssi),
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          trailing: const Icon(
                            Icons.chevron_right,
                            color: Color(0xFF00E5FF),
                          ),
                          onTap: () {
                            Navigator.pop(context);
                            widget.ble.connectToDevice(device);
                          },
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Color _getSignalColor(int rssi) {
    if (rssi > -60) return Colors.greenAccent;
    if (rssi > -75) return Colors.orangeAccent;
    return Colors.redAccent;
  }
}

// ─────────────────────────────────────────────────────────────
// TAB 0: LED STATUS SCREEN
// Layout mirrors LEDStatusView.swift:
//   ELS200+ black title bar
//   SF [yellow reg9] [yellow reg8] PF
//   Row 4: [green reg7] [red reg6]  4
//   Row 3: [green reg5] [red reg4]  3
//   Row 2: [green reg3] [red reg2]  2
//   Row 1: [green reg1] [red reg0]  1
// ─────────────────────────────────────────────────────────────
// ─────────────────────────────────────────────────────────────
// TAB 1: CUSTOM COMMAND SCREEN
// ─────────────────────────────────────────────────────────────
class CustomCommandScreen extends StatefulWidget {
  final BLEManager ble;
  final bool? isSaved;
  final VoidCallback? onToggleSave;
  
  const CustomCommandScreen({
    super.key, 
    required this.ble,
    this.isSaved,
    this.onToggleSave,
  });
  
  @override
  State<CustomCommandScreen> createState() => _CustomCommandScreenState();
}

class _CustomCommandScreenState extends State<CustomCommandScreen> {
  late final TextEditingController _slaveCtrl;
  late final TextEditingController _startCtrl;
  late final TextEditingController _qtyCtrl;
  late final TextEditingController _valCtrl;
  final _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _slaveCtrl = TextEditingController(text: widget.ble.slaveID);
    _startCtrl = TextEditingController(text: widget.ble.startRegister);
    _qtyCtrl   = TextEditingController(text: widget.ble.quantity);
    _valCtrl   = TextEditingController(text: widget.ble.registerValues);
    widget.ble.addListener(_onUpdate);
  }

  @override
  void dispose() {
    widget.ble.removeListener(_onUpdate);
    _slaveCtrl.dispose(); _startCtrl.dispose();
    _qtyCtrl.dispose();   _valCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onUpdate() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients)
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
    });
  }

  void _send() {
    widget.ble.slaveID        = _slaveCtrl.text;
    widget.ble.startRegister  = _startCtrl.text;
    widget.ble.quantity       = _qtyCtrl.text;
    widget.ble.registerValues = _valCtrl.text;
    widget.ble.sendCustomCommand();
  }

  @override
  Widget build(BuildContext context) {
    final isWrite = widget.ble.functionCode == '16';

    return Column(children: [
      BLEHeader(
        ble: widget.ble, 
        title: 'CUSTOM COMMAND',
        isSaved: widget.isSaved,
        onToggleSave: widget.onToggleSave,
      ),

      Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          Row(children: [
            Expanded(child: _Field(ctrl: _slaveCtrl, label: 'Slave ID', hint: '247')),
            const SizedBox(width: 12),
            Expanded(
              child: _dropdown(
                value: widget.ble.functionCode,
                items: const {'3': 'FC 3 – Read', '16': 'FC 16 – Write'},
                onChanged: (v) => setState(() => widget.ble.functionCode = v!),
              ),
            ),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: _Field(ctrl: _startCtrl, label: 'Start Register', hint: '4')),
            const SizedBox(width: 12),
            Expanded(
              child: isWrite
                  ? _Field(ctrl: _valCtrl, label: 'Values (+ sep)', hint: '100+200')
                  : _Field(ctrl: _qtyCtrl, label: 'Quantity', hint: '10'),
            ),
          ]),
          const SizedBox(height: 14),

          if (widget.ble.generatedHex.isNotEmpty)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF0D1A0D),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.greenAccent.withOpacity(0.3)),
              ),
              child: Text('HEX: ${widget.ble.generatedHex}',
                  style: const TextStyle(
                      color: Colors.greenAccent,
                      fontFamily: 'monospace', fontSize: 12)),
            ),

          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _send,
              icon:  const Icon(Icons.send_rounded, size: 18),
              label: const Text('Generate & Send'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00E5FF),
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ]),
      ),

      const Divider(color: Colors.white10, height: 1),

      Expanded(
        child: ListView.builder(
          controller: _scrollCtrl,
          padding: const EdgeInsets.all(12),
          itemCount: widget.ble.logs.length,
          itemBuilder: (_, i) {
            final log   = widget.ble.logs[i];
            final isTX  = log.startsWith('TX:');
            final isErr = log.startsWith('ERROR') || log.startsWith('TX ERROR');
            return Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(log,
                  style: TextStyle(
                      fontFamily: 'monospace', fontSize: 11,
                      color: isErr
                          ? Colors.redAccent
                          : isTX
                              ? const Color(0xFF00E5FF)
                              : Colors.greenAccent)),
            );
          },
        ),
      ),
    ]);
  }

  Widget _dropdown({
    required String value,
    required Map<String, String> items,
    required ValueChanged<String?> onChanged,
  }) =>
      Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white12),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: value,
            dropdownColor: const Color(0xFF1A1A2E),
            style: const TextStyle(color: Colors.white, fontFamily: 'monospace'),
            onChanged: onChanged,
            items: items.entries
                .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                .toList(),
          ),
        ),
      );
}

// ─────────────────────────────────────────────────────────────
// SHARED: STYLED TEXT FIELD
// ─────────────────────────────────────────────────────────────
class _Field extends StatelessWidget {
  final TextEditingController ctrl;
  final String label, hint;
  const _Field({required this.ctrl, required this.label, required this.hint});

  @override
  Widget build(BuildContext context) => TextField(
        controller: ctrl,
        keyboardType: TextInputType.number,
        style: const TextStyle(
            color: Colors.white, fontFamily: 'monospace', fontSize: 13),
        decoration: InputDecoration(
          labelText: label,
          hintText:  hint,
          labelStyle: const TextStyle(color: Colors.white54, fontSize: 12),
          hintStyle:  const TextStyle(color: Colors.white24, fontSize: 12),
          filled: true,
          fillColor: const Color(0xFF1A1A2E),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Colors.white12)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Colors.white12)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFF00E5FF))),
        ),
      );
}