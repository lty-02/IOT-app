import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart' as classic;
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as ble;
import 'package:fl_chart/fl_chart.dart';
import 'package:http/http.dart' as http;
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:intl/intl.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:ntp/ntp.dart';

// Define the BLE device wrapper class at the top level
class _BleDeviceWithName {
  final ble.BluetoothDevice device;
  final String displayName;
  
  _BleDeviceWithName({required this.device, required this.displayName});
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Badminton Racket',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.light,
        ),
        fontFamily: 'Roboto',
        cardTheme: CardTheme(
          elevation: 3,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            elevation: 2,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ),
      home: const MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({Key? key}) : super(key: key);

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> with SingleTickerProviderStateMixin {
  List<dynamic> devices = []; // 存 Classic & BLE 設備
  bool isScanning = false;
  bool showDeviceList = true; // 控制裝置列表的顯示/隱藏
  StreamSubscription<classic.BluetoothDiscoveryResult>? classicScanSubscription;
  StreamSubscription<List<ble.ScanResult>>? bleScanSubscription;
  classic.BluetoothState _bluetoothState = classic.BluetoothState.UNKNOWN;
  classic.BluetoothConnection? classicConnection;
  ble.BluetoothDevice? bleConnectedDevice;
  bool isConnected = false;
  String connectionStatus = "Not connected";
  // 儲存歷史數據用於繪製圖表
  List<Map<String, dynamic>> _sensorHistory = [];
  final int _maxDataPoints = 300; // 最多儲存 50 個資料點
  bool _isAnalyzing = false;
  Map<String, dynamic> _predictionResults = {
    "speed": 0.0,
    "strokeType": "unknown",
  };
  //savedata
  List<Map<String, dynamic>> _savedDataSessions = [];
  bool _isRecording = false;
  String _currentSessionName = "";
  DateTime _recordingStartTime = DateTime.now();
  List<Map<String, dynamic>> _currentSessionData = [];
  int _selectedTabIndex = 0;
  // Sensor Data
  Map<String, dynamic> sensorData = {
    "timestamp": "",  // Empty timestamp
    "accelX": 0.0,
    "accelY": 0.0,
    "accelZ": 0.0,
    "gyroX": 0.0,
    "gyroY": 0.0,
    "gyroZ": 0.0
  };
  Timer? _analysisTimer; // API call
  String _deviceId = 'UNKNOWN';
  DateTime? _ntpTime; // Store NTP time

  // Animation controller for scan button
  late AnimationController _scanAnimationController;
  
  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _setupListeners();
    _getDeviceId();
    _loadSessionsFromLocalStorage();
    startContinuousAnalysis();

    // Initialize animation controller
    _scanAnimationController = AnimationController(
      duration: const Duration(seconds: 1),
      vsync: this,
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _analysisTimer?.cancel();
    classicScanSubscription?.cancel();
    bleScanSubscription?.cancel();
    classicConnection?.dispose();
    bleConnectedDevice?.disconnect();
    _scanAnimationController.dispose();
    super.dispose();
  }

  //bluetooth
  Future<void> _requestPermissions() async {
    final permissions = [
      Permission.bluetooth,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.location,
      Permission.storage,
    ];
    await permissions.request();
  }

  void _setupListeners() {
    classic.FlutterBluetoothSerial.instance.state.then((state) {
      setState(() {
        _bluetoothState = state;
      });
    });

    classic.FlutterBluetoothSerial.instance.onStateChanged().listen((state) {
      setState(() {
        _bluetoothState = state;
      });
    });
  }

  void startScan() async {
    if (isScanning) return;

    if (_bluetoothState != classic.BluetoothState.STATE_ON) {
      _showCustomSnackBar(
        "Please turn on Bluetooth",
        icon: Icons.bluetooth_disabled,
        isError: true,
      );
      return;
    }

    setState(() {
      devices = [];
      isScanning = true;
    });

    //Classic SPP
    classicScanSubscription?.cancel();
    classicScanSubscription = classic.FlutterBluetoothSerial.instance.startDiscovery().listen((result) {
      final classic.BluetoothDevice device = result.device;
      
      // 確保設備未重複加入
      bool deviceExists = devices.any((d) =>
          d is classic.BluetoothDevice && d.address == device.address);

      if (!deviceExists) {
        setState(() {
          devices.add(device);
        });
      }
    });

    //BLE
    ble.FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));
    bleScanSubscription?.cancel();
    bleScanSubscription = ble.FlutterBluePlus.scanResults.listen((results) {
      for (ble.ScanResult result in results) {
        final ble.BluetoothDevice device = result.device;
        
        // Try to get advertising data which might contain the device name
        String deviceName = device.name;
        if (deviceName.isEmpty && result.advertisementData.localName.isNotEmpty) {
          deviceName = result.advertisementData.localName;
        }
        
        // Create a temporary device with the name (for display purposes)
        final displayDevice = _BleDeviceWithName(
          device: device,
          displayName: deviceName.isNotEmpty ? deviceName : "Unknown BLE Device"
        );

        // 確保設備未重複加入
        bool deviceExists = devices.any((d) {
          if (d is _BleDeviceWithName) {
            return d.device.id.id == device.id.id;
          } else if (d is ble.BluetoothDevice) {
            return d.id.id == device.id.id;
          }
          return false;
        });

        if (!deviceExists) {
          setState(() {
            devices.add(displayDevice);
          });
        }
      }
    });

    await Future.delayed(const Duration(seconds: 5));
    await ble.FlutterBluePlus.stopScan();
    setState(() {
      isScanning = false;
    });
  }

  void stopScan() {
    classicScanSubscription?.cancel();
    bleScanSubscription?.cancel();
    setState(() {
      isScanning = false;
    });
  }
  
  Future<void> connectToDevice(dynamic device) async {
    if (isConnected) {
      await disconnectDevice();
      return;
    }

    // Handle the wrapper class
    if (device is _BleDeviceWithName) {
      device = device.device;
    }

    setState(() {
      connectionStatus = "Connecting to ${device is classic.BluetoothDevice ? device.name : device is ble.BluetoothDevice ? device.name : 'Unknown device'}...";
    });

    try {
      if (device is classic.BluetoothDevice) {
        // 🔹 Classic SPP 連線
        try {
          // 設置更長的超時時間
          classicConnection = await classic.BluetoothConnection.toAddress(device.address)
              .timeout(const Duration(seconds: 10), onTimeout: () {
            throw TimeoutException("Connection timeout after 10 seconds");
          });
          
          setState(() {
            isConnected = true;
            showDeviceList = false;
            connectionStatus = "Connected to ${device.name ?? 'Unknown device'}";
          });

          classicConnection!.input!.listen(
            (Uint8List data) {
              // Parse binary data
              try {
                Map<String, dynamic> parsedData = _parseBinaryData(data);
                setState(() {
                  sensorData = parsedData;
                });
                addSensorDataToHistory(sensorData);
              } catch (e) {
                print("Binary data parsing error: $e");
              }
            },
            onError: (error) {
              print("Classic Bluetooth Error: $error");
              disconnectDevice();
            },
            onDone: () {
              print("Classic Bluetooth connection closed");
              disconnectDevice();
            },
          );
        } catch (e) {
          print("Classic Bluetooth Connection Error: $e");
          _showCustomSnackBar(
            "Failed to connect: ${e.toString().split(':').first}",
            icon: Icons.error_outline,
            isError: true
          );
          setState(() {
            connectionStatus = "Connection failed";
          });
          return;
        }
      } else if (device is ble.BluetoothDevice) {
        //BLE 連線
        try {
          // 先確認設備是否已連接，若已連接則不要嘗試再次連接
          final connectedDevices = await ble.FlutterBluePlus.connectedDevices;
          final alreadyConnected = connectedDevices.any((d) => d.id.id == device.id.id);
          
          if (!alreadyConnected) {
            await device.connect(timeout: const Duration(seconds: 15), autoConnect: false);
          }
          
          bleConnectedDevice = device;
          setState(() {
            isConnected = true;
            showDeviceList = false;
            connectionStatus = "Connected to ${device.name.isNotEmpty ? device.name : 'Unknown device'}";
          });

          // 增加延遲
          await Future.delayed(const Duration(milliseconds: 1000));
          
          List<ble.BluetoothService> services = await device.discoverServices();
          print("Found ${services.length} services");
          
          // 追蹤是否找到至少一個可用的特性
          bool foundUsableCharacteristic = false;
          
          // 遍歷所有服務和特性
          for (var service in services) {
            print("Service UUID: ${service.uuid}");
            
            for (var characteristic in service.characteristics) {
              print("  Char UUID: ${characteristic.uuid}");
              
              // 
              final properties = characteristic.properties;
              if (properties.notify || properties.indicate) {
                try {
                  // try-catch 處理設置通知的異常
                  await characteristic.setNotifyValue(true);
                  print("  ✓ 已開啟通知: ${characteristic.uuid}");
                  foundUsableCharacteristic = true;
                  
                  // 監聽
                  characteristic.value.listen(
                    (value) {
                      if (value.isNotEmpty) {
                        try {
                          // Convert List<int> to Uint8List before parsing
                          Uint8List uint8Data = Uint8List.fromList(value);
                          Map<String, dynamic> parsedData = _parseBinaryData(uint8Data);
                          setState(() {
                            sensorData = parsedData;
                          });
                          addSensorDataToHistory(sensorData);
                        } catch (e) {
                          // If parsing fails, log the error
                          print("Data parsing error: $e, raw data: ${value.toString()}");
                        }
                      }
                    },
                    onError: (error) {
                      print("BLE Characteristic Error: $error");
                    },
                    cancelOnError: false,
                  );
                } catch (e) {
                  print("  ✗ 通知設置失敗: ${characteristic.uuid}, 錯誤: $e");
                  // 繼續處理其他特性，不中斷流程
                }
              }
            }
          }
          
          if (!foundUsableCharacteristic) {
            print("Warning: No usable characteristics found");
            _showCustomSnackBar(
              "Connected, but no usable data channels found",
              icon: Icons.warning_amber_rounded,
              isError: true
            );
          }
        } catch (e) {
          print('BLE 連接或服務發現錯誤: $e');
          setState(() {
            connectionStatus = "Connection failed";
          });
          _showCustomSnackBar(
            "BLE connection failed: ${e.toString().split(':').first}",
            icon: Icons.bluetooth_disabled,
            isError: true
          );
          // 確保清理資源
          try {
            await device.disconnect();
          } catch (_) {}
          return;
        }
      } else {
        _showCustomSnackBar(
          "Unknown device type",
          icon: Icons.device_unknown,
          isError: true
        );
        setState(() {
          connectionStatus = "Not connected";
        });
      }
    } catch (e) {
      print('Connection error: $e');
      setState(() {
        connectionStatus = "Connection failed";
      });
      _showCustomSnackBar(
        "Connection error: ${e.toString().split(':').first}",
        icon: Icons.error_outline,
        isError: true
      );
    }
  }

  Future<void> disconnectDevice() async {
    // 斷開 Classic 連線
    try {
      if (classicConnection != null) {
        await classicConnection?.close();
        classicConnection = null;
      }
    } catch (e) {
      print("Classic 斷開連線錯誤: $e");
    }
    
    // 斷開 BLE 連線
    try {
      if (bleConnectedDevice != null) {
        await bleConnectedDevice?.disconnect();
        bleConnectedDevice = null;
      }
    } catch (e) {
      print("BLE 斷開連線錯誤: $e");
    }

    // 重置狀態
    setState(() {
      isConnected = false;
      showDeviceList = true;
      connectionStatus = "Not connected";
      sensorData = {
        "timestamp": "",  // Empty timestamp
        "accelX": 0.0,
        "accelY": 0.0,
        "accelZ": 0.0,
        "gyroX": 0.0,
        "gyroY": 0.0,
        "gyroZ": 0.0
      };
    });
  }

  Future<void> _getDeviceId() async {
    DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
      _deviceId = androidInfo.id ?? 'UNKNOWN';
    } else if (Platform.isIOS) {
      IosDeviceInfo iosInfo = await deviceInfo.iosInfo;
      _deviceId = iosInfo.identifierForVendor ?? 'UNKNOWN';
    }
  }

  // Fetch NTP time
  Future<void> _fetchNtpTime() async {
    try {
      _ntpTime = await NTP.now();
      print('NTP Time: $_ntpTime');
    } catch (e) {
      print('Error fetching NTP time: $e');
      // Handle errors (e.g., network issues)
    }
  }

  // Binary data parsing function
  Map<String, dynamic> _parseBinaryData(Uint8List data) {
    if (data.length != 24) {
      print("Invalid sensor data length: expected 24 bytes, received ${data.length}");
      throw FormatException("Invalid sensor data length");
    }
    
    // Use ByteData for easier handling of binary data
    ByteData byteData = ByteData.view(data.buffer, data.offsetInBytes, 24);
    
    // Parse each float value (4 bytes each)
    // Using little-endian for byte order as it's most common
    double accelX = byteData.getFloat32(0, Endian.little);
    double accelY = byteData.getFloat32(4, Endian.little);
    double accelZ = byteData.getFloat32(8, Endian.little);
    double gyroX = byteData.getFloat32(12, Endian.little);
    double gyroY = byteData.getFloat32(16, Endian.little);
    double gyroZ = byteData.getFloat32(20, Endian.little);
    
    // Return the parsed sensor data with an empty timestamp
    return {
      "timestamp": _ntpTime?.toIso8601String() ??DateTime.now().toIso8601String(), 
      "accelX": accelX,
      "accelY": accelY,
      "accelZ": accelZ,
      "gyroX": gyroX,
      "gyroY": gyroY,
      "gyroZ": gyroZ
    };
  }

  // Custom SnackBar for Errors
  void _showCustomSnackBar(String message, {
    IconData icon = Icons.info_outline, 
    bool isError = false,
    Duration duration = const Duration(seconds: 3)
  }) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        content: Row(
          children: [
            Icon(
              icon, 
              color: isError ? Colors.white : Colors.white70
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
        backgroundColor: isError ? Colors.red.shade700 : Colors.black87,
        duration: duration,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        elevation: 4,
      ),
    );
  }

  // Datahistory
  void addSensorDataToHistory(Map<String, dynamic> data) {
    setState(() {
      // 添加新數據到歷史列表
      _sensorHistory.add(Map<String, dynamic>.from(data));
      
      // 如果超過最大長度，移除最舊的數據
      if (_sensorHistory.length > _maxDataPoints) {
        _sensorHistory.removeAt(0);
      }
      // 如果正在記錄，添加到當前session
      if (_isRecording) {
        _currentSessionData.add(Map<String, dynamic>.from(data));
      }
    });
  }

  // ACCchart
  Widget _buildAccelerometerChart() {
    if (_sensorHistory.isEmpty) {
      return _buildEmptyChartState("Waiting for data...");
    }

    // 設定加速度 Y 軸範圍
    double minY = -15;
    double maxY = 15;

    return Padding(
      padding: const EdgeInsets.only(right: 16.0, top: 16.0, bottom: 12.0),
      child: SizedBox(
        height: 120,
        child: LineChart(
          LineChartData(
            gridData: FlGridData(
              drawHorizontalLine: true,
              horizontalInterval: 5,
              getDrawingHorizontalLine: (value) {
                return FlLine(
                  color: Colors.grey.shade300,
                  strokeWidth: 1,
                  dashArray: value == 0 ? null : [5, 5],
                );
              },
              drawVerticalLine: false,
            ),
            titlesData: FlTitlesData(
              rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              bottomTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 40,
                  getTitlesWidget: (value, meta) {
                    return Padding(
                      padding: const EdgeInsets.only(right: 8.0),
                      child: Text(
                        value.toInt().toString(),
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: value == 0 ? FontWeight.bold : FontWeight.normal,
                          color: value == 0 ? Colors.black : Colors.grey.shade700,
                        ),
                      ),
                    );
                  },
                  interval: 5,
                ),
              ),
            ),
            borderData: FlBorderData(
              show: true,
              border: Border.all(color: Colors.grey.shade300),
            ),
            lineTouchData: LineTouchData(
              touchTooltipData: LineTouchTooltipData(
                tooltipRoundedRadius: 8,
                getTooltipItems: (List<LineBarSpot> touchedSpots) {
                  return touchedSpots.map((spot) {
                    String axis = "";
                    Color color = Colors.white;
                    if (spot.barIndex == 0) {
                      axis = "X";
                      color = Colors.red;
                    } else if (spot.barIndex == 1) {
                      axis = "Y";
                      color = Colors.green;
                    } else {
                      axis = "Z";
                      color = Colors.blue;
                    }
                    return LineTooltipItem(
                      "$axis: ${spot.y.toStringAsFixed(1)}",
                      TextStyle(color: color, fontWeight: FontWeight.bold),
                    );
                  }).toList();
                },
              ),
            ),
            minX: 0,
            maxX: (_sensorHistory.length - 1).toDouble(),
            minY: minY,
            maxY: maxY,
            lineBarsData: [
              LineChartBarData(
                spots: _getAccelSpots('accelX'),
                isCurved: true,
                color: Colors.red,
                barWidth: 2.5,
                isStrokeCapRound: true,
                dotData: const FlDotData(show: false),
                belowBarData: BarAreaData(
                  show: true,
                  color: Colors.red.withOpacity(0.1),
                ),
              ),
              LineChartBarData(
                spots: _getAccelSpots('accelY'),
                isCurved: true,
                color: Colors.green,
                barWidth: 2.5,
                isStrokeCapRound: true,
                dotData: const FlDotData(show: false),
                belowBarData: BarAreaData(
                  show: true,
                  color: Colors.green.withOpacity(0.1),
                ),
              ),
              LineChartBarData(
                spots: _getAccelSpots('accelZ'),
                isCurved: true,
                color: Colors.blue,
                barWidth: 2.5,
                isStrokeCapRound: true,
                dotData: const FlDotData(show: false),
                belowBarData: BarAreaData(
                  show: true,
                  color: Colors.blue.withOpacity(0.1),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // GYROchart
  Widget _buildGyroscopeChart() {
    if (_sensorHistory.isEmpty) {
      return _buildEmptyChartState("Waiting for data...");
    }

    double minY = -1;
    double maxY = 1;

    return Padding(
      padding: const EdgeInsets.only(right: 16.0, top: 16.0, bottom: 12.0),
      child: SizedBox(
        height: 120,
        child: LineChart(
          LineChartData(
            gridData: FlGridData(
              drawHorizontalLine: true,
              horizontalInterval: 50,
              getDrawingHorizontalLine: (value) {
                return FlLine(
                  color: Colors.grey.shade300,
                  strokeWidth: 1,
                  dashArray: value == 0 ? null : [5, 5],
                );
              },
              drawVerticalLine: false,
            ),
            titlesData: FlTitlesData(
              rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              bottomTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 40,
                  getTitlesWidget: (value, meta) {
                    return Padding(
                      padding: const EdgeInsets.only(right: 8.0),
                      child: Text(
                        value.toInt().toString(),
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: value == 0 ? FontWeight.bold : FontWeight.normal,
                          color: value == 0 ? Colors.black : Colors.grey.shade700,
                        ),
                      ),
                    );
                  },
                  interval: 100,
                ),
              ),
            ),
            borderData: FlBorderData(
              show: true,
              border: Border.all(color: Colors.grey.shade300),
            ),
            lineTouchData: LineTouchData(
              touchTooltipData: LineTouchTooltipData(
                tooltipRoundedRadius: 8,
                getTooltipItems: (List<LineBarSpot> touchedSpots) {
                  return touchedSpots.map((spot) {
                    String axis = "";
                    Color color = Colors.white;
                    if (spot.barIndex == 0) {
                      axis = "X";
                      color = Colors.red;
                    } else if (spot.barIndex == 1) {
                      axis = "Y";
                      color = Colors.green;
                    } else {
                      axis = "Z";
                      color = Colors.blue;
                    }
                    return LineTooltipItem(
                      "$axis: ${spot.y.toStringAsFixed(1)}",
                      TextStyle(color: color, fontWeight: FontWeight.bold),
                    );
                  }).toList();
                },
              ),
            ),
            minX: 0,
            maxX: (_sensorHistory.length - 1).toDouble(),
            minY: minY,
            maxY: maxY,
            lineBarsData: [
              LineChartBarData(
                spots: _getGyroSpots('gyroX'),
                isCurved: true,
                color: Colors.red,
                barWidth: 2.5,
                isStrokeCapRound: true,
                dotData: const FlDotData(show: false),
                belowBarData: BarAreaData(
                  show: true,
                  color: Colors.red.withOpacity(0.1),
                ),
              ),
              LineChartBarData(
                spots: _getGyroSpots('gyroY'),
                isCurved: true,
                color: Colors.green,
                barWidth: 2.5,
                isStrokeCapRound: true,
                dotData: const FlDotData(show: false),
                belowBarData: BarAreaData(
                  show: true,
                  color: Colors.green.withOpacity(0.1),
                ),
              ),
              LineChartBarData(
                spots: _getGyroSpots('gyroZ'),
                isCurved: true,
                color: Colors.blue,
                barWidth: 2.5,
                isStrokeCapRound: true,
                dotData: const FlDotData(show: false),
                belowBarData: BarAreaData(
                  show: true,
                  color: Colors.blue.withOpacity(0.1),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Empty chart placeholder
  Widget _buildEmptyChartState(String message) {
    return Container(
      height: 200,
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.timeline, size: 48, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            Text(
              message,
              style: TextStyle(color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }

  // ACCdataspots
  List<FlSpot> _getAccelSpots(String axis) {
    List<FlSpot> spots = [];
    for (int i = 0; i < _sensorHistory.length; i++) {
      double value = (_sensorHistory[i][axis] ?? 0.0).toDouble();
      // 確保值在合理範圍內
      value = value.clamp(-15.0, 15.0);
      spots.add(FlSpot(i.toDouble(), value));
    }
    return spots;
  }

  // GRROdataspots
  List<FlSpot> _getGyroSpots(String axis) {
    List<FlSpot> spots = [];
    for (int i = 0; i < _sensorHistory.length; i++) {
      double value = (_sensorHistory[i][axis] ?? 0.0).toDouble();
      // 確保值在合理範圍內
      value = value.clamp(-200.0, 200.0);
      spots.add(FlSpot(i.toDouble(), value));
    }
    return spots;
  }

  //exportdata
  Future<void> _startRecording() async {
    if (_isRecording) return;
    
    // 生成session名稱 (例如: "Session_2025-03-26_15-30-45")
    _recordingStartTime = DateTime.now();
    _currentSessionName = "Session_${DateFormat('yyyy-MM-dd_HH-mm-ss').format(_recordingStartTime)}";
    
    setState(() {
      _isRecording = true;
      _currentSessionData = [];
    });
    
    _showCustomSnackBar(
      "Started recording: $_currentSessionName",
      icon: Icons.fiber_manual_record,
      isError: false
    );
  }
  
  Future<void> _stopRecording() async {
    if (!_isRecording) return;
    
    // 計算session時長
    final duration = DateTime.now().difference(_recordingStartTime);
    
    // 保存session數據
    final newSession = {
      'name': _currentSessionName,
      'timestamp': _recordingStartTime.toIso8601String(),
      'duration': duration.inSeconds,
      'dataCount': _currentSessionData.length,
      'data': _currentSessionData,
    };
    
    setState(() {
      _savedDataSessions.add(newSession);
      _isRecording = false;
    });
    
    // 保存到本地儲存
    await _saveSessionsToLocalStorage();
    
    _showCustomSnackBar(
      "Saved recording: $_currentSessionName (${duration.inSeconds}s)",
      icon: Icons.save,
      isError: false
    );
  }
  
  // 將session保存到本地儲存的方法
  Future<void> _saveSessionsToLocalStorage() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/racket_data_sessions.json');
      
      // 轉換為JSON並保存
      await file.writeAsString(jsonEncode(_savedDataSessions));
      print("Sessions saved to ${file.path}");
    } catch (e) {
      print("Error saving sessions: $e");
    }
  }
  
  // 從本地儲存加載session的方法
  Future<void> _loadSessionsFromLocalStorage() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/racket_data_sessions.json');
      
      if (await file.exists()) {
        final contents = await file.readAsString();
        final List<dynamic> decoded = jsonDecode(contents);
        
        setState(() {
          _savedDataSessions = decoded.map((session) => session as Map<String, dynamic>).toList();
        });
        
        print("Loaded ${_savedDataSessions.length} sessions from local storage");
      }
    } catch (e) {
      print("Error loading sessions: $e");
    }
  }
  
  // 匯出session數據為CSV的方法
  Future<void> _exportSessionAsCSV(Map<String, dynamic> session) async {
    try {
      final sessionName = session['name'];
      final List<dynamic> sessionData = session['data'];
      
      if (sessionData.isEmpty) {
        _showCustomSnackBar(
          "No data to export",
          icon: Icons.warning_amber_rounded,
          isError: true
        );
        return;
      }
      
      // 建立CSV heading
      final headers = sessionData.first.keys.toList();
      String csv = headers.join(',') + '\n';
      
      // 添加資料行
      for (var dataPoint in sessionData) {
        final values = headers.map((header) {
          var value = dataPoint[header];
          if (value is double) {
            return value.toStringAsFixed(4);
          }
          return value.toString();
        }).toList();
        csv += values.join(',') + '\n';
      }
      
      // 儲存到臨時檔案
      final directory = await getTemporaryDirectory();
      final String filePath = '${directory.path}/$sessionName.csv';
      final File file = File(filePath);
      await file.writeAsString(csv);
      
      // 分享/匯出文件
      await Share.shareFiles([filePath], text: 'Racket Sensor Data');
      
      _showCustomSnackBar(
        "Data exported successfully",
        icon: Icons.check_circle_outline,
        isError: false
      );
    } catch (e) {
      print("Error exporting data: $e");
      _showCustomSnackBar(
        "Error exporting data: ${e.toString().split(':').first}",
        icon: Icons.error_outline,
        isError: true
      );
    }
  }
  
  // 刪除session的方法
  Future<void> _deleteSession(int index) async {
    setState(() {
      _savedDataSessions.removeAt(index);
    });
    
    await _saveSessionsToLocalStorage();
    
    _showCustomSnackBar(
      "Session deleted",
      icon: Icons.delete_outline,
      isError: false
    );
  }

  Future<void> _exportData() async {
    if (_savedDataSessions.isEmpty) {
      _showCustomSnackBar(
        "No recordings available to export",
        icon: Icons.warning_amber_rounded,
        isError: true
      );
      return;
    }
    
    // 顯示匯出選項
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text(
              "Export Options",
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.table_chart),
            title: const Text("Export as CSV"),
            subtitle: const Text("Comma-separated values spreadsheet"),
            onTap: () {
              Navigator.pop(context);
              if (_savedDataSessions.isNotEmpty) {
                _exportSessionAsCSV(_savedDataSessions.last);
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.cloud_upload),
            title: const Text("Post to Server"),
            subtitle: const Text("Send session data to cloud"),
            onTap: () {
              Navigator.pop(context);
              _postSessionToServer(_savedDataSessions.last);
            },
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
  //data collection http post data
  Future<void> _postSessionToServer(Map<String, dynamic> session) async {
    try {
      // 提取資料
      List<Map<String, dynamic>> formattedData = session['data'].map<Map<String, dynamic>>((item) {
        return {
          "device_id": _deviceId,
          "TimeStamp": item['timestamp'],
          "accel_x": item['accelX'],
          "accel_y": item['accelY'],
          "accel_z": item['accelZ'],
          "gyro_x": item['gyroX'],
          "gyro_y": item['gyroY'],
          "gyro_z": item['gyroZ'],
        };
      }).toList();

      print("Sending data to server:"); //debug
      print(jsonEncode(formattedData));

      final response = await http.post(
        Uri.parse('https://iot.dinochou.dev/sensor_data'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(formattedData), // 發送格式化後的資料
      );

      if (response.statusCode == 201) {
        _showCustomSnackBar("Posted session successfully", icon: Icons.check_circle_outline, isError: false);
      } else {
        throw Exception('Server error ${response.statusCode}');
      }
    } catch (e) {
      _showCustomSnackBar("Failed to post session", icon: Icons.error_outline, isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Smart Badminton Racket',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Theme.of(context).colorScheme.surface,
        actions: [
            if (isConnected && _selectedTabIndex == 2)
            IconButton(
              icon: const Icon(Icons.file_download, color: Colors.blue),
              onPressed: _exportData,
              tooltip: "Export Data",
            ),
          if (isConnected)
            IconButton(
              icon: const Icon(Icons.power_settings_new, color: Colors.red),
              onPressed: disconnectDevice,
              tooltip: "Disconnect",
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Connection Status
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              padding: const EdgeInsets.symmetric(vertical: 12.0, horizontal: 16.0),
              color: isConnected 
                ? Colors.green.shade50 
                : connectionStatus.contains("failed") 
                  ? Colors.red.shade50 
                  : connectionStatus.contains("Connecting") 
                    ? Colors.orange.shade50 
                    : Colors.grey.shade50,
              width: double.infinity,
              child: Row(
                children: [
                  Icon(
                    isConnected 
                      ? Icons.bluetooth_connected 
                      : connectionStatus.contains("failed") 
                        ? Icons.error_outline
                        : connectionStatus.contains("Connecting")
                          ? Icons.bluetooth_searching
                          : Icons.bluetooth_disabled,
                    color: isConnected 
                      ? Colors.green.shade700 
                      : connectionStatus.contains("failed")
                        ? Colors.red.shade700
                        : connectionStatus.contains("Connecting")
                          ? Colors.orange.shade700
                          : Colors.grey.shade700,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      connectionStatus,
                      style: TextStyle(
                        fontWeight: FontWeight.w500,
                        color: isConnected 
                          ? Colors.green.shade700 
                          : connectionStatus.contains("failed")
                            ? Colors.red.shade700
                            : connectionStatus.contains("Connecting")
                              ? Colors.orange.shade700
                              : Colors.grey.shade700,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Main Content
            Expanded(
              child: isConnected
                ? _buildConnectedView()
                : _buildDeviceListView(),
            ),
          ],
        ),
      ),

      // 右下角的 FloatingActionButton：顯示 "SCAN" 或 "斷開連線"
      floatingActionButton: isConnected
          ? null  // When connected, use the power button in app bar instead
          : FloatingActionButton.extended(
              onPressed: isScanning ? stopScan : startScan,
              label: Text(
                isScanning ? "STOP SCAN" : "SCAN",
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              icon: isScanning 
                ? AnimatedBuilder(
                    animation: _scanAnimationController,
                    builder: (context, child) {
                      return Transform.rotate(
                        angle: _scanAnimationController.value * 2 * 3.14159,
                        child: const Icon(Icons.radar),
                      );
                    },
                  )
                : const Icon(Icons.bluetooth_searching),
              elevation: 4,
              backgroundColor: isScanning ? Colors.red : Theme.of(context).colorScheme.primary,
              tooltip: isScanning ? 'Stop scan' : 'Start scan',
            ),
    );
  }

  // 連接後的介面
  Widget _buildConnectedView() {
    return Column(
      children: [
        // 頁籤（3個）
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.grey.withOpacity(0.2),
                spreadRadius: 0,
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            children: [
              Expanded(
                child: _buildTabButton(
                  index: 0,
                  icon: Icons.sensors,
                  label: 'IMU Data',
                ),
              ),
              Expanded(
                child: _buildTabButton(
                  index: 1,
                  icon: Icons.insights,
                  label: 'Analysis',
                ),
              ),
              Expanded(
                child: _buildTabButton(
                  index: 2,
                  icon: Icons.save_alt,
                  label: 'Records',
                ),
              ),
            ],
          ),
        ),
        
        // 頁籤內容
        Expanded(
          child: _selectedTabIndex == 0 
            ? _buildIMUDataView() 
            : _selectedTabIndex == 1 
              ? _buildPredictionDataView() 
              : _buildRecordsView(),
        ),
      ],
    );
  }

  // 新增一個建立頁籤按鈕的幫助方法
  Widget _buildTabButton({required int index, required IconData icon, required String label}) {
    return InkWell(
      onTap: () {
        setState(() {
          _selectedTabIndex = index;
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: _selectedTabIndex == index 
                  ? Theme.of(context).colorScheme.primary 
                  : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              color: _selectedTabIndex == index 
                ? Theme.of(context).colorScheme.primary
                : Colors.grey,
              size: 20,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: _selectedTabIndex == index 
                  ? Theme.of(context).colorScheme.primary
                  : Colors.grey,
                fontWeight: _selectedTabIndex == index 
                  ? FontWeight.bold 
                  : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  // 新增數據記錄頁面
  Widget _buildRecordsView() {
    return Column(
      children: [
        // 錄製控制器
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.grey.withOpacity(0.1),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _isRecording ? "Recording in progress..." : "Start a new recording",
                style: TextStyle(
                  fontWeight: FontWeight.w500,
                  color: _isRecording ? Colors.red : Colors.grey.shade700,
                ),
              ),
              _isRecording
                ? ElevatedButton.icon(
                    onPressed: _stopRecording,
                    icon: const Icon(Icons.stop, color: Colors.white),
                    label: const Text("STOP"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      foregroundColor: Colors.white,
                    ),
                  )
                : ElevatedButton.icon(
                    onPressed: _startRecording,
                    icon: const Icon(Icons.fiber_manual_record, color: Colors.white),
                    label: const Text("RECORD"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      foregroundColor: Colors.white,
                    ),
                  ),
            ],
          ),
        ),
        
        // 保存的會話列表
        Expanded(
          child: _savedDataSessions.isEmpty
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.save_outlined,
                      size: 64,
                      color: Colors.grey.shade400,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      "No saved recordings yet",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      "Tap RECORD to start capturing sensor data",
                      style: TextStyle(color: Colors.grey.shade600),
                    ),
                  ],
                ),
              )
            : ListView.builder(
                padding: const EdgeInsets.only(bottom: 16),
                itemCount: _savedDataSessions.length,
                itemBuilder: (context, index) {
                  final session = _savedDataSessions[index];
                  final sessionName = session['name'] as String;
                  final timestamp = DateTime.parse(session['timestamp'] as String);
                  final duration = session['duration'] as int;
                  final dataCount = session['dataCount'] as int;
                  
                  return Card(
                    margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                    child: Column(
                      children: [
                        ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                          leading: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: Colors.blue.shade50,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Icon(
                              Icons.analytics_outlined,
                              color: Colors.blue.shade700,
                            ),
                          ),
                          title: Text(
                            sessionName,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text(
                            "${DateFormat('MMM dd, yyyy HH:mm').format(timestamp)} • ${duration}s • $dataCount data points",
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.cloud_upload),
                            tooltip: 'Post to Server',
                            onPressed: () => _postSessionToServer(session),
                          ),
                        ),
                        const Divider(),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            TextButton.icon(
                              onPressed: () => _exportSessionAsCSV(session),
                              icon: const Icon(Icons.download, size: 20),
                              label: const Text("Export"),
                            ),
                            TextButton.icon(
                              onPressed: () => _showSessionDetails(session),
                              icon: const Icon(Icons.visibility, size: 20),
                              label: const Text("View"),
                            ),
                            TextButton.icon(
                              onPressed: () => _deleteSession(index),
                              icon: const Icon(Icons.delete_outline, size: 20),
                              label: const Text("Delete"),
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.red,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
        ),
      ],
    );
  }
  
  // 顯示會話詳情的方法
  void _showSessionDetails(Map<String, dynamic> session) {
    final sessionName = session['name'] as String;
    final List<dynamic> sessionData = session['data'];
    
    if (sessionData.isEmpty) {
      _showCustomSnackBar(
        "No data available for this session",
        icon: Icons.info_outline,
        isError: true
      );
      return;
    }
    
    // 計算主要統計數據
    final accelXValues = sessionData.map((d) => d['accelX'] as double).toList();
    final accelYValues = sessionData.map((d) => d['accelY'] as double).toList();
    final accelZValues = sessionData.map((d) => d['accelZ'] as double).toList();
    
    final gyroXValues = sessionData.map((d) => d['gyroX'] as double).toList();
    final gyroYValues = sessionData.map((d) => d['gyroY'] as double).toList();
    final gyroZValues = sessionData.map((d) => d['gyroZ'] as double).toList();
    
    // 計算平均值、最大值等
    double avgAccelX = accelXValues.reduce((a, b) => a + b) / accelXValues.length;
    double avgAccelY = accelYValues.reduce((a, b) => a + b) / accelYValues.length;
    double avgAccelZ = accelZValues.reduce((a, b) => a + b) / accelZValues.length;
    
    double maxAccelX = accelXValues.reduce((a, b) => a > b ? a : b);
    double maxAccelY = accelYValues.reduce((a, b) => a > b ? a : b);
    double maxAccelZ = accelZValues.reduce((a, b) => a > b ? a : b);
    
    double maxGyroX = gyroXValues.reduce((a, b) => a > b ? a : b);
    double maxGyroY = gyroYValues.reduce((a, b) => a > b ? a : b);
    double maxGyroZ = gyroZValues.reduce((a, b) => a > b ? a : b);
    
    // 顯示詳情對話框
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(sessionName),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Data points: ${sessionData.length}'),
              const SizedBox(height: 16),
              
              const Text('Acceleration Stats:', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text('Average X: ${avgAccelX.toStringAsFixed(2)} m/s²'),
              Text('Average Y: ${avgAccelY.toStringAsFixed(2)} m/s²'),
              Text('Average Z: ${avgAccelZ.toStringAsFixed(2)} m/s²'),
              const SizedBox(height: 8),
              Text('Max X: ${maxAccelX.toStringAsFixed(2)} m/s²'),
              Text('Max Y: ${maxAccelY.toStringAsFixed(2)} m/s²'),
              Text('Max Z: ${maxAccelZ.toStringAsFixed(2)} m/s²'),
              
              const SizedBox(height: 16),
              const Text('Gyroscope Stats:', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text('Max X: ${maxGyroX.toStringAsFixed(2)} °/s'),
              Text('Max Y: ${maxGyroY.toStringAsFixed(2)} °/s'),
              Text('Max Z: ${maxGyroZ.toStringAsFixed(2)} °/s'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              _exportSessionAsCSV(session);
            },
            child: const Text('Export CSV'),
          ),
        ],
      ),
    );
  }

  // IMU資料頁籤內容
  Widget _buildIMUDataView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

          // 加速度計資料
          _buildSensorSection(
            title: "Accelerometer",
            icon: Icons.speed,
            iconColor: Colors.blue,
            sensorData: {
              "X-axis": "${sensorData['accelX']?.toStringAsFixed(2) ?? '0.00'} m/s²",
              "Y-axis": "${sensorData['accelY']?.toStringAsFixed(2) ?? '0.00'} m/s²",
              "Z-axis": "${sensorData['accelZ']?.toStringAsFixed(2) ?? '0.00'} m/s²",
            },
            chartWidget: SizedBox(
              height: 200,
              child: _buildAccelerometerChart(),
            ),
            legendColors: const [Colors.red, Colors.green, Colors.blue],
          ),
          
          const SizedBox(height: 24),
          
          // 陀螺儀資料
          _buildSensorSection(
            title: "Gyroscope",
            icon: Icons.rotate_90_degrees_ccw,
            iconColor: Colors.purple,
            sensorData: {
              "X-axis": "${sensorData['gyroX']?.toStringAsFixed(2) ?? '0.00'} °/s",
              "Y-axis": "${sensorData['gyroY']?.toStringAsFixed(2) ?? '0.00'} °/s",
              "Z-axis": "${sensorData['gyroZ']?.toStringAsFixed(2) ?? '0.00'} °/s",
            },
            chartWidget: SizedBox(
              height: 200,
              child: _buildGyroscopeChart(),
            ),
            legendColors: const [Colors.red, Colors.green, Colors.blue],
          ),
        ],
      ),
    );
  }

  // Reusable sensor section widget
  Widget _buildSensorSection({
    required String title,
    required IconData icon,
    required Color iconColor,
    required Map<String, String> sensorData,
    required Widget chartWidget,
    required List<Color> legendColors,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section title
        Row(
          children: [
            Icon(icon, color: iconColor, size: 24),
            const SizedBox(width: 8),
            Text(
              title,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        
        const SizedBox(height: 12),
        
        // Data values
        Card(
          elevation: 2,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                // Legend row
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (int i = 0; i < legendColors.length; i++) ...[
                      if (i > 0) const SizedBox(width: 24),
                      Row(
                        children: [
                          Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              color: legendColors[i],
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            sensorData.keys.elementAt(i),
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
                
                const SizedBox(height: 8),
                const Divider(),
                const SizedBox(height: 8),
                
                // Values grid
                Row(
                  children: [
                    for (int i = 0; i < sensorData.length; i++)
                      Expanded(
                        child: Column(
                          children: [
                            Text(
                              sensorData.values.elementAt(i),
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: legendColors[i],
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
                
                const SizedBox(height: 16),
                
                // Chart
                chartWidget,
              ],
            ),
          ),
        ),
      ],
    );
  }

  // 預測資料頁籤內容
  Widget _buildPredictionDataView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [            
          // 分析結果
          const Text(
            "Analysis Results",
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),         
          const SizedBox(height: 16),
          
          // 速度卡片
          _buildMetricCard(
            title: "Speed",
            icon: Icons.speed,
            iconColor: Colors.blue,
            value: "${_predictionResults['speed']?.toStringAsFixed(1) ?? '0.0'} m/s",
            valueColor: Colors.blue,
            description: "The maximum speed of badminton during the stroke",
          ),
          
          const SizedBox(height: 16),
          
          // 揮拍類型卡片
          Card(
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.sports_tennis, color: Colors.green, size: 24),
                      const SizedBox(width: 8),
                      const Text(
                        "Stroke Type",
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Center(child: _buildStrokeTypeIndicator()),
                ],
              ),
            ),
          ),
          
          const SizedBox(height: 24),         
        ],
      ),
    );
  }
  
  // 指標卡片
  Widget _buildMetricCard({
    required String title,
    required IconData icon,
    required Color iconColor,
    required String value,
    required Color valueColor,
    required String description,
  }) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: iconColor, size: 24),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Center(
              child: Text(
                value,
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: valueColor,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              description,
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey.shade600,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
  
  // 顯示揮拍類型的介面
  Widget _buildStrokeTypeIndicator() {
    final String strokeType = _predictionResults['strokeType'] ?? 'unknown';
    
    // 將 strokeType 映射到中文名稱和英文名稱
    Map<String, Map<String, dynamic>> strokeInfo = {
      'Smash': {
        'name': '殺球',
        'englishName': 'Smash',
        'color': Colors.red,
        'icon': Icons.arrow_downward,
      },
      'Drive': {
        'name': '平球',
        'englishName': 'Drive',
        'color': Colors.orange,
        'icon': Icons.arrow_forward,
      },
      'Lob': {
        'name': '挑球',
        'englishName': 'Toss',
        'color': Colors.yellow.shade800,
        'icon': Icons.arrow_upward,
      },
      'Net': {
        'name': '網前',
        'englishName': 'Drop',
        'color': Colors.green,
        'icon': Icons.arrow_drop_down,
      },
      'Clear': {
        'name': '高遠',
        'englishName': 'Clear',
        'color': Colors.blue,
        'icon': Icons.wifi_tethering,
      },
      'Other': {
        'name': '其他',
        'englishName': 'Other',
        'color': Colors.grey,
        'icon': Icons.help_outline,
      },
      'unknown': {
        'name': '未知',
        'englishName': 'Unknown',
        'color': Colors.grey.shade400,
        'icon': Icons.device_unknown,
      },
    };
    
    final info = strokeInfo[strokeType] ?? strokeInfo['unknown']!;
    
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
      decoration: BoxDecoration(
        color: info['color'].withOpacity(0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: info['color'],
          width: 2,
        ),
      ),
      child: Column(
        children: [
          Icon(
            info['icon'],
            color: info['color'],
            size: 48,
          ),
          const SizedBox(height: 16),
          Text(
            info['name'],
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: info['color'],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            info['englishName'],
            style: TextStyle(
              fontSize: 18,
              color: info['color'].withOpacity(0.8),
            ),
          ),
        ],
      ),
    );
  }

  void startContinuousAnalysis() async {
    while (true) {
      await _postAnalysis();  // 等待分析完成
      await Future.delayed(Duration(seconds: 2));  // 延遲兩秒
    }
  }

  bool _isPosting = false;

  Future<void> _postAnalysis() async {
    if (_isPosting) return; // 避免重複呼叫
    _isPosting = true;

    try {
      // 感測器歷史數據不足 30 筆不進行分析
      if (_sensorHistory.length < 30) {
        print('Sensor history too short for analysis (${_sensorHistory.length} < 30)');
        return;
      }

      // /inferencebydata API Body
      final List<Map<String, dynamic>> dataForInference = _sensorHistory.map((dataPoint) {
        return {
          "accel_x": dataPoint['accelX'] ?? 0.0,
          "accel_y": dataPoint['accelY'] ?? 0.0,
          "accel_z": dataPoint['accelZ'] ?? 0.0,
          "gyro_x": dataPoint['gyroX'] ?? 0.0,
          "gyro_y": dataPoint['gyroY'] ?? 0.0,
          "gyro_z": dataPoint['gyroZ'] ?? 0.0,
        };
      }).toList();

      final Uri apiUrl = Uri.parse('https://iot.dinochou.dev/inferencebydata');
      print('Sending data to API: ${jsonEncode(requestBody)}');

      final response = await http.post(
        apiUrl,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(dataForInference),
      );

      if (response.statusCode == 200) {
        final responseData = jsonDecode(response.body);

        if (responseData is List && responseData.isNotEmpty) {
          final firstPrediction = responseData[0];

          final List<dynamic>? classificationList = firstPrediction['classification_prediction'];
          String strokeType = 'unknown';
          if (classificationList != null && classificationList.isNotEmpty) {
            strokeType = classificationList[0].toString();
          }

          double speed = 0.0;
          if (firstPrediction['speed_prediction'] is List && firstPrediction['speed_prediction'].isNotEmpty) {
            final List<dynamic> speedPredictionOuter = firstPrediction['speed_prediction'];
            if (speedPredictionOuter[0] is List && speedPredictionOuter[0].isNotEmpty) {
              speed = (speedPredictionOuter[0][0] as num).toDouble();
            }
          }

          setState(() {
            _predictionResults = {
              'speed': speed,
              'strokeType': strokeType,
            };
          });

          print('Inference successful: $_predictionResults');
          _showCustomSnackBar("Inference successful!", icon: Icons.check_circle, isError: false);
        } else {
          print('Inference API response format error: $responseData');
          _showCustomSnackBar("Inference failed: Invalid response format", icon: Icons.warning_amber, isError: true);
        }
      } else {
        print('Server error during inference: ${response.statusCode}, Response body: ${response.body}');
        _showCustomSnackBar("Inference failed: Server error ${response.statusCode}", icon: Icons.cloud_off, isError: true);
      }
    } catch (e) {
      print('Auto analysis/inference error: $e');
      _showCustomSnackBar("Inference connection error: ${e.toString().split(':').first}", icon: Icons.error_outline, isError: true);
    } finally {
      _isPosting = false; // 無論成功與否都解除鎖定
    }
  }


  // 設備列表視圖
  Widget _buildDeviceListView() {
    if (devices.isEmpty) {
      return Center(
        child: isScanning
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 60,
                    height: 60,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Scanning for devices...',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Make sure your device is turned on and in pairing mode',
                    style: TextStyle(color: Colors.grey.shade600),
                    textAlign: TextAlign.center,
                  ),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.bluetooth_searching,
                    size: 80,
                    color: Colors.grey.shade400,
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'No devices found',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Tap the button below to scan for nearby devices',
                    style: TextStyle(color: Colors.grey.shade600),
                  ),
                ],
              ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Text(
            'Available Devices',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.only(bottom: 80), // Add padding for FAB
            itemCount: devices.length,
            separatorBuilder: (context, index) => const Divider(height: 1, indent: 72),
            itemBuilder: (context, index) {
              final device = devices[index];
              String deviceName = "Unknown Device";
              String deviceAddress = "";
              dynamic originalDevice = device;
              bool isBleDevice = false;
              
              if (device is _BleDeviceWithName) {
                deviceName = device.displayName;
                deviceAddress = device.device.id.id;
                originalDevice = device.device; // Use the actual device for connection
                isBleDevice = true;
              } else if (device is classic.BluetoothDevice) {
                deviceName = device.name?.isNotEmpty == true ? device.name! : "Unknown Classic Device";
                deviceAddress = device.address;
                isBleDevice = false;
              } else if (device is ble.BluetoothDevice) {
                deviceName = device.name.isNotEmpty ? device.name : "Unknown BLE Device";
                deviceAddress = device.id.id;
                isBleDevice = true;
              }
              
              return ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                leading: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: isBleDevice 
                      ? Colors.blue.shade100 
                      : Colors.green.shade100,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Icon(
                    isBleDevice ? Icons.bluetooth : Icons.settings_bluetooth,
                    color: isBleDevice ? Colors.blue.shade700 : Colors.green.shade700,
                  ),
                ),
                title: Text(
                  deviceName,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                subtitle: Text(
                  deviceAddress,
                  style: TextStyle(
                    color: Colors.grey.shade600,
                    fontSize: 12,
                  ),
                ),
                trailing: ElevatedButton(
                  onPressed: () => connectToDevice(originalDevice),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  ),
                  child: const Text(
                    "Connect",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                onTap: () => connectToDevice(originalDevice),
              );
            },
          ),
        ),
      ],
    );
  }
}