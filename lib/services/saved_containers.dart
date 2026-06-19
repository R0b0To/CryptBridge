import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

class SavedContainerService {
  static Future<File> get _saveFile async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/saved_containers.json');
  }

  static Future<void> saveContainer(String uri, String name) async {
    try {
      final file = await _saveFile;
      List<dynamic> list = [];
      if (await file.exists()) {
        final content = await file.readAsString();
        list = jsonDecode(content) as List<dynamic>;
      }
      list.removeWhere((item) => item['uri'] == uri);
      list.add({'uri': uri, 'name': name});
      await file.writeAsString(jsonEncode(list));
    } catch (_) {
      // Safe fallback — never crash the UI over a persistence failure.
    }
  }

  static Future<List<Map<String, String>>> loadContainers() async {
    try {
      final file = await _saveFile;
      if (await file.exists()) {
        final content = await file.readAsString();
        final list = jsonDecode(content) as List<dynamic>;
        return list
            .map((item) => {
                  'uri': item['uri'] as String,
                  'name': item['name'] as String,
                })
            .toList();
      }
    } catch (_) {}
    return [];
  }

  static Future<void> removeContainer(String uri) async {
    try {
      final file = await _saveFile;
      if (await file.exists()) {
        final content = await file.readAsString();
        final list = jsonDecode(content) as List<dynamic>;
        list.removeWhere((item) => item['uri'] == uri);
        await file.writeAsString(jsonEncode(list));
      }
    } catch (_) {}
  }
}