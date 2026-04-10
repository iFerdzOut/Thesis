// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

class CloudinaryService {
  static const String _cloudName = 'dg9zbrt9a';
  static const String _uploadPreset = 'Smishing Shield Ph cloud storage';
  static const int _maxBytes = 25 * 1024 * 1024; // 25MB

  Future<CloudinaryResult> uploadFile(
    File file, {
    void Function(double progress)? onProgress,
  }) async {
    final fileSize = await file.length();
    if (fileSize > _maxBytes) {
      throw Exception(
          'File exceeds the 25MB limit (${(fileSize / 1024 / 1024).toStringAsFixed(1)}MB)');
    }

    // Get filename and sanitize
    final rawName = file.path.split(Platform.pathSeparator).last;
    final safeName =
        rawName.replaceAll(RegExp(r'[^a-zA-Z0-9.\-_]'), '_');

    // Determine resource type
    final ext = safeName.split('.').last.toLowerCase();
    const imageExts = ['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'bmp'];
    const videoExts = ['mp4', 'mov', 'avi', 'mkv', 'wmv'];
    String resourceType = 'raw';
    if (imageExts.contains(ext)) resourceType = 'image';
    if (videoExts.contains(ext)) resourceType = 'video';

    final uploadUrl =
        'https://api.cloudinary.com/v1_1/$_cloudName/$resourceType/upload';

    // Use timestamp-only public_id — NO slashes, NO special chars
    final publicId = DateTime.now().millisecondsSinceEpoch.toString();

    print('[Cloudinary] Uploading $resourceType: $safeName');
    onProgress?.call(0.1);

    // Use multipart upload — faster and more reliable than base64
    final request = http.MultipartRequest('POST', Uri.parse(uploadUrl));
    request.fields['upload_preset'] = _uploadPreset;
    request.fields['public_id'] = publicId;
    request.files.add(await http.MultipartFile.fromPath('file', file.path));

    onProgress?.call(0.4);

    final streamedResponse = await request.send();
    final responseBody = await streamedResponse.stream.bytesToString();

    onProgress?.call(1.0);

    if (streamedResponse.statusCode == 200) {
      final data = jsonDecode(responseBody) as Map<String, dynamic>;
      final url = data['secure_url'] as String? ?? '';
      if (url.isEmpty) throw Exception('Cloudinary returned no URL.');

      print('[Cloudinary] Upload success: $url');

      return CloudinaryResult(
        url: url,
        fileName: rawName,
        resourceType: resourceType,
        sizeBytes: fileSize,
      );
    } else {
      final error = jsonDecode(responseBody);
      final msg = error['error']?['message'] ?? responseBody;
      print('[Cloudinary] Upload failed: $msg');
      throw Exception('Upload failed: $msg');
    }
  }

  Future<CloudinaryResult> uploadBytes(
    Uint8List bytes, {
    required String fileName,
    String resourceType = 'raw',
    void Function(double progress)? onProgress,
  }) async {
    final fileSize = bytes.lengthInBytes;
    if (fileSize == 0) {
      throw Exception('Cannot upload an empty file.');
    }
    if (fileSize > _maxBytes) {
      throw Exception(
          'File exceeds the 25MB limit (${(fileSize / 1024 / 1024).toStringAsFixed(1)}MB)');
    }

    final safeName = fileName.replaceAll(RegExp(r'[^a-zA-Z0-9.\-_]'), '_');
    final uploadUrl =
        'https://api.cloudinary.com/v1_1/$_cloudName/$resourceType/upload';
    final publicId = DateTime.now().millisecondsSinceEpoch.toString();

    print('[Cloudinary] Uploading encrypted bytes: $safeName');
    onProgress?.call(0.1);

    final request = http.MultipartRequest('POST', Uri.parse(uploadUrl));
    request.fields['upload_preset'] = _uploadPreset;
    request.fields['public_id'] = publicId;
    request.files.add(http.MultipartFile.fromBytes(
      'file',
      bytes,
      filename: safeName,
    ));

    onProgress?.call(0.4);

    final streamedResponse = await request.send();
    final responseBody = await streamedResponse.stream.bytesToString();

    onProgress?.call(1.0);

    if (streamedResponse.statusCode == 200) {
      final data = jsonDecode(responseBody) as Map<String, dynamic>;
      final url = data['secure_url'] as String? ?? '';
      if (url.isEmpty) throw Exception('Cloudinary returned no URL.');

      print('[Cloudinary] Encrypted upload success: $url');

      return CloudinaryResult(
        url: url,
        fileName: fileName,
        resourceType: resourceType,
        sizeBytes: fileSize,
      );
    }

    final error = jsonDecode(responseBody);
    final msg = error['error']?['message'] ?? responseBody;
    print('[Cloudinary] Encrypted upload failed: $msg');
    throw Exception('Upload failed: $msg');
  }
}

class CloudinaryResult {
  final String url;
  final String fileName;
  final String resourceType;
  final int sizeBytes;

  CloudinaryResult({
    required this.url,
    required this.fileName,
    required this.resourceType,
    required this.sizeBytes,
  });

  bool get isImage => resourceType == 'image';
  bool get isVideo => resourceType == 'video';
  bool get isFile => resourceType == 'raw';

  String get sizeLabel {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(sizeBytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
