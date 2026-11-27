import 'package:flutter_test/flutter_test.dart';

import 'package:awaaz_sos/main.dart';

void main() {
  group('trusted contact serialization', () {
    test('JSON round-trip preserves delimiter text in a name', () {
      final original = Contact(name: 'Maa|||Home', phone: '+919876543210');

      final restored = Contact.tryParse(original.serialize());

      expect(restored?.name, original.name);
      expect(restored?.phone, original.phone);
    });

    test('valid legacy contacts are normalized for migration', () {
      final restored = Contact.tryParse('Maa|||+91 98765 43210');

      expect(restored?.name, 'Maa');
      expect(restored?.phone, '+919876543210');
    });

    test('legacy delimiter injection cannot supply an alternate number', () {
      final restored = Contact.tryParse('Trusted|||Attacker|||+919876543210');

      expect(restored, isNull);
    });

    test('invalid destination numbers are rejected', () {
      expect(
        Contact.tryParse('{"name":"Maa","phone":"+910000000000"}'),
        isNull,
      );
    });
  });

  test('contact test message is unmistakable and contains no location', () {
    final message = AlertService.buildTestMsg().toLowerCase();

    expect(message, contains('test only'));
    expect(message, contains('not an emergency'));
    expect(message, isNot(contains('http')));
    expect(message, isNot(contains('location')));
  });

  test('contact test alerts are disabled by default', () {
    expect(AppSettings().contactTestAlertsEnabled, isFalse);
  });
}
