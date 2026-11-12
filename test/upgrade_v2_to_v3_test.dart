import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/data/shelf_database.dart';
import 'package:shelf/data/shelf_store.dart';
import 'package:shelf/models/color_label.dart';
import 'package:shelf/models/library_document.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Builds a version-2 library the way Shelf shipped before document_state.
Future<void> createV2Database(String path) async {
  final opened = await databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 2,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE documents (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            stored_name TEXT NOT NULL,
            imported_at INTEGER NOT NULL,
            page_count INTEGER
          )
        ''');
        await db.execute('''
          CREATE TABLE color_labels (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            meaning TEXT NOT NULL,
            hex TEXT NOT NULL,
            is_default INTEGER NOT NULL DEFAULT 0,
            sort_order INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE notes (
            id TEXT PRIMARY KEY,
            document_id TEXT NOT NULL,
            page INTEGER NOT NULL,
            x REAL NOT NULL,
            y REAL NOT NULL,
            text TEXT NOT NULL,
            color_label_id TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            selected_text TEXT,
            selection_left REAL,
            selection_top REAL,
            selection_right REAL,
            selection_bottom REAL,
            FOREIGN KEY(document_id) REFERENCES documents(id) ON DELETE CASCADE,
            FOREIGN KEY(color_label_id) REFERENCES color_labels(id)
          )
        ''');
        for (final label in ColorLabel.seedDefaults()) {
          await db.insert('color_labels', label.toMap());
        }
        await db.insert('color_labels', {
          'id': 'label_custom',
          'name': 'Margin',
          'meaning': 'A mark in the margin.',
          'hex': '#0F766E',
          'is_default': 0,
          'sort_order': 2,
        });
        await db.insert('documents', {
          'id': 'pdf-1',
          'title': 'Notes on method',
          'stored_name': 'pdf-1.pdf',
          'imported_at': 1000,
          'page_count': 8,
        });
        await db.insert('documents', {
          'id': 'pdf-2',
          'title': 'Field guide',
          'stored_name': 'pdf-2.pdf',
          'imported_at': 2000,
          'page_count': 24,
        });
        await db.insert('notes', {
          'id': 'note-1',
          'document_id': 'pdf-1',
          'page': 2,
          'x': 0.3,
          'y': 0.4,
          'text': 'Come back to this diagram.',
          'color_label_id': ColorLabel.orangeId,
          'created_at': 3000,
          'updated_at': 3000,
          'selected_text': 'method',
          'selection_left': 0.2,
          'selection_top': 0.2,
          'selection_right': 0.4,
          'selection_bottom': 0.25,
        });
      },
    ),
  );
  await opened.close();
}

Future<String> dumpRows(Database database) async {
  final buffer = StringBuffer();
  for (final table in ['documents', 'notes', 'color_labels']) {
    final rows = await database.rawQuery('SELECT * FROM $table ORDER BY 1');
    final normalised = [
      for (final row in rows)
        Map.fromEntries(
          row.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
        ),
    ];
    buffer.writeln('$table: $normalised');
  }
  return buffer.toString();
}

class BrokenReadingStateDatabase extends ShelfDatabase {
  BrokenReadingStateDatabase({required super.factory, required super.path});

  @override
  Future<List<DocumentReadingState>> loadDocumentStates() async {
    throw StateError('no such table: document_state');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test('v2 database upgrades to v3 and ShelfStore.init succeeds', () async {
    final dir = await Directory.systemTemp.createTemp('shelf-v2-');
    addTearDown(() => dir.delete(recursive: true));
    final path = p.join(dir.path, 'shelf.db');
    await createV2Database(path);

    final beforeDb = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(readOnly: true),
    );
    final before = await dumpRows(beforeDb);
    final beforeVersion = (await beforeDb.rawQuery('PRAGMA user_version'))
        .first['user_version'];
    expect(beforeVersion, 2);
    final stateBefore = await beforeDb.rawQuery(
      "SELECT name FROM sqlite_master WHERE name = 'document_state'",
    );
    expect(stateBefore, isEmpty);
    await beforeDb.close();

    final library = await Directory.systemTemp.createTemp('shelf-v2-lib-');
    final cache = await Directory.systemTemp.createTemp('shelf-v2-cache-');
    addTearDown(() async {
      if (library.existsSync()) {
        await library.delete(recursive: true);
      }
      if (cache.existsSync()) {
        await cache.delete(recursive: true);
      }
    });
    final db = ShelfDatabase(
      factory: databaseFactoryFfi,
      path: path,
      libraryDirectory: library,
      cacheDirectory: cache,
    );
    addTearDown(db.close);
    final raw = await db.database;
    final version = (await raw.rawQuery('PRAGMA user_version'))
        .first['user_version'];
    expect(version, 3);
    final state = await raw.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'document_state'",
    );
    expect(state, isNotEmpty);
    expect(await dumpRows(raw), before);

    final store = ShelfStore(database: db);
    await store.init();
    expect(store.ready, isTrue);
    expect(store.documents.map((item) => item.id).toList(), ['pdf-2', 'pdf-1']);
    expect(store.notes, hasLength(1));
    expect(store.notes.single.text, 'Come back to this diagram.');
    expect(store.notes.single.selection?.text, 'method');
    expect(store.notes.single.selection?.left, 0.2);
    expect(store.labels.map((label) => label.id).toList(), [
      ColorLabel.orangeId,
      ColorLabel.purpleId,
      'label_custom',
    ]);
  });

  test('a broken reading-state read does not block startup', () async {
    final dir = await Directory.systemTemp.createTemp('shelf-state-');
    addTearDown(() => dir.delete(recursive: true));
    final db = BrokenReadingStateDatabase(
      factory: databaseFactoryFfi,
      path: p.join(dir.path, 'shelf.db'),
    );
    addTearDown(db.close);
    await db.upsertDocument(
      LibraryDocument(
        id: 'pdf-1',
        title: 'Notes on method',
        storedName: 'pdf-1.pdf',
        importedAt: DateTime.utc(2026, 9, 13),
        pageCount: 8,
      ),
    );
    final store = ShelfStore(database: db);
    await store.init();
    expect(store.ready, isTrue);
    expect(store.documents.single.id, 'pdf-1');
    expect(store.notes, isEmpty);
    expect(store.readingPositionFor('pdf-1'), isNull);
    expect(store.lastOpenedDocumentId, isNull);
  });
}
