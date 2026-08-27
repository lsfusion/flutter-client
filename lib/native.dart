import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:printing/printing.dart';
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
    return {'error': '$e'};
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
    return {'error': '$e'};
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
    return {'result': null};
  } catch (e) {
    return {'result': 'Error making dir: $e'};
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

// the extensions WriteUtils appends by merging documents rather than bytes
const _mergedFormats = ['xls', 'xlsx', 'docx', 'pdf'];

// writeAsBytes in append mode does not serialize with itself. Measured over CDP:
// two writeFile commands dispatched in the same turn left only the second one's
// bytes - 'AAA' then 'BBB' gave 'BBB', not 'AAABBB'. The writes are queued so
// each one starts after the one before it has finished.
Future<void> _writes = Future<void>.value();

// A relative path goes into the user's Downloads, which is what the desktop client
// makes of one (WriteUtils.writeFile) - and it does so for writing alone: every other
// command of ours works off the process's own directory. Only where there is such a
// folder, though: on Android and iOS a relative path stays in the sandbox.
String _clientPath(String path) {
  final home = Platform.isWindows
      ? Platform.environment['USERPROFILE']
      : (Platform.isLinux || Platform.isMacOS ? Platform.environment['HOME'] : null);
  final absolute = Platform.isWindows
      ? RegExp(r'^([a-zA-Z]:[\\/]|\\\\)').hasMatch(path)
      : path.startsWith('/');
  if (home == null || home.isEmpty || absolute) return path;
  return '$home${Platform.pathSeparator}Downloads${Platform.pathSeparator}$path';
}

// Appending is concatenation. Onto an existing xls/xlsx/docx/pdf the desktop client
// merges documents instead, with POI and PDFBox, and this client has neither - so
// those it refuses rather than corrupt. A file that is not there yet is simply
// created, for any type, the way WriteUtils does; anything else is concatenated.
// Same rule as the web-agent's, and like it the check runs inside the queue - two
// appends arriving together would otherwise both find no file and both concatenate.
Future<Map<String, dynamic>> _writeBytes(
    String path, Uint8List bytes, bool append) {
  final write = _writes.then((_) async {
    final file = File(path);
    if (append) {
      final dot = path.lastIndexOf('.');
      final extension = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
      if (_mergedFormats.contains(extension) && await file.exists()) {
        return {
          'error': 'APPEND to an existing $extension file is supported only in '
              'the desktop client'
        };
      }
    }
    await file.writeAsBytes(bytes,
        mode: append ? FileMode.append : FileMode.write);
    return {'result': null};
  });
  // a failed write must not poison the queue for the writes behind it; its
  // caller still gets the error through the future it is awaiting
  _writes = write.then((_) {}, onError: (_) {});
  return write;
}

Future<Map<String, dynamic>> writeFile(String url, String path,
    [String? fileData, bool append = false]) async {
  try {
    Uint8List bytes;
    if (fileData != null) {
      // WRITE CLIENT delivers the file content as base64 in `fileData` (the web
      // client always fills it — see ClientActionToGwtConverter.convertAction).
      // Write those bytes directly, the same way the web-agent does. Downloading
      // `url` instead reaches the app server WITHOUT the webview's session
      // cookie, so it 401s and no file is created — and because WRITE is a
      // fire-and-forget action, that failure was silent.
      bytes = base64Decode(fileData);
    } else {
      final uri = Uri.parse(url);
      final httpClient = HttpClient()..autoUncompress = true;

      final request = await httpClient.getUrl(uri);
      request.followRedirects = true;
      request.headers.set('User-Agent', 'Mozilla/5.0 (compatible; Dart)');

      final response = await request.close();
      if (response.statusCode != 200) {
        return {'error': 'HTTP error: ${response.statusCode}'};
      }
      bytes = await consolidateHttpClientResponseBytes(response);
    }

    return await _writeBytes(_clientPath(path), bytes, append);
  } catch (e) {
    return {'error': 'Error writing file: $e'};
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

// A command line, not an executable: `echo hi` has no echo.exe to find, and
// Process.run without runInShell looks for exactly that and throws. The web-agent
// hands the whole line to a shell, so do the same - runInShell is cmd /c on Windows
// and /bin/sh -c elsewhere.
// One thing the web-agent still does better on Windows: dart:io escapes the line as
// a process argument, so a double quote inside it reaches cmd.exe as \" and a quoted
// path (cmd /c copy "a b.txt" c) is not understood. There is no dart:io call that
// passes a raw command line, and every way around it - a temporary .cmd, indirection
// through an environment variable - trades the quotes for something else that breaks.
Future<Map<String, dynamic>> runCommand(
  String command,
  String? directory,
  bool wait,
) async {
  if (!wait) {
    // nothing is waited for, so there is no exit code to judge and no output to
    // report: a null result is what the server side reads as "left alone", the
    // same as the desktop client's runCmd, which returns null without wait
    await Process.start(
      command,
      List.empty(),
      runInShell: true,
      workingDirectory: directory,
      mode: ProcessStartMode.detached,
    );
    return {'result': null};
  }

  final result = await Process.run(
    command,
    List.empty(),
    runInShell: true,
    workingDirectory: directory,
    // raw bytes: the decoding is ours to do, see _decodeOutput
    stdoutEncoding: null,
    stderrEncoding: null,
  );
  return {
    'cmdOut': (await _decodeOutput(result.stdout as List<int>)).trim(),
    'cmdErr': (await _decodeOutput(result.stderr as List<int>)).trim(),
    'exitValue': result.exitCode,
  };
}

// A command's output comes back in the console (OEM) code page, and Dart's
// systemEncoding decodes the ANSI one instead - Cp1251 where the console is Cp866 -
// turning every non-ASCII character into noise; for a command that fails, that noise
// is the error message the user gets to read. Windows itself is asked to decode, so
// a console that is 850 or 852 reads as well as a 866 one, while the desktop client,
// which hardcodes cp866, only ever gets the latter right.
Future<String> _decodeOutput(List<int> bytes) async {
  if (!Platform.isWindows || bytes.isEmpty) return systemEncoding.decode(bytes);
  final codePage = await _consoleCodePage;
  final source = malloc<Uint8>(bytes.length);
  source.asTypedList(bytes.length).setAll(0, bytes);
  try {
    final length = _multiByteToWideChar(
        codePage, 0, source, bytes.length, nullptr, 0);
    if (length <= 0) return systemEncoding.decode(bytes);
    final target = malloc<Uint16>(length);
    try {
      _multiByteToWideChar(codePage, 0, source, bytes.length, target, length);
      // what MultiByteToWideChar writes is UTF-16, which is what a Dart string is
      return String.fromCharCodes(target.asTypedList(length));
    } finally {
      malloc.free(target);
    }
  } finally {
    malloc.free(source);
  }
}

// Asked the same way the web-agent asks, so both answer alike whatever the machine:
// chcp run through a shell reports the code page of a child exactly like the ones our
// commands run in, which neither GetOEMCP nor the calling console's own page is bound
// to match. Lazy and kept, so it costs one process for the life of the client.
final Future<int> _consoleCodePage = () async {
  try {
    final chcp = await Process.run('chcp', const [], runInShell: true, stdoutEncoding: null);
    // "Active code page: 866", localized elsewhere and sometimes ending in a full
    // stop - only the number is worth reading
    final number = RegExp(r'(\d+)\D*$')
        .firstMatch(String.fromCharCodes(chcp.stdout as List<int>).trim());
    if (number != null) return int.parse(number.group(1)!);
  } catch (_) {
    // an unanswered chcp
  }
  return 866; // the guess of last resort
}();

// opened lazily, so nothing here is touched on a platform without a kernel32
final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

final int Function(int, int, Pointer<Uint8>, int, Pointer<Uint16>, int)
    _multiByteToWideChar = _kernel32.lookupFunction<
        Int32 Function(
            Uint32, Uint32, Pointer<Uint8>, Int32, Pointer<Uint16>, Int32),
        int Function(int, int, Pointer<Uint8>, int, Pointer<Uint16>, int)>(
    'MultiByteToWideChar');

Future<Map<String, dynamic>> writeToSocket(
  String host,
  int port,
  String text,
  String charset,
) async {
  Encoding encoding;

  // settled before connecting: a charset we cannot encode used to open a socket and
  // walk away from it, while the web-agent turns the request down without connecting
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
      return {'error': 'Unsupported charset: $charset'};
  }

  try {
    final socket = await Socket.connect(host, port);
    socket.add(encoding.encode(text));
    await socket.flush();
    await socket.close();

    return {'result': null};
  } catch (e) {
    return {'error': '$e'};
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
