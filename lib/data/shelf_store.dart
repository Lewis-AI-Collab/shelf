import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import '../models/color_label.dart';
import '../models/library_document.dart';
import '../models/note.dart';
import '../models/note_selection.dart';
import 'shelf_database.dart';

class ShelfStore extends ChangeNotifier {
  ShelfStore({ShelfDatabase? database}) : _db = database ?? ShelfDatabase();

  final ShelfDatabase _db;

  final List<LibraryDocument> documents = [];
  final List<Note> notes = [];
  final List<ColorLabel> labels = [];
  bool ready = false;
  String? lastError;

  /// Document whose reader route is on screen, if any.
  String? openDocumentId;

  /// Most recently opened document that is still in the library.
  String? lastOpenedDocumentId;

  final Map<String, int> _readingPositions = {};
  final Map<String, DateTime> _openedAt = {};
  final Map<String, int> _activity = {};
  final Set<String> _deletedIds = {};

  ColorLabel get defaultLabel {
    return labels.firstWhere(
      (label) => label.isDefault,
      orElse: () =>
          labels.isNotEmpty ? labels.first : ColorLabel.seedDefaults().first,
    );
  }

  ColorLabel labelById(String id) {
    return labels.firstWhere(
      (label) => label.id == id,
      orElse: () => defaultLabel,
    );
  }

  Future<void> init() async {
    documents
      ..clear()
      ..addAll(await _db.loadDocuments());
    labels
      ..clear()
      ..addAll(await _db.loadLabels());
    notes
      ..clear()
      ..addAll(await _db.loadNotes());
    await _loadReadingState();
    ready = true;
    notifyListeners();
  }

  Future<void> _loadReadingState() async {
    _readingPositions.clear();
    _openedAt.clear();
    lastOpenedDocumentId = null;
    final states = await _db.loadDocumentStates();
    DateTime? newest;
    for (final state in states) {
      if (_deletedIds.contains(state.documentId)) {
        continue;
      }
      if (documentById(state.documentId) == null) {
        continue;
      }
      final page = state.lastPage;
      if (page != null && page >= 1) {
        _readingPositions[state.documentId] = page;
      }
      final opened = state.lastOpenedAt;
      if (opened == null) {
        continue;
      }
      _openedAt[state.documentId] = opened;
      final currentNewest = newest;
      if (currentNewest == null || opened.isAfter(currentNewest)) {
        newest = opened;
        lastOpenedDocumentId = state.documentId;
      }
    }
  }

  int? readingPositionFor(String documentId) => _readingPositions[documentId];

  bool isDocumentBusy(String documentId) => (_activity[documentId] ?? 0) > 0;

  /// Holds a document while an export or share is in flight so delete can
  /// refuse instead of removing the file mid-send.
  Future<void> withDocumentActivity(
    String documentId,
    Future<void> Function() action,
  ) async {
    _activity[documentId] = (_activity[documentId] ?? 0) + 1;
    try {
      return await action();
    } finally {
      final next = (_activity[documentId] ?? 1) - 1;
      if (next <= 0) {
        _activity.remove(documentId);
      } else {
        _activity[documentId] = next;
      }
    }
  }

  /// Records the open reader. Does not change which page the reader shows.
  Future<void> noteDocumentOpened(String id, {int? page}) {
    if (_deletedIds.contains(id) || documentById(id) == null) {
      return Future<void>.value();
    }
    openDocumentId = id;
    lastOpenedDocumentId = id;
    _openedAt[id] = DateTime.now();
    if (page != null && page >= 1) {
      _readingPositions[id] = page;
    }
    return _persistDocumentState(id);
  }

  void noteDocumentClosed(String id) {
    if (openDocumentId == id) {
      openDocumentId = null;
    }
  }

  /// Records the page the reader is showing. Opening still starts at page 1
  /// or the note page; this exists so delete can drop the stored position.
  Future<void> noteReadingPosition(String id, int page) {
    if (page < 1 || _deletedIds.contains(id) || documentById(id) == null) {
      return Future<void>.value();
    }
    if (_readingPositions[id] == page && _openedAt.containsKey(id)) {
      return Future<void>.value();
    }
    _readingPositions[id] = page;
    return _persistDocumentState(id);
  }

  Future<void> _persistDocumentState(String id) async {
    if (_deletedIds.contains(id) || documentById(id) == null) {
      return;
    }
    try {
      await _db.upsertDocumentState(
        DocumentReadingState(
          documentId: id,
          lastPage: _readingPositions[id],
          lastOpenedAt: _openedAt[id],
        ),
      );
    } on Object {
      // Reading position must not break the reader or the library.
    }
    if (_deletedIds.contains(id)) {
      try {
        await _db.deleteDocument(id);
      } on Object {
        // The delete path already removed the row.
      }
    }
  }

  LibraryDocument? documentById(String id) {
    for (final document in documents) {
      if (document.id == id) {
        return document;
      }
    }
    return null;
  }

  List<Note> notesForDocument(String documentId) {
    return notes.where((note) => note.documentId == documentId).toList();
  }

  List<Note> notesOnPage(String documentId, int page) {
    return notes
        .where((note) => note.documentId == documentId && note.page == page)
        .toList();
  }

  List<Note> searchNotes({String query = '', String? colorLabelId}) {
    final needle = query.trim().toLowerCase();
    return notes.where((note) {
      if (colorLabelId != null && note.colorLabelId != colorLabelId) {
        return false;
      }
      if (needle.isEmpty) {
        return true;
      }
      final document = documentById(note.documentId);
      final label = labelById(note.colorLabelId);
      final haystack = [
        note.text,
        note.selection?.text ?? '',
        document?.title ?? '',
        label.name,
        label.meaning,
        'page ${note.page}',
      ].join(' ').toLowerCase();
      return haystack.contains(needle);
    }).toList();
  }

  Future<String> pdfPath(LibraryDocument document) {
    return _db.pdfPathFor(document);
  }

  Future<LibraryDocument?> importPdf() async {
    lastError = null;
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
    );
    if (picked == null || picked.files.isEmpty) {
      return null;
    }
    final sourcePath = picked.files.single.path;
    if (sourcePath == null) {
      lastError = 'Could not read that file on this device.';
      notifyListeners();
      return null;
    }

    final id = ShelfDatabase.newId();
    final originalName = picked.files.single.name;
    final title = p.basenameWithoutExtension(originalName);
    final storedName = '$id.pdf';
    final dir = await _db.libraryDirectory();
    final destination = File(p.join(dir.path, storedName));
    await File(sourcePath).copy(destination.path);

    var pageCount = 0;
    try {
      final pdf = await PdfDocument.openFile(destination.path);
      pageCount = pdf.pages.length;
      await pdf.dispose();
    } on Object {
      pageCount = 0;
    }

    final document = LibraryDocument(
      id: id,
      title: title.isEmpty ? 'Untitled PDF' : title,
      storedName: storedName,
      importedAt: DateTime.now(),
      pageCount: pageCount == 0 ? null : pageCount,
    );
    await _db.upsertDocument(document);
    documents.insert(0, document);
    notifyListeners();
    return document;
  }

  Future<void> updatePageCount(String documentId, int pageCount) async {
    final index = documents.indexWhere((doc) => doc.id == documentId);
    if (index < 0) {
      return;
    }
    final updated = documents[index].copyWith(pageCount: pageCount);
    documents[index] = updated;
    await _db.upsertDocument(updated);
    notifyListeners();
  }

  /// Drops [document] from the library. Returns false when an export or share
  /// for it is still in flight, and deletes nothing in that case.
  ///
  /// Otherwise removes the copied file (a missing file is fine), notes,
  /// comments, highlights, selection anchors, reading position, last-opened
  /// mark, and cover or thumbnail files named for this document only.
  Future<bool> removeDocument(LibraryDocument document) async {
    final id = document.id;
    if (isDocumentBusy(id)) {
      return false;
    }
    _deletedIds.add(id);
    _readingPositions.remove(id);
    _openedAt.remove(id);
    if (openDocumentId == id) {
      openDocumentId = null;
    }
    if (lastOpenedDocumentId == id) {
      lastOpenedDocumentId = _latestOpenedId();
    }
    documents.removeWhere((item) => item.id == id);
    notes.removeWhere((note) => note.documentId == id);
    notifyListeners();
    try {
      await _db.deleteDocumentFiles(document, extraRoots: _pdfCacheRoots());
    } on Object {
      // File cleanup is best-effort; the library row still goes.
    }
    await _db.deleteDocument(id);
    return true;
  }

  String? _latestOpenedId() {
    String? id;
    DateTime? newest;
    for (final entry in _openedAt.entries) {
      final current = newest;
      if (current == null || entry.value.isAfter(current)) {
        newest = entry.value;
        id = entry.key;
      }
    }
    return id;
  }

  List<Directory> _pdfCacheRoots() {
    final configured = Pdfrx.cacheDirectoryPath;
    if (configured == null || configured.isEmpty) {
      return const [];
    }
    return [Directory(configured)];
  }

  Future<Note> addNote({
    required String documentId,
    required int page,
    required double x,
    required double y,
    String text = '',
    String? colorLabelId,
    NoteSelection? selection,
  }) async {
    final now = DateTime.now();
    final note = Note(
      id: ShelfDatabase.newId(),
      documentId: documentId,
      page: page,
      x: Note.normalizeCoord(x),
      y: Note.normalizeCoord(y),
      text: text,
      colorLabelId: colorLabelId ?? defaultLabel.id,
      createdAt: now,
      updatedAt: now,
      selection: selection,
    );
    await _db.upsertNote(note);
    notes.insert(0, note);
    notifyListeners();
    return note;
  }

  Future<void> saveNote(Note note) async {
    final updated = note.copyWith(updatedAt: DateTime.now());
    await _db.upsertNote(updated);
    final index = notes.indexWhere((item) => item.id == updated.id);
    if (index >= 0) {
      notes[index] = updated;
    } else {
      notes.insert(0, updated);
    }
    notes.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    notifyListeners();
  }

  Future<void> deleteNote(String id) async {
    await _db.deleteNote(id);
    notes.removeWhere((note) => note.id == id);
    notifyListeners();
  }

  Future<void> saveLabel(ColorLabel label) async {
    var next = label;
    if (label.isDefault) {
      for (var i = 0; i < labels.length; i++) {
        if (labels[i].id != label.id && labels[i].isDefault) {
          labels[i] = labels[i].copyWith(isDefault: false);
        }
      }
    }
    final index = labels.indexWhere((item) => item.id == label.id);
    if (index >= 0) {
      labels[index] = next;
    } else {
      labels.add(next);
    }
    labels.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    await _db.upsertLabel(next);
    notifyListeners();
  }

  Future<void> deleteLabel(ColorLabel label) async {
    if (labels.length <= 1) {
      lastError = 'Keep at least one colour label.';
      notifyListeners();
      return;
    }
    final fallback = labels.firstWhere(
      (item) => item.id != label.id && item.isDefault,
      orElse: () => labels.firstWhere((item) => item.id != label.id),
    );
    var promoted = fallback;
    if (label.isDefault && !fallback.isDefault) {
      promoted = fallback.copyWith(isDefault: true);
      await _db.upsertLabel(promoted);
    }
    await _db.deleteLabel(label.id, fallbackId: promoted.id);
    labels.removeWhere((item) => item.id == label.id);
    final fallbackIndex = labels.indexWhere((item) => item.id == promoted.id);
    if (fallbackIndex >= 0) {
      labels[fallbackIndex] = promoted;
    }
    for (var i = 0; i < notes.length; i++) {
      if (notes[i].colorLabelId == label.id) {
        notes[i] = notes[i].copyWith(colorLabelId: promoted.id);
      }
    }
    notifyListeners();
  }
}
