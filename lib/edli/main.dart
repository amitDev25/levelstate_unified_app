import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'adminfragment.dart';
import 'homefragment.dart';
import 'configfragment.dart';
import 'settingfragment.dart';
import 'ledstatusfragment.dart';

// ─────────────────────────────────────────────────────────────
// HTTP OVERRIDES - Bypass SSL certificate verification
// ─────────────────────────────────────────────────────────────
class MyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback = (X509Certificate cert, String host, int port) => true;
  }
}

// ─────────────────────────────────────────────────────────────
// ENTRY POINT
// ─────────────────────────────────────────────────────────────
void main() {
  HttpOverrides.global = MyHttpOverrides();
  runApp(const BLEAsciiApp());
}

class BLEAsciiApp extends StatelessWidget {
  const BLEAsciiApp({super.key});
  
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
      home: const BLETerminalScreen(),
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
  
  bool _initialQuerySent = false;
  bool _query0001Sent = false; // Track if ?0001! command has been sent
  String? _pendingHmacResponse; // Store response waiting for API call
  bool isDeviceRegistered = true; // Track if device is registered (default true until checked)
  String? registrationError; // Store registration error message
  bool isDeviceActivated = true; // Track if device is activated (default true until checked)
  String? field94Value; // Store FIELD_94 value for activation check
  List<String> _fullArrayHex = []; // Store all 96 fields for activation
  String? hmacHash; // Store HMAC hash for activation

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

  // ── PUBLIC: activate device ───────────────────────────────
  Future<void> activateDevice() async {
    if (!isConnected) {
      logs.add('ERROR: Not connected to device');
      notifyListeners();
      return;
    }

    if (_fullArrayHex.isEmpty || _fullArrayHex.length < 109) {
      logs.add('ERROR: Insufficient field data for activation (need at least 109 fields, have ${_fullArrayHex.length})');
      notifyListeners();
      return;
    }

    if (hmacHash == null || hmacHash!.isEmpty) {
      logs.add('ERROR: No HMAC hash available for activation');
      notifyListeners();
      return;
    }

    try {
      logs.add('Starting device activation...');
      notifyListeners();

      // Divide the 64-character hash into 16 parts of 4 characters each
      final hashParts = <String>[];
      for (int i = 0; i < hmacHash!.length; i += 4) {
        if (i + 4 <= hmacHash!.length) {
          final part = hmacHash!.substring(i, i + 4).toUpperCase();
          
          // Byte-swap each 4-character part: split into 2 parts and swap
          // e.g., "E67C" -> "7CE6" (E6|7C -> 7C|E6)
          if (part.length == 4) {
            final firstByte = part.substring(0, 2);
            final secondByte = part.substring(2, 4);
            final swapped = secondByte + firstByte;
            hashParts.add(swapped);
          } else {
            hashParts.add(part);
          }
        }
      }

      if (hashParts.length != 16) {
        logs.add('ERROR: Invalid HMAC hash length (expected 64 characters, got ${hmacHash!.length})');
        notifyListeners();
        return;
      }

      logs.add('HMAC divided and byte-swapped into 16 parts: ${hashParts.join(", ")}');

      // Create a copy of the full array and modify FIELD_94 to FIELD_109
      final modifiedArray = List<String>.from(_fullArrayHex);
      
      // Write hash parts to FIELD_94 through FIELD_109 (indices 93-108)
      for (int i = 0; i < hashParts.length; i++) {
        modifiedArray[93 + i] = hashParts[i];
      }

      logs.add('Writing activation data to FIELD_94 through FIELD_109...');
      notifyListeners();

      // Build the write command: |field1,field2,...,fieldN!
      final commandString = '|${modifiedArray.join(',')}!';
      
      // Send the write command
      await sendLongString(commandString);
      logs.add('Activation write command sent');
      notifyListeners();

      // Wait and send verification commands
      await Future.delayed(const Duration(milliseconds: 500));
      await sendString('?0002!');
      logs.add('Verification command ?0002! sent');
      notifyListeners();

      await Future.delayed(const Duration(milliseconds: 500));
      await sendString('?0005!');
      logs.add('Verification command ?0005! sent');
      notifyListeners();

      // Update activation status
      isDeviceActivated = true;
      field94Value = hashParts[0]; // FIELD_94 now has first part of hash
      logs.add('Device activation completed successfully!');
      notifyListeners();

    } catch (e) {
      logs.add('ERROR: Activation failed: $e');
      notifyListeners();
    }
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

  // ── AUTO-QUERY: Send ?0005! then ?0001! on connect and call HMAC API ──
  Future<void> _sendInitialQueryAndCallApi() async {
    if (_initialQuerySent || !isConnected) return;
    
    _initialQuerySent = true;
    logs.add('Sending initial query ?0005!...');
    notifyListeners();
    
    try {
      // First send ?0005! command
      await sendString('?0005!');
      
      // Wait 3 seconds
      await Future.delayed(const Duration(seconds: 3));
      
      // Then send ?0001! command
      logs.add('Sending query ?0001!...');
      notifyListeners();
      _query0001Sent = true;
      await sendString('?0001!');
      
      // Response will be handled in _parseAndLogRxData
      // which will trigger _processHmacFields if response contains field data
    } catch (e) {
      logs.add('ERROR: Failed to send initial query: $e');
      notifyListeners();
    }
  }

  Future<void> _processHmacFields(String jsonResponse) async {
    try {
      // Extract all fields dynamically up to FIELD_120 (to support up to FIELD_109 for activation)
      _fullArrayHex.clear();
      for (int fieldNum = 1; fieldNum <= 120; fieldNum++) {
        final fieldName = 'FIELD_$fieldNum';
        final pattern = '"$fieldName": "';
        
        final startIndex = jsonResponse.indexOf(pattern);
        if (startIndex != -1) {
          final valueStart = startIndex + pattern.length;
          final valueEnd = jsonResponse.indexOf('"', valueStart);
          if (valueEnd != -1) {
            final hexValue = jsonResponse.substring(valueStart, valueEnd);
            final cleanHex = hexValue.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
            _fullArrayHex.add(cleanHex.isNotEmpty ? cleanHex : '0000');
          } else {
            _fullArrayHex.add('0000');
          }
        } else {
          _fullArrayHex.add('0000');
        }
      }
      
      // Extract FIELD_88 to FIELD_93 for HMAC
      final hexValues = <String>[];
      for (int fieldNum = 88; fieldNum <= 93; fieldNum++) {
        final fieldName = 'FIELD_$fieldNum';
        final pattern = '"$fieldName": "';
        
        final startIndex = jsonResponse.indexOf(pattern);
        if (startIndex != -1) {
          final valueStart = startIndex + pattern.length;
          final valueEnd = jsonResponse.indexOf('"', valueStart);
          if (valueEnd != -1) {
            final hexValue = jsonResponse.substring(valueStart, valueEnd);
            // Remove pipe and other non-hex characters
            final cleanHex = hexValue.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
            final paddedHex = (cleanHex.isNotEmpty ? cleanHex : '0000').padLeft(4, '0');
            
            // Swap bytes: split into 2 parts and swap (e.g., "007E" -> "7E00")
            if (paddedHex.length >= 4) {
              final firstPart = paddedHex.substring(0, 2);
              final secondPart = paddedHex.substring(2, 4);
              final swapped = secondPart + firstPart;
              hexValues.add(swapped);
            } else {
              hexValues.add('0000');
            }
          } else {
            hexValues.add('0000');
          }
        } else {
          hexValues.add('0000');
        }
      }
      
      // Extract FIELD_94 for activation check
      final field94Pattern = '"FIELD_94": "';
      final field94StartIndex = jsonResponse.indexOf(field94Pattern);
      if (field94StartIndex != -1) {
        final field94ValueStart = field94StartIndex + field94Pattern.length;
        final field94ValueEnd = jsonResponse.indexOf('"', field94ValueStart);
        if (field94ValueEnd != -1) {
          final hexValue = jsonResponse.substring(field94ValueStart, field94ValueEnd);
          final cleanHex = hexValue.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
          field94Value = cleanHex.isNotEmpty ? cleanHex : '0000';
          logs.add('FIELD_94 extracted: $field94Value');
        }
      }
      
      // Concatenate all hex values (already byte-swapped)
      final concatenatedHex = hexValues.join('');
      logs.add('HMAC hex extracted (byte-swapped): $concatenatedHex');
      notifyListeners();
      
      // Make POST request to API
      await _sendHmacToApi(concatenatedHex);
      
    } catch (e) {
      logs.add('ERROR: Failed to process HMAC fields: $e');
      notifyListeners();
    }
  }

  Future<void> _sendHmacToApi(String hexString) async {
    try {
      logs.add('Sending HMAC to API...');
      notifyListeners();
      
      // Get actual device location
      String locationString = 'Unknown';
      try {
        // Check location permission
        LocationPermission permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) {
          logs.add('Location permission denied, requesting...');
          permission = await Geolocator.requestPermission();
        }
        
        if (permission == LocationPermission.deniedForever) {
          logs.add('Location permission permanently denied');
          locationString = 'Permission Denied';
        } else if (permission == LocationPermission.denied) {
          logs.add('Location permission denied by user');
          locationString = 'Permission Denied';
        } else {
          // Get current position
          logs.add('Fetching device location...');
          final Position position = await Geolocator.getCurrentPosition(
            desiredAccuracy: LocationAccuracy.high,
            timeLimit: const Duration(seconds: 10),
          ).catchError((error) {
            logs.add('Failed to get location: $error');
            return Position(
              latitude: 0,
              longitude: 0,
              timestamp: DateTime.now(),
              accuracy: 0,
              altitude: 0,
              heading: 0,
              speed: 0,
              speedAccuracy: 0,
              altitudeAccuracy: 0,
              headingAccuracy: 0,
            );
          });
          
          if (position.latitude != 0 && position.longitude != 0) {
            locationString = '${position.latitude},${position.longitude}';
            logs.add('Location obtained: $locationString');
          } else {
            locationString = 'Unknown';
            logs.add('Location unavailable');
          }
        }
      } catch (locationError) {
        logs.add('Location error: $locationError');
        locationString = 'Error';
      }
      
      final url = Uri.parse('https://levelstate-server-flask.onrender.com/hmac');
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'hex': hexString,
          'location': locationString,
        }),
      );
      
      if (response.statusCode == 200 || response.statusCode == 201) {
        logs.add('HMAC API success: ${response.body}');
        
        // Parse the response to check device registration
        try {
          final responseData = jsonDecode(response.body);
          final hmacValue = responseData['hmac_sha256']?.toString() ?? '';
          
          if (hmacValue == '-1') {
            isDeviceRegistered = false;
            registrationError = 'Device is not registered';
            logs.add('WARNING: Device is not registered (HMAC: -1)');
          } else {
            isDeviceRegistered = true;
            registrationError = null;
            hmacHash = hmacValue; // Store HMAC hash for activation
            logs.add('Device registration verified (HMAC: $hmacValue)');
            
            // Check activation status (FIELD_94)
            if (field94Value != null && field94Value == '0000') {
              isDeviceActivated = false;
              logs.add('WARNING: Device is registered but not activated (FIELD_94: 0000)');
            } else {
              isDeviceActivated = true;
              logs.add('Device activation verified (FIELD_94: ${field94Value ?? "unknown"})');
            }
          }
        } catch (parseError) {
          logs.add('ERROR: Failed to parse HMAC response: $parseError');
          // Assume registered if we can't parse (fail open)
          isDeviceRegistered = true;
          isDeviceActivated = true;
        }
      } else {
        logs.add('HMAC API error: ${response.statusCode} - ${response.body}');
        // Assume registered if API fails (fail open)
        isDeviceRegistered = true;
        isDeviceActivated = true;
      }
      notifyListeners();
      
    } catch (e) {
      logs.add('ERROR: Failed to send HMAC to API: $e');
      // Assume registered if request fails (fail open)
      isDeviceRegistered = true;
      notifyListeners();
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
          _initialQuerySent = false;
          _query0001Sent = false;
          _pendingHmacResponse = null;
          isDeviceRegistered = true; // Reset registration status
          registrationError = null;
          isDeviceActivated = true; // Reset activation status
          field94Value = null;
          _fullArrayHex.clear(); // Clear stored fields
          hmacHash = null; // Clear HMAC hash
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
          
          // Send initial query and call API
          await _sendInitialQueryAndCallApi();
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
      notifyListeners();
      
      // Send initial query and call API
      await _sendInitialQueryAndCallApi();
    } else {
      status = 'No writable characteristic found';
      logs.add('ERROR: No writable characteristic found');
      notifyListeners();
    }
  }

  // ── PRIVATE: handle received data ─────────────────────────
  void _handleReceive(List<int> data) {
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
      
      // If this is response to ?0001! query, process HMAC fields
      if (_query0001Sent && _pendingHmacResponse == null) {
        _pendingHmacResponse = buffer.toString();
        _processHmacFields(buffer.toString());
      }
    } else {
      // Simple message, just log it
      logs.add('RX: $fullData');
    }
    
    notifyListeners();
  }

  @override
  void dispose() {
    _parseTimer?.cancel();
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
  const BLETerminalScreen({super.key});
  
  @override
  State<BLETerminalScreen> createState() => _BLETerminalScreenState();
}

class _BLETerminalScreenState extends State<BLETerminalScreen>
    with SingleTickerProviderStateMixin {
  final BLEManager _ble = BLEManager();
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 6, vsync: this);
    _ble.addListener(_onUpdate);
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
        body: Column(
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
              ],
            ),
          ),

          // Tab Views
          Expanded(
            child: !_ble.isDeviceRegistered && _ble.isConnected
                ? _buildUnregisteredDeviceView()
                : _ble.isDeviceRegistered && !_ble.isDeviceActivated && _ble.isConnected
                    ? _buildNotActivatedDeviceView()
                    : TabBarView(
                        controller: _tabController,
                        children: [
                          HomeFragment(bleManager: _ble),
                          CustomCommandTab(ble: _ble),
                          AdminFragment(bleManager: _ble),
                          ConfigFragment(bleManager: _ble),
                          LedStatusFragment(bleManager: _ble),
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
            child: IgnorePointer(
              ignoring: (!_ble.isDeviceRegistered || !_ble.isDeviceActivated) && _ble.isConnected,
              child: Opacity(
                opacity: ((!_ble.isDeviceRegistered || !_ble.isDeviceActivated) && _ble.isConnected) ? 0.3 : 1.0,
                child: TabBar(
                  controller: _tabController,
                  indicatorColor: const Color(0xFF00E5FF),
                  indicatorWeight: 3,
                  indicatorSize: TabBarIndicatorSize.tab,
                  labelColor: const Color(0xFF00E5FF),
                  unselectedLabelColor: Colors.white38,
                  tabs: const [
                    Tab(icon: Icon(Icons.home, size: 24)),
                    Tab(icon: Icon(Icons.terminal, size: 24)),
                    Tab(icon: Icon(Icons.admin_panel_settings, size: 24)),
                    Tab(icon: Icon(Icons.tune, size: 24)),
                    Tab(icon: Icon(Icons.lightbulb_outline, size: 24)),
                    Tab(icon: Icon(Icons.settings, size: 24)),
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

  Widget _buildUnregisteredDeviceView() {
    return Container(
      color: const Color(0xFF0D0D1A),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Error icon
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.redAccent.withOpacity(0.1),
                border: Border.all(
                  color: Colors.redAccent,
                  width: 2,
                ),
              ),
              child: const Icon(
                Icons.block,
                size: 64,
                color: Colors.redAccent,
              ),
            ),
            const SizedBox(height: 32),
            
            // Error message
            Text(
              _ble.registrationError ?? 'Device is not registered',
              style: const TextStyle(
                color: Colors.redAccent,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            
            // Additional info
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 48),
              child: Text(
                'This device is not authorized to use this application. Please contact your administrator to register this device.',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.6),
                  fontSize: 14,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 32),
            
            // Disconnect button
            ElevatedButton.icon(
              onPressed: _ble.disconnect,
              icon: const Icon(Icons.close),
              label: const Text('Disconnect'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNotActivatedDeviceView() {
    return Container(
      color: const Color(0xFF0D0D1A),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Warning icon
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.orangeAccent.withOpacity(0.1),
                border: Border.all(
                  color: Colors.orangeAccent,
                  width: 2,
                ),
              ),
              child: const Icon(
                Icons.warning_amber_rounded,
                size: 64,
                color: Colors.orangeAccent,
              ),
            ),
            const SizedBox(height: 32),
            
            // Message
            const Text(
              'Device is registered but not activated',
              style: TextStyle(
                color: Colors.orangeAccent,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            
            // Additional info
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 48),
              child: Text(
                'This device is registered but requires activation before use. Click the button below to activate it.',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.6),
                  fontSize: 14,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 32),
            
            // Activate button
            ElevatedButton.icon(
              onPressed: () async {
                await _ble.activateDevice();
              },
              icon: const Icon(Icons.check_circle),
              label: const Text('Activate'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.greenAccent,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 14,
                ),
              ),
            ),
            const SizedBox(height: 16),
            
            // Disconnect button (secondary)
            TextButton.icon(
              onPressed: _ble.disconnect,
              icon: const Icon(Icons.close, size: 18),
              label: const Text('Disconnect'),
              style: TextButton.styleFrom(
                foregroundColor: Colors.white54,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// CUSTOM COMMAND TAB
// ─────────────────────────────────────────────────────────────
class CustomCommandTab extends StatefulWidget {
  final BLEManager ble;
  
  const CustomCommandTab({super.key, required this.ble});

  @override
  State<CustomCommandTab> createState() => _CustomCommandTabState();
}

class _CustomCommandTabState extends State<CustomCommandTab> {
  final TextEditingController _msgCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.ble.addListener(_onUpdate);
  }

  @override
  void dispose() {
    widget.ble.removeListener(_onUpdate);
    _msgCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onUpdate() {
    if (!mounted) return;
    setState(() {});
    // Auto-scroll to bottom
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
      }
    });
  }

  void _sendMessage() {
    if (_msgCtrl.text.trim().isEmpty) return;
    widget.ble.sendString(_msgCtrl.text);
    _msgCtrl.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Log area
        Expanded(
          child: Container(
            color: const Color(0xFF0D0D1A),
            child: ListView.builder(
              controller: _scrollCtrl,
              padding: const EdgeInsets.all(12),
              itemCount: widget.ble.logs.length,
              itemBuilder: (context, index) {
                final log = widget.ble.logs[index];
                final isTX = log.startsWith('TX:');
                final isRX = log.startsWith('RX');
                final isError = log.startsWith('ERROR');
                final isJson = log.contains('{') && log.contains('}');
                
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Container(
                    padding: isJson ? const EdgeInsets.all(8) : null,
                    decoration: isJson ? BoxDecoration(
                      color: const Color(0xFF1A1A2E),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Colors.greenAccent.withOpacity(0.3),
                      ),
                    ) : null,
                    child: Text(
                      log,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: isJson ? 11 : 12,
                        height: 1.4,
                        color: isError
                            ? Colors.redAccent
                            : isTX
                                ? const Color(0xFF00E5FF)
                                : isRX
                                    ? Colors.greenAccent
                                    : Colors.white70,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),

        // Input area
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF12121F),
            border: Border(
              top: BorderSide(color: Colors.cyan.withOpacity(0.15)),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _msgCtrl,
                  enabled: widget.ble.isConnected,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Enter ASCII command...',
                    hintStyle: const TextStyle(color: Colors.white38),
                    filled: true,
                    fillColor: const Color(0xFF1A1A2E),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: Colors.white12),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: Colors.white12),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: Color(0xFF00E5FF)),
                    ),
                  ),
                  onSubmitted: (_) => _sendMessage(),
                ),
              ),
              const SizedBox(width: 12),
              ElevatedButton(
                onPressed: widget.ble.isConnected ? _sendMessage : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00E5FF),
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 16,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: const Text(
                  'Send',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
