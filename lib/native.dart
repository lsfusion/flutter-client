import 'dart:convert';
import 'dart:io';

Future<String> ping(String host) async {
  try {
    host = Uri.parse(host).host;
    final socket = await Socket.connect(
      host,
      80,
      timeout: const Duration(seconds: 5),
    );
    socket.destroy();
    return 'OK';
  } catch (e) {
    return 'Host is not reachable: $e';
  }
}

Future<String> listFiles(String source, bool recursive) async {
  final List<FileInfo> results = [];

  Future<void> listDir(Directory dir) async {
    await for (var entity in dir.list(recursive: false, followLinks: false)) {
      final stat = await entity.stat();

      final info = FileInfo(
        path: entity.path,
        isDirectory: stat.type == FileSystemEntityType.directory,
        modifiedDateTime: stat.modified,
        fileSize: stat.type == FileSystemEntityType.file ? stat.size : 0,
      );

      results.add(info);

      if (recursive && stat.type == FileSystemEntityType.directory) {
        await listDir(Directory(entity.path));
      }
    }
  }

  final dir = Directory(source);
  if (await dir.exists()) {
    await listDir(dir);
  }

  return jsonEncode(results.map((e) => e.toJson()).toList());
}

class FileInfo {
  final String path;
  final bool isDirectory;
  final DateTime modifiedDateTime;
  final int fileSize;

  FileInfo({
    required this.path,
    required this.isDirectory,
    required this.modifiedDateTime,
    required this.fileSize,
  });

  Map<String, dynamic> toJson() => {
    'path': path.replaceAll(r'\', r'\\'),
    'isDirectory': isDirectory,
    'modifiedDateTime': modifiedDateTime.toIso8601String(),
    'fileSize': fileSize,
  };
}