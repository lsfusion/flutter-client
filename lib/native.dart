import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'dart:ffi';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:win32/win32.dart';
import 'package:ffi/ffi.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:flutter_libserialport/flutter_libserialport.dart';

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

    return {'result': base64Encode(resultBytes)};
  } catch (e) {
    return {'result': base64Encode(utf8.encode(e.toString()))};
  }
}

Future<Map<String, dynamic>> sendUDP(
  String host,
  int port,
  String fileBytes,
) async {
  try {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.send(base64Decode(fileBytes), InternetAddress(host), port);
    socket.close();

    return {'result': null};
  } catch (e) {
    return {'result': base64Encode(utf8.encode(e.toString()))};
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

Future<Map<String, dynamic>> writeFile(String url, String path) async {
  try {
    final uri = Uri.parse(url);
    final httpClient = HttpClient()..autoUncompress = true;

    final request = await httpClient.getUrl(uri);
    request.followRedirects = true;
    request.headers.set('User-Agent', 'Mozilla/5.0 (compatible; Dart)');

    final response = await request.close();
    if (response.statusCode != 200) {
      return {
        'result': base64Encode(
          utf8.encode('HTTP error: ${response.statusCode}'),
        ),
      };
    }

    final bytes = await consolidateHttpClientResponseBytes(response);
    if (bytes.isEmpty) {
      return {'result': base64Encode(utf8.encode('Downloaded 0 bytes'))};
    }

    final file = File(path);
    await file.writeAsBytes(bytes);

    return {'result': null};
  } catch (e) {
    return {'result': base64Encode(utf8.encode('Exception: $e'))};
  }
}

Future<Map<String, dynamic>> getAvailablePrinters() async {
  try {
    final printers = await Printing.listPrinters();
    final names = printers.map((p) => p.name).join('\n');
    return {'result': names};
  } catch (e) {
    return {'result': 'Failed to list printers: $e'};
  }
}

Future<Map<String, dynamic>> print(
  String? base64,
  String? path,
  String? text,
  String? printerName,
) async {
  try {
    Uint8List fileBytes;
    if (base64 != null) {
      fileBytes = base64Decode(base64);
    } else if (path != null) {
      final file = File(path);
      if (!(await file.exists())) {
        return {'result': 'File does not exist: $path'};
      }
      fileBytes = await file.readAsBytes();
    } else if(text != null) {
      final pdf = pw.Document();
      pdf.addPage(
        pw.Page(
          build: (context) => pw.Text(text),
        ),
      );
      fileBytes = await pdf.save();
    }else {
      return {'result': 'No file path or base64 or text provided'};
    }

    final printers = await Printing.listPrinters();
    if (printers.isEmpty) {
      return {'result': 'No available printers found'};
    }

    Printer? targetPrinter = printers
        .where((p) => p.name == printerName)
        .cast<Printer?>()
        .firstOrNull;
    targetPrinter ??= printers
        .where((p) => p.isDefault)
        .cast<Printer?>()
        .firstOrNull;

    if (targetPrinter == null) {
      return {'result': 'No available printers found'};
    }

    Printing.directPrintPdf(
      printer: targetPrinter,
      onLayout: (_) async => fileBytes,
    );

    return {'result': null};
  } catch (e) {
    return {'result': 'Failed to print file: $e'};
  }
}

Future<Map<String, dynamic>> runCommand(String command) async {
  final result = await Process.run(command, List.empty());
  return {
    'cmdOut': result.stdout.toString().trim(),
    'cmdErr': result.stderr.toString().trim(),
    'exitValue': result.exitCode,
  };
}

Future<Map<String, dynamic>> writeToSocket(
  String host,
  int port,
  String text,
  String charset,
) async {
  try {
    final socket = await Socket.connect(host, port);
    Encoding encoding;

    switch (charset.toLowerCase()) {
      case 'utf8':
      case 'utf-8':
        encoding = utf8;
        break;
      case 'ascii':
        encoding = ascii;
        break;
      case 'latin1':
      case 'iso-8859-1':
        encoding = latin1;
        break;
      default:
        return {'result': 'Unsupported charset: $charset'};
    }

    socket.add(encoding.encode(text));
    await socket.flush();
    await socket.close();
    
    return {'result': null};

  } catch (e) {
      return {'result': 'Socket error: $e'};
  }
}

Future<Map<String, dynamic>> writeToComPort(String portName, int baudRate, String base64) async {
  try {
    final port = SerialPort(portName);
    if (!port.openReadWrite()) {
      return {'result': 'Failed to open port $portName'};
    }

    final config = SerialPortConfig();
    config.baudRate = baudRate;
    port.config = config;

    final data = base64Decode(base64);
    final bytesWritten = port.write(data);

    port.close();

    if (bytesWritten == data.length) {
      return {'result': null};
    } else {
      return {'result': 'Failed to write all bytes to port'};
    }
  } catch (e) {
    return {'result': 'Error writing to COM port: $e'};
  }
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
