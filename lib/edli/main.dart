import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import '../device_preferences.dart';
import 'adminfragment.dart';
import 'homefragment.dart';
import 'configfragment.dart';
import 'settingfragment.dart';
import 'ledstatusfragment.dart';

// ─────────────────────────────────────────────────────────────
// ENTRY POINT
// ─────────────────────────────────────────────────────────────
void main() {
  runApp(const BLEAsciiApp());
}

class BLEAsciiApp extends StatelessWidget {
  final BluetoothDevice? autoConnectDevice;
  
  const BLEAsciiApp({super.key, this.autoConnectDevice});
  
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'EDLI',
      theme: ThemeData(
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00E5FF),
          secondary: Color(0xFFFF6D00),
          surface: Color(0xFF1A1A2E),
        ),
        scaffoldBackgroundColor: const Color(0xFF0D0D1A),
        useMaterial3: true,
      ),
      home: BLETerminalScreen(autoConnectDevice: autoConnectDevice),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// BLE MANAGER
// Simplified: only connection, send ASCII, receive ASCII
// ─────────────────────────────────────────────────────────────
class BLEManager extends ChangeNotifier {
  List<ScanResult> availableDevices = [];
  
  // Field mapping for response array (update with actual PDF field names)
  static const Map<int, String> fieldNames = {
    0: 'FIELD_1',
    1: 'FIELD_2',
    2: 'FIELD_3',
    3: 'FIELD_4',
    4: 'FIELD_5',
    5: 'FIELD_6',
    6: 'FIELD_7',
    7: 'FIELD_8',
    8: 'FIELD_9',
    9: 'FIELD_10',
    10: 'FIELD_11',
    11: 'FIELD_12',
    12: 'FIELD_13',
    13: 'FIELD_14',
    14: 'FIELD_15',
    15: 'FIELD_16',
    16: 'FIELD_17',
    17: 'FIELD_18',
    18: 'FIELD_19',
    19: 'FIELD_20',
    20: 'FIELD_21',
    21: 'FIELD_22',
    22: 'FIELD_23',
    23: 'FIELD_24',
    24: 'FIELD_25',
    25: 'FIELD_26',
    26: 'FIELD_27',
    27: 'FIELD_28',
    28: 'FIELD_29',
    29: 'FIELD_30',
    30: 'FIELD_31',
    31: 'FIELD_32',
    32: 'FIELD_33',
    33: 'FIELD_34',
    34: 'FIELD_35',
    35: 'FIELD_36',
    36: 'FIELD_37',
    37: 'FIELD_38',
    38: 'FIELD_39',
    39: 'FIELD_40',
    40: 'FIELD_41',
    41: 'FIELD_42',
    42: 'FIELD_43',
    43: 'FIELD_44',
    44: 'FIELD_45',
    45: 'FIELD_46',
    46: 'FIELD_47',
    47: 'FIELD_48',
    48: 'FIELD_49',
    49: 'FIELD_50',
    50: 'FIELD_51',
    51: 'FIELD_52',
    52: 'FIELD_53',
    53: 'FIELD_54',
    54: 'FIELD_55',
    55: 'FIELD_56',
    56: 'FIELD_57',
    57: 'FIELD_58',
    58: 'FIELD_59',
    59: 'FIELD_60',
    60: 'FIELD_61',
    61: 'FIELD_62',
    62: 'FIELD_63',
    63: 'FIELD_64',
    64: 'FIELD_65',
    65: 'FIELD_66',
    66: 'FIELD_67',
    67: 'FIELD_68',
    68: 'FIELD_69',
    69: 'FIELD_70',
    70: 'FIELD_71',
    71: 'FIELD_72',
    72: 'FIELD_73',
    73: 'FIELD_74',
    74: 'FIELD_75',
    75: 'FIELD_76',
    76: 'FIELD_77',
    77: 'FIELD_78',
    78: 'FIELD_79',
    79: 'FIELD_80',
    80: 'FIELD_81',
    81: 'FIELD_82',
    82: 'FIELD_83',
    83: 'FIELD_84',
    84: 'FIELD_85',
    85: 'FIELD_86',
    86: 'FIELD_87',
    87: 'FIELD_88',
    88: 'FIELD_89',
    89: 'FIELD_90',
    90: 'FIELD_91',
    91: 'FIELD_92',
    92: 'FIELD_93',
    93: 'FIELD_94',
    94: 'FIELD_95',
    95: 'FIELD_96',
  };
  
  String _rxBuffer = ''; // Accumulate RX chunks
  DateTime? _lastRxTime;
  Timer? _parseTimer;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _writeChar;
  BluetoothCharacteristic? _notifyChar;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  bool isConnected = false;
  String status = 'Disconnected';
  List<String> logs = [];

  // ── Custom command fields (for modbus) ───────────────────────────────
  String slaveID        = '';
  String functionCode   = '3';
  String startRegister  = '';
  String quantity       = '';
  String registerValues = '';
  String generatedHex   = '';

  // ── Modbus response handling for fragments ──────────────────────────────
  Uint8List lastModbusResponse = Uint8List(0);
  VoidCallback? onModbusResponse;
  final int defaultSlaveID = 247;
  
  // ── Activation state ─────────────────────────────────────────────────────
  bool needsActivation = false;
  bool isActivating = false;
  bool isAppDisabled = false; // Flag to disable entire app if API returns -1
  String deviceHexData = '';
  List<String> hmacSwappedData = [];
  List<int> _rxBuffer_modbus = [];
  Timer? _modbusFrameTimer;

  // ── PUBLIC: connect / disconnect ──────────────────────────
  Future<void> startScan() async {
    availableDevices.clear();
    status = 'Scanning...';
    logs.add('Scanning for BLE devices...');
    notifyListeners();
    await _startScan();
  }

  Future<void> connectToDevice(BluetoothDevice device) async {
    status = 'Connecting...';
    logs.add('Connecting to ${device.platformName.isNotEmpty ? device.platformName : device.remoteId}...');
    notifyListeners();
    await _connectToDevice(device);
  }

  Future<void> disconnect() async {
    await _device?.disconnect();
  }

  // ── PUBLIC: send ASCII string ─────────────────────────────
  Future<void> sendString(String message) async {
    if (_writeChar == null) {
      logs.add('ERROR: Not connected');
      notifyListeners();
      throw Exception('Not connected to device');
    }
    
    try {
      final data = utf8.encode(message);
      final noResp = _writeChar!.properties.writeWithoutResponse;
      
      // If data is small enough, send in one chunk
      if (data.length <= 20) {
        await _writeChar!.write(data, withoutResponse: noResp);
        logs.add('TX: $message');
      } else {
        // Chunk data into 20-byte pieces
        await sendLongString(message);
      }
      notifyListeners();
    } catch (e) {
      logs.add('TX ERROR: $e');
      notifyListeners();
      rethrow; // Re-throw the exception so calling code can handle it
    }
  }

  Future<void> sendLongString(String message) async {
    if (_writeChar == null) {
      logs.add('ERROR: Not connected');
      notifyListeners();
      throw Exception('Not connected to device');
    }
    
    try {
      final data = utf8.encode(message);
      final noResp = _writeChar!.properties.writeWithoutResponse;
      const chunkSize = 20;
      
      logs.add('TX (chunked): Starting ${data.length} bytes...');
      
      for (int i = 0; i < data.length; i += chunkSize) {
        final end = (i + chunkSize < data.length) ? i + chunkSize : data.length;
        final chunk = data.sublist(i, end);
        
        await _writeChar!.write(chunk, withoutResponse: noResp);
        
        // Small delay between chunks to avoid overwhelming the device
        if (i + chunkSize < data.length) {
          await Future.delayed(const Duration(milliseconds: 50));
        }
      }
      
      logs.add('TX: ${message.length} chars sent (${data.length} bytes)');
      notifyListeners();
    } catch (e) {
      logs.add('TX ERROR: $e');
      notifyListeners();
      rethrow; // Re-throw the exception so calling code can handle it
    }
  }

  // ─────────────────────────────────────────────────────────────
  // CUSTOM COMMAND (Custom tab) - MODBUS
  // ─────────────────────────────────────────────────────────────
  void sendCustomCommand() {
    final sid = int.tryParse(slaveID);
    final fc  = int.tryParse(functionCode);
    final st  = int.tryParse(startRegister);

    if (sid == null || fc == null || st == null) {
      logs.add('ERROR: Invalid input'); notifyListeners(); return;
    }

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
  // SEND MODBUS FRAME
  // ─────────────────────────────────────────────────────────────
  Future<void> _sendFrame(Uint8List data, {required bool logTX}) async {
    if (_writeChar == null) {
      logs.add('ERROR: Not connected'); notifyListeners(); return;
    }
    try {
      // Clear any pending Modbus frame data to prevent collision
      _modbusFrameTimer?.cancel();
      _rxBuffer_modbus.clear();
      
      final noResp = _writeChar!.properties.writeWithoutResponse;
      await _writeChar!.write(data, withoutResponse: noResp);
      if (logTX) { logs.add('TX: ${_toHexString(data)}'); notifyListeners(); }
    } catch (e) {
      logs.add('TX ERROR: $e'); notifyListeners();
    }
  }

  String _toHexString(Uint8List data) =>
      data.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');

  // ─────────────────────────────────────────────────────────────
  // PUBLIC MODBUS READ/WRITE METHODS FOR FRAGMENTS
  // ─────────────────────────────────────────────────────────────
  
  /// Read multiple registers (FC 3)
  Future<void> readRegisters({
    int? slaveID,
    required int startRegister,
    required int quantity,
  }) async {
    final sid = slaveID ?? defaultSlaveID;
    final frame = _buildReadFrame(
      slave: sid,
      start: startRegister,
      qty: quantity,
    );
    logs.add('Reading $quantity registers from $startRegister (Slave: $sid)');
    await _sendFrame(frame, logTX: true);
  }

  /// Write multiple registers (FC 16)
  Future<void> writeRegisters({
    int? slaveID,
    required int startRegister,
    required List<int> values,
  }) async {
    final sid = slaveID ?? defaultSlaveID;
    final frame = _buildWriteFrame(
      slave: sid,
      start: startRegister,
      values: values,
    );
    logs.add('Writing ${values.length} registers from $startRegister (Slave: $sid)');
    await _sendFrame(frame, logTX: true);
  }

  /// Parse Modbus FC 3 read response
  List<int> parseReadResponse(Uint8List frame) {
    if (frame.length < 5) return [];
    
    final slaveID = frame[0];
    final functionCode = frame[1];
    final byteCount = frame[2];
    
    if (functionCode != 0x03) {
      logs.add('ERROR: Expected FC 3, got $functionCode');
      return [];
    }
    
    if (frame.length < 3 + byteCount + 2) {
      logs.add('ERROR: Incomplete frame');
      return [];
    }
    
    final values = <int>[];
    for (int i = 0; i < byteCount; i += 2) {
      final highByte = frame[3 + i];
      final lowByte = frame[3 + i + 1];
      values.add((highByte << 8) | lowByte);
    }
    
    return values;
  }

  /// Helper method to poll register 0 until it becomes 0
  Future<bool> _waitForRegister0ToBeZero({int maxAttempts = 30, int delayMs = 200}) async {
    for (int i = 0; i < maxAttempts; i++) {
      await Future.delayed(Duration(milliseconds: delayMs));
      
      // Read register 0
      await readRegisters(startRegister: 0, quantity: 1);
      
      // Wait a bit for response
      await Future.delayed(const Duration(milliseconds: 100));
      
      // Check the response
      if (lastModbusResponse.length >= 5 && lastModbusResponse[1] == 0x03) {
        final values = parseReadResponse(lastModbusResponse);
        if (values.isNotEmpty && values[0] == 0) {
          logs.add('✓ Register 0 = 0 (device ready)');
          notifyListeners();
          return true; // Register 0 is now 0, device is ready
        } else if (values.isNotEmpty) {
          logs.add('⌛ Poll #${i + 1}: Reg 0 = ${values[0]} (waiting...)');
          notifyListeners();
        }
      }
    }
    logs.add('❌ Timeout: Register 0 did not become 0');
    notifyListeners();
    return false; // Timeout
  }

  /// PUBLIC: Run device initialization sequence
  Future<void> runInitializationSequence() async {
    if (!isConnected) {
      logs.add('❌ ERROR: Device not connected');
      notifyListeners();
      return;
    }

    try {
      logs.add('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      logs.add('🚀 Starting initialization sequence');
      logs.add('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      notifyListeners();
      
      // Step 1: Write 5 to register 0
      logs.add('📝 Step 1: Writing 5 to reg 0...');
      notifyListeners();
      await writeRegisters(startRegister: 0, values: [5]);
      logs.add('✓ Wrote 5 to reg 0');
      notifyListeners();
      
      // Step 2: Wait 3 seconds
      logs.add('⏳ Step 2: Waiting 3 seconds...');
      notifyListeners();
      await Future.delayed(const Duration(seconds: 3));
      logs.add('✓ Wait complete');
      notifyListeners();
      
      // Step 3: Write 1 to register 0
      logs.add('📝 Step 3: Writing 1 to reg 0...');
      notifyListeners();
      await writeRegisters(startRegister: 0, values: [1]);
      logs.add('✓ Wrote 1 to reg 0');
      notifyListeners();
      
      // Step 4: Wait 3 seconds
      logs.add('⏳ Step 4: Waiting 3 seconds...');
      notifyListeners();
      await Future.delayed(const Duration(seconds: 3));
      logs.add('✓ Wait complete');
      notifyListeners();
      
      // Step 5: Read device ID (registers 89-95, quantity 7)
      logs.add('📖 Step 5: Reading device ID (regs 89-95)...');
      notifyListeners();
      await readRegisters(startRegister: 89, quantity: 7);
      
      // Wait for response and parse values
      await Future.delayed(const Duration(milliseconds: 500));
      if (lastModbusResponse.length >= 5 && lastModbusResponse[1] == 0x03) {
        final values = parseReadResponse(lastModbusResponse);
        if (values.isNotEmpty && values.length >= 7) {
          logs.add('✓ Device ID raw values:');
          for (int i = 0; i < values.length; i++) {
            logs.add('  Reg ${89 + i} = ${values[i]} (0x${values[i].toRadixString(16).padLeft(4, '0').toUpperCase()})');
          }
          notifyListeners();
          
          // Check the last register (register 95, index 6)
          final reg95Value = values[6];
          logs.add('');
          logs.add('🔍 Checking activation status (Reg 95)...');
          logs.add('  Reg 95 = 0x${reg95Value.toRadixString(16).padLeft(4, '0').toUpperCase()}');
          notifyListeners();
          
          if (reg95Value != 0) {
            // Device is already activated
            logs.add('');
            logs.add('✅ Device is already activated!');
            logs.add('   (Register 95 is not 0000)');
            logs.add('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
            logs.add('✅ Initialization complete');
            logs.add('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
            needsActivation = false;
            notifyListeners();
            return;
          }
          
          // Device needs activation (reg 95 is 0000)
          logs.add('');
          logs.add('⚠️  Register 95 is 0000 - Device needs activation');
          notifyListeners();
          
          // Step 6: Swap bytes for first 6 registers (89-94)
          logs.add('');
          logs.add('🔄 Step 6: Swapping bytes for device ID...');
          notifyListeners();
          
          final swappedParts = <String>[];
          for (int i = 0; i < 6; i++) { // Only first 6 registers for device ID
            final original = values[i].toRadixString(16).padLeft(4, '0').toUpperCase();
            final swapped = original.substring(2, 4) + original.substring(0, 2);
            logs.add('  Reg ${89 + i}: $original → $swapped');
            swappedParts.add(swapped);
          }
          
          deviceHexData = swappedParts.join('');
          logs.add('✓ Device hex string: $deviceHexData');
          notifyListeners();
          
          // Set flag to show activate button
          needsActivation = true;
          logs.add('');
          logs.add('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
          logs.add('⏸️  Paused - Click ACTIVATE button to continue');
          logs.add('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
          notifyListeners();
          
        } else {
          logs.add('❌ Failed to parse register values or insufficient data');
          notifyListeners();
        }
      } else {
        logs.add('❌ No valid response for device ID');
        notifyListeners();
      }
      
    } catch (e) {
      logs.add('❌ Init error: $e');
      notifyListeners();
    }
  }

  /// PUBLIC: Complete device activation (called when Activate button is clicked)
  Future<void> completeActivation() async {
    if (!isConnected || !needsActivation || deviceHexData.isEmpty) {
      logs.add('❌ ERROR: Cannot complete activation');
      notifyListeners();
      return;
    }

    try {
      isActivating = true;
      needsActivation = false;
      notifyListeners();
      
      logs.add('');
      logs.add('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      logs.add('🔐 Starting activation process...');
      logs.add('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      notifyListeners();
      
      // Step 7: Get device location
      logs.add('📍 Step 7: Getting device location...');
      notifyListeners();
      final location = await _getDeviceLocation();
      logs.add('✓ Location: $location');
      notifyListeners();
      
      // Step 8: Post to HMAC API
      logs.add('');
      logs.add('🌐 Step 8: Posting to HMAC API...');
      logs.add('  Device hex: $deviceHexData');
      notifyListeners();
      
      final response = await http.post(
        Uri.parse('https://levelstate-server-flask.onrender.com/hmac'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'hex': deviceHexData,
          'location': 'https://www.google.com/maps/search/?api=1&query=$location',
        }),
      ).timeout(const Duration(seconds: 20));
      
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }
      
      logs.add('✓ API response received');
      notifyListeners();
      
      // Step 9: Parse and swap HMAC response
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final hmacHash = (json['hmac_sha256'] as String).trim();
      
      // Check if API returned -1 (device blocked/unauthorized)
      if (hmacHash == '-1') {
        logs.add('');
        logs.add('❌ CRITICAL: Device authorization failed!');
        logs.add('   API returned -1 - Device is blocked');
        logs.add('   App will be disabled.');
        logs.add('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
        isAppDisabled = true;
        isActivating = false;
        needsActivation = false;
        notifyListeners();
        return;
      }
      
      logs.add('✓ HMAC received: $hmacHash');
      notifyListeners();
      
      logs.add('');
      logs.add('🔄 Step 9: Swapping HMAC response bytes...');
      notifyListeners();
      
      // Swap the HMAC response in same way
      hmacSwappedData.clear();
      for (int i = 0; i < hmacHash.length; i += 4) {
        if (i + 4 <= hmacHash.length) {
          final chunk = hmacHash.substring(i, i + 4);
          final swapped = chunk.substring(2, 4) + chunk.substring(0, 2);
          hmacSwappedData.add(swapped);
          logs.add('  Chunk ${i ~/ 4 + 1}: $chunk → $swapped');
        }
      }
      
      final hmacSwapped = hmacSwappedData.join('');
      logs.add('✓ Swapped HMAC: $hmacSwapped');
      notifyListeners();
      
      // Step 10: Write HMAC to registers starting from 95
      logs.add('');
      logs.add('📝 Step 10: Writing HMAC to registers (starting at 95)...');
      notifyListeners();
      
      int regOffset = 95;
      for (int i = 0; i < hmacSwappedData.length; i++) {
        final chunk = hmacSwappedData[i];
        final chunkValue = int.parse(chunk, radix: 16);
        
        await writeRegisters(startRegister: regOffset, values: [chunkValue]);
        logs.add('  Wrote $chunk (${chunkValue}) → Reg $regOffset');
        notifyListeners();
        
        // Small delay between writes
        await Future.delayed(const Duration(milliseconds: 100));
        regOffset++;
      }
      
      logs.add('✓ All HMAC chunks written to registers 95-${regOffset - 1}');
      notifyListeners();
      
      // Step 11: Write 2 to register 0 (commit)
      logs.add('');
      logs.add('📝 Step 11: Writing 2 to reg 0 (commit)...');
      notifyListeners();
      await writeRegisters(startRegister: 0, values: [2]);
      logs.add('✓ Wrote 2 to reg 0');
      notifyListeners();
      
      // Step 12: Wait 3 seconds
      logs.add('⏳ Step 12: Waiting 3 seconds...');
      notifyListeners();
      await Future.delayed(const Duration(seconds: 3));
      logs.add('✓ Wait complete');
      notifyListeners();
      
      // Step 13: Write 5 to register 0 (finalize)
      logs.add('📝 Step 13: Writing 5 to reg 0 (finalize)...');
      notifyListeners();
      await writeRegisters(startRegister: 0, values: [5]);
      logs.add('✓ Wrote 5 to reg 0');
      notifyListeners();
      
      logs.add('');
      logs.add('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      logs.add('✅ Activation complete!');
      logs.add('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      isActivating = false;
      notifyListeners();
      
    } catch (e) {
      logs.add('❌ Activation error: $e');
      isActivating = false;
      needsActivation = true; // Allow retry
      notifyListeners();
    }
  }

  /// Get device location with permission
  Future<String> _getDeviceLocation() async {
    try {
      // Check and request location permission
      var permission = await Permission.location.status;
      if (!permission.isGranted) {
        logs.add('  → Requesting location permission...');
        notifyListeners();
        permission = await Permission.location.request();
        if (!permission.isGranted) {
          logs.add('  ⚠ Location permission denied');
          notifyListeners();
          return 'Unknown';
        }
      }
      
      // Check if location service is enabled
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        logs.add('  ⚠ Location services are disabled');
        notifyListeners();
        return 'Unknown';
      }
      
      // Get current position
      logs.add('  → Acquiring GPS coordinates...');
      notifyListeners();
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 5),
      );
      
      final location = '${position.latitude.toStringAsFixed(6)},${position.longitude.toStringAsFixed(6)}';
      return location;
      
    } catch (e) {
      logs.add('  ⚠ Location error: $e');
      notifyListeners();
      return 'Unknown';
    }
  }

  // ── PRIVATE: scan and connect ─────────────────────────────
  Future<void> _startScan() async {
    await FlutterBluePlus.stopScan();
    _scanSub?.cancel();
    
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      availableDevices = results;
      notifyListeners();
    });
    
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
    
    // After scan completes
    await Future.delayed(const Duration(seconds: 10));
    await FlutterBluePlus.stopScan();
    _scanSub?.cancel();
    
    // Only update status if not already connected
    if (!isConnected) {
      if (availableDevices.isEmpty) {
        status = 'No devices found';
        logs.add('No BLE devices found');
      } else {
        status = 'Scan complete';
        logs.add('Found ${availableDevices.length} device(s)');
      }
      notifyListeners();
    }
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    try {
      // Stop scanning when connecting
      await FlutterBluePlus.stopScan();
      _scanSub?.cancel();
      
      _device = device;
      await device.connect(autoConnect: false);
      
      _connSub = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          isConnected = false;
          status = 'Disconnected';
          _writeChar = null;
          _notifyChar = null;
          _notifySub?.cancel();
          logs.add('Disconnected');
          notifyListeners();
        }
      });
      
      isConnected = true;
      status = 'Connected';
      logs.add('Connected successfully');
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

    // Try to find a single characteristic that can both write and notify
    for (final s in services) {
      for (final c in s.characteristics) {
        final canWrite = c.properties.write || c.properties.writeWithoutResponse;
        final canNotify = c.properties.notify || c.properties.indicate;
        
        if (canWrite && canNotify) {
          _writeChar = c;
          _notifyChar = c;
          await c.setNotifyValue(true);
          _notifySub = c.onValueReceived.listen(_handleReceive);
          logs.add('Characteristics configured');
          notifyListeners();
          return;
        }
      }
    }

    // Otherwise, find separate write and notify characteristics
    for (final s in services) {
      for (final c in s.characteristics) {
        if ((c.properties.write || c.properties.writeWithoutResponse) && _writeChar == null) {
          _writeChar = c;
        }
        if ((c.properties.notify || c.properties.indicate) && _notifyChar == null) {
          _notifyChar = c;
          await c.setNotifyValue(true);
          _notifySub = c.onValueReceived.listen(_handleReceive);
        }
      }
    }

    if (_writeChar != null) {
      logs.add('Characteristics configured');
      logs.add('→ Go to Custom Command tab and press');
      logs.add('  "Start Initialization Sequence" button');
      notifyListeners();
    } else {
      status = 'No writable characteristic found';
      logs.add('ERROR: No writable characteristic found');
      notifyListeners();
    }
  }

  // ── PRIVATE: handle received data ─────────────────────────
  void _handleReceive(List<int> data) {
    // Check if this looks like a Modbus response
    // Modbus frame starts with: SlaveID (247) + FunctionCode (0x03, 0x10, 0x06)
    bool looksLikeModbus = false;
    
    if (data.isNotEmpty) {
      // If buffer is empty and first byte is slave ID, likely Modbus
      if (_rxBuffer_modbus.isEmpty && data.length >= 2 && data[0] == defaultSlaveID) {
        final fc = data[1];
        if (fc == 0x03 || fc == 0x10 || fc == 0x06) {
          looksLikeModbus = true;
        }
      }
      // If buffer already has data, continue accumulating
      else if (_rxBuffer_modbus.isNotEmpty) {
        looksLikeModbus = true;
      }
    }
    
    if (looksLikeModbus) {
      // Cancel existing timer
      _modbusFrameTimer?.cancel();
      
      // Accumulate data
      _rxBuffer_modbus.addAll(data);
      logs.add('RX chunk: ${_toHexString(Uint8List.fromList(data))} (buffered: ${_rxBuffer_modbus.length} bytes)');
      
      // Try to parse complete frame
      bool frameComplete = false;
      
      if (_rxBuffer_modbus.length >= 5) {
        final slaveID = _rxBuffer_modbus[0];
        final fc = _rxBuffer_modbus[1];
        
        if (fc == 0x03) {
          // Read response: slave + fc + bytecount + data + crc(2)
          final byteCount = _rxBuffer_modbus[2];
          final expectedLength = 5 + byteCount;
          if (_rxBuffer_modbus.length >= expectedLength) {
            frameComplete = true;
          }
        } else if (fc == 0x10 || fc == 0x06) {
          // Write response: slave + fc + addr(2) + qty/value(2) + crc(2) = 8 bytes
          if (_rxBuffer_modbus.length >= 8) {
            frameComplete = true;
          }
        }
      }
      
      if (frameComplete) {
        // We have a complete frame
        _modbusFrameTimer?.cancel();
        _processCompleteModbusFrame();
      } else {
        // Wait for more data (200ms timeout)
        _modbusFrameTimer = Timer(const Duration(milliseconds: 200), () {
          if (_rxBuffer_modbus.isNotEmpty) {
            logs.add('Modbus frame timeout, processing partial data...');
            _processCompleteModbusFrame();
          }
        });
      }
      return;
    }
    
    // Try to handle as ASCII (legacy support)
    try {
      final message = utf8.decode(data);
      
      // Accumulate the RX data
      _rxBuffer += message;
      _lastRxTime = DateTime.now();
      
      // Cancel existing timer
      _parseTimer?.cancel();
      
      // Wait 500ms for all chunks to arrive, then parse
      _parseTimer = Timer(const Duration(milliseconds: 500), () {
        if (_rxBuffer.isNotEmpty) {
          _parseAndLogRxData(_rxBuffer);
          _rxBuffer = '';
        }
      });
      
    } catch (e) {
      // If not valid UTF-8, show as hex
      final hex = data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
      logs.add('RX (HEX): $hex');
      notifyListeners();
    }
  }
  
  void _processCompleteModbusFrame() {
    if (_rxBuffer_modbus.isEmpty) return;
    
    final frame = Uint8List.fromList(_rxBuffer_modbus);
    _rxBuffer_modbus.clear();
    
    lastModbusResponse = frame;
    logs.add('RX Complete Frame: ${_toHexString(frame)}');
    
    // Notify listener if registered
    print('[BLEManager] Modbus callback registered: ${onModbusResponse != null}');
    if (onModbusResponse != null) {
      print('[BLEManager] Calling onModbusResponse callback');
      onModbusResponse!();
    }
    
    notifyListeners();
  }
  
  void _parseAndLogRxData(String fullData) {
    // Check if data contains comma-separated values (config response)
    if (fullData.contains(',')) {
      final parts = fullData.split(',').where((s) => s.trim().isNotEmpty).toList();
      
      // Create JSON-style output
      final buffer = StringBuffer();
      buffer.writeln('RX: {');
      
      for (int i = 0; i < parts.length; i++) {
        final hexValue = parts[i].trim();
        final fieldName = fieldNames[i] ?? 'FIELD_${i + 1}';
        
        try {
          final decValue = int.parse(hexValue, radix: 16);
          buffer.write('  "$fieldName": "$hexValue" (Dec: $decValue)');
        } catch (e) {
          buffer.write('  "$fieldName": "$hexValue"');
        }
        
        if (i < parts.length - 1) {
          buffer.writeln(',');
        } else {
          buffer.writeln();
        }
      }
      
      buffer.write('}');
      logs.add(buffer.toString());
    } else {
      // Simple message, just log it
      logs.add('RX: $fullData');
    }
    
    notifyListeners();
  }

  @override
  void dispose() {
    _parseTimer?.cancel();
    _modbusFrameTimer?.cancel();
    _scanSub?.cancel();
    _notifySub?.cancel();
    _connSub?.cancel();
    super.dispose();
  }
}

// ─────────────────────────────────────────────────────────────
// BLE TERMINAL SCREEN
// ─────────────────────────────────────────────────────────────
class BLETerminalScreen extends StatefulWidget {
  final BluetoothDevice? autoConnectDevice;
  
  const BLETerminalScreen({super.key, this.autoConnectDevice});
  
  @override
  State<BLETerminalScreen> createState() => _BLETerminalScreenState();
}

class _BLETerminalScreenState extends State<BLETerminalScreen>
    with SingleTickerProviderStateMixin {
  final BLEManager _ble = BLEManager();
  late TabController _tabController;
  bool _isSaved = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 6, vsync: this);
    _ble.addListener(_onUpdate);
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
    _tabController.dispose();
    _ble.removeListener(_onUpdate);
    _ble.dispose();
    super.dispose();
  }

  void _onUpdate() {
    if (!mounted) return;
    setState(() {});
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
          deviceType: 'EDLI',
          deviceId: _ble._device!.remoteId.toString(),
          deviceName: _ble._device!.platformName.isNotEmpty 
              ? _ble._device!.platformName 
              : 'EDLI Device',
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

  Future<void> _showDeviceSelectionDialog() async {
    if (!mounted) return;
    
    // Show dialog immediately
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          // Listen to BLE manager updates
          void bleUpdateListener() {
            if (mounted) {
              setDialogState(() {});
            }
          }
          
          // Add listener when dialog is built
          _ble.addListener(bleUpdateListener);
          
          // Remove listener when dialog is closed
          Future.delayed(Duration.zero, () {
            if (context.mounted) {
              // Schedule cleanup when dialog is popped
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _ble.removeListener(bleUpdateListener);
              });
            }
          });
          
          return AlertDialog(
            backgroundColor: const Color(0xFF1A1A2E),
            title: Row(
              children: [
                const Text(
                  'Select BLE Device',
                  style: TextStyle(color: Color(0xFF00E5FF)),
                ),
                const Spacer(),
                Text(
                  '(${_ble.availableDevices.length})',
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              height: 300,
              child: _ble.availableDevices.isEmpty
                  ? const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(
                            color: Color(0xFF00E5FF),
                          ),
                          SizedBox(height: 16),
                          Text(
                            'Scanning for devices...',
                            style: TextStyle(color: Colors.white70),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: _ble.availableDevices.length,
                      itemBuilder: (context, index) {
                        final device = _ble.availableDevices[index].device;
                        final rssi = _ble.availableDevices[index].rssi;
                        final deviceName = device.platformName.isNotEmpty
                            ? device.platformName
                            : device.advName.isNotEmpty
                                ? device.advName
                                : 'Unknown Device';
                        final deviceId = device.remoteId.toString();
                        
                        return Card(
                          color: const Color(0xFF0D0D1A),
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            title: Text(
                              deviceName,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  deviceId,
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 11,
                                  ),
                                ),
                                Text(
                                  'Signal: $rssi dBm',
                                  style: TextStyle(
                                    color: rssi > -70
                                        ? Colors.greenAccent
                                        : rssi > -85
                                            ? Colors.orange
                                            : Colors.redAccent,
                                    fontSize: 10,
                                  ),
                                ),
                              ],
                            ),
                            trailing: const Icon(
                              Icons.bluetooth,
                              color: Color(0xFF00E5FF),
                            ),
                            onTap: () async {
                              Navigator.of(context).pop();
                              await _ble.connectToDevice(device);
                            },
                          ),
                        );
                      },
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                },
                child: const Text(
                  'Cancel',
                  style: TextStyle(color: Colors.redAccent),
                ),
              ),
              TextButton(
                onPressed: () async {
                  setDialogState(() {
                    _ble.availableDevices.clear();
                  });
                  await _ble.startScan();
                },
                child: const Text(
                  'Refresh',
                  style: TextStyle(color: Color(0xFF00E5FF)),
                ),
              ),
            ],
          );
        },
      ),
    );
    
    // Start scanning after showing dialog
    await _ble.startScan();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Scaffold(
        body: Stack(
          children: [
            Column(
              children: [
                // Header with connection controls
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            decoration: BoxDecoration(
              color: const Color(0xFF12121F),
              border: Border(
                bottom: BorderSide(color: Colors.cyan.withOpacity(0.15)),
              ),
            ),
            child: Row(
              children: [
                const Text(
                  'EDLI',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: 1.2,
                  ),
                ),
                const Spacer(),
                // Status indicator
                AnimatedContainer(
                  duration: const Duration(milliseconds: 400),
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _ble.isConnected ? Colors.greenAccent : Colors.redAccent,
                    boxShadow: [
                      BoxShadow(
                        color: (_ble.isConnected ? Colors.green : Colors.red)
                            .withOpacity(0.5),
                        blurRadius: 6,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _ble.status,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.6),
                    fontSize: 13,
                  ),
                ),
                const SizedBox(width: 12),
                // Connect/Disconnect button
                GestureDetector(
                  onTap: _ble.isConnected ? _ble.disconnect : _showDeviceSelectionDialog,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: _ble.isConnected
                            ? Colors.redAccent
                            : const Color(0xFF00E5FF),
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _ble.isConnected ? 'Disconnect' : 'Connect',
                      style: TextStyle(
                        color: _ble.isConnected
                            ? Colors.redAccent
                            : const Color(0xFF00E5FF),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                // Save/Unsave button (only show when connected)
                if (_ble.isConnected)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: GestureDetector(
                      onTap: _toggleSaveDevice,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: _isSaved 
                              ? Colors.orange.withOpacity(0.2)
                              : Colors.green.withOpacity(0.2),
                          border: Border.all(
                            color: _isSaved ? Colors.orange : Colors.green,
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _isSaved ? Icons.bookmark : Icons.bookmark_border,
                              size: 16,
                              color: _isSaved ? Colors.orange : Colors.green,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _isSaved ? 'Unsave' : 'Save',
                              style: TextStyle(
                                color: _isSaved ? Colors.orange : Colors.green,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // Tab Views
          Expanded(
            child: TabBarView(
                controller: _tabController,
                children: [
                  LedStatusFragment(bleManager: _ble),
                  HomeFragment(bleManager: _ble),
                  CustomCommandTab(ble: _ble),
                  AdminFragment(bleManager: _ble),
                  ConfigFragment(bleManager: _ble),
                  SettingFragment(bleManager: _ble),
                ],
              ),
          ),

          // Tab Bar at Bottom
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A2E),
              border: Border(
                top: BorderSide(
                  color: const Color(0xFF00E5FF).withOpacity(0.2),
                  width: 1,
                ),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.3),
                  blurRadius: 8,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: TabBar(
              controller: _tabController,
              indicatorColor: const Color(0xFF00E5FF),
              indicatorWeight: 3,
              indicatorSize: TabBarIndicatorSize.tab,
              labelColor: const Color(0xFF00E5FF),
              unselectedLabelColor: Colors.white38,
              tabs: const [
                Tab(icon: Icon(Icons.lightbulb_outline, size: 24)),
                Tab(icon: Icon(Icons.home, size: 24)),
                Tab(icon: Icon(Icons.terminal, size: 24)),
                Tab(icon: Icon(Icons.admin_panel_settings, size: 24)),
                Tab(icon: Icon(Icons.tune, size: 24)),
                Tab(icon: Icon(Icons.settings, size: 24)),
              ],
            ),
          ),
          ],
        ),
        
        // Blocking overlay when app is disabled
        if (_ble.isAppDisabled)
          Container(
            color: Colors.black.withOpacity(0.95),
            child: Center(
              child: Container(
                margin: const EdgeInsets.all(32),
                padding: const EdgeInsets.all(32),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1A2E),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.redAccent, width: 2),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.block,
                      size: 80,
                      color: Colors.redAccent,
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      'Device Unauthorized',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.redAccent,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'This device has been blocked by the server.\n'
                      'Authorization failed (API returned -1).\n\n'
                      'Please contact support for assistance.',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 16,
                        height: 1.5,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// CUSTOM COMMAND TAB - MODBUS
// ─────────────────────────────────────────────────────────────
class CustomCommandTab extends StatefulWidget {
  final BLEManager ble;
  
  const CustomCommandTab({super.key, required this.ble});

  @override
  State<CustomCommandTab> createState() => _CustomCommandTabState();
}

class _CustomCommandTabState extends State<CustomCommandTab> {
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
      // Header
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF12121F),
          border: Border(
            bottom: BorderSide(color: Colors.cyan.withOpacity(0.15)),
          ),
        ),
        child: Row(
          children: [
            const Icon(Icons.terminal, color: Color(0xFF00E5FF), size: 20),
            const SizedBox(width: 8),
            const Text(
              'CUSTOM COMMAND',
              style: TextStyle(
                color: Color(0xFF00E5FF),
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
            const Spacer(),
            if (widget.ble.isConnected)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.greenAccent.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.greenAccent),
                ),
                child: const Text(
                  'Connected',
                  style: TextStyle(
                    color: Colors.greenAccent,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
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
              onPressed: widget.ble.isConnected 
                  ? () => widget.ble.runInitializationSequence()
                  : null,
              icon:  const Icon(Icons.play_arrow_rounded, size: 20),
              label: const Text('Start Initialization Sequence'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4CAF50),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),

          const SizedBox(height: 10),

          // Activate button - shown when device needs activation
          if (widget.ble.needsActivation)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: widget.ble.isConnected && !widget.ble.isActivating
                    ? () => widget.ble.completeActivation()
                    : null,
                icon: widget.ble.isActivating
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.black,
                        ),
                      )
                    : const Icon(Icons.bolt_rounded, size: 20),
                label: Text(widget.ble.isActivating 
                    ? 'Activating...' 
                    : 'ACTIVATE Device'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),

          if (widget.ble.needsActivation)
            const SizedBox(height: 10),

          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: widget.ble.isConnected ? _send : null,
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

