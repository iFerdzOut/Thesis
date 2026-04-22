import 'dart:convert';
import 'dart:math';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:basic_utils/basic_utils.dart';
import 'package:pointycastle/api.dart' as pc;
import 'package:pointycastle/asymmetric/api.dart' as pc_rsa;
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/key_derivators/pbkdf2.dart';
import 'package:pointycastle/key_derivators/api.dart' as pc_kdf;
import 'package:pointycastle/key_generators/api.dart' as pc_keygen;
import 'package:pointycastle/key_generators/rsa_key_generator.dart' as pc_rsa_gen;
import 'package:pointycastle/macs/hmac.dart';
import 'package:pointycastle/random/fortuna_random.dart';

// ignore_for_file: extra_positional_arguments_could_be_named, argument_type_not_assignable

class SecurityService {
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();
  static const String _privateKeyStorageKey = 'hybrid_rsa_private_key';
  static const String _publicKeyStorageKey = 'hybrid_rsa_public_key';

  bool _looksLikePem(String value, {required String marker}) {
    final trimmed = value.trimLeft();
    return trimmed.startsWith('-----BEGIN') && trimmed.contains(marker);
  }

  bool _isValidRsaPublicKeyPem(String pem) {
    if (!_looksLikePem(pem, marker: 'PUBLIC KEY-----')) return false;
    try {
      final parsed = encrypt.RSAKeyParser().parse(pem);
      return parsed is pc_rsa.RSAPublicKey;
    } catch (_) {
      return false;
    }
  }

  bool _isValidRsaPrivateKeyPem(String pem) {
    if (!_looksLikePem(pem, marker: 'PRIVATE KEY-----')) return false;
    try {
      final parsed = encrypt.RSAKeyParser().parse(pem);
      return parsed is pc_rsa.RSAPrivateKey;
    } catch (_) {
      return false;
    }
  }

  /// Generates a 2048-bit RSA Key Pair, stores the private key securely,
  /// and creates a PIN-encrypted backup blob of the private key.
  Future<Map<String, String>> generateAndBackupKeyPair({
    required String pin,
    required String salt,
  }) async {
    try {
      if (pin.length != 6) throw Exception('PIN must be exactly 6 digits.');

      // Offload heavy key generation to a background isolate
      final keyPairMap = await compute(_generateRSAKeyPairIsolated, null);

      final privateKeyPEM = keyPairMap['private']!;
      final publicKeyPEM = keyPairMap['public']!;

      // Offload PBKDF2 derivation and AES encryption of the private key
      final recoveryBlob = await compute(_deriveAndEncryptPrivateKeyIsolated, {
        'pin': pin,
        'salt': salt,
        'privateKeyPEM': privateKeyPEM,
      });

      // Store locally
      await _secureStorage.write(key: _privateKeyStorageKey, value: privateKeyPEM);
      await _secureStorage.write(key: _publicKeyStorageKey, value: publicKeyPEM);

      return {
        'publicKey': publicKeyPEM,
        'recoveryBlob': recoveryBlob,
      };
    } catch (e) {
      debugPrint('[SecurityService] Key generation/backup failed: $e');
      throw Exception('Failed to generate and backup security keys.');
    }
  }

  /// Recovers the RSA Private Key from the cloud backup blob using the user's PIN.
  Future<void> recoverPrivateKey({
    required String pin,
    required String salt,
    required String encryptedBlob,
  }) async {
    try {
      if (pin.length != 6) throw Exception('PIN must be exactly 6 digits.');

      // Offload heavy PBKDF2 derivation and decryption
      final privateKeyPEM = await compute(_deriveAndDecryptPrivateKeyIsolated, {
        'pin': pin,
        'salt': salt,
        'encryptedBlob': encryptedBlob,
      });

      // Store the recovered key locally
      await _secureStorage.write(key: _privateKeyStorageKey, value: privateKeyPEM);
    } catch (e) {
      debugPrint('[SecurityService] Key recovery failed: $e');
      throw Exception('Failed to recover private key. Ensure your PIN is correct.');
    }
  }

  /// Encrypts a message using a generated AES key, then encrypts the AES key
  /// using the recipient's RSA Public Key.
  Future<Map<String, dynamic>> encryptMessage(String plainText, String recipientPublicKeyPEM) async {
    try {
      if (plainText.isEmpty) throw Exception('Cannot encrypt an empty message.');
      
      // STEP 2: Validate RSA Key Format
      if (!recipientPublicKeyPEM.contains('PUBLIC KEY-----')) {
        debugPrint('[SecurityService] ERROR: Invalid RSA Public Key format.');
        debugPrint('[SecurityService] Key received: $recipientPublicKeyPEM');
        throw const FormatException('Unable to parse key: Missing PEM headers (BEGIN/END PUBLIC KEY)');
      }

      // Generate random AES Key and IV
      final aesKey = encrypt.Key.fromSecureRandom(32); // 256-bit AES Key
      final iv = encrypt.IV.fromSecureRandom(16);      // 128-bit IV

      // Encrypt the plaintext with AES-256-CBC
      final encrypter = encrypt.Encrypter(encrypt.AES(aesKey, mode: encrypt.AESMode.cbc));
      final encryptedText = encrypter.encrypt(plainText, iv: iv);

      // Offload the RSA encryption of the AES key to a background isolate
      final encryptedAesKeyBase64 = await compute(_rsaEncryptIsolated, {
        'aesKeyBytes': aesKey.bytes,
        'publicKeyPEM': recipientPublicKeyPEM,
      });

      // Prefer Firestore field naming: cipherText/encrypted_aes_key/iv.
      // Keep legacy aliases for older call sites.
      return {
        'cipherText': encryptedText.base64,
        'ciphertext': encryptedText.base64,
        'encrypted_aes_key': encryptedAesKeyBase64,
        'iv': iv.base64,
      };
    } catch (e) {
      debugPrint('[SecurityService] Encryption pipeline failed: $e');
      throw Exception('Failed to encrypt message securely.');
    }
  }

  /// Decrypts the payload by extracting the AES key via RSA decryption,
  /// then uses the AES key to decrypt the ciphertext.
  Future<String> decryptMessage(Map<String, dynamic> payload) async {
    try {
      final ciphertextBase64 = payload['cipherText']?.toString() ??
          payload['ciphertext']?.toString() ??
          payload['cipher_text']?.toString();
      final encryptedAesKeyBase64 = payload['encrypted_aes_key']?.toString() ??
          payload['encryptedAesKey']?.toString() ??
          payload['encrypted_aesKey']?.toString();
      final ivBase64 = payload['iv']?.toString();

      if (ciphertextBase64 == null || encryptedAesKeyBase64 == null || ivBase64 == null) {
        throw Exception('Malformed encrypted payload.');
      }

      // 1. Retrieve the local Private Key PEM (Do this on the main thread, platform channels aren't isolate-safe by default)
      final privateKeyPEM = await _secureStorage.read(key: _privateKeyStorageKey);
      if (privateKeyPEM == null) {
        throw Exception('Local private key not found. Cannot decrypt message.');
      }
      final normalizedKey = privateKeyPEM.trimLeft();
      if (!normalizedKey.startsWith('-----BEGIN') ||
          !normalizedKey.contains('PRIVATE KEY-----')) {
        throw Exception('Local private key is not a valid PEM private key.');
      }

      // 2. Offload RSA decryption of the AES key to a background isolate
      final decryptedAesKeyBytes = await compute(_rsaDecryptIsolated, {
        'encryptedAesKeyBase64': encryptedAesKeyBase64,
        'privateKeyPEM': privateKeyPEM,
      });

      // 3. AES Decrypt the ciphertext
      final aesKey = encrypt.Key(Uint8List.fromList(decryptedAesKeyBytes));
      final iv = encrypt.IV.fromBase64(ivBase64);
      final encrypter = encrypt.Encrypter(encrypt.AES(aesKey, mode: encrypt.AESMode.cbc));
      
      final plainText = encrypter.decrypt64(ciphertextBase64, iv: iv);
      return plainText;
    } catch (e) {
      debugPrint('[SecurityService] Decryption pipeline failed: $e');
      throw Exception('Failed to decrypt message. It may be corrupted or encrypted with a different key.');
    }
  }

  /// Returns the current local public key PEM if it exists.
  Future<String?> getLocalPublicKey() async {
    return await _secureStorage.read(key: _publicKeyStorageKey);
  }

  /// Ensures the user has generated an RSA key pair and uploaded the perfect PEM to Firestore.
  Future<void> ensureKeysUploaded() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    
    var pubKey = await getLocalPublicKey();
    final privKey = await _secureStorage.read(key: _privateKeyStorageKey);

    final haveLocalKeys = pubKey != null &&
        pubKey.isNotEmpty &&
        privKey != null &&
        privKey.isNotEmpty;
    final keysValid = haveLocalKeys
        ? _isValidRsaPublicKeyPem(pubKey) && _isValidRsaPrivateKeyPem(privKey)
        : false;

    if (!keysValid) {
      debugPrint('[SecurityService] Generating new RSA keys for user...');
      final keyPairMap = await compute(_generateRSAKeyPairIsolated, null);
      final privateKeyPEM = keyPairMap['private'] ?? '';
      final publicKeyPEM = keyPairMap['public'] ?? '';
      if (privateKeyPEM.isEmpty || publicKeyPEM.isEmpty) {
        throw Exception('Failed to generate RSA key pair.');
      }
      await _secureStorage.write(key: _privateKeyStorageKey, value: privateKeyPEM);
      await _secureStorage.write(key: _publicKeyStorageKey, value: publicKeyPEM);
      pubKey = publicKeyPEM;
    }

    // Force upload to Firestore under e2eePublicKey to ensure readiness
    await FirebaseFirestore.instance.collection('users').doc(uid).set({
      'e2eePublicKey': pubKey,
    }, SetOptions(merge: true));
    
    debugPrint('[SecurityService] Uploaded RSA Public Key to Firestore.');
  }

  /// STEP 3: Isolate encryption test (Local Crypto Validation)
  Future<void> testCryptoPipeline() async {
    debugPrint('[CryptoTest] Starting local encryption test...');
    try {
      final keys = await generateAndBackupKeyPair(pin: '123456', salt: 'test_salt');
      final pubKey = keys['publicKey']!;
      
      const msg = "hello secure world";
      debugPrint('[CryptoTest] Original message: $msg');
      
      final encrypted = await encryptMessage(msg, pubKey);
      debugPrint('[CryptoTest] Encrypted payload: $encrypted');
      
      final decrypted = await decryptMessage(encrypted);
      debugPrint('[CryptoTest] Decrypted message: $decrypted');
      
      if (msg == decrypted) {
        debugPrint('[CryptoTest] SUCCESS: Crypto pipeline is fully working!');
      } else {
        debugPrint('[CryptoTest] FAILED: Decrypted message does not match.');
      }
    } catch (e, stack) {
      debugPrint('[CryptoTest] CRASH during pipeline test: $e\n$stack');
    }
  }
}

// ---------------------------------------------------------------------------
// ISOLATE FUNCTIONS
// These must be top-level functions to be used with compute().
// ---------------------------------------------------------------------------

Map<String, String> _generateRSAKeyPairIsolated(dynamic _) {
  // Setup Fortuna Random
  final secureRandom = FortunaRandom();
  final seedSource = Random.secure();
  final seeds = List<int>.generate(32, (_) => seedSource.nextInt(256));
  secureRandom.seed(pc.KeyParameter(Uint8List.fromList(seeds)));

  // Initialize RSA Key Generator (2048-bit)
  final keyGen = pc_rsa_gen.RSAKeyGenerator()
    ..init(pc.ParametersWithRandom(
      pc_keygen.RSAKeyGeneratorParameters(BigInt.parse('65537'), 2048, 64),
      secureRandom,
    ));

  final pair = keyGen.generateKeyPair();
  final publicKey = pair.publicKey as pc_rsa.RSAPublicKey;
  final privateKey = pair.privateKey as pc_rsa.RSAPrivateKey;

  return {
    'public': CryptoUtils.encodeRSAPublicKeyToPem(publicKey),
    'private': CryptoUtils.encodeRSAPrivateKeyToPem(privateKey),
  };
}

String _rsaEncryptIsolated(Map<String, dynamic> args) {
  final aesKeyBytes = args['aesKeyBytes'] as List<int>;
  final publicKeyPEM = args['publicKeyPEM'] as String;

  final parsed = encrypt.RSAKeyParser().parse(publicKeyPEM);
  if (parsed is! pc_rsa.RSAPublicKey) {
    throw const FormatException('Unsupported public key type. Expected RSA.');
  }
  final rsaPub = parsed;
  
  // Encrypt the AES key bytes using PKCS1
  final rsaEncrypter = encrypt.Encrypter(encrypt.RSA(publicKey: rsaPub));
  final encrypted = rsaEncrypter.encryptBytes(aesKeyBytes);
  
  return encrypted.base64;
}

List<int> _rsaDecryptIsolated(Map<String, dynamic> args) {
  final encryptedAesKeyBase64 = args['encryptedAesKeyBase64'] as String;
  final privateKeyPEM = args['privateKeyPEM'] as String;

  final parsed = encrypt.RSAKeyParser().parse(privateKeyPEM);
  if (parsed is! pc_rsa.RSAPrivateKey) {
    throw const FormatException('Unsupported private key type. Expected RSA.');
  }
  final rsaPriv = parsed;
  
  final rsaEncrypter = encrypt.Encrypter(encrypt.RSA(privateKey: rsaPriv));
  final decryptedBytes = rsaEncrypter.decryptBytes(
    encrypt.Encrypted.fromBase64(encryptedAesKeyBase64)
  );

  return decryptedBytes;
}

// ---------------------------------------------------------------------------
// PIN RECOVERY & PBKDF2 HELPER FUNCTIONS
// ---------------------------------------------------------------------------

Uint8List _derivePbkdf2(String pin, String salt) {
  // HMAC-SHA256 with 64-byte block size
  final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64));
  derivator.init(pc_kdf.Pbkdf2Parameters(
    Uint8List.fromList(utf8.encode(salt)),
    100000, // 100k iterations is standard/secure for PBKDF2
    32,     // 256-bit AES key
  ));
  return derivator.process(Uint8List.fromList(utf8.encode(pin)));
}

String _deriveAndEncryptPrivateKeyIsolated(Map<String, dynamic> args) {
  final pin = args['pin'] as String;
  final salt = args['salt'] as String;
  final privateKeyPEM = args['privateKeyPEM'] as String;

  final keyBytes = _derivePbkdf2(pin, salt);
  final aesKey = encrypt.Key(keyBytes);
  final iv = encrypt.IV.fromSecureRandom(16);

  final encrypter = encrypt.Encrypter(encrypt.AES(aesKey, mode: encrypt.AESMode.cbc));
  final encrypted = encrypter.encrypt(privateKeyPEM, iv: iv);

  // Format: iv:ciphertext
  return '${iv.base64}:${encrypted.base64}';
}

String _deriveAndDecryptPrivateKeyIsolated(Map<String, dynamic> args) {
  final pin = args['pin'] as String;
  final salt = args['salt'] as String;
  final blob = args['encryptedBlob'] as String;

  final parts = blob.split(':');
  if (parts.length != 2) throw Exception('Invalid recovery blob format.');

  final iv = encrypt.IV.fromBase64(parts[0]);
  final cipherText = parts[1];

  final keyBytes = _derivePbkdf2(pin, salt);
  final aesKey = encrypt.Key(keyBytes);

  final encrypter = encrypt.Encrypter(encrypt.AES(aesKey, mode: encrypt.AESMode.cbc));
  try {
    return encrypter.decrypt64(cipherText, iv: iv);
  } catch (e) {
    throw Exception('Incorrect PIN or corrupted backup.');
  }
}
