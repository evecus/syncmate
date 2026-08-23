import 'package:flutter/material.dart';

/// 来源选择菜单：用空串表示本机，避免 PopupMenuItem value=null 时 onSelected 不触发。
PopupMenuButton<String> buildSourceMenu({
  required List<({String? fingerprint, String alias})> sources,
  required String? currentSource,
  required ValueChanged<String?> onSourceChanged,
  required Widget child,
}) {
  return PopupMenuButton<String>(
    tooltip: '切换视图来源',
    position: PopupMenuPosition.under,
    onSelected: (fp) {
      final source = fp.isEmpty ? null : fp;
      if (source != currentSource) onSourceChanged(source);
    },
    itemBuilder: (context) => [
      for (final s in sources)
        PopupMenuItem<String>(
          value: s.fingerprint ?? '',
          child: Text(s.alias),
        ),
    ],
    child: child,
  );
}
