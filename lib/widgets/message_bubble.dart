import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

class MessageBubble extends StatelessWidget {
  final String text;
  final bool isMe;
  final void Function(String url)? onUrlTap;

  const MessageBubble({
    super.key,
    required this.text,
    required this.isMe,
    this.onUrlTap,
  });

  static final _urlRegex = RegExp(
    r'https?://[^\s]+',
    caseSensitive: false,
  );

  List<InlineSpan> _buildSpans(String text, TextStyle baseStyle) {
    final spans = <InlineSpan>[];
    int last = 0;
    for (final match in _urlRegex.allMatches(text)) {
      if (match.start > last) {
        spans.add(TextSpan(
          text: text.substring(last, match.start),
          style: baseStyle,
        ));
      }
      final url = match.group(0)!;
      if (onUrlTap != null) {
        spans.add(TextSpan(
          text: url,
          style: baseStyle.copyWith(
            color: const Color(0xFF1565C0),
            decoration: TextDecoration.underline,
            decorationColor: const Color(0xFF1565C0),
          ),
          recognizer: TapGestureRecognizer()..onTap = () => onUrlTap!(url),
        ));
      } else {
        spans.add(TextSpan(text: url, style: baseStyle));
      }
      last = match.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last), style: baseStyle));
    }
    return spans.isEmpty ? [TextSpan(text: text, style: baseStyle)] : spans;
  }

  @override
  Widget build(BuildContext context) {
    // Derive base style from DefaultTextStyle so RichText inherits the correct
    // dark text color (RichText does not inherit DefaultTextStyle automatically).
    final baseStyle = DefaultTextStyle.of(context).style.copyWith(fontSize: 15);
    final spans = _buildSpans(text, baseStyle);
    final hasUrls = _urlRegex.hasMatch(text);

    return Container(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.72,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isMe ? const Color(0xFFDCF8C6) : Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft: Radius.circular(isMe ? 14 : 0),
            bottomRight: Radius.circular(isMe ? 0 : 14),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 2,
            ),
          ],
        ),
        child: hasUrls && onUrlTap != null
            ? RichText(text: TextSpan(children: spans))
            : Text(text, style: baseStyle),
      ),
    );
  }
}
