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

// ═══════════════════════════════════════════════════════════════
//  BACKGROUND TASK  (top-level, required by flutter_foreground_task)
// ═══════════════════════════════════════════════════════════════
@pragma('vm:entry-point')
void startCallback() => FlutterForegroundTask.setTaskHandler(_BgHandler());

class _BgHandler extends TaskHandler {
  SpeechToText _st = SpeechToText();
  bool _ready = false;
  bool _destroyed = false;
  Timer? _restartTimer;
  String _wakeWord = 'help me now';
  String _locale = 'en_IN';

  @override
  Future<void> onStart(DateTime ts, TaskStarter s) async {
    _destroyed = false;
    final p = await SharedPreferences.getInstance();
    _wakeWord = (p.getString('wake_word') ?? 'help me now').toLowerCase();
    _locale = p.getString('locale_id') ?? 'en_IN';
    _ready = await _st.initialize(
      onStatus: (st) {
        if (st == 'done' || st == 'notListening') _restart();
      },
    );
    if (_ready) _listen();
  }

  void _listen() {
    if (!_ready) return;
    _st.listen(
      onResult: (r) {
        final t = r.recognizedWords.toLowerCase();
        if (_matchWake(t)) FlutterForegroundTask.sendDataToMain({'command': 'wake'});
        if (_matchSafe(t)) FlutterForegroundTask.sendDataToMain({'command': 'safe'});
      },
      listenFor: const Duration(minutes: 5),
      pauseFor: const Duration(minutes: 5),
      localeId: _locale,
      cancelOnError: false,
      partialResults: true,
    );
  }

  void _restart() {
    if (!_ready || _destroyed || _restartTimer?.isActive == true) return;
    _restartTimer = Timer(const Duration(milliseconds: 400), () {
      _restartTimer = null;
      if (!_destroyed) _listen();
    });
  }

  bool _matchWake(String t) {
    if (t.contains(_wakeWord)) return true;
    return RegExp(r'(help\s+me\s+now|bachao|बचाओ|madat\s+karo|help\s+me|emergency)').hasMatch(t);
  }

  bool _matchSafe(String t) =>
      RegExp(r"(i'?m\s+safe|i\s+am\s+safe|cancel\s+sos|safe\s+now|im\s+safe)").hasMatch(t);

  @override Future<void> onRepeatEvent(DateTime ts) async {}
  @override
  Future<void> onDestroy(DateTime ts) async {
    _destroyed = true;
    _ready = false;
    _restartTimer?.cancel();
    await _st.cancel();
  }
}

// ═══════════════════════════════════════════════════════════════
//  ENTRY POINT
// ═══════════════════════════════════════════════════════════════
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const AwaazSurakshaApp());
}

class AwaazSurakshaApp extends StatelessWidget {
  const AwaazSurakshaApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Awaaz Suraksha',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: const ColorScheme.dark(primary: Color(0xFFDA3633), surface: Color(0xFF161B22)),
      scaffoldBackgroundColor: const Color(0xFF0D1117),
      useMaterial3: true,
    ),
    home: const HomeScreen(),
  );
}

// ═══════════════════════════════════════════════════════════════
//  CONSTANTS
// ═══════════════════════════════════════════════════════════════
const _kRed    = Color(0xFFDA3633);
const _kGreen  = Color(0xFF238636);
const _kBg     = Color(0xFF0D1117);
const _kCard   = Color(0xFF161B22);
const _kBorder = Color(0xFF30363D);
const _kText   = Color(0xFFE6EDF3);
const _kMuted  = Color(0xFF8B949E);
const _kSosBg  = Color(0xFF1A0000);
const _kAmber  = Color(0xFFFF9933);

// ═══════════════════════════════════════════════════════════════
//  MODELS
// ═══════════════════════════════════════════════════════════════
class Contact {
  final String name;
  final String phone;
  Contact({required this.name, required this.phone});
  factory Contact.fromSerialized(String s) {
    final p = s.split('|||');
    return Contact(name: p[0], phone: p.length > 1 ? p[1] : '');
  }
  String serialize() => '$name|||$phone';
}

class AppSettings {
  String wakeWord;
  String localeId;
  String languageLabel;
  bool voiceEnabled;
  bool sirenEnabled;
  bool silentMode;
  bool shakeEnabled;
  bool demoMode;
  double shakeSensitivity;
  int checkinMinutes;

  AppSettings({
    this.wakeWord = 'help me now',
    this.localeId = 'en_IN',
    this.languageLabel = 'English (en-IN)',
    this.voiceEnabled = true,
    this.sirenEnabled = true,
    this.silentMode = false,
    this.shakeEnabled = true,
    this.demoMode = false,
    this.shakeSensitivity = 20.0,
    this.checkinMinutes = 30,
  });

  static Future<AppSettings> load() async {
    final p = await SharedPreferences.getInstance();
    return AppSettings(
      wakeWord: p.getString('wake_word') ?? 'help me now',
      localeId: p.getString('locale_id') ?? 'en_IN',
      languageLabel: p.getString('language_label') ?? 'English (en-IN)',
      voiceEnabled: p.getBool('voice_enabled') ?? true,
      sirenEnabled: p.getBool('siren_enabled') ?? true,
      silentMode: p.getBool('silent_mode') ?? false,
      shakeEnabled: p.getBool('shake_enabled') ?? true,
      demoMode: p.getBool('demo_mode') ?? false,
      shakeSensitivity: p.getDouble('shake_sensitivity') ?? 20.0,
      checkinMinutes: p.getInt('checkin_minutes') ?? 30,
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('wake_word', wakeWord);
    await p.setString('locale_id', localeId);
    await p.setString('language_label', languageLabel);
    await p.setBool('voice_enabled', voiceEnabled);
    await p.setBool('siren_enabled', sirenEnabled);
    await p.setBool('silent_mode', silentMode);
    await p.setBool('shake_enabled', shakeEnabled);
    await p.setBool('demo_mode', demoMode);
    await p.setDouble('shake_sensitivity', shakeSensitivity);
    await p.setInt('checkin_minutes', checkinMinutes);
  }

  AppSettings copy() => AppSettings(
    wakeWord: wakeWord, localeId: localeId, languageLabel: languageLabel,
    voiceEnabled: voiceEnabled, sirenEnabled: sirenEnabled, silentMode: silentMode,
    shakeEnabled: shakeEnabled, demoMode: demoMode, shakeSensitivity: shakeSensitivity,
    checkinMinutes: checkinMinutes,
  );
}

// ═══════════════════════════════════════════════════════════════
//  SIREN SERVICE  (bundled siren audio + haptic storm)
// ═══════════════════════════════════════════════════════════════
class SirenService {
  static const MethodChannel _channel = MethodChannel('com.awaaz.sos/siren');
  Timer? _hapticTimer;
  bool _active = false;

  Future<void> start() async {
    if (_active) return;
    _active = true;
    try {
      await _channel.invokeMethod('start');
    } catch (_) {
      _active = false;
      return;
    }

    // Haptic storm: heavy triple-pulse every 500ms
    _hapticTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!_active) return;
      HapticFeedback.heavyImpact();
      Future.delayed(const Duration(milliseconds: 150), () {
        if (_active) HapticFeedback.heavyImpact();
      });
      Future.delayed(const Duration(milliseconds: 300), () {
        if (_active) HapticFeedback.heavyImpact();
      });
    });

  }

  void stop() {
    if (!_active) return;
    _active = false;
    _hapticTimer?.cancel();
    _channel.invokeMethod('stop');
  }

  bool get isActive => _active;
}

// ═══════════════════════════════════════════════════════════════
//  SERVICES
// ═══════════════════════════════════════════════════════════════
class StorageService {
  static const _cKey = 'awaaz_contacts_v2';
  static const maxContacts = 5;

  static Future<List<Contact>> loadContacts() async {
    final p = await SharedPreferences.getInstance();
    return (p.getStringList(_cKey) ?? [])
        .map(Contact.fromSerialized)
        .where((c) => c.phone.isNotEmpty)
        .toList();
  }

  static Future<void> saveContacts(List<Contact> cs) async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_cKey, cs.map((c) => c.serialize()).toList());
  }

  static String? validatePhone(String input) {
    String d = input.replaceAll(RegExp(r'[^\d]'), '');
    if (d.startsWith('91') && d.length == 12) d = d.substring(2);
    if (d.startsWith('0') && d.length == 11) d = d.substring(1);
    if (!RegExp(r'^[6-9]\d{9}$').hasMatch(d)) return null;
    return '+91$d';
  }

  static String formatPhone(String e164) {
    final d = e164.replaceAll(RegExp(r'\D'), '');
    if (d.length == 12 && d.startsWith('91')) return '+91 ${d.substring(2, 7)} ${d.substring(7)}';
    return e164;
  }

  static Future<void> addLog(String entry) async {
    final p = await SharedPreferences.getInstance();
    final logs = p.getStringList('incident_log') ?? [];
    logs.insert(0, '${DateTime.now().toString().substring(0, 19)}|$entry');
    if (logs.length > 100) logs.removeLast();
    await p.setStringList('incident_log', logs);
  }

  static Future<List<String>> loadLog() async {
    final p = await SharedPreferences.getInstance();
    return p.getStringList('incident_log') ?? [];
  }

  static Future<void> wipeAll() async {
    final p = await SharedPreferences.getInstance();
    await p.clear();
    try {
      final dir = await getApplicationDocumentsDirectory();
      dir.listSync().whereType<File>().where((f) => f.path.endsWith('.m4a')).forEach((f) {
        try { f.deleteSync(); } catch (_) {}
      });
    } catch (_) {}
  }
}

class TtsService {
  final FlutterTts _t = FlutterTts();
  bool _muted = false;
  TtsService() {
    _t.setLanguage('en-IN');
    _t.setSpeechRate(0.52);
    _t.setPitch(1.0);
    _t.setVolume(1.0);
  }
  void setMuted(bool v) => _muted = v;
  Future<void> speak(String s, {VoidCallback? onDone}) async {
    if (_muted) { onDone?.call(); return; }
    await _t.stop();
    _t.setCompletionHandler(() => onDone?.call());
    await _t.speak(s);
  }
  Future<void> stop() => _t.stop();
}

class LocationService {
  static Future<Map<String, dynamic>> get() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return {'ok': false, 'reason': 'GPS off'};
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.deniedForever || perm == LocationPermission.denied) {
        return {'ok': false, 'reason': 'Permission denied'};
      }
      Position? pos;
      try { pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high).timeout(const Duration(seconds: 5)); } catch (_) {}
      if (pos == null) {
        try { pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.low).timeout(const Duration(seconds: 3)); } catch (_) {}
      }
      if (pos == null) return {'ok': false, 'reason': 'GPS unavailable'};
      return {'ok': true, 'lat': pos.latitude.toStringAsFixed(6), 'lng': pos.longitude.toStringAsFixed(6), 'acc': pos.accuracy.toStringAsFixed(0)};
    } catch (_) {
      return {'ok': false, 'reason': 'Error'};
    }
  }
  static String mapsUrl(String lat, String lng) => 'https://maps.google.com/?q=$lat,$lng';
}

class RecordingService {
  final AudioRecorder _r = AudioRecorder();
  String? _path;
  DateTime? _start;

  Future<bool> start() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final stamp = DateTime.now().toIso8601String().replaceAll(':', '-').replaceAll('.', '-').substring(0, 19);
      _path = '${dir.path}/awaaz-evidence-$stamp.m4a';
      _start = DateTime.now();
      await _r.start(const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 128000), path: _path!);
      return true;
    } catch (_) { return false; }
  }

  Duration get elapsed => _start != null ? DateTime.now().difference(_start!) : Duration.zero;
  Future<String?> stop() async { try { return await _r.stop() ?? _path; } catch (_) { return _path; } }
  Future<void> cancel() async { try { await _r.cancel(); } catch (_) {} }
}

class AlertService {
  static String buildMsg(Map<String, dynamic> loc) {
    final ts = DateTime.now().toString().substring(0, 19);
    if (loc['ok'] == true) {
      final url = LocationService.mapsUrl(loc['lat'], loc['lng']);
      final acc = loc['acc'] != null ? ' (±${loc['acc']}m)' : '';
      return '🚨 EMERGENCY — Awaaz Suraksha SOS\n\nYour contact needs help RIGHT NOW!\n\n📍 Location$acc:\n$url\n\n⏰ $ts\n\n📞 Emergency: 112 | Women: 181 | Police: 100';
    }
    return '🚨 EMERGENCY — Awaaz Suraksha SOS\n\nYour contact needs help RIGHT NOW!\n📍 Location unavailable — call them NOW!\n\n⏰ $ts\n\n📞 Emergency: 112 | Women: 181 | Police: 100';
  }

  static Future<bool> whatsapp(Contact c, String msg) async {
    final d = c.phone.replaceAll(RegExp(r'\D'), '');
    final text = Uri.encodeComponent(msg);
    final direct = Uri.parse('whatsapp://send?phone=$d&text=$text');
    final web = Uri.parse('https://wa.me/$d?text=$text');
    try {
      if (await canLaunchUrl(direct)) {
        return await launchUrl(direct, mode: LaunchMode.externalApplication);
      }
      return await launchUrl(web, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  static Future<void> call(Contact c) async {
    try { await launchUrl(Uri.parse('tel:${c.phone}')); } catch (_) {}
  }
}

// ═══════════════════════════════════════════════════════════════
//  HOME SCREEN  (4-tab shell)
// ═══════════════════════════════════════════════════════════════
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int _tab = 0;
  List<Contact> _contacts = [];
  AppSettings _settings = AppSettings();
  bool _micOk = false;
  bool _gpsOk = false;
  String _transcript = 'Initialising…';
  bool _serviceRunning = false;
  bool _loading = true;

  final TtsService _tts = TtsService();
  SpeechToText _speech = SpeechToText();
  StreamSubscription<AccelerometerEvent>? _shakeSub;
  List<DateTime> _shakeTimes = [];
  double _lastMag = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  Future<void> _init() async {
    _settings = await AppSettings.load();
    _contacts = await StorageService.loadContacts();
    await WakelockPlus.enable();
    _initFg();
    await _requestPerms();
    if (_settings.voiceEnabled) await _startVoice();
    else await _stopBgService();
    if (_settings.shakeEnabled) _startShake();
    if (mounted) setState(() { _loading = false; });
  }

  Future<void> _requestPerms() async {
    final s = await [
      Permission.microphone,
      Permission.location,
      Permission.locationWhenInUse,
      Permission.notification,
    ].request();
    if (mounted) setState(() {
      _micOk = s[Permission.microphone]?.isGranted ?? false;
      _gpsOk = (s[Permission.location]?.isGranted ?? false) || (s[Permission.locationWhenInUse]?.isGranted ?? false);
    });
  }

  void _initFg() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'awaaz_guard_v2',
        channelName: 'Awaaz Suraksha Guard',
        channelDescription: 'Background voice listener — say "${_settings.wakeWord}" anytime.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: true, playSound: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(10000),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    FlutterForegroundTask.addTaskDataCallback(_onBgData);
  }

  void _onBgData(dynamic data) {
    if (data is Map && data['command'] == 'wake' && mounted) {
      _triggerSOS(source: 'Voice (Background)');
    } else if (data is Map && data['command'] == 'safe') {
      // The active SOS screen has its own recognizer and handles cancellation.
    }
  }

  Future<void> _startBgService() async {
    if (await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.startService(
      serviceId: 1001,
      notificationTitle: '🛡️ Awaaz Suraksha Active',
      notificationText: 'Say "${_settings.wakeWord}" anytime • Shake 3× for SOS',
      callback: startCallback,
    );
    if (mounted) setState(() => _serviceRunning = true);
  }

  Future<void> _stopBgService() async {
    await FlutterForegroundTask.stopService();
    if (mounted) setState(() => _serviceRunning = false);
  }

  Future<void> _startVoice() async {
    final ready = await _speech.initialize(
      onError: (e) {
        if (mounted) setState(() {
          _micOk = false;
          _transcript = 'Mic error — tap "Grant Mic" to fix';
        });
      },
    );
    if (mounted) setState(() => _micOk = ready);
    if (ready) {
      await _startBgService();
      if (mounted) setState(() => _transcript = '🎙 Listening for "${_settings.wakeWord}"…');
    } else {
      if (mounted) setState(() => _transcript = '⚠ Mic unavailable — tap "Grant Mic" button');
    }
  }

  void _startShake() {
    _shakeSub?.cancel();
    _shakeSub = accelerometerEventStream().listen((e) {
      if (!_settings.shakeEnabled || !mounted) return;
      final mag = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
      final delta = (mag - _lastMag).abs();
      _lastMag = mag;
      if (delta > _settings.shakeSensitivity) {
        final now = DateTime.now();
        _shakeTimes = _shakeTimes.where((t) => now.difference(t).inMilliseconds < 1500).toList();
        _shakeTimes.add(now);
        if (_shakeTimes.length >= 3) {
          _shakeTimes.clear();
          _triggerSOS(source: 'Shake to SOS');
        }
      }
    });
  }

  void _triggerSOS({required String source, bool forceSilent = false}) {
    if (!mounted) return;
    HapticFeedback.heavyImpact();
    _tts.setMuted(forceSilent || _settings.silentMode);
    StorageService.addLog('SOS triggered: $source');
    _speech.cancel();
    _stopBgService();
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SosActiveScreen(
        contacts: List.from(_contacts),
        isDemo: _settings.demoMode,
        isSilent: forceSilent || _settings.silentMode,
        sirenEnabled: _settings.sirenEnabled && !(forceSilent || _settings.silentMode),
        source: source,
        tts: _tts,
        onDeactivated: () {
          _tts.setMuted(false);
          if (_settings.voiceEnabled && mounted) _startVoice();
        },
      ),
      fullscreenDialog: true,
    ));
  }

  Future<void> _grantMic() async {
    final status = await Permission.microphone.request();
    if (status.isPermanentlyDenied) {
      openAppSettings();
    } else if (status.isGranted) {
      if (mounted) setState(() => _micOk = true);
      await _startVoice();
    }
  }

  Future<void> _grantGps() async {
    final status = await Permission.location.request();
    if (status.isPermanentlyDenied) {
      openAppSettings();
    } else if (status.isGranted) {
      if (mounted) setState(() => _gpsOk = true);
    }
  }

  Future<void> _openSettings() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsScreen(settings: _settings)));
    final s = await AppSettings.load();
    final c = await StorageService.loadContacts();
    if (!mounted) return;
    setState(() { _settings = s; _contacts = c; });
    await _speech.cancel();
    if (_settings.voiceEnabled) await _startVoice();
    if (_settings.shakeEnabled) _startShake(); else _shakeSub?.cancel();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      if (_settings.voiceEnabled) _startVoice();
      WakelockPlus.enable();
      AppSettings.load().then((s) { if (mounted) setState(() => _settings = s); });
      StorageService.loadContacts().then((c) { if (mounted) setState(() => _contacts = c); });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _shakeSub?.cancel();
    FlutterForegroundTask.removeTaskDataCallback(_onBgData);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        backgroundColor: _kBg,
        body: Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(width: 80, height: 80, decoration: BoxDecoration(color: _kRed.withOpacity(0.1), borderRadius: BorderRadius.circular(40),
              border: Border.all(color: _kRed, width: 2)),
              child: const Icon(Icons.shield, color: _kRed, size: 48)),
          const SizedBox(height: 20),
          const Text('Awaaz Suraksha', style: TextStyle(color: _kText, fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          const Text('Loading…', style: TextStyle(color: _kMuted, fontSize: 14)),
          const SizedBox(height: 20),
          const CircularProgressIndicator(color: _kRed, strokeWidth: 2),
        ])),
      );
    }

    final tabs = <Widget>[
      _SosTab(
        micOk: _micOk, gpsOk: _gpsOk, transcript: _transcript,
        settings: _settings, contacts: _contacts, serviceRunning: _serviceRunning,
        onSOS: () => _triggerSOS(source: 'SOS Button'),
        onDemoSOS: () => _triggerSOS(source: 'Test SOS (Demo)'),
        onGrantMic: _grantMic, onGrantGps: _grantGps,
        onToggleVoice: (v) async {
          _settings.voiceEnabled = v; await _settings.save(); setState(() {});
          if (v) { await _startVoice(); } else { await _speech.cancel(); await _stopBgService(); }
        },
        onToggleSilent: (v) async { _settings.silentMode = v; await _settings.save(); setState(() {}); },
        onToggleSiren: (v) async { _settings.sirenEnabled = v; await _settings.save(); setState(() {}); },
        onToggleShake: (v) async {
          _settings.shakeEnabled = v; await _settings.save(); setState(() {});
          if (v) _startShake(); else _shakeSub?.cancel();
        },
        onShowFakeCall: (name) => Navigator.push(context, MaterialPageRoute(
            builder: (_) => FakeCallScreen(callerName: name), fullscreenDialog: true)),
      ),
      const _VaultTab(),
      _ToolsTab(
        settings: _settings,
        onFakeCall: (name) => Navigator.push(context, MaterialPageRoute(
            builder: (_) => FakeCallScreen(callerName: name), fullscreenDialog: true)),
        onCheckinExpired: () => _triggerSOS(source: 'Check-in Timer Expired'),
      ),
      _ContactsTab(
        contacts: _contacts,
        onChanged: (updated) async {
          await StorageService.saveContacts(updated);
          setState(() => _contacts = updated);
        },
      ),
    ];

    return WithForegroundTask(
      child: Scaffold(
        backgroundColor: _kBg,
        appBar: AppBar(
          backgroundColor: _kBg,
          elevation: 0,
          titleSpacing: 14,
          title: GestureDetector(
            onLongPress: () => _triggerSOS(source: 'Long-press logo', forceSilent: true),
            child: Row(children: [
              const Icon(Icons.shield, color: _kRed, size: 24),
              const SizedBox(width: 8),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Awaaz Suraksha', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900, letterSpacing: 1, color: _kText)),
                Text('Hold logo → Silent SOS${_settings.demoMode ? " • DEMO MODE" : ""}',
                    style: const TextStyle(fontSize: 10, color: _kMuted)),
              ]),
            ]),
          ),
          actions: [
            if (_serviceRunning) const Icon(Icons.wifi_tethering, color: _kGreen, size: 18),
            const SizedBox(width: 4),
            IconButton(icon: const Icon(Icons.settings, color: _kMuted), onPressed: _openSettings, tooltip: 'Settings'),
          ],
        ),
        body: IndexedStack(index: _tab, children: tabs),
        bottomNavigationBar: NavigationBar(
          backgroundColor: _kCard,
          indicatorColor: _kRed.withOpacity(0.18),
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          destinations: const [
            NavigationDestination(icon: Icon(Icons.emergency_outlined), selectedIcon: Icon(Icons.emergency, color: _kRed), label: 'SOS'),
            NavigationDestination(icon: Icon(Icons.lock_outline), selectedIcon: Icon(Icons.lock, color: _kRed), label: 'Vault'),
            NavigationDestination(icon: Icon(Icons.build_outlined), selectedIcon: Icon(Icons.build, color: _kRed), label: 'Tools'),
            NavigationDestination(icon: Icon(Icons.people_outline), selectedIcon: Icon(Icons.people, color: _kRed), label: 'Contacts'),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  TAB 0 — SOS
// ═══════════════════════════════════════════════════════════════
class _SosTab extends StatelessWidget {
  final bool micOk, gpsOk, serviceRunning;
  final String transcript;
  final AppSettings settings;
  final List<Contact> contacts;
  final VoidCallback onSOS, onDemoSOS, onGrantMic, onGrantGps;
  final Function(String) onShowFakeCall;
  final ValueChanged<bool> onToggleVoice, onToggleSilent, onToggleSiren, onToggleShake;

  const _SosTab({
    required this.micOk, required this.gpsOk, required this.serviceRunning,
    required this.transcript, required this.settings, required this.contacts,
    required this.onSOS, required this.onDemoSOS, required this.onGrantMic, required this.onGrantGps,
    required this.onShowFakeCall, required this.onToggleVoice, required this.onToggleSilent,
    required this.onToggleSiren, required this.onToggleShake,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Tricolor strip
        Row(children: [
          Expanded(child: Container(height: 3, color: _kAmber)),
          Expanded(child: Container(height: 3, color: Colors.white)),
          Expanded(child: Container(height: 3, color: const Color(0xFF138808))),
        ]),
        const SizedBox(height: 10),

        // Mic permission banner
        if (!micOk) _permBanner(
          icon: Icons.mic_off, color: _kRed,
          text: 'Microphone access denied — Voice SOS disabled',
          btnText: 'Grant Mic',
          onTap: onGrantMic,
        ),
        if (!gpsOk) _permBanner(
          icon: Icons.location_off, color: _kAmber,
          text: 'Location denied — GPS won\'t work on SOS',
          btnText: 'Grant GPS',
          onTap: onGrantGps,
        ),
        if (contacts.isEmpty) Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(color: _kCard, border: Border.all(color: _kRed), borderRadius: BorderRadius.circular(8)),
          child: Row(children: [
            const Icon(Icons.warning_amber, color: _kRed, size: 18),
            const SizedBox(width: 8),
            const Expanded(child: Text('No trusted contacts! Open "Contacts" tab below to add.',
                style: TextStyle(fontSize: 13, color: _kText))),
          ]),
        ),

        // Big SOS button
        Center(child: Column(children: [
          const SizedBox(height: 10),
          GestureDetector(
            onTap: onSOS,
            child: Container(
              width: 175, height: 175,
              decoration: BoxDecoration(
                color: _kRed, shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: _kRed.withOpacity(0.55), blurRadius: 44, spreadRadius: 8)],
                border: Border.all(color: Colors.white.withOpacity(0.22), width: 2),
              ),
              child: const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.mic, color: Colors.white, size: 60),
                SizedBox(height: 4),
                Text('SOS', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 3, color: Colors.white)),
                Text('TAP TO ALERT', style: TextStyle(fontSize: 10, letterSpacing: 1.5, color: Colors.white70, fontWeight: FontWeight.bold)),
              ]),
            ),
          ),
          const SizedBox(height: 10),
          RichText(text: TextSpan(
            style: const TextStyle(fontSize: 13, color: _kText),
            children: [
              const TextSpan(text: 'Say '),
              TextSpan(text: '"${settings.wakeWord}"',
                  style: const TextStyle(fontWeight: FontWeight.bold, color: _kRed)),
              const TextSpan(text: ' • Tap • Shake 3×'),
            ],
          )),
          const SizedBox(height: 10),
        ])),

        // Status chips (mic + gps + bg service)
        Row(children: [
          _statusChip(Icons.mic, 'Mic', micOk),
          const SizedBox(width: 6),
          _statusChip(Icons.location_on, 'GPS', gpsOk),
          const SizedBox(width: 6),
          _statusChip(Icons.wifi_tethering, 'BG Service', serviceRunning),
        ]),
        const SizedBox(height: 10),

        // Transcript box
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(color: _kCard, border: Border.all(color: _kBorder), borderRadius: BorderRadius.circular(8)),
          child: Row(children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(
                color: micOk ? _kGreen : _kMuted, shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Expanded(child: Text(transcript, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, color: _kMuted))),
          ]),
        ),
        const SizedBox(height: 10),

        // Helplines grid
        GridView.count(
          crossAxisCount: 4, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 8, crossAxisSpacing: 8, childAspectRatio: 0.9,
          children: [
            _hlBtn('112', 'Emergency'), _hlBtn('181', 'Women'),
            _hlBtn('100', 'Police'), _hlBtn('108', 'Ambulance'),
          ],
        ),
        const SizedBox(height: 10),

        // Quick actions row
        Row(children: [
          Expanded(child: OutlinedButton.icon(
            onPressed: onDemoSOS,
            icon: const Icon(Icons.play_arrow, size: 18),
            label: const Text('Test SOS'),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: _kRed), foregroundColor: _kRed,
              padding: const EdgeInsets.symmetric(vertical: 11),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          )),
          const SizedBox(width: 8),
          Expanded(child: OutlinedButton.icon(
            onPressed: () => _fakeCallSheet(context),
            icon: const Icon(Icons.call, size: 18),
            label: const Text('Fake Call'),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: _kBorder), foregroundColor: _kText,
              padding: const EdgeInsets.symmetric(vertical: 11),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          )),
        ]),
        const SizedBox(height: 10),

        // Toggles card
        Container(
          decoration: BoxDecoration(color: _kCard, border: Border.all(color: _kBorder), borderRadius: BorderRadius.circular(8)),
          child: Column(children: [
            _tRow(Icons.record_voice_over, 'Voice Wake Word', '"${settings.wakeWord}" always listening', settings.voiceEnabled, onToggleVoice),
            const Divider(color: _kBorder, height: 1),
            _tRow(Icons.visibility_off, 'Silent SOS Mode', 'No sound — stealth alert only', settings.silentMode, onToggleSilent),
            const Divider(color: _kBorder, height: 1),
            _tRow(Icons.volume_up, 'SOS Siren (Audio + Haptic)', 'Loud "ALERT!" alarm + triple haptic pulses', settings.sirenEnabled, onToggleSiren),
            const Divider(color: _kBorder, height: 1),
            _tRow(Icons.screen_rotation, 'Shake to SOS', '3 strong shakes within 1.5s', settings.shakeEnabled, onToggleShake),
          ]),
        ),
        const SizedBox(height: 10),

        // Info card
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: _kCard, border: Border.all(color: _kBorder), borderRadius: BorderRadius.circular(8)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('HOW IT WORKS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 1, color: _kMuted)),
            const SizedBox(height: 8),
            _iRow('🗣️', 'Say wake word (or "Bachao") — works with phone in pocket'),
            _iRow('📳', 'Shake phone 3× quickly within 1.5 seconds'),
            _iRow('👆', 'Tap the big red SOS button'),
            _iRow('🤫', 'Hold shield logo (top-left) 3s → Silent SOS, no sound'),
            _iRow('🔊', 'Siren = loud "ALERT!" voice + triple vibration pulses'),
            _iRow('⚙️', 'Tap ⚙ (top-right) to change wake word, language & more'),
          ]),
        ),
        const SizedBox(height: 20),
        const Center(child: Text('Made with ❤️ in India | Team CTRL ALT ELITE',
            style: TextStyle(fontSize: 11, color: _kMuted), textAlign: TextAlign.center)),
        const SizedBox(height: 4),
        const Center(child: Text('Offline-ready • No tracking • Local storage only',
            style: TextStyle(fontSize: 11, color: _kMuted))),
        const SizedBox(height: 20),
      ]),
    );
  }

  void _fakeCallSheet(BuildContext ctx) {
    String caller = 'Maa';
    final opts = ['Maa', 'Dad', 'Didi', 'Bhai', 'Friend', '112 Control Room'];
    showModalBottomSheet(
      context: ctx, backgroundColor: _kCard,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (c) => StatefulBuilder(builder: (c, sm) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Fake Incoming Call', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _kText)),
          const SizedBox(height: 14),
          Wrap(spacing: 8, runSpacing: 8, children: opts.map((n) => GestureDetector(
            onTap: () => sm(() => caller = n),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: BoxDecoration(
                color: caller == n ? _kGreen : _kBg,
                border: Border.all(color: caller == n ? _kGreen : _kBorder),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(n, style: TextStyle(fontWeight: FontWeight.bold, color: caller == n ? Colors.white : _kText)),
            ),
          )).toList()),
          const SizedBox(height: 20),
          SizedBox(width: double.infinity, child: ElevatedButton.icon(
            onPressed: () { Navigator.pop(c); onShowFakeCall(caller); },
            icon: const Icon(Icons.call),
            label: const Text('Trigger Now', style: TextStyle(fontWeight: FontWeight.bold)),
            style: ElevatedButton.styleFrom(
              backgroundColor: _kGreen, foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          )),
        ]),
      )),
    );
  }

  Widget _permBanner({required IconData icon, required Color color, required String text, required String btnText, required VoidCallback onTap}) =>
      Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(color: color.withOpacity(0.1), border: Border.all(color: color), borderRadius: BorderRadius.circular(8)),
        child: Row(children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(fontSize: 12, color: color))),
          const SizedBox(width: 8),
          GestureDetector(onTap: onTap, child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(6)),
            child: Text(btnText, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white)),
          )),
        ]),
      );

  Widget _statusChip(IconData icon, String label, bool ok) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(color: _kCard, borderRadius: BorderRadius.circular(99), border: Border.all(color: _kBorder)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 7, height: 7, decoration: BoxDecoration(color: ok ? _kGreen : _kRed, shape: BoxShape.circle)),
      const SizedBox(width: 5),
      Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: _kText)),
    ]),
  );

  Widget _hlBtn(String num, String label) => GestureDetector(
    onTap: () => launchUrl(Uri.parse('tel:$num')),
    child: Container(
      decoration: BoxDecoration(color: _kCard, border: Border.all(color: _kBorder), borderRadius: BorderRadius.circular(8)),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Icon(Icons.phone, color: _kGreen, size: 16),
        const SizedBox(height: 2),
        Text(num, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: _kText)),
        Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 11, color: _kMuted)),
      ]),
    ),
  );

  Widget _tRow(IconData icon, String title, String desc, bool val, ValueChanged<bool> onChange) =>
      Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10), child: Row(children: [
        Icon(icon, color: _kMuted, size: 20),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: _kText)),
          const SizedBox(height: 2),
          Text(desc, style: const TextStyle(fontSize: 12, color: _kMuted)),
        ])),
        Switch(value: val, onChanged: onChange, activeColor: _kGreen, inactiveThumbColor: _kMuted, inactiveTrackColor: _kBg),
      ]));

  Widget _iRow(String emoji, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 5),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(emoji, style: const TextStyle(fontSize: 14)),
      const SizedBox(width: 8),
      Expanded(child: Text(text, style: const TextStyle(fontSize: 12, color: _kMuted))),
    ]),
  );
}

// ═══════════════════════════════════════════════════════════════
//  TAB 1 — VAULT
// ═══════════════════════════════════════════════════════════════
class _VaultTab extends StatefulWidget {
  const _VaultTab();
  @override State<_VaultTab> createState() => _VaultTabState();
}

class _VaultTabState extends State<_VaultTab> {
  List<String> _log = [];
  List<File> _recs = [];
  bool _loading = true;

  @override void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    final log = await StorageService.loadLog();
    final dir = await getApplicationDocumentsDirectory();
    final recs = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.m4a')).toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    if (mounted) setState(() { _log = log; _recs = recs; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator(color: _kRed));
    return RefreshIndicator(
      onRefresh: _load, color: _kRed, backgroundColor: _kCard,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _sectionHdr('🎙️ Audio Evidence Vault', '${_recs.length} file${_recs.length != 1 ? "s" : ""}', Icons.refresh, _load),
          if (_recs.isEmpty) _empty('No recordings yet.\nAudio is auto-saved when SOS dispatches.'),
          ..._recs.map((f) => _recItem(f)),
          const SizedBox(height: 20),
          _sectionHdr('📋 Incident Log', '${_log.length} event${_log.length != 1 ? "s" : ""}', Icons.delete_sweep, () async {
            final p = await SharedPreferences.getInstance();
            await p.remove('incident_log');
            _load();
          }),
          if (_log.isEmpty) _empty('No incidents logged.\nSOS events appear here automatically.'),
          ..._log.map((e) => _logItem(e)),
          const SizedBox(height: 20),
        ]),
      ),
    );
  }

  Widget _sectionHdr(String title, String sub, IconData actionIcon, VoidCallback action) =>
      Padding(padding: const EdgeInsets.only(bottom: 10), child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: _kText)),
          Text(sub, style: const TextStyle(fontSize: 12, color: _kMuted)),
        ])),
        IconButton(icon: Icon(actionIcon, color: _kMuted, size: 20), onPressed: action, tooltip: 'Action'),
      ]));

  Widget _empty(String msg) => Container(
    width: double.infinity, margin: const EdgeInsets.only(bottom: 16),
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(color: _kCard, border: Border.all(color: _kBorder), borderRadius: BorderRadius.circular(8)),
    child: Text(msg, textAlign: TextAlign.center, style: const TextStyle(color: _kMuted, fontSize: 13)),
  );

  Widget _recItem(File f) {
    final name = f.path.split('/').last;
    final sizeKb = (f.statSync().size / 1024).toStringAsFixed(1);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: _kCard, border: Border.all(color: _kBorder), borderRadius: BorderRadius.circular(8)),
      child: Row(children: [
        const Icon(Icons.audio_file, color: _kRed, size: 24),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name, style: const TextStyle(fontSize: 12, color: _kText, fontFamily: 'monospace'),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          Text('$sizeKb KB', style: const TextStyle(fontSize: 11, color: _kMuted)),
        ])),
        IconButton(icon: const Icon(Icons.delete_outline, color: _kRed, size: 20), onPressed: () async {
          try { await f.delete(); } catch (_) {}
          _load();
        }),
      ]),
    );
  }

  Widget _logItem(String entry) {
    final parts = entry.split('|');
    final ts = parts.isNotEmpty ? parts[0] : '';
    final msg = parts.length > 1 ? parts.sublist(1).join('|') : entry;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: _kCard, border: Border.all(color: _kBorder), borderRadius: BorderRadius.circular(8)),
      child: Row(children: [
        const Icon(Icons.event_note, color: _kMuted, size: 18),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(msg, style: const TextStyle(fontSize: 13, color: _kText)),
          Text(ts, style: const TextStyle(fontSize: 11, color: _kMuted, fontFamily: 'monospace')),
        ])),
      ]),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  TAB 2 — TOOLS
// ═══════════════════════════════════════════════════════════════
class _ToolsTab extends StatefulWidget {
  final AppSettings settings;
  final Function(String) onFakeCall;
  final VoidCallback onCheckinExpired;
  const _ToolsTab({required this.settings, required this.onFakeCall, required this.onCheckinExpired});
  @override State<_ToolsTab> createState() => _ToolsTabState();
}

class _ToolsTabState extends State<_ToolsTab> {
  bool _armed = false;
  Timer? _timer;
  Duration _remaining = Duration.zero;
  String _caller = 'Maa';
  int _delay = 0;
  final _callerOpts = ['Maa', 'Dad', 'Didi', 'Bhai', 'Friend', '112 Control Room'];

  @override void dispose() { _timer?.cancel(); super.dispose(); }

  void _arm() {
    setState(() { _armed = true; _remaining = Duration(minutes: widget.settings.checkinMinutes); });
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() { _remaining -= const Duration(seconds: 1); });
      if (_remaining.inSeconds <= 0) {
        t.cancel();
        setState(() => _armed = false);
        widget.onCheckinExpired();
        StorageService.addLog('Check-in expired — SOS triggered automatically');
      }
    });
  }

  void _disarm() {
    _timer?.cancel();
    setState(() => _armed = false);
    StorageService.addLog('Check-in disarmed — user confirmed safe');
  }

  String _fmt(Duration d) =>
      '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Check-in timer
        _secTitle('⏱️ Check-In Timer'),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: _kCard, border: Border.all(color: _armed ? _kRed : _kBorder), borderRadius: BorderRadius.circular(8)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Auto-SOS in ${widget.settings.checkinMinutes} min if you don\'t disarm.',
                style: const TextStyle(fontSize: 13, color: _kMuted)),
            const SizedBox(height: 14),
            if (_armed) ...[
              Center(child: Text(_fmt(_remaining),
                  style: const TextStyle(fontSize: 60, fontWeight: FontWeight.w900, color: _kRed, fontFamily: 'monospace'))),
              const SizedBox(height: 4),
              const Center(child: Text('until SOS fires — tap below when safe!',
                  style: TextStyle(fontSize: 12, color: _kMuted))),
              const SizedBox(height: 14),
              SizedBox(width: double.infinity, child: ElevatedButton.icon(
                onPressed: _disarm,
                icon: const Icon(Icons.check_circle, color: Colors.white),
                label: const Text('I\'M SAFE — Disarm Timer', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.white)),
                style: ElevatedButton.styleFrom(backgroundColor: _kGreen,
                    padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
              )),
            ] else
              SizedBox(width: double.infinity, child: ElevatedButton.icon(
                onPressed: _arm,
                icon: const Icon(Icons.timer, color: Colors.white),
                label: Text('ARM ${widget.settings.checkinMinutes}-Min Check-In',
                    style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                style: ElevatedButton.styleFrom(backgroundColor: _kRed,
                    padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
              )),
          ]),
        ),
        const SizedBox(height: 20),

        // Fake Call
        _secTitle('📞 Fake Incoming Call'),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: _kCard, border: Border.all(color: _kBorder), borderRadius: BorderRadius.circular(8)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Pretend you\'re on a call — escape danger safely.', style: TextStyle(fontSize: 13, color: _kMuted)),
            const SizedBox(height: 14),
            const Text('CALLER', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: _kMuted, letterSpacing: 1)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: _callerOpts.map((n) =>
              GestureDetector(
                onTap: () => setState(() => _caller = n),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: _caller == n ? _kGreen : _kBg,
                    border: Border.all(color: _caller == n ? _kGreen : _kBorder),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(n, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold,
                      color: _caller == n ? Colors.white : _kText)),
                ),
              ),
            ).toList()),
            const SizedBox(height: 14),
            const Text('DELAY', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: _kMuted, letterSpacing: 1)),
            const SizedBox(height: 8),
            Row(children: [0, 5, 10, 30].map((d) =>
              Padding(padding: const EdgeInsets.only(right: 8),
                child: GestureDetector(
                  onTap: () => setState(() => _delay = d),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: _delay == d ? _kGreen : _kBg,
                      border: Border.all(color: _delay == d ? _kGreen : _kBorder),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(d == 0 ? 'Now' : '${d}s',
                        style: TextStyle(fontWeight: FontWeight.bold, color: _delay == d ? Colors.white : _kText)),
                  ),
                ),
              ),
            ).toList()),
            const SizedBox(height: 14),
            SizedBox(width: double.infinity, child: ElevatedButton.icon(
              onPressed: () {
                Future.delayed(Duration(seconds: _delay), () {
                  if (mounted) { HapticFeedback.heavyImpact(); widget.onFakeCall(_caller); }
                });
                if (_delay > 0 && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    backgroundColor: _kCard,
                    content: Text('Fake call rings in ${_delay}s…', style: const TextStyle(color: _kText)),
                    duration: Duration(seconds: _delay + 1),
                  ));
                }
              },
              icon: const Icon(Icons.call, color: Colors.white),
              label: const Text('Trigger Fake Call', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
              style: ElevatedButton.styleFrom(backgroundColor: _kGreen,
                  padding: const EdgeInsets.symmetric(vertical: 13), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            )),
          ]),
        ),
        const SizedBox(height: 20),

        // Utility Finder
        _secTitle('🏥 24/7 Emergency Utilities'),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(color: _kCard, border: Border.all(color: _kBorder), borderRadius: BorderRadius.circular(8)),
          child: Column(children: [
            _utilBtn(Icons.local_hospital, 'Nearest Hospital', 'https://www.google.com/maps/search/hospital+near+me'),
            const Divider(color: _kBorder, height: 1),
            _utilBtn(Icons.local_police, 'Nearest Police Station', 'https://www.google.com/maps/search/police+station+near+me'),
            const Divider(color: _kBorder, height: 1),
            _utilBtn(Icons.wc, 'Women\'s Shelter / NGO', 'https://www.google.com/maps/search/women+shelter+ngo+near+me'),
            const Divider(color: _kBorder, height: 1),
            _utilBtn(Icons.local_pharmacy, '24-hr Pharmacy', 'https://www.google.com/maps/search/24+hour+pharmacy+near+me'),
          ]),
        ),
        const SizedBox(height: 20),

        // Safety tips
        _secTitle('💡 Safety Tips'),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: _kCard, border: Border.all(color: _kBorder), borderRadius: BorderRadius.circular(8)),
          child: Column(children: [
            _tip('"Bachao" and "Help me now" always trigger SOS'),
            _tip('Keep battery above 20% when going out alone'),
            _tip('Add at least 3 trusted contacts for best coverage'),
            _tip('Use Check-In timer when traveling alone at night'),
            _tip('Test SOS (Demo Mode) every week to stay ready'),
            _tip('Settings ⚙ → Change wake word to something unique to you'),
          ]),
        ),
        const SizedBox(height: 20),
      ]),
    );
  }

  Widget _secTitle(String t) => Text(t, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: _kText));

  Widget _utilBtn(IconData icon, String label, String url) => ListTile(
    leading: Icon(icon, color: _kGreen, size: 22),
    title: Text(label, style: const TextStyle(fontSize: 14, color: _kText)),
    trailing: const Icon(Icons.open_in_new, color: _kMuted, size: 16),
    onTap: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
  );

  Widget _tip(String t) => Padding(padding: const EdgeInsets.only(bottom: 8), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text('•', style: TextStyle(color: _kGreen, fontSize: 16, fontWeight: FontWeight.bold)),
    const SizedBox(width: 8),
    Expanded(child: Text(t, style: const TextStyle(fontSize: 13, color: _kMuted))),
  ]));
}

// ═══════════════════════════════════════════════════════════════
//  TAB 3 — CONTACTS
// ═══════════════════════════════════════════════════════════════
class _ContactsTab extends StatefulWidget {
  final List<Contact> contacts;
  final Function(List<Contact>) onChanged;
  const _ContactsTab({required this.contacts, required this.onChanged});
  @override State<_ContactsTab> createState() => _ContactsTabState();
}

class _ContactsTabState extends State<_ContactsTab> {
  late List<Contact> _contacts;

  @override void initState() { super.initState(); _contacts = List.from(widget.contacts); }

  @override void didUpdateWidget(_ContactsTab old) {
    super.didUpdateWidget(old);
    if (old.contacts != widget.contacts) setState(() => _contacts = List.from(widget.contacts));
  }

  void _addEdit({Contact? editing, int? idx}) {
    final nc = TextEditingController(text: editing?.name ?? '');
    final pc = TextEditingController(text: editing?.phone.replaceAll('+91', '') ?? '');
    String? err;
    showModalBottomSheet(
      context: context, isScrollControlled: true, backgroundColor: _kCard,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(builder: (ctx, sm) => Padding(
        padding: EdgeInsets.only(left: 20, right: 20, top: 20, bottom: MediaQuery.of(ctx).viewInsets.bottom + 24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(editing != null ? 'Edit Contact' : 'Add Trusted Contact',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _kText)),
          const Text('Gets WhatsApp alert with GPS on SOS', style: TextStyle(fontSize: 12, color: _kMuted)),
          const SizedBox(height: 16),
          TextField(controller: nc, style: const TextStyle(color: _kText),
              decoration: _deco('Name', 'e.g. Maa, Didi, Best Friend'), textCapitalization: TextCapitalization.words, maxLength: 30),
          const SizedBox(height: 10),
          TextField(controller: pc, style: const TextStyle(color: _kText), keyboardType: TextInputType.phone,
              decoration: _deco('+91 Mobile Number', '9876543210'), maxLength: 10),
          if (err != null) ...[const SizedBox(height: 8), Text(err!, style: const TextStyle(color: _kRed, fontSize: 13))],
          const SizedBox(height: 16),
          SizedBox(width: double.infinity, child: ElevatedButton(
            onPressed: () {
              final phone = StorageService.validatePhone(pc.text.trim());
              final name = nc.text.trim();
              if (name.isEmpty || phone == null) { sm(() => err = 'Enter a valid name and 10-digit +91 number.'); return; }
              final updated = List<Contact>.from(_contacts);
              if (idx != null) { updated[idx] = Contact(name: name, phone: phone); }
              else {
                if (updated.length >= StorageService.maxContacts) { sm(() => err = 'Max ${StorageService.maxContacts} contacts allowed.'); return; }
                updated.add(Contact(name: name, phone: phone));
              }
              setState(() => _contacts = updated);
              widget.onChanged(updated);
              Navigator.pop(ctx);
            },
            style: ElevatedButton.styleFrom(backgroundColor: _kGreen, foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: Text(editing != null ? 'Update Contact' : 'Add Contact', style: const TextStyle(fontWeight: FontWeight.bold)),
          )),
        ]),
      )),
    );
  }

  InputDecoration _deco(String label, String hint) => InputDecoration(
    labelText: label, hintText: hint,
    labelStyle: const TextStyle(color: _kMuted), hintStyle: const TextStyle(color: _kMuted),
    counterStyle: const TextStyle(color: _kMuted), filled: true, fillColor: _kBg,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: _kBorder)),
    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: _kBorder)),
    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: _kText)),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      floatingActionButton: _contacts.length < StorageService.maxContacts
          ? FloatingActionButton.extended(
              onPressed: () => _addEdit(),
              backgroundColor: _kGreen,
              icon: const Icon(Icons.add, color: Colors.white),
              label: const Text('Add Contact', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            )
          : null,
      body: _contacts.isEmpty
          ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.people_outline, size: 64, color: _kMuted),
              const SizedBox(height: 16),
              const Text('No trusted contacts', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _kText)),
              const SizedBox(height: 8),
              const Text('Add up to 5 contacts.\nThey\'ll receive a WhatsApp SOS\nalert with your GPS location.',
                  textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: _kMuted)),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: () => _addEdit(),
                icon: const Icon(Icons.add),
                label: const Text('Add First Contact', style: TextStyle(fontWeight: FontWeight.bold)),
                style: ElevatedButton.styleFrom(backgroundColor: _kGreen, foregroundColor: Colors.white),
              ),
            ]))
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 100),
              itemCount: _contacts.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (ctx, i) {
                final c = _contacts[i];
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(color: _kCard, border: Border.all(color: _kBorder), borderRadius: BorderRadius.circular(8)),
                  child: Row(children: [
                    Container(width: 36, height: 36,
                        decoration: BoxDecoration(color: _kRed.withOpacity(0.1), borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: _kRed.withOpacity(0.3))),
                        child: Center(child: Text('${i + 1}', style: const TextStyle(fontWeight: FontWeight.w900, color: _kRed, fontSize: 15)))),
                    const SizedBox(width: 12),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(c.name, style: const TextStyle(fontWeight: FontWeight.bold, color: _kText, fontSize: 15)),
                      Text(StorageService.formatPhone(c.phone), style: const TextStyle(fontSize: 13, color: _kMuted, fontFamily: 'monospace')),
                    ])),
                    IconButton(icon: const Icon(Icons.call, color: _kGreen, size: 22), onPressed: () => AlertService.call(c), tooltip: 'Call'),
                    IconButton(icon: const Icon(Icons.edit, color: _kMuted, size: 20), onPressed: () => _addEdit(editing: c, idx: i), tooltip: 'Edit'),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: _kRed, size: 20),
                      onPressed: () => showDialog(context: context, builder: (_) => AlertDialog(
                        backgroundColor: _kCard,
                        title: const Text('Remove Contact?', style: TextStyle(color: _kText)),
                        content: Text('Remove ${c.name}?', style: const TextStyle(color: _kMuted)),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel', style: TextStyle(color: _kMuted))),
                          TextButton(onPressed: () {
                            Navigator.pop(context);
                            final u = List<Contact>.from(_contacts)..removeAt(i);
                            setState(() => _contacts = u);
                            widget.onChanged(u);
                          }, child: const Text('Remove', style: TextStyle(color: _kRed))),
                        ],
                      )),
                    ),
                  ]),
                );
              },
            ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  SETTINGS SCREEN
// ═══════════════════════════════════════════════════════════════
class SettingsScreen extends StatefulWidget {
  final AppSettings settings;
  const SettingsScreen({super.key, required this.settings});
  @override State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late AppSettings _s;
  late TextEditingController _wakeCtrl;

  final _languages = {
    'English (en-IN)': 'en_IN',
    'Hindi (hi-IN)': 'hi_IN',
    'Kannada (kn-IN)': 'kn_IN',
    'Tamil (ta-IN)': 'ta_IN',
    'Telugu (te-IN)': 'te_IN',
    'Marathi (mr-IN)': 'mr_IN',
  };

  @override
  void initState() {
    super.initState();
    _s = widget.settings.copy();
    _wakeCtrl = TextEditingController(text: _s.wakeWord);
  }

  @override
  void dispose() { _wakeCtrl.dispose(); super.dispose(); }

  Future<void> _save() async {
    _s.wakeWord = _wakeCtrl.text.trim().isEmpty ? 'help me now' : _wakeCtrl.text.trim().toLowerCase();
    await _s.save();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        backgroundColor: _kBg, elevation: 0,
        title: const Text('Settings', style: TextStyle(color: _kText, fontWeight: FontWeight.bold)),
        leading: IconButton(icon: const Icon(Icons.arrow_back, color: _kText),
            onPressed: () async { await _save(); Navigator.pop(context); }),
        actions: [TextButton(
          onPressed: () async { await _save(); Navigator.pop(context); },
          child: const Text('Save', style: TextStyle(color: _kGreen, fontWeight: FontWeight.bold, fontSize: 16)),
        )],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

          // Wake word
          _hdr('🗣️ Wake Word'),
          _card([Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Custom Wake Word', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: _kText)),
            const SizedBox(height: 4),
            const Text('The phrase that triggers SOS when spoken aloud', style: TextStyle(fontSize: 12, color: _kMuted)),
            const SizedBox(height: 10),
            TextField(
              controller: _wakeCtrl,
              style: const TextStyle(color: _kText, fontWeight: FontWeight.bold),
              decoration: InputDecoration(
                hintText: 'help me now',
                hintStyle: const TextStyle(color: _kMuted),
                filled: true, fillColor: _kBg,
                prefixIcon: const Icon(Icons.mic, color: _kRed),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: _kBorder)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: _kBorder)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: _kRed)),
                suffixIcon: IconButton(icon: const Icon(Icons.restore, color: _kMuted),
                    onPressed: () => _wakeCtrl.text = 'help me now'),
              ),
            ),
            const SizedBox(height: 8),
            const Text('💡 "Bachao", "Help me now", "Emergency" always work too', style: TextStyle(fontSize: 11, color: _kMuted)),
          ]))]),
          const SizedBox(height: 16),

          // Language
          _hdr('🌏 Voice Language'),
          _card([Padding(padding: const EdgeInsets.fromLTRB(14, 14, 14, 8), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Speech Recognition Language', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: _kText)),
            const SizedBox(height: 4),
            const Text('Changes the language for voice guard recognition', style: TextStyle(fontSize: 12, color: _kMuted)),
            const SizedBox(height: 10),
            ..._languages.entries.map((e) => RadioListTile<String>(
              value: e.key, groupValue: _s.languageLabel,
              onChanged: (v) => setState(() { _s.languageLabel = v!; _s.localeId = _languages[v]!; }),
              title: Text(e.key, style: const TextStyle(color: _kText, fontSize: 14)),
              activeColor: _kGreen, contentPadding: EdgeInsets.zero,
            )),
          ]))]),
          const SizedBox(height: 16),

          // SOS behaviour toggles
          _hdr('🚨 SOS Behaviour'),
          _card([
            _tog('Voice Wake Word', 'Listen for wake word in background', _s.voiceEnabled, (v) => setState(() => _s.voiceEnabled = v)),
            const Divider(color: _kBorder, height: 1),
            _tog('Shake to SOS', '3 strong shakes within 1.5s', _s.shakeEnabled, (v) => setState(() => _s.shakeEnabled = v)),
            const Divider(color: _kBorder, height: 1),
            _tog('SOS Siren (Audio + Haptic)', 'Loud "ALERT!" alarm + triple haptic vibration', _s.sirenEnabled, (v) => setState(() => _s.sirenEnabled = v)),
            const Divider(color: _kBorder, height: 1),
            _tog('Silent SOS Mode', 'No sound — stealth alert only', _s.silentMode, (v) => setState(() => _s.silentMode = v)),
            const Divider(color: _kBorder, height: 1),
            _tog('Demo Mode', 'Test SOS without sending real alerts', _s.demoMode, (v) => setState(() => _s.demoMode = v)),
          ]),
          const SizedBox(height: 16),

          // Shake sensitivity
          _hdr('📳 Shake Sensitivity'),
          _card([Padding(padding: const EdgeInsets.fromLTRB(14, 14, 14, 10), child: Column(children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              const Text('Sensitivity', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: _kText)),
              Text(_s.shakeSensitivity >= 25 ? 'Low (Less sensitive)' : _s.shakeSensitivity >= 18 ? 'Medium' : 'High (More sensitive)',
                  style: const TextStyle(fontSize: 13, color: _kGreen, fontWeight: FontWeight.bold)),
            ]),
            Slider(value: _s.shakeSensitivity, min: 10, max: 30, divisions: 4, activeColor: _kRed, inactiveColor: _kBorder,
                onChanged: (v) => setState(() => _s.shakeSensitivity = v)),
            const Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('Very sensitive', style: TextStyle(fontSize: 11, color: _kMuted)),
              Text('Less sensitive', style: TextStyle(fontSize: 11, color: _kMuted)),
            ]),
          ]))]),
          const SizedBox(height: 16),

          // Check-in interval
          _hdr('⏱️ Check-In Timer Duration'),
          _card([Padding(padding: const EdgeInsets.fromLTRB(14, 14, 14, 10), child: Column(children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              const Text('Auto-SOS after', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: _kText)),
              Text('${_s.checkinMinutes} minutes', style: const TextStyle(fontSize: 13, color: _kGreen, fontWeight: FontWeight.bold)),
            ]),
            Slider(value: _s.checkinMinutes.toDouble(), min: 5, max: 120, divisions: 23, activeColor: _kRed, inactiveColor: _kBorder,
                onChanged: (v) => setState(() => _s.checkinMinutes = v.round())),
            const Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('5 min', style: TextStyle(fontSize: 11, color: _kMuted)),
              Text('120 min', style: TextStyle(fontSize: 11, color: _kMuted)),
            ]),
          ]))]),
          const SizedBox(height: 16),

          // Data & privacy
          _hdr('🔒 Data & Privacy'),
          _card([
            ListTile(
              leading: const Icon(Icons.delete_forever, color: _kRed),
              title: const Text('Wipe All Data', style: TextStyle(color: _kRed, fontWeight: FontWeight.bold)),
              subtitle: const Text('Delete all contacts, logs, and recordings', style: TextStyle(color: _kMuted, fontSize: 12)),
              onTap: () => showDialog(context: context, builder: (_) => AlertDialog(
                backgroundColor: _kCard,
                title: const Text('⚠️ Wipe All Data?', style: TextStyle(color: _kText)),
                content: const Text('Permanently deletes all contacts, incident logs, and audio recordings. Cannot be undone.',
                    style: TextStyle(color: _kMuted)),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel', style: TextStyle(color: _kMuted))),
                  TextButton(onPressed: () async {
                    Navigator.pop(context);
                    await StorageService.wipeAll();
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        backgroundColor: _kCard,
                        content: Text('All data wiped.', style: TextStyle(color: _kText)),
                      ));
                      Navigator.pop(context);
                    }
                  }, child: const Text('Wipe Everything', style: TextStyle(color: _kRed))),
                ],
              )),
            ),
          ]),
          const SizedBox(height: 16),

          // About
          _hdr('ℹ️ About'),
          _card([const Padding(padding: EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Awaaz Suraksha — आवाज़ सुरक्षा', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: _kText)),
            SizedBox(height: 4),
            Text('Voice-First Emergency Safety App for Women in India', style: TextStyle(fontSize: 13, color: _kMuted)),
            SizedBox(height: 10),
            Text('Hackathon: Wispr Flow × Scaler AI Voice Hackathon', style: TextStyle(fontSize: 12, color: _kMuted)),
            SizedBox(height: 4),
            Text('Team: CTRL ALT ELITE', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: _kText)),
            SizedBox(height: 4),
            Text('Made with ❤️ in India', style: TextStyle(fontSize: 12, color: _kMuted)),
            SizedBox(height: 10),
            Text('Offline-ready • No tracking • Local storage only • Open source', style: TextStyle(fontSize: 11, color: _kMuted)),
          ]))]),
          const SizedBox(height: 40),
        ]),
      ),
    );
  }

  Widget _hdr(String t) => Padding(padding: const EdgeInsets.only(bottom: 8),
      child: Text(t, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: _kText)));

  Widget _card(List<Widget> ch) => Container(
      decoration: BoxDecoration(color: _kCard, border: Border.all(color: _kBorder), borderRadius: BorderRadius.circular(8)),
      child: Column(children: ch));

  Widget _tog(String title, String desc, bool val, ValueChanged<bool> ch) =>
      Padding(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10), child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: _kText)),
          const SizedBox(height: 2),
          Text(desc, style: const TextStyle(fontSize: 12, color: _kMuted)),
        ])),
        Switch(value: val, onChanged: ch, activeColor: _kGreen, inactiveThumbColor: _kMuted, inactiveTrackColor: _kBg),
      ]));
}

// ═══════════════════════════════════════════════════════════════
//  SOS ACTIVE SCREEN  (the full-screen alarm)
// ═══════════════════════════════════════════════════════════════
class SosActiveScreen extends StatefulWidget {
  final List<Contact> contacts;
  final bool isDemo, isSilent, sirenEnabled;
  final String source;
  final TtsService tts;
  final VoidCallback onDeactivated;

  const SosActiveScreen({
    super.key,
    required this.contacts, required this.isDemo, required this.isSilent,
    required this.sirenEnabled, required this.source, required this.tts, required this.onDeactivated,
  });

  @override State<SosActiveScreen> createState() => _SosActiveState();
}

class _SosActiveState extends State<SosActiveScreen> with TickerProviderStateMixin {
  int _cd = 5;
  Timer? _cdTimer;
  bool _dispatched = false;
  bool _cancelled = false;

  String _gpsStatus = 'Locating…';
  String _recStatus = 'Standby';
  String _alertStatus = 'Waiting…';
  Map<String, dynamic>? _loc;
  String? _mapsUrl;

  final RecordingService _rec = RecordingService();
  final SirenService _siren = SirenService();
  SpeechToText _speech = SpeechToText();
  Timer? _recTimer;
  Duration _recElapsed = Duration.zero;

  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;
  late AnimationController _bgCtrl;
  late Animation<Color?> _bgAnim;

  @override
  void initState() {
    super.initState();

    // Pulsing SOS text
    _pulseCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 700))..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.94, end: 1.07).animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));

    // Red flashing background
    _bgCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 600))..repeat(reverse: true);
    _bgAnim = ColorTween(begin: const Color(0xFF1A0000), end: const Color(0xFF3A0000)).animate(_bgCtrl);

    WakelockPlus.enable();
    _startCountdown();
    _startVoiceCancel();
    if (widget.sirenEnabled) _siren.start();
  }

  void _startCountdown() {
    widget.tts.speak('Awaaz Suraksha SOS activated. Sending alert in 5 seconds. Say I\'m safe to cancel.');
    _cdTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_cancelled) { t.cancel(); return; }
      if (mounted) setState(() => _cd--);
      if (_cd <= 0) { t.cancel(); _dispatch(); }
    });
  }

  Future<void> _dispatch() async {
    if (_cancelled || _dispatched) return;
    _dispatched = true;
    if (mounted) setState(() => _alertStatus = 'Dispatching…');
    widget.tts.speak('Alerting your contacts now. Stay calm. Help is on the way.');

    // Start recording
    if (mounted) setState(() => _recStatus = 'Starting…');
    final recOk = await _rec.start();
    if (recOk) {
      if (mounted) setState(() => _recStatus = '🔴 Recording 00:00');
      _recTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() {
          _recElapsed = _rec.elapsed;
          final mm = _recElapsed.inMinutes.toString().padLeft(2, '0');
          final ss = (_recElapsed.inSeconds % 60).toString().padLeft(2, '0');
          _recStatus = '🔴 Recording $mm:$ss';
        });
      });
    } else {
      if (mounted) setState(() => _recStatus = '⚠ Mic denied — check permissions');
    }

    // GPS
    if (mounted) setState(() => _gpsStatus = 'Capturing (8s max)…');
    final loc = await LocationService.get();
    if (mounted) setState(() {
      _loc = loc;
      if (loc['ok'] == true) {
        final acc = loc['acc'] != null ? ' ±${loc['acc']}m' : '';
        _mapsUrl = LocationService.mapsUrl(loc['lat'], loc['lng']);
        _gpsStatus = '${loc['lat']}, ${loc['lng']}$acc';
      } else {
        _gpsStatus = 'Unavailable: ${loc['reason']}';
      }
    });

    // Alert contacts
    if (widget.isDemo) {
      if (mounted) setState(() => _alertStatus = '⚡ DEMO — nothing sent');
    } else {
      final msg = AlertService.buildMsg(loc);
      int opened = 0;
      for (final c in widget.contacts) {
        final ok = await AlertService.whatsapp(c, msg);
        if (ok) opened++;
        await Future.delayed(const Duration(milliseconds: 600));
      }
      if (mounted) setState(() => _alertStatus = widget.contacts.isEmpty
          ? '⚠ No contacts — dial 112!'
          : opened > 0 ? '✅ Sent to $opened/${widget.contacts.length}' : '⚠ WhatsApp blocked — tap Call below');
    }
  }

  void _startVoiceCancel() async {
    final rec = SpeechToText();
    await rec.initialize();
    _speech = rec;
    _listenSafe();
  }

  void _listenSafe() {
    if (_cancelled) return;
    _speech.listen(
      onResult: (r) {
        if (RegExp(r"(i'?m\s+safe|i\s+am\s+safe|cancel\s+sos|safe\s+now|im\s+safe)").hasMatch(r.recognizedWords.toLowerCase())) {
          _deactivate('Voice: "I\'m safe"');
        }
      },
      listenFor: const Duration(minutes: 5),
      pauseFor: const Duration(minutes: 5),
      localeId: 'en_IN',
      cancelOnError: false,
      partialResults: true,
    );
    _speech.statusListener = (st) {
      if ((st == 'done' || st == 'notListening') && !_cancelled) {
        Future.delayed(const Duration(milliseconds: 400), _listenSafe);
      }
    };
  }

  Future<void> _deactivate(String reason) async {
    if (_cancelled) return;
    _cancelled = true;
    _siren.stop();
    _cdTimer?.cancel();
    _recTimer?.cancel();
    await _speech.cancel();
    await widget.tts.stop();

    if (_dispatched) {
      final savedPath = await _rec.stop();
      if (!widget.isSilent) await widget.tts.speak('Awaaz Suraksha deactivated. You are safe now.');
      await StorageService.addLog('SOS deactivated by: $reason');
      if (mounted && savedPath != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: _kCard,
          content: Text('Audio evidence saved:\n$savedPath', style: const TextStyle(color: _kText, fontSize: 12)),
          duration: const Duration(seconds: 6),
        ));
      }
    } else {
      await _rec.cancel();
      await StorageService.addLog('SOS cancelled: $reason (before dispatch)');
    }

    widget.onDeactivated();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _cdTimer?.cancel(); _recTimer?.cancel(); _siren.stop();
    _pulseCtrl.dispose(); _bgCtrl.dispose(); _speech.cancel();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _bgAnim,
      builder: (_, __) => Scaffold(
        backgroundColor: _bgAnim.value ?? _kSosBg,
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
              // Badges row
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                if (widget.isDemo) _badge('DEMO — NOTHING SENT', _kRed),
                if (widget.isSilent) ...[if (widget.isDemo) const SizedBox(width: 8), _badge('SILENT', _kCard)],
                if (widget.sirenEnabled && !widget.isSilent) ...[const SizedBox(width: 8), _badge('🔊 SIREN ACTIVE', const Color(0xFF7D2D00))],
              ]),
              const SizedBox(height: 16),

              // SOS ACTIVE title (pulsing)
              ScaleTransition(
                scale: _pulseAnim,
                child: const Text('SOS ACTIVE', style: TextStyle(fontSize: 42, fontWeight: FontWeight.w900, letterSpacing: 4, color: Colors.white)),
              ),
              const SizedBox(height: 4),
              Text('Triggered: ${widget.source}', style: const TextStyle(fontSize: 11, color: Colors.white38, letterSpacing: 0.5)),
              const SizedBox(height: 10),

              // Countdown / status
              if (!_dispatched)
                Column(children: [
                  Text('$_cd', style: const TextStyle(fontSize: 90, fontWeight: FontWeight.w900, color: Colors.white, fontFamily: 'monospace')),
                  Text('seconds until alert fires\nSay "I\'m safe" to cancel',
                      textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white70)),
                ])
              else
                Text(widget.isDemo ? 'DEMO — no real alerts sent' : '🚨 Alerting contacts — stay calm.',
                    textAlign: TextAlign.center, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white)),

              const SizedBox(height: 20),

              // Telemetry cards
              _card2('📍 GPS Location', _gpsStatus),
              const SizedBox(height: 8),
              _card2('🎙️ Audio Evidence', _recStatus),
              const SizedBox(height: 8),
              _card2('💬 Contact Alerts', _alertStatus),

              // Maps link
              if (_mapsUrl != null) ...[
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: () => launchUrl(Uri.parse(_mapsUrl!), mode: LaunchMode.externalApplication),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(color: _kCard.withOpacity(0.7), border: Border.all(color: _kBorder), borderRadius: BorderRadius.circular(8)),
                    child: const Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.map, color: _kGreen, size: 16),
                      SizedBox(width: 6),
                      Text('Open in Google Maps →', style: TextStyle(color: Colors.white, decoration: TextDecoration.underline, fontWeight: FontWeight.bold)),
                    ]),
                  ),
                ),
              ],

              // Contact fallback buttons
              if (_dispatched && widget.contacts.isNotEmpty) ...[
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: _kCard.withOpacity(0.7), border: Border.all(color: _kBorder), borderRadius: BorderRadius.circular(8)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('DIRECT CONTACT', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 1, color: _kMuted)),
                    const SizedBox(height: 8),
                    ...widget.contacts.map((c) => _contactRow(c)),
                    if (widget.isDemo) ...[
                      const SizedBox(height: 8),
                      Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: _kBg, borderRadius: BorderRadius.circular(6)),
                          child: Text('Preview: ${AlertService.buildMsg(_loc ?? {'ok': false})}',
                              style: const TextStyle(fontSize: 11, color: _kMuted))),
                    ],
                  ]),
                ),
              ],

              const SizedBox(height: 16),

              // 112 button
              SizedBox(width: double.infinity, child: OutlinedButton.icon(
                onPressed: () => launchUrl(Uri.parse('tel:112')),
                icon: const Icon(Icons.phone, color: Colors.white),
                label: const Text('CALL 112 — EMERGENCY', style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1, color: Colors.white)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.white, width: 2),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              )),
              const SizedBox(height: 12),
              const Text('Say "I\'m safe" or tap button below to stop',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white70)),
              const SizedBox(height: 10),

              // Cancel SOS button
              GestureDetector(
                onTap: () => _deactivate('Cancel Button'),
                child: Container(
                  width: double.infinity, height: 64,
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10)),
                  child: const Center(child: Text("I'M SAFE — CANCEL SOS",
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, letterSpacing: 1, color: _kSosBg))),
                ),
              ),
              const SizedBox(height: 20),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _badge(String t, Color bg) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(99), border: Border.all(color: Colors.white)),
    child: Text(t, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 1, color: Colors.white)),
  );

  Widget _card2(String label, String val) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(color: _kCard.withOpacity(0.7), border: Border.all(color: _kBorder), borderRadius: BorderRadius.circular(8)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 0.8, color: _kMuted)),
      const SizedBox(height: 3),
      Text(val, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: _kText)),
    ]),
  );

  Widget _contactRow(Contact c) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(children: [
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(c.name, style: const TextStyle(fontWeight: FontWeight.bold, color: _kText, fontSize: 13)),
        Text(StorageService.formatPhone(c.phone), style: const TextStyle(fontSize: 11, color: _kMuted, fontFamily: 'monospace')),
      ])),
      GestureDetector(onTap: () => AlertService.call(c), child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), margin: const EdgeInsets.only(left: 6),
        decoration: BoxDecoration(color: _kGreen, borderRadius: BorderRadius.circular(6)),
        child: const Text('Call', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white)),
      )),
      if (!widget.isDemo) GestureDetector(
        onTap: () => AlertService.whatsapp(c, AlertService.buildMsg(_loc ?? {'ok': false})),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), margin: const EdgeInsets.only(left: 6),
          decoration: BoxDecoration(color: const Color(0xFF25D366), borderRadius: BorderRadius.circular(6)),
          child: const Text('WA', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white)),
        ),
      ),
    ]),
  );
}

// ═══════════════════════════════════════════════════════════════
//  FAKE CALL SCREEN
// ═══════════════════════════════════════════════════════════════
class FakeCallScreen extends StatefulWidget {
  final String callerName;
  const FakeCallScreen({super.key, required this.callerName});
  @override State<FakeCallScreen> createState() => _FakeCallState();
}

class _FakeCallState extends State<FakeCallScreen> {
  bool _accepted = false;
  Duration _dur = Duration.zero;
  Timer? _timer;
  String _status = 'Ringing…';

  void _accept() {
    HapticFeedback.heavyImpact();
    setState(() { _accepted = true; _status = '00:00'; });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() { _dur += const Duration(seconds: 1); _status = _fmt(_dur); });
    });
  }

  void _end() { _timer?.cancel(); Navigator.of(context).pop(); }

  String _fmt(Duration d) =>
      '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override void dispose() { _timer?.cancel(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1C1C1E),
      body: SafeArea(
        child: Column(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Column(children: [
            const SizedBox(height: 48),
            const Text('INCOMING VOICE CALL', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 2, color: _kMuted)),
            const SizedBox(height: 20),
            Container(width: 80, height: 80,
                decoration: BoxDecoration(color: _kCard, borderRadius: BorderRadius.circular(40), border: Border.all(color: _kBorder, width: 2)),
                child: const Icon(Icons.person, color: _kMuted, size: 44)),
            const SizedBox(height: 14),
            Text(widget.callerName, style: const TextStyle(fontSize: 36, fontWeight: FontWeight.w800, color: _kText)),
            const SizedBox(height: 6),
            Text(widget.callerName == '112 Control Room' ? 'Emergency Dispatch • India' : 'Mobile • India',
                style: const TextStyle(fontSize: 15, color: _kMuted)),
            const SizedBox(height: 10),
            Text(_status, style: const TextStyle(fontSize: 18, fontFamily: 'monospace', color: _kText)),
          ]),
          Padding(
            padding: const EdgeInsets.only(bottom: 48),
            child: Row(
              mainAxisAlignment: _accepted ? MainAxisAlignment.center : MainAxisAlignment.spaceEvenly,
              children: [
                if (!_accepted) _btn(Icons.call_end, 'Decline', _kRed, _end),
                _btn(_accepted ? Icons.call_end : Icons.call, _accepted ? 'End Call' : 'Accept',
                    _accepted ? _kRed : _kGreen, _accepted ? _end : _accept),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  Widget _btn(IconData icon, String label, Color color, VoidCallback onTap) =>
      GestureDetector(onTap: onTap, child: Column(children: [
        Container(width: 72, height: 72, decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: 32)),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(fontSize: 13, color: _kText, fontWeight: FontWeight.bold)),
      ]));
}
