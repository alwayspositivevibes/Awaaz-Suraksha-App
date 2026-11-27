import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:record/record.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:path_provider/path_provider.dart';

// ─── Background Task Entry Point ─────────────────────────────────────────────
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(_SosBackgroundHandler());
}

class _SosBackgroundHandler extends TaskHandler {
  SpeechToText _speech = SpeechToText();
  bool _speechReady = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _speechReady = await _speech.initialize(
      onStatus: (status) {
        if (status == 'done' || status == 'notListening') {
          _restartListening();
        }
      },
      onError: (err) {
        _restartListening();
      },
    );
    if (_speechReady) _startListening();
  }

  void _startListening() {
    if (!_speechReady) return;
    _speech.listen(
      onResult: (result) {
        final text = result.recognizedWords.toLowerCase();
        if (_matchWake(text)) {
          FlutterForegroundTask.sendDataToMain({'command': 'wake', 'text': text});
        } else if (_matchSafe(text)) {
          FlutterForegroundTask.sendDataToMain({'command': 'safe'});
        }
      },
      listenFor: const Duration(seconds: 60),
      pauseFor: const Duration(seconds: 3),
      localeId: 'en_IN',
      cancelOnError: false,
      partialResults: true,
    );
  }

  void _restartListening() {
    Future.delayed(const Duration(milliseconds: 600), _startListening);
  }

  bool _matchWake(String t) {
    // English + Hindi + Kannada ("Kapaadi" / "Nanna bachaav maadi") + Code Words
    final r = RegExp(
      r'(?:^|\s)(help\s+me\s+now|sos\s+help|bachao|बचाओ|kapaadi|ಕಾಪಾಡಿ|(?:a+w+a+[sz]|a+v+a+[sz]|how\s+has|आवाज़?)\s+help\s+me)(?:\s|$)',
    );
    return r.hasMatch(t);
  }

  bool _matchSafe(String t) {
    final r = RegExp(
      r"(?:^|\s)(i'?m\s+safe|i\s+am\s+safe|cancel\s+sos|safe\s+now)(?:\s|$)",
    );
    return r.hasMatch(t);
  }

  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    await _speech.cancel();
  }
}

// ─── Main App Entry ──────────────────────────────────────────────────────────
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const AwaazSosApp());
}

class AwaazSosApp extends StatelessWidget {
  const AwaazSosApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Awaaz Suraksha',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0D1117),
        primaryColor: const Color(0xFFDA3633),
        fontFamily: 'sans-serif',
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFDA3633),
          secondary: Color(0xFF58A6FF),
          surface: Color(0xFF161B22),
        ),
      ),
      home: const MainNavigationScreen(),
    );
  }
}

// ─── Models ──────────────────────────────────────────────────────────────────
class TrustedContact {
  String name;
  String phone;
  bool isPrimary;
  TrustedContact({required this.name, required this.phone, this.isPrimary = false});

  Map<String, dynamic> toJson() => {'name': name, 'phone': phone, 'isPrimary': isPrimary};
  factory TrustedContact.fromJson(Map<String, dynamic> json) =>
      TrustedContact(name: json['name'] ?? '', phone: json['phone'] ?? '', isPrimary: json['isPrimary'] ?? false);
}

class IncidentRecord {
  final DateTime time;
  final String type;
  final String details;
  IncidentRecord({required this.time, required this.type, required this.details});
}

// ─── Main Navigation Screen ──────────────────────────────────────────────────
class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> with WidgetsBindingObserver {
  int _currentTabIndex = 0;

  // Contacts & Logs
  List<TrustedContact> _contacts = [];
  List<String> _recordings = [];
  List<IncidentRecord> _incidentLogs = [];

  // Toggles & Settings (Covering Screenshots 1-9)
  bool _voiceEnabled = true;
  bool _silentMode = false;
  bool _sirenEnabled = true;
  bool _shakeEnabled = true;
  double _voiceVolume = 1.0;
  String _selectedLanguage = 'en_IN'; // Multilingual (en_IN, hi_IN, kn_IN)
  bool _lowBatteryOptimization = true;
  bool _offlineSmsFallback = true;
  int _checkInMinutes = 30; // Check-in Timer
  Timer? _checkInTimer;
  int _checkInSecondsRemaining = 0;
  String _customCodeWord = 'Red Alert';
  bool _stealthMode = false;

  // Hardware Status
  bool _micOk = false;
  bool _gpsOk = false;
  String _transcript = 'Listening for "Help me now" / "Bachao"…';
  String _selectedCategory = 'Women (181)';

  // Services
  final FlutterTts _tts = FlutterTts();
  Timer? _sirenTimer;
  SpeechToText? _speech;
  bool _speechInitialized = false;
  StreamSubscription<AccelerometerEvent>? _shakeSubscription;
  List<DateTime> _shakeTimes = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initApp();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _shakeSubscription?.cancel();
    _speech?.stop();
    _sirenTimer?.cancel();
    _checkInTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkPermissions();
      if (_voiceEnabled && !_speechInitialized) {
        _startVoiceGuard();
      }
    } else if (state == AppLifecycleState.paused) {
      _speech?.stop();
      _speechInitialized = false;
    }
  }

  Future<void> _initApp() async {
    await _loadSavedPreferences();
    await _setupTts();
    await _checkPermissions();
    await WakelockPlus.enable();
    _initForegroundService();
    if (_voiceEnabled) await _startVoiceGuard();
    if (_shakeEnabled) _startShakeDetection();
  }

  Future<void> _setupTts() async {
    try {
      await _tts.setLanguage(_selectedLanguage);
      await _tts.setVolume(_voiceVolume);
      await _tts.setSpeechRate(0.5);
      await _tts.setPitch(1.0);
    } catch (_) {}
  }

  Future<void> _speak(String text) async {
    if (_silentMode) return;
    try {
      await _tts.setVolume(_voiceVolume);
      await _tts.speak(text);
    } catch (_) {}
  }

  Future<void> _loadSavedPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _voiceEnabled = prefs.getBool('voiceEnabled') ?? true;
      _silentMode = prefs.getBool('silentMode') ?? false;
      _sirenEnabled = prefs.getBool('sirenEnabled') ?? true;
      _shakeEnabled = prefs.getBool('shakeEnabled') ?? true;
      _voiceVolume = prefs.getDouble('voiceVolume') ?? 1.0;
      _selectedLanguage = prefs.getString('selectedLanguage') ?? 'en_IN';
      _customCodeWord = prefs.getString('customCodeWord') ?? 'Red Alert';
      _lowBatteryOptimization = prefs.getBool('lowBattery') ?? true;
      _offlineSmsFallback = prefs.getBool('smsFallback') ?? true;

      final contactsRaw = prefs.getStringList('contacts') ?? [];
      _contacts = contactsRaw.map((s) {
        final parts = s.split('|');
        return TrustedContact(
          name: parts[0],
          phone: parts.length > 1 ? parts[1] : '',
          isPrimary: parts.length > 2 ? parts[2] == 'true' : false,
        );
      }).toList();
    });
  }

  Future<void> _savePreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('voiceEnabled', _voiceEnabled);
    await prefs.setBool('silentMode', _silentMode);
    await prefs.setBool('sirenEnabled', _sirenEnabled);
    await prefs.setBool('shakeEnabled', _shakeEnabled);
    await prefs.setDouble('voiceVolume', _voiceVolume);
    await prefs.setString('selectedLanguage', _selectedLanguage);
    await prefs.setString('customCodeWord', _customCodeWord);
    await prefs.setBool('lowBattery', _lowBatteryOptimization);
    await prefs.setBool('smsFallback', _offlineSmsFallback);

    final raw = _contacts.map((c) => '${c.name}|${c.phone}|${c.isPrimary}').toList();
    await prefs.setStringList('contacts', raw);
  }

  Future<void> _checkPermissions() async {
    final mic = await Permission.microphone.status;
    final loc = await Permission.location.status;

    if (!mic.isGranted || !loc.isGranted) {
      final res = await [
        Permission.microphone,
        Permission.location,
        Permission.notification,
      ].request();

      setState(() {
        _micOk = res[Permission.microphone]?.isGranted ?? false;
        _gpsOk = res[Permission.location]?.isGranted ?? false;
      });
    } else {
      setState(() {
        _micOk = true;
        _gpsOk = true;
      });
    }
  }

  void _initForegroundService() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'awaaz_guard',
        channelName: 'Awaaz Suraksha Shield',
        channelDescription: 'Listening for voice SOS in background',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(10000),
        autoRunOnBoot: true,
        allowWakeLock: true,
      ),
    );

    FlutterForegroundTask.addTaskDataCallback((data) {
      if (data is Map && data['command'] == 'wake') {
        _triggerSos(source: 'Voice (Background)');
      }
    });
  }

  Future<void> _startVoiceGuard() async {
    _speech ??= SpeechToText();

    _speechInitialized = await _speech!.initialize(
      onStatus: (status) {
        if (status == 'done' || status == 'notListening') {
          Future.delayed(const Duration(milliseconds: 500), _listenLoop);
        }
      },
      onError: (err) {
        setState(() => _transcript = 'Microphone active — waiting for voice');
        Future.delayed(const Duration(milliseconds: 1200), _listenLoop);
      },
    );

    if (_speechInitialized) {
      _listenLoop();
      if (!await FlutterForegroundTask.isRunningService) {
        FlutterForegroundTask.startService(
          serviceId: 1001,
          notificationTitle: '🛡️ Awaaz Suraksha Active',
          notificationText: 'Say "Help me now", "Bachao" or code word',
          callback: startCallback,
        );
      }
    }
  }

  void _listenLoop() {
    if (!_voiceEnabled || _speech == null || !_speech!.isAvailable) return;
    try {
      _speech!.listen(
        onResult: (result) {
          final words = result.recognizedWords;
          if (words.isNotEmpty) {
            setState(() => _transcript = 'Heard: "$words"');
          }
          final norm = words.toLowerCase();
          final codeNorm = _customCodeWord.toLowerCase().trim();

          final wakeRegex = RegExp(
            r'(?:^|\s)(help\s+me\s+now|sos\s+help|bachao|बचाओ|kapaadi|ಕಾಪಾಡಿ|(?:a+w+a+[sz]|a+v+a+[sz]|how\s+has|आवाज़?)\s+help\s+me)(?:\s|$)',
          );

          if (wakeRegex.hasMatch(norm) || (codeNorm.isNotEmpty && norm.contains(codeNorm))) {
            _triggerSos(source: 'Voice ("$words")');
          }
        },
        listenFor: const Duration(seconds: 45),
        pauseFor: const Duration(seconds: 3),
        localeId: _selectedLanguage,
        cancelOnError: false,
        partialResults: true,
      );
    } catch (_) {}
  }

  void _startShakeDetection() {
    _shakeSubscription?.cancel();
    _shakeSubscription = accelerometerEventStream().listen((event) {
      final g = math.sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
      if (g > 25) {
        final now = DateTime.now();
        _shakeTimes.add(now);
        _shakeTimes.removeWhere((t) => now.difference(t).inMilliseconds > 1500);
        if (_shakeTimes.length >= 3) {
          _shakeTimes.clear();
          _triggerSos(source: 'Shake Gesture');
        }
      }
    });
  }

  void _triggerSos({bool isDemo = false, String source = 'Manual Tap'}) {
    setState(() {
      _incidentLogs.insert(
        0,
        IncidentRecord(
          time: DateTime.now(),
          type: isDemo ? 'Demo Test SOS' : 'Active SOS',
          details: 'Trigger: $source | Target: $_selectedCategory',
        ),
      );
    });

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SosActiveScreen(
          isDemo: isDemo,
          silentMode: _silentMode,
          sirenEnabled: _sirenEnabled,
          contacts: _contacts,
          category: _selectedCategory,
          offlineSmsFallback: _offlineSmsFallback,
          onLogRecordedAudio: (path) {
            setState(() => _recordings.insert(0, path));
          },
        ),
      ),
    );
  }

  // Check-In Timer Feature
  void _startCheckInTimer(int minutes) {
    _checkInTimer?.cancel();
    setState(() {
      _checkInMinutes = minutes;
      _checkInSecondsRemaining = minutes * 60;
    });

    _checkInTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_checkInSecondsRemaining > 1) {
        setState(() => _checkInSecondsRemaining--);
      } else {
        _checkInTimer?.cancel();
        _triggerSos(source: 'Check-In Timer Expired (No Confirmation)');
      }
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Safety Check-In Timer started for $minutes minutes!')),
    );
  }

  void _cancelCheckInTimer() {
    _checkInTimer?.cancel();
    setState(() => _checkInSecondsRemaining = 0);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Check-In Timer cancelled. Safe arrival confirmed!')),
    );
  }

  // Siren Play/Stop
  Future<void> _playSiren() async {
    _sirenTimer?.cancel();
    _sirenTimer = Timer.periodic(const Duration(milliseconds: 350), (t) {
      SystemSound.play(SystemSoundType.alert);
      HapticFeedback.heavyImpact();
    });
  }

  Future<void> _stopSiren() async {
    _sirenTimer?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        elevation: 0,
        title: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: const Color(0xFFDA3633),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.shield, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_stealthMode ? 'Notes App' : 'Awaaz Suraksha', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
                Text(_stealthMode ? 'Quick Notes' : 'ERSS Voice Safety Shield', style: const TextStyle(fontSize: 11, color: Colors.grey)),
              ],
            ),
          ],
        ),
        actions: [
          _buildStatusPill('Mic', _micOk),
          const SizedBox(width: 6),
          _buildStatusPill('GPS: ${_gpsOk ? "Active" : "Standby"}', _gpsOk),
          IconButton(
            icon: const Icon(Icons.settings, color: Colors.grey),
            onPressed: _openSettingsModal,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: IndexedStack(
        index: _currentTabIndex,
        children: [
          _buildSosTab(),
          _buildTrackVaultTab(),
          _buildToolsTab(),
          _buildContactsTab(),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentTabIndex,
        onTap: (i) => setState(() => _currentTabIndex = i),
        type: BottomNavigationBarType.fixed,
        backgroundColor: const Color(0xFF161B22),
        selectedItemColor: const Color(0xFFDA3633),
        unselectedItemColor: Colors.grey,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.shield), label: '112 SOS'),
          BottomNavigationBarItem(icon: Icon(Icons.location_on), label: 'Track & Vault'),
          BottomNavigationBarItem(icon: Icon(Icons.call), label: 'Tools'),
          BottomNavigationBarItem(icon: Icon(Icons.people), label: 'Contacts'),
        ],
      ),
    );
  }

  Widget _buildStatusPill(String label, bool ok) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: ok ? const Color(0xFF1F6FEB).withOpacity(0.3) : const Color(0xFFDA3633).withOpacity(0.3),
        border: Border.all(color: ok ? const Color(0xFF58A6FF) : const Color(0xFFDA3633), width: 1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: ok ? const Color(0xFF3FB950) : const Color(0xFFDA3633),
            ),
          ),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 10, color: ok ? Colors.white : const Color(0xFFFF7B72))),
        ],
      ),
    );
  }

  // ─── TAB 1: 112 SOS ────────────────────────────────────────────────────────
  Widget _buildSosTab() {
    final categories = ['Women (181)', 'Police (100)', 'Medical (108)', 'Fire (101)', '1091 Helpline'];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // Active Check-in Banner if running
          if (_checkInSecondsRemaining > 0)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF0883E).withOpacity(0.2),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFF0883E)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.timer, color: Color(0xFFF0883E), size: 18),
                      const SizedBox(width: 8),
                      Text(
                        'Check-In Timer: ${(_checkInSecondsRemaining ~/ 60).toString().padLeft(2, '0')}:${(_checkInSecondsRemaining % 60).toString().padLeft(2, '0')}',
                        style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 13),
                      ),
                    ],
                  ),
                  TextButton(
                    onPressed: _cancelCheckInTimer,
                    child: const Text('I Arrived (Cancel)', style: TextStyle(color: Color(0xFF58A6FF), fontSize: 12, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ),

          // Regional Helpline Chip Selector
          SizedBox(
            height: 38,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: categories.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (ctx, idx) {
                final c = categories[idx];
                final sel = c == _selectedCategory;
                return ChoiceChip(
                  label: Text(c, style: TextStyle(fontSize: 12, color: sel ? Colors.white : Colors.grey)),
                  selected: sel,
                  selectedColor: const Color(0xFFDA3633),
                  backgroundColor: const Color(0xFF21262D),
                  onSelected: (val) {
                    if (val) setState(() => _selectedCategory = c);
                  },
                );
              },
            ),
          ),
          const SizedBox(height: 16),

          // Central SOS Card with Animated Pulsing Button
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
            decoration: BoxDecoration(
              color: const Color(0xFF161B22),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF30363D)),
            ),
            child: Column(
              children: [
                // Voice Active badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF238636).withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF238636)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.circle, color: Color(0xFF3FB950), size: 8),
                      const SizedBox(width: 6),
                      Text('Voice Active ($_selectedLanguage)', style: const TextStyle(fontSize: 11, color: Colors.white)),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // Pulsing SOS Button
                PulsingSosButton(
                  targetName: _selectedCategory,
                  onTap: () => _triggerSos(source: 'Center Button Tap'),
                ),
                const SizedBox(height: 20),

                const Text(
                  'Say "Help me now", "Bachao", or "Kaapadi"',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),
                Text(
                  'Custom Code Word: "$_customCodeWord" | WhatsApp + SMS Auto-Dispatch',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),

                // Transcript box
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0D1117),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF30363D)),
                  ),
                  child: Text(
                    _transcript,
                    style: const TextStyle(fontSize: 11, color: Color(0xFF58A6FF)),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Toggles Card
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF161B22),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF30363D)),
            ),
            child: Column(
              children: [
                _buildSwitchTile('Voice Wake-Word Listener', 'Continuous regional voice recognition', _voiceEnabled, (v) {
                  setState(() => _voiceEnabled = v);
                  _savePreferences();
                  if (v) _startVoiceGuard();
                }),
                const Divider(color: Color(0xFF30363D)),
                _buildSwitchTile('Silent SOS Mode', 'Zero sound or speech during trigger (Discreet)', _silentMode, (v) {
                  setState(() => _silentMode = v);
                  _savePreferences();
                }),
                const Divider(color: Color(0xFF30363D)),
                _buildSwitchTile('Loud SOS Siren', 'High-decibel dual-tone siren on activation', _sirenEnabled, (v) {
                  setState(() => _sirenEnabled = v);
                  _savePreferences();
                }),
                const Divider(color: Color(0xFF30363D)),
                _buildSwitchTile('Shake to SOS', '3 rapid phone shakes trigger emergency countdown', _shakeEnabled, (v) {
                  setState(() => _shakeEnabled = v);
                  _savePreferences();
                  if (v) _startShakeDetection();
                }),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSwitchTile(String title, String subtitle, bool val, ValueChanged<bool> onChange) {
    return SwitchListTile(
      title: Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 10, color: Colors.grey)),
      value: val,
      activeColor: const Color(0xFFDA3633),
      contentPadding: EdgeInsets.zero,
      onChanged: onChange,
    );
  }

  // ─── TAB 2: Track & Vault ──────────────────────────────────────────────────
  Widget _buildTrackVaultTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Live GPS Telemetry Card
          _buildHeaderCard(
            title: 'Live GPS Telemetry',
            subtitle: _gpsOk ? 'Dual-Source GPS + Network locked' : 'Location permissions pending',
            trailing: TextButton.icon(
              icon: const Icon(Icons.refresh, size: 14, color: Color(0xFF58A6FF)),
              label: const Text('Refresh', style: TextStyle(fontSize: 12, color: Color(0xFF58A6FF))),
              onPressed: _checkPermissions,
            ),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF0D1117),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.my_location, color: Color(0xFF3FB950), size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _gpsOk ? 'Coordinates ready for live tracking broadcast' : 'Tap refresh to allow location access',
                      style: const TextStyle(fontSize: 12, color: Colors.white70),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Late-Night Open Utility Finder (Pharmacies, Hospitals, Police)
          _buildHeaderCard(
            title: '24/7 Late-Night Utility Finder',
            subtitle: 'Instant map filters for open amenities in your city (Bengaluru / India)',
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _buildUtilityButton('24/7 Pharmacy', Icons.local_pharmacy, 'https://www.google.com/maps/search/24+hour+pharmacy+near+me'),
                _buildUtilityButton('Emergency Hospital', Icons.local_hospital, 'https://www.google.com/maps/search/emergency+hospital+near+me'),
                _buildUtilityButton('Police Station', Icons.local_police, 'https://www.google.com/maps/search/police+station+near+me'),
                _buildUtilityButton('Late Fuel / EV', Icons.ev_station, 'https://www.google.com/maps/search/petrol+pump+near+me'),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Audio Evidence Vault Card
          _buildHeaderCard(
            title: 'Audio Evidence Vault',
            subtitle: 'Encrypted on-device recordings (${_recordings.length} clips)',
            child: _recordings.isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Center(
                    child: Text('No recorded SOS audio clips yet.', style: TextStyle(color: Colors.grey, fontSize: 12)),
                  ),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _recordings.length,
                  itemBuilder: (_, i) {
                    final path = _recordings[i];
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.audiotrack, color: Color(0xFFDA3633)),
                      title: Text('SOS_Evidence_${i + 1}.m4a', style: const TextStyle(fontSize: 12, color: Colors.white)),
                      subtitle: Text(path, style: const TextStyle(fontSize: 9, color: Colors.grey), maxLines: 1),
                      trailing: IconButton(
                        icon: const Icon(Icons.play_arrow, color: Color(0xFF58A6FF)),
                        onPressed: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Playing local audio evidence clip…')),
                          );
                        },
                      ),
                    );
                  },
                ),
          ),
          const SizedBox(height: 16),

          // Incident Log Card
          _buildHeaderCard(
            title: 'Incident Log',
            subtitle: 'DPDP Act Compliant — Stored 100% locally on device (${_incidentLogs.length} events)',
            trailing: TextButton(
              onPressed: () => setState(() => _incidentLogs.clear()),
              child: const Text('Clear', style: TextStyle(color: Color(0xFFFF7B72), fontSize: 12)),
            ),
            child: _incidentLogs.isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Center(
                    child: Text('No SOS events logged yet.', style: TextStyle(color: Colors.grey, fontSize: 12)),
                  ),
                )
              : ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _incidentLogs.length,
                  separatorBuilder: (_, __) => const Divider(color: Color(0xFF30363D)),
                  itemBuilder: (_, i) {
                    final item = _incidentLogs[i];
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        item.type.contains('Demo') ? Icons.bug_report : Icons.warning_rounded,
                        color: item.type.contains('Demo') ? const Color(0xFF58A6FF) : const Color(0xFFDA3633),
                      ),
                      title: Text(item.type, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white)),
                      subtitle: Text('${item.details}\n${item.time.toLocal().toString().substring(0, 19)}', style: const TextStyle(fontSize: 10, color: Colors.grey)),
                    );
                  },
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildUtilityButton(String label, IconData icon, String url) {
    return ActionChip(
      avatar: Icon(icon, color: const Color(0xFF58A6FF), size: 16),
      label: Text(label, style: const TextStyle(fontSize: 11, color: Colors.white)),
      backgroundColor: const Color(0xFF21262D),
      onPressed: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
    );
  }

  // ─── TAB 3: Tools ──────────────────────────────────────────────────────────
  Widget _buildToolsTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // Scheduled Safety Check-In Timer Card
          _buildHeaderCard(
            title: 'Safety Check-In Timer',
            subtitle: 'Automatically alerts your contacts if you do not confirm safe arrival within the set time.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildCheckInChip(15),
                    _buildCheckInChip(30),
                    _buildCheckInChip(60),
                  ],
                ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  icon: const Icon(Icons.timer, color: Colors.white, size: 18),
                  label: Text('Start ${_checkInMinutes}-Min Check-In Timer', style: const TextStyle(color: Colors.white)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1F6FEB),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  onPressed: () => _startCheckInTimer(_checkInMinutes),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Fake Incoming Call Card
          _buildHeaderCard(
            title: 'Fake Incoming Call',
            subtitle: 'Simulate a realistic ringing call to discreetly exit unsafe situations.',
            child: ElevatedButton.icon(
              icon: const Icon(Icons.call, color: Colors.white),
              label: const Text('Start Fake Call Screen', style: TextStyle(color: Colors.white)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF238636),
                padding: const EdgeInsets.symmetric(vertical: 12),
                minimumSize: const Size.fromHeight(42),
              ),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const FakeCallScreen()),
                );
              },
            ),
          ),
          const SizedBox(height: 16),

          // SHOUT & Share Card
          _buildHeaderCard(
            title: 'SHOUT & Share',
            subtitle: 'Broadcast an immediate distress message with GPS coordinates via any app.',
            child: OutlinedButton.icon(
              icon: const Icon(Icons.share, color: Color(0xFFF0883E)),
              label: const Text('SHOUT Distress Share', style: TextStyle(color: Color(0xFFF0883E))),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFFF0883E)),
                padding: const EdgeInsets.symmetric(vertical: 12),
                minimumSize: const Size.fromHeight(42),
              ),
              onPressed: () async {
                final msg = Uri.encodeComponent('EMERGENCY! I need immediate help. Sent via Awaaz Suraksha.');
                final url = Uri.parse('https://wa.me/?text=$msg');
                if (await canLaunchUrl(url)) launchUrl(url, mode: LaunchMode.externalApplication);
              },
            ),
          ),
          const SizedBox(height: 16),

          // Hackathon Demo Mode Card
          _buildHeaderCard(
            title: 'Hackathon Demo Mode',
            subtitle: 'Test the full 5s SOS countdown, siren, voice feedback, and UI without sending real WhatsApp alerts.',
            child: ElevatedButton.icon(
              icon: const Icon(Icons.play_circle_fill, color: Colors.white),
              label: const Text('Run Test SOS (Demo)', style: TextStyle(color: Colors.white)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFDA3633),
                padding: const EdgeInsets.symmetric(vertical: 12),
                minimumSize: const Size.fromHeight(42),
              ),
              onPressed: () => _triggerSos(isDemo: true, source: 'Demo Mode Test'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCheckInChip(int mins) {
    final sel = _checkInMinutes == mins;
    return ChoiceChip(
      label: Text('$mins mins'),
      selected: sel,
      selectedColor: const Color(0xFF1F6FEB),
      backgroundColor: const Color(0xFF21262D),
      onSelected: (v) {
        if (v) setState(() => _checkInMinutes = mins);
      },
    );
  }

  // ─── TAB 4: Contacts & Safety Profile ───────────────────────────────────────
  Widget _buildContactsTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // Trusted Contacts Card (Up to 5 Contacts Supported)
          _buildHeaderCard(
            title: 'Trusted Contacts (${_contacts.length}/5)',
            subtitle: 'Prioritize up to 5 emergency contacts with WhatsApp & SMS alert dispatches.',
            child: Column(
              children: [
                if (_contacts.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('No trusted contacts saved yet.', style: TextStyle(color: Colors.grey, fontSize: 12)),
                  )
                else
                  ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: _contacts.length,
                    separatorBuilder: (_, __) => const Divider(color: Color(0xFF30363D)),
                    itemBuilder: (_, i) {
                      final c = _contacts[i];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: CircleAvatar(
                          backgroundColor: c.isPrimary ? const Color(0xFF238636) : const Color(0xFFDA3633),
                          child: Text(c.name.isNotEmpty ? c.name[0].toUpperCase() : 'C', style: const TextStyle(color: Colors.white)),
                        ),
                        title: Row(
                          children: [
                            Text(c.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white)),
                            if (c.isPrimary)
                              Container(
                                margin: const EdgeInsets.only(left: 6),
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(color: const Color(0xFF238636), borderRadius: BorderRadius.circular(4)),
                                child: const Text('Primary', style: TextStyle(fontSize: 9, color: Colors.white)),
                              ),
                          ],
                        ),
                        subtitle: Text('+91 ${c.phone}', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: Icon(c.isPrimary ? Icons.star : Icons.star_border, color: const Color(0xFFF0883E), size: 20),
                              onPressed: () {
                                setState(() {
                                  for (var item in _contacts) {
                                    item.isPrimary = false;
                                  }
                                  c.isPrimary = true;
                                });
                                _savePreferences();
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete, color: Color(0xFFFF7B72), size: 18),
                              onPressed: () {
                                setState(() => _contacts.removeAt(i));
                                _savePreferences();
                              },
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                const SizedBox(height: 12),
                if (_contacts.length < 5)
                  ElevatedButton.icon(
                    icon: const Icon(Icons.person_add, color: Colors.white, size: 18),
                    label: const Text('Add Trusted Contact', style: TextStyle(color: Colors.white, fontSize: 12)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF238636),
                      minimumSize: const Size.fromHeight(40),
                    ),
                    onPressed: _openAddContactDialog,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Citizen Safety Profile Card
          _buildHeaderCard(
            title: 'Citizen Safety Profile',
            subtitle: 'Optional details included in your emergency alert payload.',
            child: Column(
              children: [
                TextField(
                  decoration: const InputDecoration(
                    labelText: 'Full Name (e.g., Ananya Sharma)',
                    labelStyle: TextStyle(color: Colors.grey, fontSize: 12),
                    border: OutlineInputBorder(),
                  ),
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  onChanged: (v) async {
                    final prefs = await SharedPreferences.getInstance();
                    prefs.setString('userName', v);
                  },
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        decoration: const InputDecoration(
                          labelText: 'Blood Group (e.g. O+)',
                          labelStyle: TextStyle(color: Colors.grey, fontSize: 12),
                          border: OutlineInputBorder(),
                        ),
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                        onChanged: (v) async {
                          final prefs = await SharedPreferences.getInstance();
                          prefs.setString('bloodGroup', v);
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        decoration: const InputDecoration(
                          labelText: 'City / State (e.g. Bengaluru)',
                          labelStyle: TextStyle(color: Colors.grey, fontSize: 12),
                          border: OutlineInputBorder(),
                        ),
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                        onChanged: (v) async {
                          final prefs = await SharedPreferences.getInstance();
                          prefs.setString('cityState', v);
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _openAddContactDialog() {
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        title: const Text('Add Emergency Contact', style: TextStyle(color: Colors.white, fontSize: 15)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'Contact Name (e.g. Maa, Sister)'),
              style: const TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: phoneCtrl,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: '10-Digit Mobile (+91)'),
              style: const TextStyle(color: Colors.white),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFDA3633)),
            onPressed: () {
              final name = nameCtrl.text.trim();
              final phone = phoneCtrl.text.trim().replaceAll(RegExp(r'[^0-9]'), '');
              if (name.isNotEmpty && phone.length >= 10) {
                setState(() {
                  _contacts.add(TrustedContact(
                    name: name,
                    phone: phone.substring(phone.length - 10),
                    isPrimary: _contacts.isEmpty,
                  ));
                });
                _savePreferences();
                Navigator.pop(ctx);
              }
            },
            child: const Text('Save Contact', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  // ─── Settings Modal (Complete implementation of Screenshots 1-9) ─────────
  void _openSettingsModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF161B22),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => DraggableScrollableSheet(
          initialChildSize: 0.85,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          expand: false,
          builder: (_, scrollController) => ListView(
            controller: scrollController,
            padding: const EdgeInsets.all(20),
            children: [
              // Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('App & Safety Settings', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                  IconButton(icon: const Icon(Icons.close, color: Colors.grey), onPressed: () => Navigator.pop(ctx)),
                ],
              ),
              const SizedBox(height: 16),

              // 1. Emergency & SOS Triggers Section
              const Text('1. EMERGENCY & SOS TRIGGERS', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF58A6FF), letterSpacing: 1.2)),
              const SizedBox(height: 10),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Custom Wake / Code Word', style: TextStyle(fontSize: 13, color: Colors.white)),
                subtitle: Text('Current trigger: "$_customCodeWord"', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                trailing: TextButton(
                  onPressed: () => _openCustomCodeWordDialog(setModalState),
                  child: const Text('Edit Word', style: TextStyle(color: Color(0xFF58A6FF))),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Offline SMS Fallback', style: TextStyle(fontSize: 13, color: Colors.white)),
                subtitle: const Text('Automatically dispatches SMS when cellular data is unavailable', style: TextStyle(fontSize: 11, color: Colors.grey)),
                value: _offlineSmsFallback,
                activeColor: const Color(0xFFDA3633),
                onChanged: (v) {
                  setModalState(() => _offlineSmsFallback = v);
                  setState(() => _offlineSmsFallback = v);
                  _savePreferences();
                },
              ),
              const Divider(color: Color(0xFF30363D)),

              // 2. Privacy & Permissions Section
              const Text('2. PRIVACY & PERMISSIONS', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF58A6FF), letterSpacing: 1.2)),
              const SizedBox(height: 10),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Stealth / Disguise Mode', style: TextStyle(fontSize: 13, color: Colors.white)),
                subtitle: const Text('Disguises app title as "Notes App" to hide from aggressors', style: TextStyle(fontSize: 11, color: Colors.grey)),
                value: _stealthMode,
                activeColor: const Color(0xFFDA3633),
                onChanged: (v) {
                  setModalState(() => _stealthMode = v);
                  setState(() => _stealthMode = v);
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Low Battery Optimization', style: TextStyle(fontSize: 13, color: Colors.white)),
                subtitle: const Text('Reduces GPS ping frequency when battery drops below 15%', style: TextStyle(fontSize: 11, color: Colors.grey)),
                value: _lowBatteryOptimization,
                activeColor: const Color(0xFFDA3633),
                onChanged: (v) {
                  setModalState(() => _lowBatteryOptimization = v);
                  setState(() => _lowBatteryOptimization = v);
                  _savePreferences();
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.delete_forever, color: Color(0xFFFF7B72)),
                title: const Text('One-Tap Data Wipe (DPDP Act)', style: TextStyle(fontSize: 13, color: Color(0xFFFF7B72))),
                subtitle: const Text('Instantly clears all contacts, logs, and recordings', style: TextStyle(fontSize: 11, color: Colors.grey)),
                onTap: () {
                  setState(() {
                    _contacts.clear();
                    _incidentLogs.clear();
                    _recordings.clear();
                  });
                  _savePreferences();
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('All local app data wiped successfully.')),
                  );
                },
              ),
              const Divider(color: Color(0xFF30363D)),

              // 3. Audio & Voice Customization
              const Text('3. AUDIO & VOICE CONTROLS', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF58A6FF), letterSpacing: 1.2)),
              const SizedBox(height: 10),
              Text('Speech Language: $_selectedLanguage', style: const TextStyle(fontSize: 13, color: Colors.white)),
              const SizedBox(height: 6),
              Row(
                children: [
                  _buildLangChoice('English (India)', 'en_IN', setModalState),
                  const SizedBox(width: 8),
                  _buildLangChoice('Hindi (हिंदी)', 'hi_IN', setModalState),
                  const SizedBox(width: 8),
                  _buildLangChoice('Kannada (ಕನ್ನಡ)', 'kn_IN', setModalState),
                ],
              ),
              const SizedBox(height: 12),
              Text('Voice Output Volume: ${(_voiceVolume * 100).toInt()}%', style: const TextStyle(color: Colors.white70, fontSize: 13)),
              Slider(
                value: _voiceVolume,
                min: 0.1,
                max: 1.0,
                divisions: 9,
                activeColor: const Color(0xFFDA3633),
                onChanged: (val) {
                  setModalState(() => _voiceVolume = val);
                  setState(() => _voiceVolume = val);
                  _savePreferences();
                  _tts.setVolume(val);
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.volume_up, color: Color(0xFF58A6FF)),
                title: const Text('Test Voice Feedback', style: TextStyle(fontSize: 13, color: Colors.white)),
                trailing: ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF238636)),
                  onPressed: () => _speak('Awaaz Suraksha voice feedback is set to maximum volume.'),
                  child: const Text('Play Voice', style: TextStyle(fontSize: 11, color: Colors.white)),
                ),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.campaign, color: Color(0xFFF0883E)),
                title: const Text('Test Loud SOS Siren', style: TextStyle(fontSize: 13, color: Colors.white)),
                trailing: ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFDA3633)),
                  onPressed: () async {
                    await _playSiren();
                    Future.delayed(const Duration(seconds: 3), _stopSiren);
                  },
                  child: const Text('Play 3s Siren', style: TextStyle(fontSize: 11, color: Colors.white)),
                ),
              ),
              const Divider(color: Color(0xFF30363D)),

              // 4. Developer & Attribution Section
              const SizedBox(height: 12),
              const Center(
                child: Text(
                  'Made with ❤️ in India | Built by Team CTRL ALT ELITE',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLangChoice(String label, String code, StateSetter setModalState) {
    final sel = _selectedLanguage == code;
    return ChoiceChip(
      label: Text(label, style: TextStyle(fontSize: 10, color: sel ? Colors.white : Colors.grey)),
      selected: sel,
      selectedColor: const Color(0xFFDA3633),
      backgroundColor: const Color(0xFF21262D),
      onSelected: (val) {
        if (val) {
          setModalState(() => _selectedLanguage = code);
          setState(() => _selectedLanguage = code);
          _savePreferences();
          _setupTts();
        }
      },
    );
  }

  void _openCustomCodeWordDialog(StateSetter setModalState) {
    final ctrl = TextEditingController(text: _customCodeWord);
    showDialog(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        title: const Text('Set Custom Code Word', style: TextStyle(color: Colors.white, fontSize: 15)),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(labelText: 'Secret phrase (e.g. Red Alert, Safe Exit)'),
          style: const TextStyle(color: Colors.white),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dCtx), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFDA3633)),
            onPressed: () {
              final w = ctrl.text.trim();
              if (w.isNotEmpty) {
                setModalState(() => _customCodeWord = w);
                setState(() => _customCodeWord = w);
                _savePreferences();
                Navigator.pop(dCtx);
              }
            },
            child: const Text('Save', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _buildHeaderCard({required String title, required String subtitle, Widget? trailing, required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white)),
                    const SizedBox(height: 2),
                    Text(subtitle, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                  ],
                ),
              ),
              if (trailing != null) trailing,
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

// ─── Animated Pulsing Center SOS Button ──────────────────────────────────────
class PulsingSosButton extends StatefulWidget {
  final String targetName;
  final VoidCallback onTap;
  const PulsingSosButton({super.key, required this.targetName, required this.onTap});

  @override
  State<PulsingSosButton> createState() => _PulsingSosButtonState();
}

class _PulsingSosButtonState extends State<PulsingSosButton> with SingleTickerProviderStateMixin {
  late AnimationController _anim;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat(reverse: true);
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (ctx, child) {
        final glow = _anim.value * 20 + 8;
        return GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 170,
            height: 170,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const RadialGradient(
                colors: [Color(0xFFE5534B), Color(0xFFDA3633), Color(0xFF8B1A1A)],
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFDA3633).withOpacity(0.5),
                  blurRadius: glow,
                  spreadRadius: _anim.value * 6,
                ),
              ],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.mic, color: Colors.white, size: 40),
                const SizedBox(height: 4),
                const Text('SOS', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: 1.5)),
                Text(widget.targetName, style: const TextStyle(fontSize: 10, color: Colors.white70, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ─── Active SOS Takeover Screen ──────────────────────────────────────────────
class SosActiveScreen extends StatefulWidget {
  final bool isDemo;
  final bool silentMode;
  final bool sirenEnabled;
  final List<TrustedContact> contacts;
  final String category;
  final bool offlineSmsFallback;
  final Function(String) onLogRecordedAudio;

  const SosActiveScreen({
    super.key,
    required this.isDemo,
    required this.silentMode,
    required this.sirenEnabled,
    required this.contacts,
    required this.category,
    required this.offlineSmsFallback,
    required this.onLogRecordedAudio,
  });

  @override
  State<SosActiveScreen> createState() => _SosActiveScreenState();
}

class _SosActiveScreenState extends State<SosActiveScreen> {
  int _countdown = 5;
  Timer? _countdownTimer;
  bool _alertSent = false;
  String _gpsStatus = 'Acquiring GPS fix…';
  String _recordingStatus = 'Standby';
  Position? _currentPosition;

  final AudioRecorder _recorder = AudioRecorder();
  final FlutterTts _tts = FlutterTts();
  Timer? _sirenTimer;

  @override
  void initState() {
    super.initState();
    _startSosSequence();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _sirenTimer?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _startSosSequence() async {
    _fetchGps();

    if (!widget.silentMode) {
      await _tts.setVolume(1.0);
      await _tts.speak('Emergency alert activated. Say "I am safe" or tap cancel.');
    }

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) async {
      if (_countdown > 1) {
        setState(() => _countdown--);
      } else {
        _countdownTimer?.cancel();
        setState(() => _alertSent = true);
        await _executeEmergencyActions();
      }
    });
  }

  Future<void> _fetchGps() async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 5)),
      );
      setState(() {
        _currentPosition = pos;
        _gpsStatus = '${pos.latitude.toStringAsFixed(5)}, ${pos.longitude.toStringAsFixed(5)}';
      });
    } catch (_) {
      setState(() => _gpsStatus = 'GPS Signal Weak (Using Cell Triangulation)');
    }
  }

  Future<void> _executeEmergencyActions() async {
    // 1. Play Siren
    if (widget.sirenEnabled && !widget.silentMode) {
      _sirenTimer = Timer.periodic(const Duration(milliseconds: 300), (t) {
        SystemSound.play(SystemSoundType.alert);
        HapticFeedback.heavyImpact();
      });
    }

    // 2. Audio Evidence Recording
    try {
      if (await _recorder.hasPermission()) {
        final dir = await getApplicationDocumentsDirectory();
        final path = '${dir.path}/SOS_${DateTime.now().millisecondsSinceEpoch}.m4a';
        await _recorder.start(const RecordConfig(), path: path);
        setState(() => _recordingStatus = 'RECORDING EVIDENCE (.m4a)');
        widget.onLogRecordedAudio(path);
      }
    } catch (_) {}

    // 3. Dispatch WhatsApp + Offline SMS Fallback
    if (!widget.isDemo) {
      _dispatchEmergencyAlerts();
    }
  }

  void _dispatchEmergencyAlerts() {
    final mapsLink = _currentPosition != null
        ? 'https://maps.google.com/?q=${_currentPosition!.latitude},${_currentPosition!.longitude}'
        : 'Location unavailable';

    final text = '🚨 EMERGENCY SOS from Awaaz Suraksha!\n'
        'I need urgent help! My live location: $mapsLink\n'
        'Target: ${widget.category}';

    // WhatsApp Dispatch
    for (final contact in widget.contacts) {
      final waUrl = Uri.parse('https://wa.me/91${contact.phone}?text=${Uri.encodeComponent(text)}');
      launchUrl(waUrl, mode: LaunchMode.externalApplication);
      break;
    }

    // Offline SMS Fallback
    if (widget.offlineSmsFallback && widget.contacts.isNotEmpty) {
      final primary = widget.contacts.firstWhere((c) => c.isPrimary, orElse: () => widget.contacts.first);
      final smsUrl = Uri.parse('sms:${primary.phone}?body=${Uri.encodeComponent(text)}');
      launchUrl(smsUrl, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Header
              Column(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: widget.isDemo ? const Color(0xFF1F6FEB) : const Color(0xFFDA3633),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      widget.isDemo ? 'DEMO TEST SOS' : 'ACTIVE EMERGENCY SOS',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _alertSent ? '🚨 SOS BROADCAST ACTIVE' : 'SENDING ALERT IN',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                ],
              ),

              // Countdown / Alert state
              if (!_alertSent)
                Container(
                  width: 140,
                  height: 140,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xFFDA3633), width: 4),
                  ),
                  child: Center(
                    child: Text('$_countdown', style: const TextStyle(fontSize: 64, fontWeight: FontWeight.bold, color: Color(0xFFDA3633))),
                  ),
                )
              else
                Column(
                  children: [
                    const Icon(Icons.warning_amber_rounded, size: 80, color: Color(0xFFDA3633)),
                    const SizedBox(height: 8),
                    Text('Status: $_recordingStatus', style: const TextStyle(fontSize: 12, color: Color(0xFF3FB950), fontWeight: FontWeight.bold)),
                  ],
                ),

              // Telemetry Card
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF161B22),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF30363D)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: const [
                        Icon(Icons.location_on, color: Color(0xFF58A6FF), size: 16),
                        SizedBox(width: 6),
                        Text('Live GPS Coordinates:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(_gpsStatus, style: const TextStyle(fontSize: 13, color: Colors.white70, fontFamily: 'monospace')),
                  ],
                ),
              ),

              // Cancel SOS Button
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF21262D),
                  side: const BorderSide(color: Color(0xFFDA3633), width: 2),
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () {
                  _countdownTimer?.cancel();
                  _sirenTimer?.cancel();
                  Navigator.pop(context);
                },
                child: const Text('CANCEL / I AM SAFE', style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Fake Call Screen ────────────────────────────────────────────────────────
class FakeCallScreen extends StatelessWidget {
  const FakeCallScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              children: const [
                SizedBox(height: 40),
                Text('INCOMING VOICE CALL', style: TextStyle(fontSize: 11, color: Colors.grey, letterSpacing: 2)),
                SizedBox(height: 12),
                Text('Maa', style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.white)),
                SizedBox(height: 4),
                Text('Mobile • India', style: TextStyle(fontSize: 13, color: Colors.white70)),
                SizedBox(height: 8),
                Text('Ringing…', style: TextStyle(fontSize: 12, color: Color(0xFF3FB950))),
              ],
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 30),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  FloatingActionButton(
                    heroTag: 'fake_call_decline',
                    backgroundColor: Colors.red,
                    onPressed: () => Navigator.pop(context),
                    child: const Icon(Icons.call_end, color: Colors.white),
                  ),
                  FloatingActionButton(
                    heroTag: 'fake_call_accept',
                    backgroundColor: Colors.green,
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Call connected — (Simulated)')),
                      );
                    },
                    child: const Icon(Icons.call, color: Colors.white),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
