import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Lets the pointer area accept Ctrl/Cmd+V without stealing keyboard focus.
class ImagePasteArea extends StatefulWidget {
  final Widget child;
  final VoidCallback onPaste;

  const ImagePasteArea({
    super.key,
    required this.child,
    required this.onPaste,
  });

  @override
  State<ImagePasteArea> createState() => _ImagePasteAreaState();
}

class _ImagePasteAreaState extends State<ImagePasteArea> {
  bool _hovering = false;

  bool _onKey(KeyEvent event) {
    if (!_hovering || event is! KeyDownEvent) return false;
    final keyboard = HardwareKeyboard.instance;
    if (event.logicalKey == LogicalKeyboardKey.keyV &&
        (keyboard.isControlPressed || keyboard.isMetaPressed)) {
      widget.onPaste();
      return true;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => _hovering = true,
      onExit: (_) => _hovering = false,
      child: widget.child,
    );
  }
}
