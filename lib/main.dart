import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart' as notifications;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:awaaz_sms/awaaz_sms.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:share_plus/share_plus.dart';
import 'package:vosk_flutter/vosk_flutter.dart';
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
  StreamSubscription<AccelerometerEvent>? _shakeSub;
  final List<DateTime> _shakeTimes = [];
  final notifications.FlutterLocalNotificationsPlugin _notifications =
      notifications.FlutterLocalNotificationsPlugin();
  double _lastMag = 0;
  double _sensitivity = 20;
  bool _sosTriggered = false;
  bool _shakeEnabled = true;
  bool _sirenEnabled = true;
  bool _silentMode = false;
  bool _demoMode = false;

  @override
  Future<void> onStart(DateTime ts, TaskStarter s) async {
    final p = await SharedPreferences.getInstance();
    _shakeEnabled = p.getBool('shake_enabled') ?? true;
    _sensitivity = p.getDouble('shake_sensitivity') ?? 20;
    _sosTriggered = p.getBool('pending_background_sos') ?? false;
    _sirenEnabled = p.getBool('siren_enabled') ?? true;
    _silentMode = p.getBool('silent_mode') ?? false;
    _demoMode = p.getBool('demo_mode') ?? false;
    if (_shakeEnabled) {
      _shakeSub = accelerometerEventStream().listen(_onAccelerometerEvent);
    }
    try {
      await _notifications.initialize(
        const notifications.InitializationSettings(
          android: notifications.AndroidInitializationSettings('ic_launcher'),
        ),
      );
    } on MissingPluginException catch (error) {
      print('Background notification plugin unavailable: $error');
    } on PlatformException catch (error) {
      print('Background notification initialization failed: $error');
    }
  }

  void _onAccelerometerEvent(AccelerometerEvent event) {
    if (!_shakeEnabled || _sosTriggered) return;
    final mag = math.sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
    final delta = (mag - _lastMag).abs();
    _lastMag = mag;
    if (delta <= _sensitivity) return;

    final now = DateTime.now();
    _shakeTimes.removeWhere((time) => now.difference(time).inMilliseconds >= 1500);
    _shakeTimes.add(now);
    if (_shakeTimes.length >= 3) {
      _shakeTimes.clear();
      _triggerBackgroundSOS('Shake detected').catchError((Object error) {
        print('Background SOS notification failed: $error');
      });
    }
  }

  Future<void> _triggerBackgroundSOS(String reason) async {
    if (_sosTriggered) return;
    _sosTriggered = true;
    final p = await SharedPreferences.getInstance();
    await p.setBool('pending_background_sos', true);
    await p.setString('pending_sos_reason', reason);
    await p.remove('checkin_deadline_ms');

    await FlutterForegroundTask.updateService(
      notificationTitle: 'SOS triggered',
      notificationText: '$reason. Open the app to continue the alert.',
    );

    if (!_demoMode && (p.getBool('sms_alerts_enabled') ?? false)) {
      await p.setBool('background_sos_sms_attempted', true);
      final contacts = await StorageService.loadContacts();
      final location = await LocationService.get(requestPermission: false);
      final sent = await AlertService.sendSmsToContacts(
        contacts,
        AlertService.buildSmsMsg(location),
      );
      await p.setStringList('background_sos_sms_sent_contacts', sent);
    }
    FlutterForegroundTask.sendDataToMain({'command': 'background_sos'});

    final playSound = _sirenEnabled && !_silentMode;
    final channelId = playSound ? 'awaaz_sos_alert' : 'awaaz_sos_silent';
    await _notifications.show(
      1002,
      'SOS triggered',
      '$reason. Open Awaaz Suraksha to continue the alert.',
      notifications.NotificationDetails(
        android: notifications.AndroidNotificationDetails(
          channelId,
          playSound ? 'SOS alerts' : 'Silent SOS alerts',
          channelDescription: 'Alerts triggered by shake detection.',
          importance: notifications.Importance.max,
          priority: notifications.Priority.max,
          category: notifications.AndroidNotificationCategory.alarm,
          playSound: playSound,
          enableVibration: true,
          vibrationPattern: Int64List.fromList([0, 500, 200, 500, 200, 700]),
          audioAttributesUsage: notifications.AudioAttributesUsage.alarm,
          visibility: notifications.NotificationVisibility.public,
        ),
      ),
      payload: 'background_sos',
    );
  }

  Future<void> _processLiveShare(
    SharedPreferences preferences,
    int nowMillis,
  ) async {
    final until = preferences.getInt('live_share_until_ms') ?? 0;
    if (until == 0) return;
    if (nowMillis >= until) {
      await preferences.remove('live_share_until_ms');
      await preferences.remove('live_share_interval_ms');
      await preferences.remove('live_share_last_update_ms');
      await StorageService.addLog('Live location share expired');
      return;
    }

    final interval = preferences.getInt('live_share_interval_ms') ?? 300000;
    final lastUpdate = preferences.getInt('live_share_last_update_ms') ?? 0;
    if (nowMillis - lastUpdate < interval) return;
    await preferences.setInt('live_share_last_update_ms', nowMillis);

    final location = await LocationService.get(requestPermission: false);
    if (location['ok'] != true) {
      await StorageService.addLog('Live location update unavailable: ${location['reason']}');
      return;
    }
    final contacts = await StorageService.loadContacts();
    final message = AlertService.buildLiveLocationMsg(
      location,
      until,
      (interval / 60000).round(),
    );
    final sent = await AlertService.sendSmsToContacts(contacts, message);
    await StorageService.addLog('Live location SMS queued for $sent/${contacts.length} contacts');
  }

  @override
  Future<void> onRepeatEvent(DateTime ts) async {
    final p = await SharedPreferences.getInstance();
    final now = DateTime.now().millisecondsSinceEpoch;
    final checkinDeadline = p.getInt('checkin_deadline_ms') ?? 0;
    if (!_sosTriggered && checkinDeadline > 0 && now >= checkinDeadline) {
      await _triggerBackgroundSOS('Check-in timer expired');
    }
    await _processLiveShare(p, now);
    final checkinActive = (p.getInt('checkin_deadline_ms') ?? 0) > now;
    final liveShareActive = (p.getInt('live_share_until_ms') ?? 0) > now;
    if (!(p.getBool('shake_enabled') ?? true) &&
        !checkinActive &&
        !liveShareActive) {
      await FlutterForegroundTask.stopService();
    }
  }
  @override
  Future<void> onDestroy(DateTime ts) async {
    await _shakeSub?.cancel();
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
  bool smsAlertsEnabled;
  bool evidenceEnabled;
  double shakeSensitivity;
  int checkinMinutes;
  int liveShareMinutes;
  int liveShareIntervalMinutes;

  AppSettings({
    this.wakeWord = 'help me now',
    this.localeId = 'en_IN',
    this.languageLabel = 'English (India; offline)',
    this.voiceEnabled = true,
    this.sirenEnabled = true,
    this.silentMode = false,
    this.shakeEnabled = true,
    this.demoMode = false,
    this.smsAlertsEnabled = false,
    this.evidenceEnabled = false,
    this.shakeSensitivity = 20.0,
    this.checkinMinutes = 30,
    this.liveShareMinutes = 30,
    this.liveShareIntervalMinutes = 5,
  });

  static Future<AppSettings> load() async {
    final p = await SharedPreferences.getInstance();
    return AppSettings(
      wakeWord: p.getString('wake_word') ?? 'help me now',
      localeId: 'en_IN',
      languageLabel: 'English (India; offline)',
      voiceEnabled: p.getBool('voice_enabled') ?? true,
      sirenEnabled: p.getBool('siren_enabled') ?? true,
      silentMode: p.getBool('silent_mode') ?? false,
      shakeEnabled: p.getBool('shake_enabled') ?? true,
      demoMode: p.getBool('demo_mode') ?? false,
      smsAlertsEnabled: p.getBool('sms_alerts_enabled') ?? false,
      evidenceEnabled: p.getBool('evidence_enabled') ?? false,
      shakeSensitivity: p.getDouble('shake_sensitivity') ?? 20.0,
      checkinMinutes: p.getInt('checkin_minutes') ?? 30,
      liveShareMinutes: p.getInt('live_share_minutes') ?? 30,
      liveShareIntervalMinutes: p.getInt('live_share_interval_minutes') ?? 5,
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
    await p.setBool('sms_alerts_enabled', smsAlertsEnabled);
    await p.setBool('evidence_enabled', evidenceEnabled);
    await p.setDouble('shake_sensitivity', shakeSensitivity);
    await p.setInt('checkin_minutes', checkinMinutes);
    await p.setInt('live_share_minutes', liveShareMinutes);
    await p.setInt('live_share_interval_minutes', liveShareIntervalMinutes);
  }

  AppSettings copy() => AppSettings(
    wakeWord: wakeWord, localeId: localeId, languageLabel: languageLabel,
    voiceEnabled: voiceEnabled, sirenEnabled: sirenEnabled, silentMode: silentMode,
    shakeEnabled: shakeEnabled, demoMode: demoMode, smsAlertsEnabled: smsAlertsEnabled,
    evidenceEnabled: evidenceEnabled, shakeSensitivity: shakeSensitivity,
    checkinMinutes: checkinMinutes, liveShareMinutes: liveShareMinutes,
    liveShareIntervalMinutes: liveShareIntervalMinutes,
  );
}

class VoiceCommandService {
  static const _modelAsset = 'assets/models/vosk-model-small-en-in-0.4.zip';
  static const _sampleRate = 16000;

  final VoskFlutterPlugin _vosk = VoskFlutterPlugin.instance();
  final ModelLoader _modelLoader = ModelLoader();
  Model? _model;
  Recognizer? _recognizer;
  SpeechService? _speechService;
  StreamSubscription<String>? _resultSubscription;
  StreamSubscription<String>? _partialSubscription;
  bool _active = false;
  bool _starting = false;
  bool _stopping = false;
  bool _shouldRun = false;

  Future<void> start({
    required ValueChanged<String> onRecognized,
    required ValueChanged<Object> onError,
  }) async {
    _shouldRun = true;
    while (_stopping) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    if (_active || _starting) return;
    _starting = true;
    try {
      if (_model == null) {
        final modelPath = await _modelLoader.loadFromAssets(_modelAsset);
        _model = await _vosk.createModel(modelPath);
      }
      if (_recognizer == null) {
        _recognizer = await _vosk.createRecognizer(
          model: _model!,
          sampleRate: _sampleRate,
        );
      }
      if (_speechService == null) {
        _speechService = await _vosk.initSpeechService(_recognizer!);
      }
      if (!_shouldRun) return;

      final service = _speechService!;
      _resultSubscription = service.onResult().listen(
        (result) => onRecognized(_extractText(result, 'text')),
        onError: (Object error) => onError(error),
      );
      _partialSubscription = service.onPartial().listen(
        (result) => onRecognized(_extractText(result, 'partial')),
        onError: (Object error) => onError(error),
      );
      final started = await service.start(onRecognitionError: onError);
      if (!_shouldRun) {
        await service.stop();
        return;
      }
      if (started != true) {
        throw StateError('Offline voice recognition did not start.');
      }
      _active = true;
    } catch (_) {
      await _resultSubscription?.cancel();
      await _partialSubscription?.cancel();
      _resultSubscription = null;
      _partialSubscription = null;
      rethrow;
    } finally {
      _starting = false;
    }
  }

  String _extractText(String result, String key) {
    final decoded = jsonDecode(result);
    if (decoded is Map<String, dynamic>) {
      return decoded[key]?.toString() ?? '';
    }
    return '';
  }

  Future<void> stop() async {
    _shouldRun = false;
    while (_stopping) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    while (_starting) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    if (_shouldRun) return;
    if (_speechService == null) return;
    _stopping = true;
    final service = _speechService!;
    try {
      _active = false;
      try {
        await service.stop();
      } finally {
        await service.dispose();
      }
    } finally {
      _speechService = null;
      await _resultSubscription?.cancel();
      await _partialSubscription?.cancel();
      _resultSubscription = null;
      _partialSubscription = null;
      _stopping = false;
    }
  }
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
    await p.setBool('shake_enabled', false);
    await FlutterForegroundTask.stopService();
    try {
      final dir = await getApplicationDocumentsDirectory();
      dir.listSync().whereType<File>().where((f) =>
          f.path.endsWith('.m4a') || f.path.endsWith('.enc')).forEach((f) {
        try { f.deleteSync(); } catch (_) {}
      });
    } catch (_) {}
    await EvidenceStorage.clearKey();
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
    _t.awaitSpeakCompletion(true);
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
  static Future<Map<String, dynamic>> get({bool requestPermission = true}) async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return {'ok': false, 'reason': 'GPS off'};
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied && requestPermission) {
        perm = await Geolocator.requestPermission();
      }
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

class EvidenceStorage {
  static const _keyId = 'awaaz_evidence_aes256_key';
  static const _header = <int>[65, 87, 65, 90, 49];
  static const _headerLength = 5;
  static const _nonceLength = 12;
  static const _macLength = 16;
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();
  static final AesGcm _cipher = AesGcm.with256bits();

  static Future<SecretKey> _getKey() async {
    final stored = await _secureStorage.read(key: _keyId);
    if (stored != null) return SecretKey(base64Decode(stored));

    final key = await _cipher.newSecretKey();
    await _secureStorage.write(
      key: _keyId,
      value: base64Encode(await key.extractBytes()),
    );
    return key;
  }

  static Future<File> encryptFile(
    File source, {
    bool deleteSourceOnFailure = false,
  }) async {
    try {
      final secretBox = await _cipher.encrypt(
        await source.readAsBytes(),
        secretKey: await _getKey(),
      );
      final encrypted = File(
        source.path.replaceFirst(RegExp(r'\.m4a$'), '.enc'),
      );
      final output = BytesBuilder(copy: false)
        ..add(_header)
        ..add(secretBox.nonce)
        ..add(secretBox.mac.bytes)
        ..add(secretBox.cipherText);
      await encrypted.writeAsBytes(output.takeBytes(), flush: true);
      await source.delete();
      return encrypted;
    } catch (_) {
      if (deleteSourceOnFailure && await source.exists()) await source.delete();
      rethrow;
    }
  }

  static Future<File> decryptToTemporaryFile(File encrypted) async {
    final data = await encrypted.readAsBytes();
    final requiredLength = _headerLength + _nonceLength + _macLength;
    if (data.length < requiredLength ||
        !_header.asMap().entries.every((entry) => data[entry.key] == entry.value)) {
      throw const FormatException('Unknown evidence file format.');
    }
    final secretBox = SecretBox(
      data.sublist(requiredLength),
      nonce: data.sublist(_headerLength, _headerLength + _nonceLength),
      mac: Mac(data.sublist(_headerLength + _nonceLength, requiredLength)),
    );
    final plaintext = await _cipher.decrypt(
      secretBox,
      secretKey: await _getKey(),
    );
    final temp = await getTemporaryDirectory();
    final file = File(
      '${temp.path}${Platform.pathSeparator}awaaz-evidence-${DateTime.now().millisecondsSinceEpoch}.m4a',
    );
    await file.writeAsBytes(plaintext, flush: true);
    return file;
  }

  static Future<void> share(File encrypted) async {
    final plaintext = await decryptToTemporaryFile(encrypted);
    try {
      await Share.shareXFiles(
        [XFile(plaintext.path)],
        text: 'Awaaz Suraksha audio evidence',
      );
    } finally {
      if (await plaintext.exists()) await plaintext.delete();
    }
  }

  static Future<void> clearKey() => _secureStorage.delete(key: _keyId);
}

class RecordingService {
  static const maxDuration = Duration(minutes: 10);
  final AudioRecorder _r = AudioRecorder();
  String? _path;
  String? _encryptedPath;
  DateTime? _start;
  bool _recording = false;

  Future<bool> start() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final stamp = DateTime.now().toIso8601String().replaceAll(':', '-').replaceAll('.', '-').substring(0, 19);
      _path = '${dir.path}/awaaz-evidence-$stamp.m4a';
      _start = DateTime.now();
      await _r.start(const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 128000), path: _path!);
      _recording = true;
      return true;
    } on Exception catch (error) {
      await StorageService.addLog('Audio evidence recording failed: $error');
      return false;
    }
  }

  Duration get elapsed => _start != null ? DateTime.now().difference(_start!) : Duration.zero;
  Future<String?> stopAndEncrypt() async {
    if (!_recording) return _encryptedPath;
    final rawPath = await _r.stop() ?? _path;
    _recording = false;
    if (rawPath == null) return null;
    final encrypted = await EvidenceStorage.encryptFile(
      File(rawPath),
      deleteSourceOnFailure: true,
    );
    _encryptedPath = encrypted.path;
    return encrypted.path;
  }

  Future<void> cancel() async {
    if (_recording) await _r.cancel();
    _recording = false;
    final source = _path;
    if (source != null) {
      final file = File(source);
      if (await file.exists()) await file.delete();
    }
  }
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

  static String buildSmsMsg(Map<String, dynamic> loc) {
    final time = DateTime.now().toString().substring(0, 16);
    if (loc['ok'] == true) {
      final url = LocationService.mapsUrl(loc['lat'], loc['lng']);
      return 'SOS from Awaaz Suraksha. I need help. Location: $url Call 112. $time';
    }
    return 'SOS from Awaaz Suraksha. I need help. Location unavailable. Call me now or dial 112. $time';
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

  static Future<List<String>> sendSmsToContacts(
    List<Contact> contacts,
    String message,
  ) async {
    final sent = <String>[];
    for (final contact in contacts) {
      try {
        await AwaazSms.send(phoneNumber: contact.phone, message: message);
        sent.add(contact.phone);
      } on PlatformException catch (error) {
        await StorageService.addLog(
          'SMS failed for ${contact.name}: ${error.message ?? error.code}',
        );
      } on MissingPluginException catch (error) {
        await StorageService.addLog('SMS service unavailable: $error');
        break;
      }
    }
    return sent;
  }

  static String buildLiveLocationMsg(
    Map<String, dynamic> location,
    int expiresAtMillis,
    int intervalMinutes,
  ) {
    final expiry = DateTime.fromMillisecondsSinceEpoch(expiresAtMillis);
    final expires = '${expiry.hour.toString().padLeft(2, '0')}:${expiry.minute.toString().padLeft(2, '0')}';
    final url = LocationService.mapsUrl(location['lat'], location['lng']);
    return 'Awaaz Suraksha live location: $url. Updates every $intervalMinutes min until $expires. If unsafe, call 112.';
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
  bool _sosActive = false;
  bool _handlingPendingSos = false;

  final TtsService _tts = TtsService();
  final VoiceCommandService _voice = VoiceCommandService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  Future<void> _init() async {
    _settings = await AppSettings.load();
    _contacts = await StorageService.loadContacts();
    _initFg();
    await _requestPerms();
    if (_settings.voiceEnabled) await _startVoice();
    await _syncShakeService();
    if (mounted) {
      setState(() { _loading = false; });
      await _handlePendingBackgroundSOS();
      await _handlePendingTileSOS();
    }
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
        channelDescription: 'Shake three times quickly to trigger an SOS alert.',
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
    if (data is Map && data['command'] == 'background_sos' && mounted) {
      _handlePendingBackgroundSOS();
    }
  }

  Future<void> _handlePendingBackgroundSOS() async {
    if (_handlingPendingSos || _sosActive || !mounted) return;
    _handlingPendingSos = true;
    try {
      final p = await SharedPreferences.getInstance();
      if (!(p.getBool('pending_background_sos') ?? false)) return;
      final reason = p.getString('pending_sos_reason') ?? 'Shake to SOS';
      final smsAttempted = p.getBool('background_sos_sms_attempted') ?? false;
      await p.remove('pending_background_sos');
      await p.remove('pending_sos_reason');
      if (mounted) {
        await _triggerSOS(source: reason, backgroundSmsAttempted: smsAttempted);
      }
    } finally {
      _handlingPendingSos = false;
    }
  }

  Future<void> _handlePendingTileSOS() async {
    final p = await SharedPreferences.getInstance();
    if (!(p.getBool('tile_sos_pending') ?? false)) return;
    await p.remove('tile_sos_pending');
    if (mounted) await _triggerSOS(source: 'Quick Settings SOS');
  }

  Future<void> _startBgService() async {
    if (await FlutterForegroundTask.isRunningService) {
      if (mounted) setState(() => _serviceRunning = true);
      return;
    }
    if (!(await Permission.locationWhenInUse.status).isGranted) {
      if (mounted) {
        setState(() {
          _serviceRunning = false;
          _transcript = 'Location permission is needed for the background safety service';
        });
      }
      return;
    }
    final p = await SharedPreferences.getInstance();
    final now = DateTime.now().millisecondsSinceEpoch;
    final liveUntil = p.getInt('live_share_until_ms') ?? 0;
    final checkinUntil = p.getInt('checkin_deadline_ms') ?? 0;
    final title = liveUntil > now
        ? 'Live location sharing active'
        : checkinUntil > now ? 'Safety check-in armed' : '🛡️ Awaaz Suraksha Active';
    final text = liveUntil > now
        ? 'Sending location updates until ${DateTime.fromMillisecondsSinceEpoch(liveUntil).toLocal()}'
        : checkinUntil > now
            ? 'Your check-in timer is running; disarm when safe.'
            : 'Shake three times quickly to trigger an SOS alert.';
    await FlutterForegroundTask.startService(
      serviceId: 1001,
      notificationTitle: title,
      notificationText: text,
      callback: startCallback,
    );
    if (mounted) setState(() => _serviceRunning = true);
  }

  Future<void> _stopBgService() async {
    await FlutterForegroundTask.stopService();
    if (mounted) setState(() => _serviceRunning = false);
  }

  Future<void> _syncShakeService({bool restart = false}) async {
    final p = await SharedPreferences.getInstance();
    final now = DateTime.now().millisecondsSinceEpoch;
    final checkinActive = (p.getInt('checkin_deadline_ms') ?? 0) > now;
    final liveShareActive = (p.getInt('live_share_until_ms') ?? 0) > now;
    if (!_settings.shakeEnabled && !checkinActive && !liveShareActive) {
      await _stopBgService();
      return;
    }
    if (restart && await FlutterForegroundTask.isRunningService) {
      await _stopBgService();
    }
    await _startBgService();
  }

  Future<void> _startVoice() async {
    if (!_settings.voiceEnabled ||
        _sosActive ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    try {
      await _voice.start(
        onRecognized: _handleVoiceText,
        onError: (error) {
          if (mounted) setState(() {
            _micOk = false;
            _transcript = 'Voice recognition error: $error';
          });
        },
      );
      if (mounted) setState(() {
        _micOk = true;
        _transcript = '🎙 Listening for "${_settings.wakeWord}"…';
      });
    } on MicrophoneAccessDeniedException {
      if (mounted) setState(() {
        _micOk = false;
        _transcript = 'Mic permission denied — tap "Grant Mic"';
      });
    } on PlatformException catch (error) {
      if (mounted) setState(() {
        _micOk = false;
        _transcript = 'Mic error: ${error.message ?? error.code}';
      });
    } on Exception catch (error) {
      if (mounted) setState(() {
        _micOk = false;
        _transcript = 'Voice setup failed: $error';
      });
    }
  }

  void _handleVoiceText(String text) {
    if (!mounted ||
        _sosActive ||
        !_settings.voiceEnabled ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed ||
        text.trim().isEmpty) {
      return;
    }
    setState(() => _transcript = '🎙 Heard: $text');
    final normalized = text.toLowerCase();
    final custom = RegExp(RegExp.escape(_settings.wakeWord.toLowerCase()));
    final builtIn = RegExp(r'(help\s+me\s+now|bachao|बचाओ|help\s+me|emergency)');
    if (custom.hasMatch(normalized) || builtIn.hasMatch(normalized)) {
      unawaited(_triggerSOS(source: 'Voice Trigger'));
    }
  }

  Future<void> _triggerSOS({
    required String source,
    bool forceSilent = false,
    bool backgroundSmsAttempted = false,
  }) async {
    if (!mounted) return;
    if (_sosActive) return;
    _sosActive = true;
    if (!backgroundSmsAttempted) {
      final p = await SharedPreferences.getInstance();
      await p.remove('background_sos_sms_attempted');
      await p.remove('background_sos_sms_sent_contacts');
    }
    HapticFeedback.heavyImpact();
    _tts.setMuted(forceSilent || _settings.silentMode);
    StorageService.addLog('SOS triggered: $source');
    await _voice.stop();
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SosActiveScreen(
        contacts: List.from(_contacts),
        isDemo: _settings.demoMode,
        isSilent: forceSilent || _settings.silentMode,
        sirenEnabled: _settings.sirenEnabled && !(forceSilent || _settings.silentMode),
        smsAlertsEnabled: _settings.smsAlertsEnabled,
        evidenceEnabled: _settings.evidenceEnabled,
        source: source,
        tts: _tts,
        voice: _voice,
        onDeactivated: () {
          _sosActive = false;
          _tts.setMuted(false);
          if (_settings.voiceEnabled && mounted) _startVoice();
          if (mounted) _syncShakeService(restart: true);
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
    await _voice.stop();
    if (_settings.voiceEnabled) await _startVoice();
    await _syncShakeService(restart: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      _handlePendingBackgroundSOS();
      _handlePendingTileSOS();
      if (_settings.voiceEnabled) _startVoice();
      AppSettings.load().then((s) { if (mounted) setState(() => _settings = s); });
      StorageService.loadContacts().then((c) { if (mounted) setState(() => _contacts = c); });
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      unawaited(_voice.stop());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_voice.stop());
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
        onSOS: () => unawaited(_triggerSOS(source: 'SOS Button')),
        onDemoSOS: () => unawaited(_triggerSOS(source: 'Test SOS (Demo)')),
        onGrantMic: _grantMic, onGrantGps: _grantGps,
        onToggleVoice: (v) async {
          _settings.voiceEnabled = v; await _settings.save(); setState(() {});
          if (v) { await _startVoice(); } else { await _voice.stop(); }
        },
        onToggleSilent: (v) async { _settings.silentMode = v; await _settings.save(); setState(() {}); },
        onToggleSiren: (v) async { _settings.sirenEnabled = v; await _settings.save(); setState(() {}); },
        onToggleShake: (v) async {
          _settings.shakeEnabled = v; await _settings.save(); setState(() {});
          await _syncShakeService(restart: true);
        },
        onShowFakeCall: (name) => Navigator.push(context, MaterialPageRoute(
            builder: (_) => FakeCallScreen(callerName: name), fullscreenDialog: true)),
      ),
      const _VaultTab(),
      _ToolsTab(
        settings: _settings,
        contacts: _contacts,
        onBackgroundMonitorChanged: () => _syncShakeService(restart: true),
        onFakeCall: (name) => Navigator.push(context, MaterialPageRoute(
            builder: (_) => FakeCallScreen(callerName: name), fullscreenDialog: true)),
        onCheckinExpired: () => unawaited(_triggerSOS(source: 'Check-in Timer Expired')),
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
            onLongPress: () => unawaited(_triggerSOS(source: 'Long-press logo', forceSilent: true)),
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
            _tRow(Icons.record_voice_over, 'Voice Wake Word', 'Listen while Awaaz Suraksha is open', settings.voiceEnabled, onToggleVoice),
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
            _iRow('⚙️', 'Tap ⚙ (top-right) to change the wake phrase & safety settings'),
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
    final recs = dir.listSync().whereType<File>().where((f) =>
        f.path.endsWith('.m4a') || f.path.endsWith('.enc')).toList()
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
          if (_recs.isEmpty) _empty('No evidence yet.\nRecording is off unless you opt in under Settings.'),
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
    final encrypted = f.path.endsWith('.enc');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: _kCard, border: Border.all(color: _kBorder), borderRadius: BorderRadius.circular(8)),
      child: Row(children: [
        Icon(encrypted ? Icons.lock : Icons.warning_amber, color: encrypted ? _kGreen : _kAmber, size: 24),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name, style: const TextStyle(fontSize: 12, color: _kText, fontFamily: 'monospace'),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          Text(
            encrypted ? '$sizeKb KB • AES-GCM encrypted' : '$sizeKb KB • legacy unencrypted',
            style: const TextStyle(fontSize: 11, color: _kMuted),
          ),
        ])),
        if (encrypted)
          IconButton(
            icon: const Icon(Icons.share, color: _kGreen, size: 20),
            tooltip: 'Decrypt temporarily and share',
            onPressed: () async {
              try {
                await EvidenceStorage.share(f);
              } on Exception catch (error) {
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Could not share evidence: $error')),
                );
              }
            },
          ),
        if (!encrypted)
          IconButton(
            icon: const Icon(Icons.lock, color: _kAmber, size: 20),
            tooltip: 'Encrypt legacy recording',
            onPressed: () async {
              try {
                await EvidenceStorage.encryptFile(f);
                await _load();
              } on Exception catch (error) {
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Could not encrypt recording: $error')),
                );
              }
            },
          ),
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
  final List<Contact> contacts;
  final Future<void> Function() onBackgroundMonitorChanged;
  final Function(String) onFakeCall;
  final VoidCallback onCheckinExpired;
  const _ToolsTab({
    required this.settings,
    required this.contacts,
    required this.onBackgroundMonitorChanged,
    required this.onFakeCall,
    required this.onCheckinExpired,
  });
  @override State<_ToolsTab> createState() => _ToolsTabState();
}

class _ToolsTabState extends State<_ToolsTab> {
  bool _armed = false;
  bool _liveShareActive = false;
  Timer? _timer;
  Duration _remaining = Duration.zero;
  int _checkinDeadlineMs = 0;
  int _liveShareUntilMs = 0;
  String _liveShareStatus = '';
  String _caller = 'Maa';
  int _delay = 0;
  final _callerOpts = ['Maa', 'Dad', 'Didi', 'Bhai', 'Friend', '112 Control Room'];

  @override
  void initState() {
    super.initState();
    _restoreTimers();
  }

  @override
  void dispose() { _timer?.cancel(); super.dispose(); }

  Future<void> _restoreTimers() async {
    final p = await SharedPreferences.getInstance();
    final now = DateTime.now().millisecondsSinceEpoch;
    final checkinDeadline = p.getInt('checkin_deadline_ms') ?? 0;
    final shareUntil = p.getInt('live_share_until_ms') ?? 0;
    if (checkinDeadline > now) {
      _checkinDeadlineMs = checkinDeadline;
      _armed = true;
      _remaining = Duration(milliseconds: checkinDeadline - now);
    } else if (checkinDeadline > 0) {
      await p.remove('checkin_deadline_ms');
      if (!(p.getBool('pending_background_sos') ?? false)) {
        widget.onCheckinExpired();
      }
    }
    if (shareUntil > now) {
      _liveShareUntilMs = shareUntil;
      _liveShareActive = true;
      _liveShareStatus = 'Live updates are active';
    }
    if (mounted) setState(() {});
    if (_armed || _liveShareActive) _startDisplayTimer();
  }

  void _startDisplayTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (_armed) {
        final seconds = ((_checkinDeadlineMs - now) / 1000).ceil();
        if (seconds <= 0) {
          setState(() {
            _armed = false;
            _remaining = Duration.zero;
          });
        } else {
          setState(() => _remaining = Duration(seconds: seconds));
        }
      }
      if (_liveShareActive) {
        if (now >= _liveShareUntilMs) {
          _liveShareActive = false;
          _liveShareStatus = 'Location sharing ended';
        } else {
          _liveShareStatus =
              'Active — ${_fmt(Duration(milliseconds: _liveShareUntilMs - now))} remaining';
        }
        setState(() {});
      }
      if (!_armed && !_liveShareActive) _timer?.cancel();
    });
  }

  Future<void> _arm() async {
    final locationPermission = await Permission.locationWhenInUse.request();
    if (!locationPermission.isGranted) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Location permission is needed for background check-in alerts.')),
      );
      return;
    }
    final deadline = DateTime.now()
        .add(Duration(minutes: widget.settings.checkinMinutes))
        .millisecondsSinceEpoch;
    final p = await SharedPreferences.getInstance();
    await p.setInt('checkin_deadline_ms', deadline);
    setState(() {
      _checkinDeadlineMs = deadline;
      _remaining = Duration(minutes: widget.settings.checkinMinutes);
      _armed = true;
    });
    _startDisplayTimer();
    try {
      await widget.onBackgroundMonitorChanged();
    } on Exception catch (error) {
      await p.remove('checkin_deadline_ms');
      if (mounted) {
        setState(() {
          _armed = false;
          _remaining = Duration.zero;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not start background monitoring: $error')),
        );
      }
      return;
    }
    await StorageService.addLog('Check-in timer armed');
  }

  Future<void> _disarm() async {
    final p = await SharedPreferences.getInstance();
    await p.remove('checkin_deadline_ms');
    _timer?.cancel();
    setState(() {
      _armed = false;
      _remaining = Duration.zero;
    });
    if (_liveShareActive) _startDisplayTimer();
    await widget.onBackgroundMonitorChanged();
    StorageService.addLog('Check-in disarmed — user confirmed safe');
  }

  Future<void> _startLiveShare() async {
    if (widget.settings.demoMode) {
      setState(() => _liveShareStatus = 'Turn off Demo Mode before sending real SMS updates');
      return;
    }
    if (!widget.settings.smsAlertsEnabled) {
      setState(() => _liveShareStatus = 'Enable automatic SMS in Settings first');
      return;
    }
    if (widget.contacts.isEmpty) {
      setState(() => _liveShareStatus = 'Add a trusted contact before sharing');
      return;
    }
    final smsPermission = await Permission.sms.request();
    if (!smsPermission.isGranted) {
      setState(() => _liveShareStatus = 'SMS permission is required');
      return;
    }
    final foregroundLocation = await Permission.locationWhenInUse.request();
    if (!foregroundLocation.isGranted) {
      setState(() => _liveShareStatus = 'Location permission is required');
      return;
    }
    final backgroundLocation = await Permission.locationAlways.request();
    if (!backgroundLocation.isGranted) {
      setState(() => _liveShareStatus =
          'Allow location all the time in Android settings to share in background');
      final openSettings = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: _kCard,
          title: const Text('Background location needed', style: TextStyle(color: _kText)),
          content: const Text(
            'Android requires “Allow all the time” for location updates after you leave the app. You can enable it in App permissions.',
            style: TextStyle(color: _kMuted),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Not now')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Open settings')),
          ],
        ),
      );
      if (openSettings == true) await openAppSettings();
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _kCard,
        title: const Text('Start live location sharing?', style: TextStyle(color: _kText)),
        content: Text(
          'Awaaz Suraksha will text your ${widget.contacts.length} trusted contact(s) now, then every ${widget.settings.liveShareIntervalMinutes} minutes for ${widget.settings.liveShareMinutes} minutes. SMS and carrier charges may apply.',
          style: const TextStyle(color: _kMuted),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Start sharing')),
        ],
      ),
    );
    if (confirm != true) return;

    final location = await LocationService.get();
    if (location['ok'] != true) {
      setState(() => _liveShareStatus = 'Location unavailable: ${location['reason']}');
      return;
    }

    final now = DateTime.now();
    final until = now.add(Duration(minutes: widget.settings.liveShareMinutes));
    final p = await SharedPreferences.getInstance();
    await p.setInt('live_share_until_ms', until.millisecondsSinceEpoch);
    await p.setInt('live_share_interval_ms', widget.settings.liveShareIntervalMinutes * 60000);
    await p.setInt('live_share_last_update_ms', now.millisecondsSinceEpoch);
    try {
      await widget.onBackgroundMonitorChanged();
    } on Exception catch (error) {
      await p.remove('live_share_until_ms');
      await p.remove('live_share_interval_ms');
      await p.remove('live_share_last_update_ms');
      if (mounted) setState(() => _liveShareStatus = 'Could not start background sharing: $error');
      return;
    }

    final sent = await AlertService.sendSmsToContacts(
      widget.contacts,
      AlertService.buildLiveLocationMsg(
        location,
        until.millisecondsSinceEpoch,
        widget.settings.liveShareIntervalMinutes,
      ),
    );
    if (sent.isEmpty) {
      await _stopLiveShare(showStatus: false);
      setState(() => _liveShareStatus = 'Could not send the first location SMS');
      return;
    }
    setState(() {
      _liveShareUntilMs = until.millisecondsSinceEpoch;
      _liveShareActive = true;
      _liveShareStatus = 'Updates sent to ${sent.length}/${widget.contacts.length} contact(s)';
    });
    _startDisplayTimer();
    await StorageService.addLog('Live location sharing started for ${widget.settings.liveShareMinutes} minutes');
  }

  Future<void> _stopLiveShare({bool showStatus = true}) async {
    final p = await SharedPreferences.getInstance();
    await p.remove('live_share_until_ms');
    await p.remove('live_share_interval_ms');
    await p.remove('live_share_last_update_ms');
    setState(() {
      _liveShareActive = false;
      _liveShareUntilMs = 0;
      if (showStatus) _liveShareStatus = 'Location sharing stopped';
    });
    if (_armed) _startDisplayTimer(); else _timer?.cancel();
    await widget.onBackgroundMonitorChanged();
    await StorageService.addLog('Live location sharing stopped');
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

        _secTitle('📍 Live Location Share'),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _kCard,
            border: Border.all(color: _liveShareActive ? _kGreen : _kBorder),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              'Text your location every ${widget.settings.liveShareIntervalMinutes} minutes for ${widget.settings.liveShareMinutes} minutes.',
              style: const TextStyle(fontSize: 13, color: _kMuted),
            ),
            const SizedBox(height: 6),
            const Text(
              'Requires automatic SMS and Android “Allow all the time” location permission. Carrier charges may apply.',
              style: TextStyle(fontSize: 11, color: _kMuted),
            ),
            if (_liveShareStatus.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(_liveShareStatus, style: TextStyle(
                fontSize: 12,
                color: _liveShareActive ? _kGreen : _kAmber,
              )),
            ],
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _liveShareActive ? _stopLiveShare : _startLiveShare,
                icon: Icon(_liveShareActive ? Icons.stop_circle : Icons.location_on),
                label: Text(_liveShareActive ? 'STOP LIVE SHARING' : 'START LIVE SHARING'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _liveShareActive ? _kMuted : _kGreen,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
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
          const Text('Receives an SMS if enabled, and WhatsApp can be opened as a fallback.', style: TextStyle(fontSize: 12, color: _kMuted)),
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
              const Text('Add up to 5 trusted contacts.\nThey can receive SOS SMS and WhatsApp alerts.',
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
    'English (India; offline)': 'en_IN',
  };

  @override
  void initState() {
    super.initState();
    _s = widget.settings.copy();
    _s.languageLabel = 'English (India; offline)';
    _s.localeId = 'en_IN';
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
            const Text('Offline Speech Model', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: _kText)),
            const SizedBox(height: 4),
            const Text('Uses an Indian-English model locally. Hindi words such as “Bachao” may be less reliable.', style: TextStyle(fontSize: 12, color: _kMuted)),
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
            _tog('Voice Wake Word', 'Listen for wake word while the app is open', _s.voiceEnabled, (v) => setState(() => _s.voiceEnabled = v)),
            const Divider(color: _kBorder, height: 1),
            _tog('Shake to SOS', '3 strong shakes within 1.5s', _s.shakeEnabled, (v) => setState(() => _s.shakeEnabled = v)),
            const Divider(color: _kBorder, height: 1),
            _tog('SOS Siren (Audio + Haptic)', 'Loud "ALERT!" alarm + triple haptic vibration', _s.sirenEnabled, (v) => setState(() => _s.sirenEnabled = v)),
            const Divider(color: _kBorder, height: 1),
            _tog('Silent SOS Mode', 'No sound — stealth alert only', _s.silentMode, (v) => setState(() => _s.silentMode = v)),
            const Divider(color: _kBorder, height: 1),
            _tog('Demo Mode', 'Test SOS without sending real alerts', _s.demoMode, (v) => setState(() => _s.demoMode = v)),
            const Divider(color: _kBorder, height: 1),
            _tog(
              'Automatic emergency SMS',
              'Send SOS and live-location texts to trusted contacts. Carrier charges may apply; messages are never read.',
              _s.smsAlertsEnabled,
              (v) async {
                if (v) {
                  final permission = await Permission.sms.request();
                  if (!permission.isGranted) {
                    if (mounted) ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('SMS permission is needed for automatic alerts.')),
                    );
                    return;
                  }
                }
                setState(() => _s.smsAlertsEnabled = v);
              },
            ),
            const Divider(color: _kBorder, height: 1),
            _tog(
              'Encrypted audio evidence',
              'Opt in to record during SOS. Files are AES-GCM encrypted on this device.',
              _s.evidenceEnabled,
              (v) => setState(() => _s.evidenceEnabled = v),
            ),
          ]),
          const SizedBox(height: 16),

          _hdr('📍 Live Location Share'),
          _card([Padding(padding: const EdgeInsets.fromLTRB(14, 14, 14, 10), child: Column(children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              const Text('Share for', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: _kText)),
              Text('${_s.liveShareMinutes} minutes', style: const TextStyle(fontSize: 13, color: _kGreen, fontWeight: FontWeight.bold)),
            ]),
            Slider(
              value: _s.liveShareMinutes.toDouble(),
              min: 15,
              max: 60,
              divisions: 3,
              activeColor: _kRed,
              inactiveColor: _kBorder,
              onChanged: (v) => setState(() => _s.liveShareMinutes = v.round()),
            ),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              const Text('15 min', style: TextStyle(fontSize: 11, color: _kMuted)),
              Text('Update every ${_s.liveShareIntervalMinutes} min', style: const TextStyle(fontSize: 13, color: _kText)),
              const Text('60 min', style: TextStyle(fontSize: 11, color: _kMuted)),
            ]),
            Slider(
              value: _s.liveShareIntervalMinutes.toDouble(),
              min: 5,
              max: 15,
              divisions: 2,
              activeColor: _kGreen,
              inactiveColor: _kBorder,
              onChanged: (v) => setState(() => _s.liveShareIntervalMinutes = v.round()),
            ),
          ]))]),
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
              subtitle: const Text('Delete contacts, logs, encrypted recordings, and their key', style: TextStyle(color: _kMuted, fontSize: 12)),
              onTap: () => showDialog(context: context, builder: (_) => AlertDialog(
                backgroundColor: _kCard,
                title: const Text('⚠️ Wipe All Data?', style: TextStyle(color: _kText)),
                content: const Text('Permanently deletes all contacts, incident logs, encrypted audio recordings, and the encryption key. Cannot be undone.',
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
  final bool isDemo, isSilent, sirenEnabled, smsAlertsEnabled, evidenceEnabled;
  final String source;
  final TtsService tts;
  final VoiceCommandService voice;
  final VoidCallback onDeactivated;

  const SosActiveScreen({
    super.key,
    required this.contacts, required this.isDemo, required this.isSilent,
    required this.sirenEnabled, required this.smsAlertsEnabled,
    required this.evidenceEnabled, required this.source, required this.tts,
    required this.voice, required this.onDeactivated,
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
    if (widget.sirenEnabled) _siren.start();
  }

  void _startCountdown() {
    unawaited(widget.tts
        .speak('Awaaz Suraksha SOS activated. Sending alert in 5 seconds. Say I\'m safe to cancel.')
        .then((_) {
      if (!_cancelled && !_dispatched) _startVoiceCancel();
    }));
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
    await widget.voice.stop();
    await widget.tts.speak('Alerting your contacts now. Stay calm. Help is on the way.');

    if (widget.evidenceEnabled) {
      if (mounted) setState(() => _recStatus = 'Starting encrypted recording…');
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
          if (_rec.elapsed >= RecordingService.maxDuration) {
            _recTimer?.cancel();
            _stopEvidenceAtLimit();
          }
        });
      } else {
        if (mounted) setState(() => _recStatus = '⚠ Recording unavailable');
      }
    } else {
      if (mounted) setState(() => _recStatus = 'Evidence recording is off');
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
      final smsMsg = AlertService.buildSmsMsg(loc);
      final prefs = await SharedPreferences.getInstance();
      final backgroundAttempted = prefs.getBool('background_sos_sms_attempted') ?? false;
      final backgroundSent = prefs.getStringList('background_sos_sms_sent_contacts') ?? [];
      await prefs.remove('background_sos_sms_attempted');
      await prefs.remove('background_sos_sms_sent_contacts');
      int smsQueued = 0;
      int whatsappOpened = 0;
      for (final c in widget.contacts) {
        var smsOk = false;
        if (widget.smsAlertsEnabled) {
          if (backgroundAttempted && backgroundSent.contains(c.phone)) {
            smsOk = true;
          } else {
            smsOk = (await AlertService.sendSmsToContacts([c], smsMsg)).contains(c.phone);
          }
        }
        if (smsOk) {
          smsQueued++;
        } else if (await AlertService.whatsapp(c, msg)) {
          whatsappOpened++;
        }
        await Future.delayed(const Duration(milliseconds: 600));
      }
      if (mounted) setState(() {
        if (widget.contacts.isEmpty) {
          _alertStatus = '⚠ No contacts — dial 112!';
        } else if (smsQueued > 0) {
          _alertStatus = '✅ SMS queued for $smsQueued/${widget.contacts.length}; WhatsApp opened for $whatsappOpened';
        } else if (whatsappOpened > 0) {
          _alertStatus = 'WhatsApp opened for $whatsappOpened/${widget.contacts.length}; tap Send';
        } else {
          _alertStatus = '⚠ Alerts could not be opened — tap Call below';
        }
      });
    }
  }

  Future<void> _stopEvidenceAtLimit() async {
    try {
      final savedPath = await _rec.stopAndEncrypt();
      if (mounted) setState(() => _recStatus =
          savedPath == null ? 'Recording stopped' : '🔒 Encrypted recording saved (10 min limit)');
    } on Exception catch (error) {
      if (mounted) setState(() => _recStatus = 'Evidence encryption failed: $error');
    }
  }

  void _startVoiceCancel() async {
    try {
      await widget.voice.start(
        onRecognized: (text) {
          if (RegExp(r"(i'?m\s+safe|i\s+am\s+safe|cancel\s+sos|safe\s+now|im\s+safe)")
              .hasMatch(text.toLowerCase())) {
            unawaited(_deactivate('Voice: "I\'m safe"'));
          }
        },
        onError: (error) {
          if (mounted) setState(() => _alertStatus = 'Voice recognition error: $error');
        },
      );
    } on Exception catch (error) {
      if (mounted) setState(() => _alertStatus = 'Voice cancellation unavailable: $error');
    }
  }

  Future<void> _deactivate(String reason) async {
    if (_cancelled) return;
    _cancelled = true;
    _siren.stop();
    _cdTimer?.cancel();
    _recTimer?.cancel();
    await widget.voice.stop();
    await widget.tts.stop();

    if (_dispatched) {
      String? savedPath;
      if (widget.evidenceEnabled) {
        try {
          savedPath = await _rec.stopAndEncrypt();
        } on Exception catch (error) {
          await StorageService.addLog('Evidence encryption failed: $error');
          if (mounted) setState(() => _recStatus = 'Evidence encryption failed');
        }
      }
      if (!widget.isSilent) await widget.tts.speak('Awaaz Suraksha deactivated. You are safe now.');
      await StorageService.addLog('SOS deactivated by: $reason');
      if (mounted && savedPath != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: _kCard,
          content: Text('Encrypted audio evidence saved:\n$savedPath', style: const TextStyle(color: _kText, fontSize: 12)),
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
    _pulseCtrl.dispose(); _bgCtrl.dispose();
    if (!_cancelled) unawaited(widget.voice.stop());
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
