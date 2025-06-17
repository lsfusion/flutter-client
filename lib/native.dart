import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

Future<Map<String, dynamic>> sendTCP(
  String host,
  int port,
  String fileBytes,
  int timeoutMillis,
) async {
  try {
    final socket = await Socket.connect(
      host,
      port,
      timeout: Duration(milliseconds: timeoutMillis),
    );
    socket.add(base64Decode(fileBytes));
    await socket.flush();
    final completer = Completer<Uint8List>();
    final response = BytesBuilder();
    socket.listen(
      response.add,
      onDone: () {
        completer.complete(response.toBytes());
        socket.destroy();
      },
      onError: (error) {
        completer.completeError(error);
        socket.destroy();
      },
      cancelOnError: true,
    );

    final Uint8List resultBytes = await completer.future.timeout(
      Duration(milliseconds: timeoutMillis),
      onTimeout: () {
        socket.destroy();
        throw 'TCP read timeout';
      },
    );

    return { 'result': base64Encode(resultBytes) };
  } catch (e) {
    return { 'result': base64Encode(utf8.encode(e.toString())) };
  }
}

Future<Map<String, dynamic>> readFile(String path) async {
  try {
    final file = File(path);
    if (!await file.exists()) {
      return {'error': 'File does not exist'};
    }
    final bytes = await file.readAsBytes();
    final base64Content = base64Encode(bytes);
    return {'result': base64Content};
  } catch (e) {
    return {'error': 'Error reading file: $e'};
  }
}

Future<Map<String, dynamic>> deleteFile(String path) async {
  try {
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.notFound) {
      return {'result': 'File or directory does not exist: $path'};
    }

    final entity = FileSystemEntity.isDirectorySync(path)
        ? Directory(path)
        : File(path);

    await entity.delete(recursive: true);
    return {'result': null};
  } catch (e) {
    return {'result': 'Error deleting file or directory: $e'};
  }
}

Future<Map<String, dynamic>> fileExists(String path) async {
  try {
    final entity = FileSystemEntity.typeSync(path);
    if (entity == FileSystemEntityType.notFound) {
      return {'result': false};
    }
    return {'result': true};
  } catch (e) {
    return {'result': false};
  }
}

Future<Map<String, dynamic>> makeDir(String path) async {
  try {
    final dir = Directory(path);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return {'result': true};
  } catch (e) {
    return {'error': 'Error making dir: $e'};
  }
}

Future<Map<String, dynamic>> moveFile(
  String sourcePath,
  String destinationPath,
) async {
  try {
    final sourceFile = File(sourcePath);
    await sourceFile.rename(destinationPath);
    return {'result': null};
  } catch (e) {
    return {'result': 'Error moving file: $e'};
  }
}

Future<Map<String, dynamic>> copyFile(
  String sourcePath,
  String destinationPath,
) async {
  try {
    final sourceFile = File(sourcePath);
    await sourceFile.copy(destinationPath);
    return {'result': null};
  } catch (e) {
    return {'result': 'Error copying file: $e'};
  }
}

Future<Map<String, dynamic>> listFiles(String source, bool recursive) async {
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

  return {'result': results.map((e) => e.toJson()).toList()};
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

Future<Map<String, dynamic>> ping(String host) async {
  try {
    host = Uri.parse(host).host;
    final socket = await Socket.connect(
      host,
      80,
      timeout: const Duration(seconds: 5),
    );
    socket.destroy();
    return {'result': null};
  } catch (e) {
    return {'result': 'Host is not reachable: $e'};
  }
}
