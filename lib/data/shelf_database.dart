import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../models/color_label.dart';
import '../models/library_document.dart';
import '../models/note.dart';

class DocumentReadingState {
  const DocumentReadingState({
    required this.documentId,
    this.lastPage,
    this.lastOpenedAt,
  });

  final String documentId;
  final int? lastPage;
  final DateTime? lastOpenedAt;

  Map<String, Object?> toMap() {
    return {
      'document_id': documentId,
      'last_page': lastPage,
      'last_opened_at': lastOpenedAt?.millisecondsSinceEpoch,
    };
  }

  factory DocumentReadingState.fromMap(Map<String, Object?> map) {
    final opened = map['last_opened_at'] as int?;
    return DocumentReadingState(
      documentId: map['document_id']! as String,
      lastPage: map['last_page'] as int?,
      lastOpenedAt: opened == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(opened),
    );
  }
}

class ShelfDatabase {
  ShelfDatabase({
    DatabaseFactory? factory,
    String? path,
    Directory? libraryDirectory,
    Directory? cacheDirectory,
  }) : _factory = factory ?? databaseFactory,
       _overridePath = path,
       _libraryDirectoryOverride = libraryDirectory,
       _cacheDirectoryOverride = cacheDirectory;

  static const _uuid = Uuid();
  static const _schemaVersion = 3;

  final DatabaseFactory _factory;
  final String? _overridePath;
  final Directory? _libraryDirectoryOverride;
  final Directory? _cacheDirectoryOverride;
  Database? _db;

  static String newId() => _uuid.v4();

  Future<Database> get database async {
    final existing = _db;
    if (existing != null) {
      return existing;
    }
    final opened = await _open();
    _db = opened;
    return opened;
  }

  Future<Database> _open() async {
    final dbPath = _overridePath ?? await _defaultPath();
    return _factory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: _schemaVersion,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
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
          await _createDocumentState(db);
          await _seedLabels(db);
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await db.execute('ALTER TABLE notes ADD COLUMN selected_text TEXT');
            await db.execute(
              'ALTER TABLE notes ADD COLUMN selection_left REAL',
            );
            await db.execute('ALTER TABLE notes ADD COLUMN selection_top REAL');
            await db.execute(
              'ALTER TABLE notes ADD COLUMN selection_right REAL',
            );
            await db.execute(
              'ALTER TABLE notes ADD COLUMN selection_bottom REAL',
            );
          }
          if (oldVersion < 3) {
            await _createDocumentState(db);
          }
        },
      ),
    );
  }

  Future<String> _defaultPath() async {
    final databasesPath = await getDatabasesPath();
    return p.join(databasesPath, 'shelf.db');
  }

  Future<Directory> libraryDirectory() async {
    final override = _libraryDirectoryOverride;
    if (override != null) {
      if (!override.existsSync()) {
        await override.create(recursive: true);
      }
      return override;
    }
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'library'));
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<void> _createDocumentState(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS document_state (
        document_id TEXT PRIMARY KEY,
        last_page INTEGER,
        last_opened_at INTEGER,
        FOREIGN KEY(document_id) REFERENCES documents(id) ON DELETE CASCADE
      )
    ''');
  }

  Future<String> pdfPathFor(LibraryDocument document) async {
    final dir = await libraryDirectory();
    return p.join(dir.path, document.storedName);
  }

  Future<void> _seedLabels(Database db) async {
    for (final label in ColorLabel.seedDefaults()) {
      await db.insert('color_labels', label.toMap());
    }
  }

  Future<List<LibraryDocument>> loadDocuments() async {
    final db = await database;
    final rows = await db.query('documents', orderBy: 'imported_at DESC');
    return rows.map(LibraryDocument.fromMap).toList();
  }

  Future<void> upsertDocument(LibraryDocument document) async {
    final db = await database;
    await db.insert(
      'documents',
      document.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteDocument(String id) async {
    final db = await database;
    await _deleteDocumentRows(db, id);
  }

  Future<void> removeStoredDocument(
    LibraryDocument document, {
    List<Directory> extraRoots = const [],
    required void Function() onStored,
  }) async {
    final db = await database;
    await _deleteDocumentRows(db, document.id);
    await deleteDocumentFiles(document, extraRoots: extraRoots);
    onStored();
  }

  Future<void> _deleteDocumentRows(Database db, String id) {
    return db.transaction((txn) async {
      await txn.delete('notes', where: 'document_id = ?', whereArgs: [id]);
      await txn.delete(
        'document_state',
        where: 'document_id = ?',
        whereArgs: [id],
      );
      await txn.delete('documents', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<List<DocumentReadingState>> loadDocumentStates() async {
    final db = await database;
    final rows = await db.query('document_state');
    return rows.map(DocumentReadingState.fromMap).toList();
  }

  Future<void> upsertDocumentState(DocumentReadingState state) async {
    final db = await database;
    await db.insert(
      'document_state',
      state.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Removes the copied PDF and any cover, thumbnail, or cache file owned by
  /// this document. A missing file is ignored. Other documents are left alone.
  Future<void> deleteDocumentFiles(
    LibraryDocument document, {
    List<Directory> extraRoots = const [],
  }) async {
    final roots = <Directory>[
      await libraryDirectory(),
      ...extraRoots,
      ...await _cacheRoots(),
    ];
    final seen = <String>{};
    for (final root in roots) {
      final key = p.normalize(root.path);
      if (!seen.add(key)) {
        continue;
      }
      _purgeDocumentRoot(root, document);
    }
  }

  Future<List<Directory>> _cacheRoots() async {
    final override = _cacheDirectoryOverride;
    if (override != null) {
      return [override];
    }
    final roots = <Directory>[];
    try {
      roots.add(await getApplicationCacheDirectory());
    } on Object {
      // Tests have no path_provider plugin.
    }
    try {
      roots.add(await getTemporaryDirectory());
    } on Object {
      // Tests have no path_provider plugin.
    }
    return roots;
  }

  void _purgeDocumentRoot(Directory root, LibraryDocument document) {
    if (!root.existsSync()) {
      return;
    }
    _deleteStoredFile(root, document);
    _purgeOwned(root, document.id);
    for (final name in const [
      'covers',
      'thumbs',
      'thumbnails',
      'cache',
      'pdfrx.cache',
    ]) {
      final nested = Directory(p.join(root.path, name));
      if (!nested.existsSync()) {
        continue;
      }
      _purgeOwned(nested, document.id);
    }
  }

  void _deleteStoredFile(Directory dir, LibraryDocument document) {
    final name = p.basename(document.storedName);
    if (name.isEmpty || name == '.' || name == '..') {
      return;
    }
    _deleteFile(File(p.join(dir.path, name)));
  }

  void _purgeOwned(Directory dir, String id) {
    if (id.isEmpty || !dir.existsSync()) {
      return;
    }
    for (final entity in dir.listSync(followLinks: false)) {
      final name = p.basename(entity.path);
      if (!_ownedByDocument(name, id)) {
        continue;
      }
      try {
        if (entity is Directory) {
          entity.deleteSync(recursive: true);
        } else if (entity is File) {
          _deleteFile(entity);
        }
      } on Object {
        // Best-effort. The library row is still removed.
      }
    }
  }

  static const _artifactExtensions = ['.pdf', '.png', '.jpg', '.jpeg', '.webp'];

  /// Exact names for this id only: `{id}`, `{id}.pdf`, `{id}.png`, `{id}-cover.png`.
  /// A longer id such as `{id}-x` or `10` when this id is `1` does not match.
  static bool _ownedByDocument(String name, String id) {
    if (id.isEmpty || name.isEmpty) {
      return false;
    }
    if (name == id) {
      return true;
    }
    for (final extension in _artifactExtensions) {
      if (name == '$id$extension' || name == '$id-cover$extension') {
        return true;
      }
    }
    return false;
  }

  void _deleteFile(File file) {
    try {
      if (!file.existsSync()) {
        return;
      }
      file.deleteSync();
    } on Object {
      try {
        if (file.existsSync()) {
          file.deleteSync();
        }
      } on Object {
        // Missing or locked. The library entry still goes.
      }
    }
  }

  Future<List<Note>> loadNotes() async {
    final db = await database;
    final rows = await db.query('notes', orderBy: 'updated_at DESC');
    return rows.map(Note.fromMap).toList();
  }

  Future<void> upsertNote(Note note) async {
    final db = await database;
    await db.insert(
      'notes',
      note.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteNote(String id) async {
    final db = await database;
    await db.delete('notes', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<ColorLabel>> loadLabels() async {
    final db = await database;
    final rows = await db.query('color_labels', orderBy: 'sort_order ASC');
    if (rows.isEmpty) {
      await _seedLabels(db);
      return ColorLabel.seedDefaults();
    }
    return rows.map(ColorLabel.fromMap).toList();
  }

  Future<void> upsertLabel(ColorLabel label) async {
    final db = await database;
    await db.transaction((txn) async {
      if (label.isDefault) {
        await txn.update('color_labels', {'is_default': 0});
      }
      await txn.insert(
        'color_labels',
        label.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  Future<void> deleteLabel(String id, {required String fallbackId}) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.update(
        'notes',
        {'color_label_id': fallbackId},
        where: 'color_label_id = ?',
        whereArgs: [id],
      );
      await txn.delete('color_labels', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<void> close() async {
    final existing = _db;
    _db = null;
    if (existing != null) {
      await existing.close();
    }
  }
}
