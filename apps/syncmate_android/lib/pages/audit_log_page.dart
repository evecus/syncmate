import 'dart:io';

import 'package:flutter/material.dart';

import '../theme.dart';

/// 操作留痕查看页：读取本机审计日志尾部（最新在前，最近 200 行）。
class AuditLogPage extends StatefulWidget {
  const AuditLogPage({super.key, required this.logPath});

  final String? logPath;

  @override
  State<AuditLogPage> createState() => _AuditLogPageState();
}

class _AuditLogPageState extends State<AuditLogPage> {
  List<String> _lines = [];
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final path = widget.logPath;
    if (path == null) {
      setState(() {
        _loading = false;
        _error = '操作留痕未启用（日志路径不可写）';
      });
      return;
    }
    try {
      final file = File(path);
      if (!await file.exists()) {
        setState(() {
          _lines = [];
          _loading = false;
        });
        return;
      }
      final all = await file.readAsLines();
      final tail = all.length > 200 ? all.sublist(all.length - 200) : all;
      if (!mounted) return;
      setState(() {
        _lines = tail.reversed.toList();
        _loading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '读取失败：$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('操作日志'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh_rounded, size: 22),
            onPressed: _load,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
      );
    }
    if (_error != null) {
      return EmptyState(
        icon: Icons.description_outlined,
        title: _error!,
        action: FilledButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh_rounded, size: 16),
          label: const Text('重试'),
        ),
      );
    }
    if (_lines.isEmpty) {
      return const EmptyState(
        icon: Icons.receipt_long_rounded,
        title: '暂无日志记录',
        subtitle: '设备之间发生的文件操作会记录在这里',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: _lines.length,
      separatorBuilder: (_, __) => const SizedBox(height: 6),
      itemBuilder: (context, index) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.surfaceSunken,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Text(
            _lines[index],
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 11.5,
              color: AppColors.textSecondary,
              height: 1.4,
            ),
          ),
        );
      },
    );
  }
}
