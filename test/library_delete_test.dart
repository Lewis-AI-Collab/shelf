import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/data/shelf_database.dart';
import 'package:shelf/data/shelf_store.dart';
import 'package:shelf/models/color_label.dart';
import 'package:shelf/models/library_document.dart';
import 'package:shelf/models/note.dart';
import 'package:shelf/models/note_selection.dart';
import 'package:shelf/screens/home_shell.dart';
import 'package:shelf/screens/library_screen.dart';
import 'package:shelf/screens/reader_screen.dart';
import 'package:shelf/theme/shelf_theme.dart';
import 'package:shelf/widgets/shelf_menu_label.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory libraryDir;
  late Directory cacheDir;
  late ShelfDatabase db;
  late ShelfStore store;

  LibraryDocument doc({
    required String id,
    required String title,
    DateTime? importedAt,
    int? pageCount,
  }) {
    return LibraryDocument(
      id: id,
      title: title,
      storedName: '$id.pdf',
      importedAt: importedAt ?? DateTime.utc(2026, 9, 13),
      pageCount: pageCount ?? 8,
    );
  }

  Note noteFor({
    required String id,
    required String documentId,
    required String text,
    String? selected,
    int page = 2,
  }) {
    return Note(
      id: id,
      documentId: documentId,
      page: page,
      x: 0.3,
      y: 0.4,
      text: text,
      colorLabelId: ColorLabel.orangeId,
      createdAt: DateTime.utc(2026, 9, 13),
      updatedAt: DateTime.utc(2026, 9, 13),
      selection: selected == null
          ? null
          : NoteSelection(
              text: selected,
              left: 0.2,
              top: 0.2,
              right: 0.4,
              bottom: 0.25,
            ),
    );
  }

  Future<void> seedFiles() async {
    await File(p.join(libraryDir.path, 'pdf-1.pdf')).writeAsBytes([1, 2, 3]);
    await File(p.join(libraryDir.path, 'pdf-1-cover.png')).writeAsBytes([4]);
    await Directory(p.join(libraryDir.path, 'pdf-1')).create();
    await File(p.join(libraryDir.path, 'pdf-1', 'page.png')).writeAsBytes([5]);
    await Directory(p.join(cacheDir.path, 'covers')).create(recursive: true);
    await File(p.join(cacheDir.path, 'covers', 'pdf-1.png')).writeAsBytes([6]);
    await File(p.join(libraryDir.path, 'pdf-2.pdf')).writeAsBytes([7, 8]);
    await File(p.join(cacheDir.path, 'covers', 'pdf-2.png')).writeAsBytes([9]);
    await File(p.join(libraryDir.path, 'pdf-2-cover.png')).writeAsBytes([10]);
  }

  Future<void> seedStore({bool withPdf1File = true}) async {
    await db.upsertDocument(doc(id: 'pdf-1', title: 'Notes on method'));
    await db.upsertDocument(
      doc(
        id: 'pdf-2',
        title: 'Field guide',
        importedAt: DateTime.utc(2026, 9, 14),
        pageCount: 24,
      ),
    );
    await db.upsertNote(
      noteFor(
        id: 'note-1',
        documentId: 'pdf-1',
        text: 'Come back to this diagram.',
        selected: 'method',
      ),
    );
    await db.upsertNote(
      noteFor(
        id: 'note-2',
        documentId: 'pdf-2',
        text: 'Keep this field note.',
        selected: 'kept-word',
        page: 4,
      ),
    );
    if (withPdf1File) {
      await seedFiles();
    } else {
      await File(p.join(libraryDir.path, 'pdf-2.pdf')).writeAsBytes([7, 8]);
      await File(p.join(libraryDir.path, 'pdf-1-cover.png')).writeAsBytes([4]);
    }
    store = ShelfStore(database: db);
    await store.init();
  }

  setUp(() async {
    libraryDir = await Directory.systemTemp.createTemp('shelf-lib-');
    cacheDir = await Directory.systemTemp.createTemp('shelf-cache-');
    db = ShelfDatabase(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
      libraryDirectory: libraryDir,
      cacheDirectory: cacheDir,
    );
  });

  tearDown(() async {
    await db.close();
    if (libraryDir.existsSync()) {
      await libraryDir.delete(recursive: true);
    }
    if (cacheDir.existsSync()) {
      await cacheDir.delete(recursive: true);
    }
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle(
      const Duration(milliseconds: 50),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 3),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
  }

  Future<void> pumpLibrary(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ShelfTheme.light(),
        home: LibraryScreen(store: store),
      ),
    );
    await tester.pump();
  }

  Future<void> openDeleteMenu(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(Key('library-card-menu-$id')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  test('delete removes the document and only its stored data', () async {
    await seedStore();
    await store.noteDocumentOpened('pdf-2', page: 3);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await store.noteDocumentOpened('pdf-1', page: 6);
    expect(store.lastOpenedDocumentId, 'pdf-1');
    expect(store.readingPositionFor('pdf-1'), 6);
    final labelCount = store.labels.length;

    final removed = await store.removeDocument(store.documentById('pdf-1')!);

    expect(removed, isTrue);
    expect(store.documentById('pdf-1'), isNull);
    expect(store.notes.where((note) => note.documentId == 'pdf-1'), isEmpty);
    expect(store.readingPositionFor('pdf-1'), isNull);
    expect(store.openDocumentId, isNull);
    expect(store.lastOpenedDocumentId, 'pdf-2');
    expect(store.readingPositionFor('pdf-2'), 3);
    expect(store.notes.single.text, 'Keep this field note.');
    expect(store.notes.single.selection?.text, 'kept-word');
    expect(store.labels, hasLength(labelCount));
    expect(File(p.join(libraryDir.path, 'pdf-1.pdf')).existsSync(), isFalse);
    expect(
      File(p.join(libraryDir.path, 'pdf-1-cover.png')).existsSync(),
      isFalse,
    );
    expect(Directory(p.join(libraryDir.path, 'pdf-1')).existsSync(), isFalse);
    expect(
      File(p.join(cacheDir.path, 'covers', 'pdf-1.png')).existsSync(),
      isFalse,
    );
    expect(File(p.join(libraryDir.path, 'pdf-2.pdf')).existsSync(), isTrue);
    expect(
      File(p.join(libraryDir.path, 'pdf-2-cover.png')).existsSync(),
      isTrue,
    );
    expect(
      File(p.join(cacheDir.path, 'covers', 'pdf-2.png')).existsSync(),
      isTrue,
    );

    final again = ShelfStore(database: db);
    await again.init();
    expect(again.documents.single.id, 'pdf-2');
    expect(again.notes.single.id, 'note-2');
    expect(again.notes.single.selection?.text, 'kept-word');
    expect(again.readingPositionFor('pdf-1'), isNull);
    expect(again.readingPositionFor('pdf-2'), 3);
    expect(again.lastOpenedDocumentId, 'pdf-2');
    expect(again.searchNotes(query: 'diagram'), isEmpty);
    expect(again.searchNotes(query: 'field note'), hasLength(1));
  });

  test('missing file still removes the library entry', () async {
    await seedStore(withPdf1File: false);
    expect(File(p.join(libraryDir.path, 'pdf-1.pdf')).existsSync(), isFalse);

    final removed = await store.removeDocument(store.documentById('pdf-1')!);

    expect(removed, isTrue);
    expect(store.documents.single.id, 'pdf-2');
    expect(store.notes.single.documentId, 'pdf-2');
    expect(
      File(p.join(libraryDir.path, 'pdf-1-cover.png')).existsSync(),
      isFalse,
    );
    expect(File(p.join(libraryDir.path, 'pdf-2.pdf')).existsSync(), isTrue);
    final notes = await db.loadNotes();
    expect(notes.single.documentId, 'pdf-2');
    expect(await db.loadDocuments(), hasLength(1));
  });

  test('in-flight export blocks delete', () async {
    await seedStore();
    final gate = Completer<void>();
    final pending = store.withDocumentActivity('pdf-1', () => gate.future);

    final blocked = await store.removeDocument(store.documentById('pdf-1')!);

    expect(blocked, isFalse);
    expect(store.documents, hasLength(2));
    expect(store.notes, hasLength(2));
    expect(File(p.join(libraryDir.path, 'pdf-1.pdf')).existsSync(), isTrue);

    gate.complete();
    await pending;
    final removed = await store.removeDocument(store.documentById('pdf-1')!);
    expect(removed, isTrue);
    expect(store.documentById('pdf-1'), isNull);
    expect(File(p.join(libraryDir.path, 'pdf-2.pdf')).existsSync(), isTrue);
  });

  testWidgets('menu Delete asks, and Cancel deletes nothing', (tester) async {
    await tester.runAsync(seedStore);
    await pumpLibrary(tester);
    await openDeleteMenu(tester, 'pdf-1');

    expect(find.byIcon(Icons.delete_outline), findsWidgets);
    final menuLabel = tester.widget<Text>(find.text('Delete'));
    expect(menuLabel.style?.color, const Color(0xFFB91C1C));
    expect(
      find.widgetWithIcon(ShelfMenuLabel, Icons.delete_outline),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('library-card-delete')));
    await settle(tester);

    expect(find.text('Delete?'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Keep'), findsNothing);
    expect(find.text('Remove'), findsNothing);
    expect(find.textContaining('will be deleted'), findsNothing);
    final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
    expect((dialog.icon as Icon).icon, Icons.delete_outline);
    final confirm = tester.widget<TextButton>(
      find.byKey(const Key('library-delete-confirm')),
    );
    expect(
      confirm.style?.foregroundColor?.resolve({}),
      const Color(0xFFB91C1C),
    );

    await tester.tap(find.byKey(const Key('library-delete-cancel')));
    await settle(tester);

    expect(find.text('Notes on method'), findsOneWidget);
    expect(find.text('Field guide'), findsOneWidget);
    expect(store.documents, hasLength(2));
    expect(store.notes, hasLength(2));
    expect(File(p.join(libraryDir.path, 'pdf-1.pdf')).existsSync(), isTrue);
    expect(
      File(p.join(libraryDir.path, 'pdf-1-cover.png')).existsSync(),
      isTrue,
    );
  });

  testWidgets('menu Delete removes the book and leaves the other', (
    tester,
  ) async {
    await tester.runAsync(seedStore);
    await pumpLibrary(tester);
    await openDeleteMenu(tester, 'pdf-1');
    await tester.tap(find.byKey(const Key('library-card-delete')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('library-delete-confirm')));
    await settle(tester);

    expect(find.text('Notes on method'), findsNothing);
    expect(find.text('Field guide'), findsOneWidget);
    expect(find.text('Nothing here yet'), findsNothing);
    expect(store.documents.single.id, 'pdf-2');
    expect(store.notes.single.documentId, 'pdf-2');
    expect(File(p.join(libraryDir.path, 'pdf-1.pdf')).existsSync(), isFalse);
    expect(File(p.join(libraryDir.path, 'pdf-2.pdf')).existsSync(), isTrue);
  });

  testWidgets('swipe Delete confirms and removes the book', (tester) async {
    await tester.runAsync(seedStore);
    await pumpLibrary(tester);
    await tester.drag(
      find.byKey(const ValueKey('pdf-1')),
      const Offset(-240, 0),
    );
    await settle(tester);

    expect(find.text('Delete?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('library-delete-confirm')));
    await settle(tester);

    expect(find.text('Notes on method'), findsNothing);
    expect(find.text('Field guide'), findsOneWidget);
    expect(File(p.join(libraryDir.path, 'pdf-1.pdf')).existsSync(), isFalse);
    expect(File(p.join(libraryDir.path, 'pdf-2.pdf')).existsSync(), isTrue);
  });

  testWidgets('deleting the last book shows the empty library', (tester) async {
    await tester.runAsync(seedStore);
    await tester.runAsync(
      () => store.removeDocument(store.documentById('pdf-2')!),
    );
    await pumpLibrary(tester);
    await openDeleteMenu(tester, 'pdf-1');
    await tester.tap(find.byKey(const Key('library-card-delete')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('library-delete-confirm')));
    await settle(tester);

    expect(find.text('Nothing here yet'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsOneWidget);
    expect(store.documents, isEmpty);
    expect(store.notes, isEmpty);
  });

  testWidgets('menu Delete is blocked while an export is in flight', (
    tester,
  ) async {
    await tester.runAsync(seedStore);
    final gate = Completer<void>();
    final pending = store.withDocumentActivity('pdf-1', () => gate.future);
    await pumpLibrary(tester);
    await openDeleteMenu(tester, 'pdf-1');
    await tester.tap(find.byKey(const Key('library-card-delete')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Export in progress'), findsOneWidget);
    expect(find.text('Delete?'), findsNothing);
    expect(find.text('Notes on method'), findsOneWidget);
    expect(File(p.join(libraryDir.path, 'pdf-1.pdf')).existsSync(), isTrue);

    gate.complete();
    await pending;
  });

  testWidgets('deleted book notes leave the Notes hub', (tester) async {
    await tester.runAsync(seedStore);
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ShelfTheme.light(),
        home: HomeShell(store: store),
      ),
    );
    await tester.pump();
    await openDeleteMenu(tester, 'pdf-1');
    await tester.tap(find.byKey(const Key('library-card-delete')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('library-delete-confirm')));
    await settle(tester);

    await tester.tap(find.byKey(const Key('nav-notes')));
    await settle(tester);

    expect(find.text('Come back to this diagram.'), findsNothing);
    expect(find.text('method'), findsNothing);
    expect(find.text('Keep this field note.'), findsOneWidget);
    expect(find.text('kept-word'), findsOneWidget);
    expect(find.text('Missing PDF'), findsNothing);
    expect(find.text('Field guide'), findsOneWidget);
  });

  testWidgets('deleting the open book closes the reader', (tester) async {
    // No library-directory override: the viewer never gets a file path, so
    // this stays on the opening spinner instead of starting pdfrx.
    final plain = ShelfDatabase(
      factory: databaseFactoryFfi,
      path: p.join(libraryDir.path, 'reader.db'),
    );
    addTearDown(plain.close);
    late ShelfStore plainStore;
    await tester.runAsync(() async {
      await plain.upsertDocument(doc(id: 'pdf-1', title: 'Notes on method'));
      await plain.upsertDocument(
        doc(
          id: 'pdf-2',
          title: 'Field guide',
          importedAt: DateTime.utc(2026, 9, 14),
        ),
      );
      await plain.upsertNote(
        noteFor(
          id: 'note-1',
          documentId: 'pdf-1',
          text: 'Come back to this diagram.',
          selected: 'method',
        ),
      );
      await plain.upsertNote(
        noteFor(
          id: 'note-2',
          documentId: 'pdf-2',
          text: 'Keep this field note.',
          selected: 'kept-word',
          page: 4,
        ),
      );
      plainStore = ShelfStore(database: plain);
      await plainStore.init();
    });
    final document = plainStore.documentById('pdf-1')!;
    await tester.pumpWidget(
      MaterialApp(
        theme: ShelfTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        ReaderScreen(store: plainStore, document: document),
                  ),
                );
              },
              child: const Text('Library home'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Library home'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(ReaderScreen), findsOneWidget);
    expect(plainStore.openDocumentId, 'pdf-1');
    expect(plainStore.lastOpenedDocumentId, 'pdf-1');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );

    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      pathChannel,
      (call) async => throw PlatformException(code: 'missing'),
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        pathChannel,
        null,
      ),
    );

    final pending = plainStore.removeDocument(document);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(ReaderScreen), findsNothing);
    expect(find.text('Library home'), findsOneWidget);
    final removed = await tester.runAsync(() => pending);
    expect(removed, isTrue);
    expect(removed, isTrue);

    expect(find.byType(ReaderScreen), findsNothing);
    expect(find.text('Library home'), findsOneWidget);
    expect(plainStore.openDocumentId, isNull);
    expect(plainStore.documentById('pdf-1'), isNull);
    expect(plainStore.readingPositionFor('pdf-1'), isNull);
    expect(
      plainStore.notes.where((note) => note.documentId == 'pdf-1'),
      isEmpty,
    );
    expect(plainStore.documentById('pdf-2'), isNotNull);
    expect(plainStore.notes.single.text, 'Keep this field note.');
  });
}
