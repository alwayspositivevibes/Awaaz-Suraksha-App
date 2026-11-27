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
import 'package:audioplayers/audioplayers.dart';

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
  final AudioPlayer _sirenPlayer = AudioPlayer();
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
    _sirenPlayer.dispose();
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
    try {
      await _sirenPlayer.setReleaseMode(ReleaseMode.loop);
      await _sirenPlayer.play(AssetSource('siren.wav'));
    } catch (_) {}
  }

  Future<void> _stopSiren() async {
    try {
      await _sirenPlayer.stop();
    } catch (_) {}
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
                borderRadius: BorderRadius.circular(8),
                image: const DecorationImage(
                  image: AssetImage('assets/app_logo.png'),
                  fit: BoxFit.cover,
                ),
              ),
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
              margin: const EdgeInsets.bottom(12),
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
                color: const
