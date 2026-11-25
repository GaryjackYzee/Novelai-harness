import 'dart:async';

import 'package:flutter/material.dart';

typedef ImagePasteCallback = Future<void> Function();

/// Lets the pointer area accept Ctrl/Cmd+V without stealing keyboard focus.
class ImagePasteArea extends StatefulWidget {
  final Widget child;
  final ImagePasteCallback onPaste;

  const ImagePasteArea({
    super.key,
    required this.child,
    required this.onPaste,
  });

  @override
  State<ImagePasteArea> createState() => _ImagePasteAreaState();
}

class _ImagePasteAreaState extends State<ImagePasteArea> {
  static final List<ImagePasteCallback> _activePastes = <ImagePasteCallback>[];

  void _activate() {
    _activePastes.remove(widget.onPaste);
    _activePastes.add(widget.onPaste);
  }

  void _deactivate() {
    _activePastes.remove(widget.onPaste);
  }

  @override
  void dispose() {
    _deactivate();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => _activate(),
      onExit: (_) => _deactivate(),
      child: widget.child,
    );
  }
}

/// Called by the studio-level Ctrl/Cmd+V shortcut so the canvas does not steal
/// the paste while the pointer is over a reference area.
class ImagePasteAreaRouter {
  const ImagePasteAreaRouter._();

  static bool tryHandle() {
    if (_ImagePasteAreaState._activePastes.isEmpty) return false;
    final callback = _ImagePasteAreaState._activePastes.last;
    unawaited(
      Future<void>.sync(callback).catchError((Object error) {
        debugPrint('[clipboard] paste failed: $error');
      }),
    );
    return true;
  }
}
