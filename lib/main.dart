import 'dart:async';
import 'dart:io';
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
import 'dart:math' as math;

// ─── Background Task Entry Point (top-level, required by flutter_foreground_task) ───
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
    );
    if (_speechReady) _startListening();
  }

  void _startListening() {
    if (!_speechReady) return;
    _speech.listen(
      onResult: (result) {
        final text = result.recognizedWords.toLowerCase();
        if (_matchWake(text)) {
          FlutterForegroundTask.sendDataToMain({'command': 'wake'});
        } else if (_matchSafe(text)) {
          FlutterForegroundTask.sendDataToMain({'command': 'safe'});
        }
      },
      listenFor: const Duration(seconds: 60),
      pauseFor: const Duration(seconds: 2),
      localeId: 'en_IN',
      cancelOnError: false,
      partialResults: true,
    );
  }

  void _restartListening() {
    Future.delayed(const Duration(milliseconds: 400), _startListening);
  }

  bool _matchWake(String t) {
    final r = RegExp(
      r'(?:^|\s)(help\s+me\s+now|sos\s+help|bachao|बचाओ|(?:a+w+a+[sz]|a+v+a+[sz]|how\s+has|आवाज़?)\s+help\s+me)(?:\s|$)',
    );
    return r.hasMatch(t);
  }

  bool _matchSafe(String t) {
    final r = RegExp(
      r"(?:^|\s)(i'?m\s+safe|i\s+am\s+safe|cancel\s+sos)(?:\s|$)",
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

// ─── App Entry ───────────────────────────────────────────────────────────────
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
      title: 'AWAAZ SOS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.dark(
          primary: const Color(0xFFDA3633),
          surface: const Color(0xFF161B22),
          onSurface: const Color(0xFFE6EDF3),
        ),
        scaffoldBackgroundColor: const Color(0xFF0D1117),
        useMaterial3: true,
        fontFamily: 'sans-serif',
      ),
      home: const HomeScreen(),
    );
  }
}

// ─── Constants ────────────────────────────────────────────────────────────────
const _kRed = Color(0xFFDA3633);
const _kGreen = Color(0xFF238636);
const _kBg = Color(0xFF0D1117);
const _kCard = Color(0xFF161B22);
const _kBorder = Color(0xFF30363D);
const _kText = Color(0xFFE6EDF3);
const _kMuted = Color(0xFF8B949E);
const _kSosBg = Color(0xFF1A0000);

// ─── Contact Model ────────────────────────────────────────────────────────────
class Contact {
  final String name;
  final String phone; // E.164 e.g. +919876543210

  Contact({required this.name, required this.phone});

  Map<String, dynamic> toJson() => {'name': name, 'phone': phone};

  factory Contact.fromJson(Map<String, dynamic> j) =>
      Contact(name: j['name'] as String, phone: j['phone'] as String);
}

// ─── Storage Service ──────────────────────────────────────────────────────────
class StorageService {
  static const _contactsKey = 'awaaz_contacts';

  static Future<List<Contact>> loadContacts() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_contactsKey) ?? [];
    return raw.map((s) {
      final parts = s.split('|||');
      return Contact(name: parts[0], phone: parts[1]);
    }).toList();
  }

  static Future<void> saveContacts(List<Contact> contacts) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _contactsKey,
      contacts.map((c) => '${c.name}|||${c.phone}').toList(),
    );
  }

  static String? validatePhone(String input) {
    String digits = input.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.startsWith('91') && digits.length == 12) digits = digits.substring(2);
    if (digits.startsWith('0') && digits.length == 11) digits = digits.substring(1);
    if (!RegExp(r'^[6-9]\d{9}$').hasMatch(digits)) return null;
    return '+91$digits';
  }

  static String formatPhone(String e164) {
    final d = e164.replaceAll(RegExp(r'\D'), '');
    if (d.length == 12 && d.startsWith('91')) {
      return '+91 ${d.substring(2, 7)} ${d.substring(7)}';
    }
    return e164;
  }
}

// ─── TTS Service ──────────────────────────────────────────────────────────────
class TtsService {
  final FlutterTts _tts = FlutterTts();
  bool _silent = false;

  TtsService() {
    _tts.setLanguage('en-IN');
    _tts.setSpeechRate(0.52);
    _tts.setPitch(1.0);
    _tts.setVolume(1.0);
  }

  void setSilent(bool v) => _silent = v;

  Future<void> speak(String text, {VoidCallback? onDone}) async {
    if (_silent) {
      onDone?.call();
      return;
    }
    await _tts.stop();
    _tts.setCompletionHandler(() => onDone?.call());
    await _tts.speak(text);
  }

  Future<void> stop() => _tts.stop();
}

// ─── Location Service ─────────────────────────────────────────────────────────
class LocationService {
  static Future<Map<String, dynamic>> getLocation() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return {'ok': false, 'reason': 'Location services disabled'};
      }

      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.deniedForever || perm == LocationPermission.denied) {
        return {'ok': false, 'reason': 'Location permission denied'};
      }

      // Try high-accuracy first (5s), then network fallback (remaining budget)
      Position? pos;
      try {
        pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
        ).timeout(const Duration(seconds: 5));
      } catch (_) {
        try {
          pos = await Geolocator.getCurrentPosition(
            desiredAccuracy: LocationAccuracy.low,
          ).timeout(const Duration(seconds: 3));
        } catch (_) {}
      }

      if (pos == null) return {'ok': false, 'reason': 'Location unavailable'};

      return {
        'ok': true,
        'lat': pos.latitude.toStringAsFixed(6),
        'lng': pos.longitude.toStringAsFixed(6),
      };
    } catch (e) {
      return {'ok': false, 'reason': e.toString()};
    }
  }

  static String buildMapsUrl(String lat, String lng) =>
      'https://maps.google.com/?q=$lat,$lng';
}

// ─── Recording Service ────────────────────────────────────────────────────────
class RecordingService {
  final AudioRecorder _recorder = AudioRecorder();
  String? _currentPath;
  DateTime? _startedAt;

  Future<bool> start() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .replaceAll('.', '-')
          .substring(0, 19);
      _currentPath = '${dir.path}/awaaz-sos-$stamp.m4a';
      _startedAt = DateTime.now();

      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 128000),
        path: _currentPath!,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Duration get elapsed =>
      _startedAt != null ? DateTime.now().difference(_startedAt!) : Duration.zero;

  Future<String?> stop() async {
    try {
      final path = await _recorder.stop();
      return path ?? _currentPath;
    } catch (_) {
      return _currentPath;
    }
  }

  Future<void> cancel() async {
    try {
      await _recorder.cancel();
    } catch (_) {}
  }
}

// ─── WhatsApp Service ─────────────────────────────────────────────────────────
class WhatsAppService {
  static String buildMessage(Map<String, dynamic> loc) {
    if (loc['ok'] == true) {
      final mapsUrl = LocationService.buildMapsUrl(loc['lat'], loc['lng']);
      return '🚨 EMERGENCY ALERT — AWAAZ SOS. Your contact needs help immediately. '
          'Location: $mapsUrl. Please call them or contact emergency services (112/181) now.';
    }
    return '🚨 EMERGENCY ALERT — AWAAZ SOS. Your contact needs help immediately. '
        'Location unavailable. Please call them or contact emergency services (112/181) now.';
  }

  static Future<bool> openWhatsApp(Contact contact, String message) async {
    final digits = contact.phone.replaceAll(RegExp(r'\D'), '');
    final uri = Uri.parse(
        'https://wa.me/$digits?text=${Uri.encodeComponent(message)}');
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  static Future<void> call(Contact contact) async {
    final uri = Uri.parse('tel:${contact.phone}');
    try {
      await launchUrl(uri);
    } catch (_) {}
  }
}

// ─── Home Screen ──────────────────────────────────────────────────────────────
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  // State
  List<Contact> _contacts = [];
  bool _voiceEnabled = true;
  bool _silentMode = false;
  bool _sirenEnabled = true;
  bool _shakeEnabled = true;

  bool _micOk = false;
  bool _gpsOk = false;
  String _transcript = 'Listening in Indian English (en-IN)…';
  bool _serviceRunning = false;

  final TtsService _tts = TtsService();
  SpeechToText _speech = SpeechToText();
  StreamSubscription<AccelerometerEvent>? _shakeSubscription;

  // Shake detection
  List<DateTime> _shakeTimestamps = [];
  double _lastMag = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  Future<void> _init() async {
    await _loadContacts();
    await _requestPermissions();
    await WakelockPlus.enable();
    _initForegroundService();
    if (_voiceEnabled) await _startVoiceGuard();
    if (_shakeEnabled) _startShakeListener();
  }

  Future<void> _loadContacts() async {
    final c = await StorageService.loadContacts();
    setState(() => _contacts = c);
  }

  Future<void> _requestPermissions() async {
    final statuses = await [
      Permission.microphone,
      Permission.location,
      Permission.locationWhenInUse,
      Permission.storage,
    ].request();

    setState(() {
      _micOk = statuses[Permission.microphone]?.isGranted ?? false;
      _gpsOk = (statuses[Permission.location]?.isGranted ?? false) ||
          (statuses[Permission.locationWhenInUse]?.isGranted ?? false);
    });
  }

  // ─── Foreground Service Setup ─────────────────────────────────────────────
  void _initForegroundService() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'awaaz_guard',
        channelName: 'AWAAZ SOS Guard',
        channelDescription: 'AWAAZ SOS is protecting you in the background.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(10000),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );

    // Listen for wake/safe commands from background service
    FlutterForegroundTask.addTaskDataCallback(_onBackgroundData);
  }

  void _onBackgroundData(dynamic data) {
    if (data is Map) {
      final cmd = data['command'];
      if (cmd == 'wake' && mounted) {
        _activateSOS(isDemo: false, source: 'Voice (Background)');
      } else if (cmd == 'safe' && mounted) {
        // Deactivate is handled in SOS screen
      }
    }
  }

  Future<void> _startBackgroundService() async {
    if (await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.startService(
      serviceId: 1001,
      notificationTitle: '🛡️ AWAAZ SOS Active',
      notificationText: 'Say "Help me now" at any time',
      callback: startCallback,
    );
    setState(() => _serviceRunning = true);
  }

  Future<void> _stopBackgroundService() async {
    await FlutterForegroundTask.stopService();
    setState(() => _serviceRunning = false);
  }

  // ─── Voice Guard (foreground) ─────────────────────────────────────────────
  Future<void> _startVoiceGuard() async {
    bool ready = await _speech.initialize(
      onStatus: (status) {
        if (status == 'done' || status == 'notListening') {
          Future.delayed(const Duration(milliseconds: 400), _listenLoop);
        }
      },
      onError: (error) {
        setState(() {
          _micOk = false;
          _transcript = 'Mic error: ${error.errorMsg}';
        });
      },
    );

    setState(() => _micOk = ready);
    if (ready) {
      _listenLoop();
      await _startBackgroundService();
    }
  }

  void _listenLoop() {
    if (!_voiceEnabled || !_speech.isAvailable) return;
    _speech.listen(
      onResult: (result) {
        final text = result.recognizedWords;
        if (text.isNotEmpty) {
          setState(() => _transcript = 'Heard: $text');
        }

        final norm = text.toLowerCase();
        final wakeR = RegExp(r'(?:^|\s)(a+w+a+[sz]|a+v+a+[sz]|आवाज़?)\s+help\s+me(?:\s|$)');
        final safeR = RegExp(r"(?:^|\s)(a+w+a+[sz]|a+v+a+[sz]|आवाज़?)\s+(i'?m|im|i\s+am)\s+safe(?:\s|$)");

        if (wakeR.hasMatch(norm)) {
          _activateSOS(isDemo: false, source: 'Voice (Foreground)');
        } else if (safeR.hasMatch(norm)) {
          // handled in SOS screen
        }
      },
      listenFor: const Duration(seconds: 60),
      pauseFor: const Duration(seconds: 2),
      localeId: 'en_IN',
      cancelOnError: false,
      partialResults: true,
    );
  }

  // ─── Shake to SOS ─────────────────────────────────────────────────────────
  void _startShakeListener() {
    _shakeSubscription = accelerometerEventStream().listen((event) {
      if (!_shakeEnabled) return;
      final mag = math.sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
      final delta = (mag - _lastMag).abs();
      _lastMag = mag;

      if (delta > 22) {
        final now = DateTime.now();
        _shakeTimestamps = _shakeTimestamps
            .where((t) => now.difference(t).inMilliseconds < 1500)
            .toList();
        _shakeTimestamps.add(now);

        if (_shakeTimestamps.length >= 3) {
          _shakeTimestamps.clear();
          _activateSOS(isDemo: false, source: 'Shake to SOS');
        }
      }
    });
  }

  // ─── SOS Activation ───────────────────────────────────────────────────────
  void _activateSOS({required bool isDemo, required String source, bool forceSilent = false}) {
    _tts.setSilent(forceSilent || _silentMode);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SosActiveScreen(
          contacts: _contacts,
          isDemo: isDemo,
          isSilent: forceSilent || _silentMode,
          sirenEnabled: _sirenEnabled && !(forceSilent || _silentMode),
          source: source,
          tts: _tts,
          onDeactivated: () {
            _tts.setSilent(false);
            if (_voiceEnabled) _listenLoop();
          },
        ),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_voiceEnabled) _listenLoop();
      WakelockPlus.enable();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _shakeSubscription?.cancel();
    FlutterForegroundTask.removeTaskDataCallback(_onBackgroundData);
    super.dispose();
  }

  // ─── Contact Management ───────────────────────────────────────────────────
  void _showAddContactSheet({Contact? editing, int? editIndex}) {
    final nameCtrl = TextEditingController(text: editing?.name ?? '');
    final phoneCtrl = TextEditingController(
        text: editing != null ? editing.phone.replaceAll('+91', '') : '');
    String? error;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _kCard,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => Padding(
          padding: EdgeInsets.only(
            left: 20, right: 20, top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(editing != null ? 'Edit Contact' : 'Add Trusted Contact',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _kText)),
              const SizedBox(height: 16),
              TextField(
                controller: nameCtrl,
                style: const TextStyle(color: _kText),
                decoration: _inputDeco('Name', 'e.g. Maa, Didi, Friend'),
                textCapitalization: TextCapitalization.words,
              ),
              const SizedBox(height: 10),
              TextField(
                controller: phoneCtrl,
                style: const TextStyle(color: _kText),
                keyboardType: TextInputType.phone,
                decoration: _inputDeco('+91 Mobile Number', '9876543210'),
              ),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(error!, style: const TextStyle(color: _kRed, fontSize: 13)),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    final phone = StorageService.validatePhone(phoneCtrl.text.trim());
                    final name = nameCtrl.text.trim();
                    if (name.isEmpty || phone == null) {
                      setModal(() => error = 'Enter a valid name and 10-digit +91 mobile number.');
                      return;
                    }
                    final updated = List<Contact>.from(_contacts);
                    if (editIndex != null) {
                      updated[editIndex] = Contact(name: name, phone: phone);
                    } else {
                      if (updated.length >= 3) {
                        setModal(() => error = 'Maximum 3 trusted contacts allowed.');
                        return;
                      }
                      updated.add(Contact(name: name, phone: phone));
                    }
                    StorageService.saveContacts(updated);
                    setState(() => _contacts = updated);
                    Navigator.pop(ctx);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _kGreen,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: Text(editing != null ? 'Update Contact' : 'Add Contact',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  InputDecoration _inputDeco(String label, String hint) => InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: const TextStyle(color: _kMuted),
        hintStyle: const TextStyle(color: _kMuted),
        filled: true,
        fillColor: _kBg,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: _kBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: _kBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: _kText),
        ),
      );

  // ─── Build ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return WithForegroundTask(
      child: Scaffold(
        backgroundColor: _kBg,
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ─ Tricolor strip
                _tricolorStrip(),
                const SizedBox(height: 10),
                // ─ Header
                _header(),
                const SizedBox(height: 10),
                // ─ No contacts banner
                if (_contacts.isEmpty) _noContactsBanner(),
                // ─ Big SOS Button
                _sosButton(),
                const SizedBox(height: 10),
                // ─ Live Transcript Box
                _transcriptBox(),
                const SizedBox(height: 10),
                // ─ Indian Emergency Helplines
                _helplines(),
                const SizedBox(height: 10),
                // ─ Test SOS + Fake Call row
                _utilityRow(),
                const SizedBox(height: 10),
                // ─ Toggles
                _togglesCard(),
                const SizedBox(height: 10),
                // ─ Trusted Contacts
                _contactsCard(),
                const SizedBox(height: 10),
                // ─ Footer
                const Center(
                  child: Text('Offline-ready • Local storage only • No tracking',
                      style: TextStyle(fontSize: 11, color: _kMuted)),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _tricolorStrip() => Row(children: [
        Expanded(child: Container(height: 3, color: const Color(0xFFFF9933))),
        Expanded(child: Container(height: 3, color: Colors.white)),
        Expanded(child: Container(height: 3, color: const Color(0xFF138808))),
      ]);

  Widget _header() => Row(
        children: [
          GestureDetector(
            onLongPress: () => _activateSOS(
                isDemo: false, source: 'Long-press logo', forceSilent: true),
            child: Row(children: [
              const Icon(Icons.shield, color: _kRed, size: 26),
              const SizedBox(width: 8),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('AWAAZ SOS',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900,
                        letterSpacing: 1.5, color: _kText)),
                const Text('Hold logo 3s: Silent SOS',
                    style: TextStyle(fontSize: 11, color: _kMuted)),
              ]),
            ]),
          ),
          const Spacer(),
          _statusPill(Icons.mic, 'Mic', _micOk),
          const SizedBox(width: 6),
          _statusPill(Icons.location_on, 'GPS', _gpsOk),
        ],
      );

  Widget _statusPill(IconData icon, String label, bool ok) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: _kCard,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: _kBorder),
        ),
        child: Row(children: [
          Container(width: 8, height: 8,
              decoration: BoxDecoration(
                  color: ok ? _kGreen : _kRed, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: _kText)),
        ]),
      );

  Widget _noContactsBanner() => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: _kCard,
          border: Border.all(color: _kRed),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            const Expanded(
              child: Text('No trusted contacts saved. Add up to 3 numbers below.',
                  style: TextStyle(fontSize: 13, color: _kText)),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => _showAddContactSheet(),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: _kRed,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text('Add', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white)),
              ),
            ),
          ],
        ),
      );

  Widget _sosButton() => Center(
        child: Column(children: [
          const SizedBox(height: 10),
          GestureDetector(
            onTap: () => _activateSOS(isDemo: false, source: 'SOS Tap Button'),
            child: Container(
              width: 160, height: 160,
              decoration: BoxDecoration(
                color: _kRed,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: _kRed.withOpacity(0.45), blurRadius: 32, spreadRadius: 4)],
                border: Border.all(color: Colors.white.withOpacity(0.18), width: 1.5),
              ),
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.mic, color: Colors.white, size: 52),
                  SizedBox(height: 4),
                  Text('SOS', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900,
                      letterSpacing: 3, color: Colors.white)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          RichText(
            text: const TextSpan(
              style: TextStyle(fontSize: 14, color: _kText),
              children: [
                TextSpan(text: 'Say '),
                TextSpan(text: '"Help me now"',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                TextSpan(text: ' or tap SOS'),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ]),
      );

  Widget _transcriptBox() => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: _kCard,
          border: Border.all(color: _kBorder),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(_transcript,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, color: _kMuted)),
      );

  Widget _helplines() => GridView.count(
        crossAxisCount: 4,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 0.9,
        children: [
          _helplineBtn('112', 'Emergency'),
          _helplineBtn('181', 'Women'),
          _helplineBtn('100', 'Police'),
          _helplineBtn('108', 'Ambulance'),
        ],
      );

  Widget _helplineBtn(String number, String label) => GestureDetector(
        onTap: () => launchUrl(Uri.parse('tel:$number')),
        child: Container(
          decoration: BoxDecoration(
            color: _kCard,
            border: Border.all(color: _kBorder),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(number, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: _kText)),
              const SizedBox(height: 2),
              Text(label, textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 11, color: _kMuted)),
            ],
          ),
        ),
      );

  Widget _utilityRow() => Row(children: [
        Expanded(
          child: OutlinedButton(
            onPressed: () => _activateSOS(isDemo: true, source: 'Test SOS'),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: _kRed),
              foregroundColor: _kText,
              padding: const EdgeInsets.symmetric(vertical: 11),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Test SOS (Demo)', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton(
            onPressed: _showFakeCallSheet,
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: _kBorder),
              foregroundColor: _kText,
              padding: const EdgeInsets.symmetric(vertical: 11),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Fake Call', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ),
      ]);

  Widget _togglesCard() => Container(
        decoration: BoxDecoration(
          color: _kCard,
          border: Border.all(color: _kBorder),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(children: [
          _toggleRow('Voice Wake Word Listener',
              '"Help me now" / "Bachao" (en-IN + Hinglish)', _voiceEnabled, (v) {
            setState(() => _voiceEnabled = v);
            if (v) { _startVoiceGuard(); } else { _speech.cancel(); _stopBackgroundService(); }
          }),
          const Divider(color: _kBorder, height: 1),
          _toggleRow('Silent SOS Mode',
              'Zero sound/siren. Trigger: hold logo 3s', _silentMode,
              (v) => setState(() => _silentMode = v)),
          const Divider(color: _kBorder, height: 1),
          _toggleRow('Loud SOS Siren',
              'Dual-tone alarm on SOS (unless silent)', _sirenEnabled,
              (v) => setState(() => _sirenEnabled = v)),
          const Divider(color: _kBorder, height: 1),
          _toggleRow('Shake to SOS',
              '3 strong shakes within 1.5s triggers SOS', _shakeEnabled, (v) {
            setState(() => _shakeEnabled = v);
            if (v) _startShakeListener(); else _shakeSubscription?.cancel();
          }),
        ]),
      );

  Widget _toggleRow(String title, String desc, bool value, ValueChanged<bool> onChanged) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: _kText)),
              const SizedBox(height: 2),
              Text(desc, style: const TextStyle(fontSize: 12, color: _kMuted)),
            ]),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: _kGreen,
            inactiveThumbColor: _kMuted,
            inactiveTrackColor: _kBg,
          ),
        ]),
      );

  Widget _contactsCard() => Container(
        decoration: BoxDecoration(
          color: _kCard,
          border: Border.all(color: _kBorder),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  const Text('Trusted Contacts',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: _kText)),
                  const Spacer(),
                  Text('${_contacts.length} / 3',
                      style: const TextStyle(fontSize: 12, color: _kMuted)),
                  if (_contacts.length < 3) ...[
                    const SizedBox(width: 10),
                    GestureDetector(
                      onTap: () => _showAddContactSheet(),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: _kGreen,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text('+ Add',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white)),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const Divider(color: _kBorder, height: 1),
            if (_contacts.isEmpty)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('No contacts saved yet.',
                    style: TextStyle(fontSize: 13, color: _kMuted)),
              ),
            ..._contacts.asMap().entries.map((e) => _contactItem(e.value, e.key)),
          ],
        ),
      );

  Widget _contactItem(Contact c, int idx) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          border: Border(bottom: idx < _contacts.length - 1
              ? const BorderSide(color: _kBorder)
              : BorderSide.none),
        ),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c.name, style: const TextStyle(fontWeight: FontWeight.bold, color: _kText)),
              Text(StorageService.formatPhone(c.phone),
                  style: const TextStyle(fontSize: 12, color: _kMuted, fontFamily: 'monospace')),
            ]),
          ),
          GestureDetector(
            onTap: () => _showAddContactSheet(editing: c, editIndex: idx),
            child: const Padding(padding: EdgeInsets.all(6), child: Text('Edit', style: TextStyle(fontSize: 12, color: _kMuted))),
          ),
          GestureDetector(
            onTap: () {
              final updated = List<Contact>.from(_contacts)..removeAt(idx);
              StorageService.saveContacts(updated);
              setState(() => _contacts = updated);
            },
            child: const Padding(padding: EdgeInsets.all(6),
                child: Text('Delete', style: TextStyle(fontSize: 12, color: _kRed))),
          ),
        ]),
      );

  void _showFakeCallSheet() {
    String caller = 'Maa';
    int delaySec = 0;
    final callerOptions = ['Maa', 'Dad', 'Didi', '112 Control Room'];

    showModalBottomSheet(
      context: context,
      backgroundColor: _kCard,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Fake Incoming Call',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _kText)),
              const SizedBox(height: 16),
              const Text('Caller', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: _kMuted)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8, runSpacing: 8,
                children: callerOptions.map((name) => GestureDetector(
                  onTap: () => setModal(() => caller = name),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                    decoration: BoxDecoration(
                      color: caller == name ? _kGreen : _kBg,
                      border: Border.all(color: caller == name ? _kGreen : _kBorder),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(name,
                        style: TextStyle(fontWeight: FontWeight.bold,
                            color: caller == name ? Colors.white : _kText)),
                  ),
                )).toList(),
              ),
              const SizedBox(height: 16),
              const Text('Delay', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: _kMuted)),
              const SizedBox(height: 8),
              Row(
                children: [0, 5, 15].map((d) => Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    onTap: () => setModal(() => delaySec = d),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
                      decoration: BoxDecoration(
                        color: delaySec == d ? _kGreen : _kBg,
                        border: Border.all(color: delaySec == d ? _kGreen : _kBorder),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text('${d}s',
                          style: TextStyle(fontWeight: FontWeight.bold,
                              color: delaySec == d ? Colors.white : _kText)),
                    ),
                  ),
                )).toList(),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    Future.delayed(Duration(seconds: delaySec), () {
                      if (mounted) {
                        Navigator.push(context,
                          MaterialPageRoute(
                            builder: (_) => FakeCallScreen(callerName: caller),
                            fullscreenDialog: true,
                          ),
                        );
                      }
                    });
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _kGreen,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('Trigger Fake Call',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── SOS Active Screen ────────────────────────────────────────────────────────
class SosActiveScreen extends StatefulWidget {
  final List<Contact> contacts;
  final bool isDemo;
  final bool isSilent;
  final bool sirenEnabled;
  final String source;
  final TtsService tts;
  final VoidCallback onDeactivated;

  const SosActiveScreen({
    super.key,
    required this.contacts,
    required this.isDemo,
    required this.isSilent,
    required this.sirenEnabled,
    required this.source,
    required this.tts,
    required this.onDeactivated,
  });

  @override
  State<SosActiveScreen> createState() => _SosActiveScreenState();
}

class _SosActiveScreenState extends State<SosActiveScreen> {
  int _countdown = 5;
  Timer? _countdownTimer;
  bool _dispatched = false;
  bool _cancelled = false;

  String _gpsStatus = 'Locating…';
  String _recStatus = 'Standby';
  String _alertStatus = 'Waiting…';

  Map<String, dynamic>? _loc;
  String? _mapsUrl;

  final RecordingService _recording = RecordingService();
  SpeechToText _speech = SpeechToText();
  Timer? _recTimer;
  Duration _recElapsed = Duration.zero;

  // Siren
  bool _sirenActive = false;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _startCountdown();
    _startVoiceDeactivationListener();
  }

  void _startCountdown() {
    widget.tts.speak(
      'AWAAZ SOS activated. Stay calm. Sending alert in 5 seconds.',
    );
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_cancelled) { t.cancel(); return; }
      setState(() => _countdown--);
      if (_countdown <= 0) {
        t.cancel();
        _dispatch();
      }
    });
  }

  Future<void> _dispatch() async {
    if (_cancelled || _dispatched) return;
    _dispatched = true;
    setState(() => _alertStatus = 'Dispatching…');

    // Speak
    widget.tts.speak('Alerting your contacts now. Stay calm.');

    // Start recording
    setState(() => _recStatus = 'Starting recording…');
    final recOk = await _recording.start();
    if (recOk) {
      setState(() => _recStatus = 'Recording 00:00');
      _recTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        setState(() {
          _recElapsed = _recording.elapsed;
          final mm = _recElapsed.inMinutes.toString().padLeft(2, '0');
          final ss = (_recElapsed.inSeconds % 60).toString().padLeft(2, '0');
          _recStatus = 'Recording $mm:$ss';
        });
      });
    } else {
      setState(() => _recStatus = 'Mic permission denied');
    }

    // GPS
    setState(() => _gpsStatus = 'Capturing (8s max)…');
    final loc = await LocationService.getLocation();
    if (mounted) {
      setState(() {
        _loc = loc;
        if (loc['ok'] == true) {
          _mapsUrl = LocationService.buildMapsUrl(loc['lat'], loc['lng']);
          _gpsStatus = '${loc['lat']}, ${loc['lng']}';
        } else {
          _gpsStatus = 'Unavailable: ${loc['reason']}';
        }
      });
    }

    // WhatsApp
    if (widget.isDemo) {
      setState(() => _alertStatus = 'DEMO — nothing sent');
    } else {
      final message = WhatsAppService.buildMessage(loc);
      int opened = 0;
      for (final c in widget.contacts) {
        final ok = await WhatsAppService.openWhatsApp(c, message);
        if (ok) opened++;
        await Future.delayed(const Duration(milliseconds: 500));
      }
      if (mounted) {
        setState(() => _alertStatus = widget.contacts.isEmpty
            ? 'No contacts — dial 112 or 181'
            : opened > 0
                ? 'WhatsApp opened ($opened/${widget.contacts.length})'
                : 'WhatsApp blocked — tap Call below');
      }
    }
  }

  void _startVoiceDeactivationListener() async {
    final rec = SpeechToText();
    await rec.initialize();
    _speech = rec;
    _listenForSafe();
  }

  void _listenForSafe() {
    if (_cancelled) return;
    _speech.listen(
      onResult: (result) {
        final norm = result.recognizedWords.toLowerCase();
        final safeR = RegExp(r"(?:^|\s)(a+w+a+[sz]|a+v+a+[sz]|आवाज़?)\s+(i'?m|im|i\s+am)\s+safe(?:\s|$)");
        if (safeR.hasMatch(norm)) {
          _deactivate('Voice ("I\'m safe")');
        }
      },
      listenFor: const Duration(seconds: 60),
      pauseFor: const Duration(seconds: 2),
      localeId: 'en_IN',
      cancelOnError: false,
      partialResults: true,
    );
    _speech.statusListener = (status) {
      if ((status == 'done' || status == 'notListening') && !_cancelled) {
        Future.delayed(const Duration(milliseconds: 400), _listenForSafe);
      }
    };
  }

  Future<void> _deactivate(String reason) async {
    if (_cancelled) return;
    _cancelled = true;
    _countdownTimer?.cancel();
    _recTimer?.cancel();
    await _speech.cancel();
    await widget.tts.stop();

    // Save recording
    if (_dispatched) {
      final savedPath = await _recording.stop();
      if (!widget.isSilent) {
        await widget.tts.speak('AWAAZ SOS deactivated. You are safe now.');
      }
      if (mounted && savedPath != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: _kCard,
            content: Text('Audio evidence saved to:\n$savedPath',
                style: const TextStyle(color: _kText, fontSize: 12)),
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } else {
      await _recording.cancel();
    }

    widget.onDeactivated();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _recTimer?.cancel();
    _speech.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kSosBg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Demo badge
              if (widget.isDemo)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(
                    color: _kRed,
                    borderRadius: BorderRadius.circular(99),
                    border: Border.all(color: Colors.white),
                  ),
                  child: const Text('DEMO MODE — NOTHING SENT',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900,
                          letterSpacing: 1, color: Colors.white)),
                ),
              if (widget.isSilent)
                Container(
                  margin: const EdgeInsets.only(top: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(
                    color: _kCard,
                    borderRadius: BorderRadius.circular(99),
                    border: Border.all(color: _kBorder),
                  ),
                  child: const Text('SILENT MODE',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900,
                          letterSpacing: 1, color: _kText)),
                ),
              const SizedBox(height: 18),

              // SOS ACTIVE title
              const Text('SOS ACTIVE',
                  style: TextStyle(fontSize: 42, fontWeight: FontWeight.w900,
                      letterSpacing: 4, color: Colors.white)),
              const SizedBox(height: 6),

              // Countdown
              if (!_dispatched)
                Column(children: [
                  Text('$_countdown',
                      style: const TextStyle(fontSize: 90, fontWeight: FontWeight.w900,
                          color: Colors.white, fontFamily: 'monospace')),
                  Text('Sending alert in $_countdown second${_countdown == 1 ? '' : 's'}…',
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold,
                          color: Colors.white70)),
                ])
              else
                Text(
                  widget.isDemo ? 'DEMO active — no real alerts sent' : 'Alerting your contacts. Stay calm.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white),
                ),

              const SizedBox(height: 20),

              // Telemetry Cards
              _sosCard('📍 GPS Location', _gpsStatus),
              const SizedBox(height: 8),
              _sosCard('🎙️ Audio Recording', _recStatus),
              const SizedBox(height: 8),
              _sosCard('💬 Contact Alerts', _alertStatus),

              // Maps link
              if (_mapsUrl != null) ...[
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: () => launchUrl(Uri.parse(_mapsUrl!),
                      mode: LaunchMode.externalApplication),
                  child: const Text('Open in Google Maps →',
                      style: TextStyle(color: Colors.white,
                          decoration: TextDecoration.underline)),
                ),
              ],

              // Contact fallback buttons
              if (_dispatched && widget.contacts.isNotEmpty) ...[
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: _kCard.withOpacity(0.7),
                    border: Border.all(color: _kBorder),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('DIRECT CALL / WHATSAPP',
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900,
                              letterSpacing: 1, color: _kMuted)),
                      const SizedBox(height: 8),
                      ...widget.contacts.map((c) => _contactActionRow(c)),
                      if (widget.isDemo) ...[
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: _kBg,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'Demo message preview:\n${WhatsAppService.buildMessage(_loc ?? {'ok': false})}',
                            style: const TextStyle(fontSize: 11, color: _kMuted),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 20),

              // Voice hint
              const Text('Say "I\'m safe" or tap below to stop',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold,
                      color: Colors.white70)),
              const SizedBox(height: 10),

              // CANCEL SOS button
              GestureDetector(
                onTap: () => _deactivate('Cancel Button'),
                child: Container(
                  width: double.infinity,
                  height: 64,
                  decoration: BoxDecoration(
                    color: _kRed,
                    border: Border.all(color: Colors.white, width: 2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Center(
                    child: Text('CANCEL SOS',
                        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900,
                            letterSpacing: 2, color: Colors.white)),
                  ),
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sosCard(String label, String value) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: _kCard.withOpacity(0.7),
          border: Border.all(color: _kBorder),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900,
              letterSpacing: 0.8, color: _kMuted)),
          const SizedBox(height: 3),
          Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: _kText)),
        ]),
      );

  Widget _contactActionRow(Contact c) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c.name, style: const TextStyle(fontWeight: FontWeight.bold, color: _kText, fontSize: 13)),
              Text(StorageService.formatPhone(c.phone),
                  style: const TextStyle(fontSize: 11, color: _kMuted, fontFamily: 'monospace')),
            ]),
          ),
          GestureDetector(
            onTap: () => WhatsAppService.call(c),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              margin: const EdgeInsets.only(left: 6),
              decoration: BoxDecoration(color: _kGreen, borderRadius: BorderRadius.circular(6)),
              child: const Text('Call', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white)),
            ),
          ),
          if (!widget.isDemo)
            GestureDetector(
              onTap: () => WhatsAppService.openWhatsApp(c, WhatsAppService.buildMessage(_loc ?? {'ok': false})),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                margin: const EdgeInsets.only(left: 6),
                decoration: BoxDecoration(
                  color: _kCard,
                  border: Border.all(color: _kBorder),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text('WhatsApp', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: _kText)),
              ),
            ),
        ]),
      );
}

// ─── Fake Call Screen ─────────────────────────────────────────────────────────
class FakeCallScreen extends StatefulWidget {
  final String callerName;
  const FakeCallScreen({super.key, required this.callerName});

  @override
  State<FakeCallScreen> createState() => _FakeCallScreenState();
}

class _FakeCallScreenState extends State<FakeCallScreen> {
  bool _accepted = false;
  Duration _callDuration = Duration.zero;
  Timer? _callTimer;
  final String _status = 'Ringing…';

  void _accept() {
    setState(() => _accepted = true);
    _callTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _callDuration += const Duration(seconds: 1));
    });
  }

  void _end() {
    _callTimer?.cancel();
    Navigator.of(context).pop();
  }

  String _formatDuration(Duration d) {
    final mm = d.inMinutes.toString().padLeft(2, '0');
    final ss = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  @override
  void dispose() {
    _callTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(children: [
              const SizedBox(height: 48),
              const Text('INCOMING VOICE CALL',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold,
                      letterSpacing: 2, color: _kMuted)),
              const SizedBox(height: 20),
              Text(widget.callerName,
                  style: const TextStyle(fontSize: 36, fontWeight: FontWeight.w800, color: _kText)),
              const SizedBox(height: 6),
              Text(
                widget.callerName == '112 Control Room'
                    ? 'Emergency Dispatch • India'
                    : 'Mobile • India',
                style: const TextStyle(fontSize: 15, color: _kMuted),
              ),
              const SizedBox(height: 10),
              Text(
                _accepted ? _formatDuration(_callDuration) : _status,
                style: const TextStyle(fontSize: 18, fontFamily: 'monospace', color: _kText),
              ),
            ]),
            Padding(
              padding: const EdgeInsets.only(bottom: 48),
              child: Row(
                mainAxisAlignment: _accepted ? MainAxisAlignment.center : MainAxisAlignment.spaceEvenly,
                children: [
                  if (!_accepted)
                    _callBtn(Icons.call_end, 'Decline', _kRed, _end),
                  _callBtn(
                    _accepted ? Icons.call_end : Icons.call,
                    _accepted ? 'End Call' : 'Accept',
                    _accepted ? _kRed : _kGreen,
                    _accepted ? _end : _accept,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _callBtn(IconData icon, String label, Color color, VoidCallback onTap) =>
      GestureDetector(
        onTap: onTap,
        child: Column(children: [
          Container(
            width: 72, height: 72,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: 32),
          ),
          const SizedBox(height: 8),
          Text(label, style: const TextStyle(fontSize: 13, color: _kText, fontWeight: FontWeight.bold)),
        ]),
      );
}
