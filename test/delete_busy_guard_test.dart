import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/data/shelf_database.dart';
import 'package:shelf/data/shelf_store.dart';
import 'package:shelf/models/color_label.dart';
import 'package:shelf/models/library_document.dart';
import 'package:shelf/models/note.dart';
import 'package:shelf/screens/library_screen.dart';
import 'package:shelf/screens/notes_hub_screen.dart';
import 'package:shelf/services/ai_secure_storage.dart';
import 'package:shelf/services/ai_settings_controller.dart';
import 'package:shelf/services/pdf_outline_source.dart';
import 'package:shelf/services/speech_capture.dart';
import 'package:shelf/theme/shelf_theme.dart';
import 'package:shelf/widgets/ai_scope.dart';
import 'package:shelf/widgets/note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_ai_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late ShelfDatabase db;
  late ShelfStore store;
  late AiSettingsController ai;

  setUp(() async {
    db = ShelfDatabase(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final document = LibraryDocument(
      id: 'pdf-1',
      title: 'Notes on method',
      storedName: 'pdf-1.pdf',
      importedAt: DateTime.utc(2026, 9, 13),
      pageCount: 8,
    );
    await db.upsertDocument(document);
    await db.upsertNote(
      Note(
        id: 'note-1',
        documentId: 'pdf-1',
        page: 2,
        x: 0.3,
        y: 0.4,
        text: 'Come back to this diagram.',
        colorLabelId: ColorLabel.orangeId,
        createdAt: DateTime.utc(2026, 9, 13),
        updatedAt: DateTime.utc(2026, 9, 13),
      ),
    );
    store = ShelfStore(database: db);
    await store.init();
    ai = AiSettingsController(
      storage: MemoryAiSecureStorage(),
      client: FakeAiClient(),
    );
    await ai.load();
    await ai.saveApiKey('sk-test-not-a-real-key');
    PdfOutlineSource.loadForDocumentOverride = (_, _) async => const [];
  });

  tearDown(() async {
    PdfOutlineSource.loadForDocumentOverride = null;
    await db.close();
  });

  Future<void> pumpLibrary(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      AiScope(
        controller: ai,
        child: MaterialApp(
          theme: ShelfTheme.light(),
          home: LibraryScreen(store: store),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> expectDeleteRefused() async {
    final removed = await store.removeDocument(store.documentById('pdf-1')!);
    expect(removed, isFalse);
    expect(store.documentById('pdf-1'), isNotNull);
    expect(store.notes, hasLength(1));
  }

  testWidgets('library Export holds the book until the preview closes', (
    tester,
  ) async {
    await pumpLibrary(tester);
    await tester.tap(find.byKey(const Key('library-card-menu-pdf-1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('library-card-export-comments')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const Key('markdown-preview-sheet')), findsOneWidget);

    await expectDeleteRefused();
  });

  testWidgets('Send to AI holds the book while the scope dialog is open', (
    tester,
  ) async {
    await pumpLibrary(tester);
    await tester.tap(find.byKey(const Key('library-card-menu-pdf-1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('library-card-send-to-ai')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('ai-send-scope-dialog')), findsOneWidget);

    await expectDeleteRefused();
  });

  testWidgets(
    'Notes hub Ask / share holds the book while the chooser is open',
    (tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: ShelfTheme.light(),
          home: NotesHubScreen(store: store),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('ask-about-note-note-1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('ask-with-your-ai')), findsOneWidget);
      expect(find.byKey(const Key('export-share-note')), findsOneWidget);

      await expectDeleteRefused();
    },
  );

  testWidgets('reader Ask / share holds the book while the chooser is open', (
    tester,
  ) async {
    final document = store.documentById('pdf-1')!;
    await tester.pumpWidget(
      MaterialApp(
        theme: ShelfTheme.light(),
        home: Scaffold(
          body: NoteEditor(
            labels: store.labels,
            defaultLabelId: store.defaultLabel.id,
            speech: SpeechCapture(),
            document: document,
            documentTitle: document.title,
            note: store.notes.single,
            documentActivity: store.withDocumentActivity,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('ask-about-note')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('ask-with-your-ai')), findsOneWidget);
    expect(find.byKey(const Key('export-share-note')), findsOneWidget);

    await expectDeleteRefused();
  });
}
