import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

class AppPin {
  static const prefix = 'argon2id-v1';
  static final _random = Random.secure();

  static Future<String> hash(String pin) async {
    final salt = List<int>.generate(16, (_) => _random.nextInt(256));
    final digest = await _derive(pin, salt);
    return '$prefix:${base64Encode(salt)}:${base64Encode(digest)}';
  }

  static Future<bool> matches(String pin, String verifier) async {
    final fields = verifier.split(':');
    if (fields.length != 3 || fields.first != prefix) {
      return false;
    }
    try {
      final salt = base64Decode(fields[1]);
      final expected = base64Decode(fields[2]);
      if (salt.length != 16 || expected.length != 32) {
        return false;
      }
      final digest = await _derive(pin, salt);
      int mismatch = 0;
      for (int i = 0; i < digest.length; i++) {
        mismatch |= digest[i] ^ expected[i];
      }
      return mismatch == 0;
    } on FormatException {
      return false;
    }
  }

  static Future<List<int>> _derive(String pin, List<int> salt) {
    return compute(_argon2id, (pin, salt));
  }

  static Future<List<int>> _argon2id((String, List<int>) input) async {
    final algorithm = Argon2id(parallelism: 1, memory: 19456, iterations: 2, hashLength: 32);
    final key = await algorithm.deriveKey(secretKey: SecretKey(utf8.encode(input.$1)), nonce: input.$2);
    return key.extractBytes();
  }
}
