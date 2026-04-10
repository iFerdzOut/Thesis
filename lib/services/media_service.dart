import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

class MediaService {
  final ImagePicker _picker = ImagePicker();

  static const double _maxImageDimension = 1920;
  static const int _imageQuality = 82;

  Future<File?> pickImageFromGallery() async {
    final XFile? file = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: _maxImageDimension,
      maxHeight: _maxImageDimension,
      imageQuality: _imageQuality,
      requestFullMetadata: false,
    );
    if (file == null) return null;
    return File(file.path);
  }

  Future<File?> takePhoto() async {
    final XFile? file = await _picker.pickImage(
      source: ImageSource.camera,
      maxWidth: _maxImageDimension,
      maxHeight: _maxImageDimension,
      imageQuality: _imageQuality,
      requestFullMetadata: false,
    );
    if (file == null) return null;
    return File(file.path);
  }

  Future<File?> pickAnyFile() async {
    final result = await FilePicker.platform.pickFiles();
    if (result == null || result.files.single.path == null) return null;
    return File(result.files.single.path!);
  }

  Future<File?> pickGif() async {
    final XFile? file = await _picker.pickImage(source: ImageSource.gallery);
    if (file == null) return null;
    final lowerPath = file.path.toLowerCase();
    if (!lowerPath.endsWith('.gif')) {
      return null;
    }
    return File(file.path);
  }
}
