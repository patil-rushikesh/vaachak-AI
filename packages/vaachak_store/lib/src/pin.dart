import 'dart:convert';
import 'package:cryptography/cryptography.dart';

class PinHasher {
  static final _algorithm = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: 210000,
    bits: 256,
  );
  Future<String> hash(String pin, List<int> salt) async {
    if (!RegExp(r'^\d{6,12}$').hasMatch(pin) || salt.length < 16) {
      throw ArgumentError('Use a 6–12 digit PIN and a 16-byte salt');
    }
    final key = await _algorithm.deriveKey(
      secretKey: SecretKey(utf8.encode(pin)),
      nonce: salt,
    );
    return base64Encode(await key.extractBytes());
  }

  Future<bool> verify(String pin, List<int> salt, String expected) async {
    if (!RegExp(r'^\d{6,12}$').hasMatch(pin)) {
      return false;
    }
    final actual = base64Decode(await hash(pin, salt)),
        wanted = base64Decode(expected);
    var difference = actual.length ^ wanted.length;
    for (var i = 0; i < actual.length && i < wanted.length; i++) {
      difference |= actual[i] ^ wanted[i];
    }
    return difference == 0;
  }
}
