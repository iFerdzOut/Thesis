import 'package:flutter/material.dart';

class UserAvatar extends StatelessWidget {
  final String name;
  final String? imageUrl;
  final double radius;
  final Color backgroundColor;
  final Color foregroundColor;

  const UserAvatar({
    super.key,
    required this.name,
    this.imageUrl,
    this.radius = 20,
    this.backgroundColor = const Color(0xFFE6F3EE),
    this.foregroundColor = const Color(0xFF075E54),
  });

  @override
  Widget build(BuildContext context) {
    final trimmedUrl = imageUrl?.trim() ?? '';
    final hasImage = trimmedUrl.isNotEmpty &&
        Uri.tryParse(trimmedUrl)?.hasAbsolutePath == true;
    final fallbackText = name.trim().isNotEmpty
        ? name.trim().substring(0, 1).toUpperCase()
        : '?';

    return CircleAvatar(
      radius: radius,
      backgroundColor: backgroundColor,
      backgroundImage: hasImage ? NetworkImage(trimmedUrl) : null,
      child: hasImage
          ? null
          : Text(
              fallbackText,
              style: TextStyle(
                color: foregroundColor,
                fontWeight: FontWeight.w700,
                fontSize: radius * 0.9,
              ),
            ),
    );
  }
}
