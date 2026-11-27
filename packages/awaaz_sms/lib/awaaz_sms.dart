import 'package:flutter/services.dart';

class AwaazSms {
  static const MethodChannel _channel = MethodChannel('com.awaaz.sos/sms');

  static Future<void> send({
    required String phoneNumber,
    required String message,
  }) async {
    await _channel.invokeMethod<void>('send', {
      'phoneNumber': phoneNumber,
      'message': message,
    });
  }
}
