import 'dart:io';

import 'package:flutter/material.dart';

import '../models/ai_provider.dart';
import '../models/color_label.dart';
import '../models/library_document.dart';
import '../models/note.dart';
import '../models/note_selection.dart';
import '../services/ai_client.dart';
import '../services/export_share.dart';
import '../services/notes_export.dart';
import '../services/pdf_section_resolver.dart';
import '../theme/shelf_theme.dart';
import 'ai_scope.dart';
import 'ai_send_scope.dart';
import 'markdown_preview_sheet.dart';
import 'note_share_sheet.dart';

typedef PdfBytesLoader = Future<List<int>?> Function();

/// Runs [action] while [documentId] must not be deleted (export / share).
typedef DocumentActivityGuard = Future<void> Function(
  String documentId,
  Future<void> Function() action,
);

/// Ask AI on an open note: ask a connected provider, or share this note.
class AskAboutNoteButton extends StatelessWidget {
  const AskAboutNoteButton({
    super.key,
    required this.noteText,
    this.selectedText,
    this.documentTitle,
    this.document,
    this.page,
    this.x,
    this.y,
    this.colorLabelId,
    this.compact = false,
    this.offerPdf = false,
    this.loadPdf,
    this.pdfFileName,
    this.notes = const [],
    this.heading,
    this.subheading,
    this.sections = const [],
    this.note,
    this.labels = const [],
    this.labelById,
    this.loadSections,
    this.documentActivity,
  });

  /// Read at tap time so the composer field is current.
  final String Function() noteText;
  final String? selectedText;
  final String? documentTitle;
  final LibraryDocument? document;
  final int? page;
  final double? x;
  final double? y;
  final String? colorLabelId;
  final bool compact;
  final bool offerPdf;
  final PdfBytesLoader? loadPdf;
  final String? pdfFileName;
  final List<AiNoteSnippet> notes;
  final String? heading;
  final String? subheading;

  /// Current PDF outline (or page-title fallback). Used when [heading]
  /// is not passed explicitly.
  final List<PdfSection> sections;
  final Note? note;
  final List<ColorLabel> labels;
  final ColorLabel Function(String id)? labelById;
  final Future<List<PdfSection>> Function()? loadSections;
  final DocumentActivityGuard? documentActivity;

  static AiAskRequest requestFor({
    required String noteText,
    String? selectedText,
    String? documentTitle,
    int? page,
    Note? note,
    List<AiNoteSnippet> notes = const [],
    List<int>? pdfBytes,
    String? pdfFileName,
    String? pdfSkippedReason,
    String? heading,
    String? subheading,
    List<PdfSection> sections = const [],
  }) {
    final resolved = _resolveHeadings(
      heading: heading,
      subheading: subheading,
      sections: sections,
      note: note,
      page: page,
    );
    return AiAskRequest(
      noteText: noteText.trim().isNotEmpty ? noteText : (note?.text ?? ''),
      selectedText: selectedText ?? note?.selection?.text,
      documentTitle: documentTitle,
      page: page ?? note?.page,
      heading: resolved.heading,
      subheading: resolved.subheading,
      notes: notes,
      pdfBytes: pdfBytes,
      pdfFileName: pdfFileName,
      pdfSkippedReason: pdfSkippedReason,
    );
  }

  static NoteHeadings _resolveHeadings({
    String? heading,
    String? subheading,
    List<PdfSection> sections = const [],
    Note? note,
    int? page,
  }) {
    if ((heading != null && heading.trim().isNotEmpty) ||
        (subheading != null && subheading.trim().isNotEmpty)) {
      return NoteHeadings(
        heading: heading?.trim().isEmpty == true ? null : heading?.trim(),
        subheading: subheading?.trim().isEmpty == true
            ? null
            : subheading?.trim(),
      );
    }
    if (note != null) {
      return PdfSectionResolver.forNote(note, sections);
    }
    if (page != null) {
      return PdfSectionResolver.headingsFor(sections: sections, page: page);
    }
    return const NoteHeadings();
  }

  static Future<void> open(
    BuildContext context, {
    required String noteText,
    String? selectedText,
    String? documentTitle,
    int? page,
    Note? note,
    List<AiNoteSnippet> notes = const [],
    bool offerPdf = false,
    PdfBytesLoader? loadPdf,
    String? pdfFileName,
    String? heading,
    String? subheading,
    List<PdfSection> sections = const [],
    Future<List<PdfSection>> Function()? loadSections,
    List<Note> notesToResolve = const [],
    ColorLabel Function(String id)? labelById,
  }) async {
    final ai = AiScope.maybeOf(context);
    if (ai == null || !ai.hasApiKey) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Add your own API key in Settings. Shelf does not ship a house key.',
          ),
        ),
      );
      return;
    }
    final sectionsFuture = loadSections?.call();
    List<int>? pdfBytes;
    String? pdfSkippedReason;
    if (offerPdf && loadPdf != null) {
      final scope = await AiSendScopeDialog.show(context);
      if (!context.mounted || scope == null) {
        return;
      }
      if (scope == AiSendScope.includePdf) {
        if (!ai.provider.supportsPdfAttachment) {
          pdfSkippedReason = ai.provider.pdfUnsupportedReason;
        } else {
          pdfBytes = await loadPdf();
          if (pdfBytes == null || pdfBytes.isEmpty) {
            pdfSkippedReason = 'Could not read the PDF on this phone.';
            pdfBytes = null;
          }
        }
      }
    }
    var resolvedSections = sections;
    if (sectionsFuture != null) {
      try {
        resolvedSections = await sectionsFuture;
      } on Object {
        resolvedSections = const [];
      }
    }
    final resolvedNotes = notesToResolve.isNotEmpty && labelById != null
        ? NotesExport.snippets(
            notes: notesToResolve,
            labelById: labelById,
            outline: resolvedSections,
          )
        : notes;
    final request = requestFor(
      noteText: noteText,
      selectedText: selectedText,
      documentTitle: documentTitle,
      page: page,
      note: note,
      notes: resolvedNotes,
      pdfBytes: pdfBytes,
      pdfFileName: pdfFileName,
      pdfSkippedReason: pdfSkippedReason,
      heading: heading,
      subheading: subheading,
      sections: resolvedSections,
    );
    if (!request.hasAnythingToAsk) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Write a note or select text first.')),
      );
      return;
    }
    if (!context.mounted) {
      return;
    }
    await AskAboutNoteSheet.show(context, ask: () => ai.askAbout(request));
  }

  /// Ask AI entry: choose Ask with your AI or Export / Share note.
  static Future<void> choose(
    BuildContext context, {
    required String noteText,
    String? selectedText,
    String? documentTitle,
    LibraryDocument? document,
    int? page,
    double? x,
    double? y,
    String? colorLabelId,
    Note? note,
    List<AiNoteSnippet> notes = const [],
    bool offerPdf = false,
    PdfBytesLoader? loadPdf,
    String? pdfFileName,
    String? heading,
    String? subheading,
    List<PdfSection> sections = const [],
    Future<List<PdfSection>> Function()? loadSections,
    List<Note> notesToResolve = const [],
    List<ColorLabel> labels = const [],
    ColorLabel Function(String id)? labelById,
  }) async {
    final origin = ShareOrigin.resolve(context: context);
    final action = await AskNoteChooserSheet.show(context);
    if (!context.mounted || action == null) {
      return;
    }
    switch (action) {
      case AskNoteAction.ask:
        await open(
          context,
          noteText: noteText,
          selectedText: selectedText,
          documentTitle: documentTitle ?? document?.title,
          page: page,
          note: note,
          notes: notes,
          offerPdf: offerPdf,
          loadPdf: loadPdf,
          pdfFileName: pdfFileName,
          heading: heading,
          subheading: subheading,
          sections: sections,
          loadSections: loadSections,
          notesToResolve: notesToResolve,
          labelById: labelById ?? _labelLookup(labels),
        );
      case AskNoteAction.export:
        await _exportFromChooser(
          context,
          noteText: noteText,
          selectedText: selectedText,
          documentTitle: documentTitle,
          document: document,
          page: page,
          x: x,
          y: y,
          colorLabelId: colorLabelId,
          note: note,
          loadPdf: loadPdf,
          pdfFileName: pdfFileName,
          sections: sections,
          loadSections: loadSections,
          labels: labels,
          labelById: labelById,
          sharePositionOrigin: origin,
        );
    }
  }

  static Future<void> _exportFromChooser(
    BuildContext context, {
    required String noteText,
    String? selectedText,
    String? documentTitle,
    LibraryDocument? document,
    int? page,
    double? x,
    double? y,
    String? colorLabelId,
    Note? note,
    PdfBytesLoader? loadPdf,
    String? pdfFileName,
    List<PdfSection> sections = const [],
    Future<List<PdfSection>> Function()? loadSections,
    List<ColorLabel> labels = const [],
    ColorLabel Function(String id)? labelById,
    Rect? sharePositionOrigin,
  }) async {
    final kind = await SingleNoteExportSheet.show(context);
    if (!context.mounted || kind == null) {
      return;
    }
    final exportNote = noteForExport(
      noteText: noteText,
      selectedText: selectedText,
      page: page,
      x: x,
      y: y,
      colorLabelId: colorLabelId,
      note: note,
      document: document,
    );
    if (exportNote.text.trim().isEmpty &&
        (exportNote.selection?.text.trim().isEmpty ?? true)) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Write a note or select text first.')),
      );
      return;
    }
    var resolvedSections = sections;
    if (loadSections != null) {
      try {
        resolvedSections = await loadSections();
      } on Object {
        resolvedSections = const [];
      }
    }
    List<int>? pdfBytes;
    if (kind.includePdf && loadPdf != null) {
      pdfBytes = await loadPdf();
    }
    final exportDocument = documentForExport(
      document: document,
      documentTitle: documentTitle,
      pdfFileName: pdfFileName,
      note: exportNote,
    );
    if (kind.includeGuide) {
      if (!context.mounted) {
        return;
      }
      final share = await MarkdownPreviewSheet.show(
        context,
        fileName: exportDocument.title,
        markdown: NotesExport.previewMarkdown(
          documentTitle: exportDocument.title,
          notes: [exportNote],
          labelById: labelById ?? _labelLookup(labels),
          outline: resolvedSections,
        ),
      );
      if (!share || !context.mounted) {
        return;
      }
    }
    try {
      await exportSingleNote(
        document: exportDocument,
        note: exportNote,
        labelById: labelById ?? _labelLookup(labels),
        kind: kind,
        outline: resolvedSections,
        pdfBytes: pdfBytes,
        sharePositionOrigin: sharePositionOrigin,
      );
    } on Object catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not export note: $error')));
    }
  }

  static ColorLabel Function(String id) _labelLookup(List<ColorLabel> labels) {
    final pool = labels.isNotEmpty ? labels : ColorLabel.seedDefaults();
    final fallback = pool.first;
    return (id) {
      for (final label in pool) {
        if (label.id == id) {
          return label;
        }
      }
      for (final label in ColorLabel.seedDefaults()) {
        if (label.id == id) {
          return label;
        }
      }
      return fallback;
    };
  }

  static Note noteForExport({
    required String noteText,
    String? selectedText,
    int? page,
    double? x,
    double? y,
    String? colorLabelId,
    Note? note,
    LibraryDocument? document,
  }) {
    final text = noteText.trim().isNotEmpty
        ? noteText.trim()
        : (note?.text ?? '');
    final quote = selectedText ?? note?.selection?.text;
    if (note != null) {
      final selection = quote == null || quote.isEmpty
          ? note.selection
          : (note.selection?.copyWith(text: quote) ??
                NoteSelection(
                  text: quote,
                  left: note.x,
                  top: note.y,
                  right: note.x,
                  bottom: note.y,
                ));
      return note.copyWith(
        text: text,
        page: page ?? note.page,
        x: x ?? note.x,
        y: y ?? note.y,
        colorLabelId: colorLabelId ?? note.colorLabelId,
        selection: selection,
      );
    }
    return Note(
      id: 'draft',
      documentId: document?.id ?? 'unknown',
      page: page ?? 1,
      x: Note.normalizeCoord(x ?? 0.5),
      y: Note.normalizeCoord(y ?? 0.5),
      text: text,
      colorLabelId: colorLabelId ?? ColorLabel.orangeId,
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
      selection: quote == null || quote.isEmpty
          ? null
          : NoteSelection(
              text: quote,
              left: Note.normalizeCoord(x ?? 0.5),
              top: Note.normalizeCoord(y ?? 0.5),
              right: Note.normalizeCoord(x ?? 0.5),
              bottom: Note.normalizeCoord(y ?? 0.5),
            ),
    );
  }

  static LibraryDocument documentForExport({
    LibraryDocument? document,
    String? documentTitle,
    String? pdfFileName,
    Note? note,
  }) {
    if (document != null) {
      return document;
    }
    final title = (documentTitle ?? '').trim().isEmpty
        ? 'Untitled'
        : documentTitle!.trim();
    return LibraryDocument(
      id: note?.documentId ?? 'unknown',
      title: title,
      storedName: (pdfFileName ?? '').trim().isEmpty
          ? '${note?.documentId ?? 'unknown'}.pdf'
          : pdfFileName!.trim(),
      importedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }

  static Future<void> exportSingleNote({
    required LibraryDocument document,
    required Note note,
    required ColorLabel Function(String id) labelById,
    required SingleNoteShareKind kind,
    Directory? directory,
    DateTime? exportedAt,
    List<PdfSection> outline = const [],
    List<int>? pdfBytes,
    File? pdfFile,
    BuildContext? shareContext,
    GlobalKey? shareKey,
    Rect? sharePositionOrigin,
  }) async {
    final origin = ShareOrigin.resolve(
      preferred: sharePositionOrigin,
      context: shareContext,
      key: shareKey,
    );
    final files = await NotesExport.writeSingleNoteFiles(
      document: document,
      note: note,
      labelById: labelById,
      kind: kind,
      directory: directory,
      exportedAt: exportedAt,
      outline: outline,
      pdfBytes: pdfBytes,
      pdfFile: pdfFile,
    );
    await ExportShare.files(
      files,
      subject: 'Shelf note — ${document.title}',
      sharePositionOrigin: origin,
    );
  }

  Future<void> _choose(BuildContext context) {
    final id = document?.id ?? note?.documentId;
    final guard = documentActivity;
    if (guard == null || id == null || id.isEmpty) {
      return choose(
        context,
        noteText: noteText(),
        selectedText: selectedText,
        documentTitle: documentTitle,
        document: document,
        page: page,
        x: x,
        y: y,
        colorLabelId: colorLabelId,
        note: note,
        notes: notes,
        offerPdf: offerPdf,
        loadPdf: loadPdf,
        pdfFileName: pdfFileName,
        heading: heading,
        subheading: subheading,
        sections: sections,
        loadSections: loadSections,
        labels: labels,
        labelById: labelById,
      );
    }
    return guard(
      id,
      () => choose(
        context,
        noteText: noteText(),
        selectedText: selectedText,
        documentTitle: documentTitle,
        document: document,
        page: page,
        x: x,
        y: y,
        colorLabelId: colorLabelId,
        note: note,
        notes: notes,
        offerPdf: offerPdf,
        loadPdf: loadPdf,
        pdfFileName: pdfFileName,
        heading: heading,
        subheading: subheading,
        sections: sections,
        loadSections: loadSections,
        labels: labels,
        labelById: labelById,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return TextButton(
        key: const Key('ask-about-note'),
        onPressed: () => _choose(context),
        child: const Text('Ask AI', overflow: TextOverflow.ellipsis),
      );
    }
    return OutlinedButton.icon(
      key: const Key('ask-about-note'),
      onPressed: () => _choose(context),
      icon: const Icon(Icons.auto_awesome_outlined, size: 18),
      label: const Text('Ask AI'),
    );
  }
}

class AskAboutNoteSheet extends StatefulWidget {
  const AskAboutNoteSheet({super.key, required this.ask});

  final Future<AiAskOutcome> Function() ask;

  static Future<void> show(
    BuildContext context, {
    required Future<AiAskOutcome> Function() ask,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: ShelfColors.white,
      builder: (context) => AskAboutNoteSheet(ask: ask),
    );
  }

  @override
  State<AskAboutNoteSheet> createState() => _AskAboutNoteSheetState();
}

class _AskAboutNoteSheetState extends State<AskAboutNoteSheet> {
  String? _reply;
  String? _error;
  String? _pdfNotice;
  var _loading = true;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final outcome = await widget.ask();
      if (!mounted) {
        return;
      }
      setState(() {
        _reply = outcome.reply;
        _pdfNotice = outcome.pdfNotice;
        _loading = false;
      });
    } on AiClientException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } on Object {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'Could not reach the provider.';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Ask about this note',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            Text(
              key: const Key('ask-about-note-error'),
              _error!,
              style: const TextStyle(color: ShelfColors.muted, height: 1.4),
            )
          else ...[
            if (_pdfNotice != null) ...[
              Text(
                key: const Key('ask-about-note-pdf-notice'),
                'PDF not attached: $_pdfNotice',
                style: const TextStyle(color: ShelfColors.muted, height: 1.4),
              ),
              const SizedBox(height: 8),
            ],
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: SingleChildScrollView(
                child: Text(
                  key: const Key('ask-about-note-result'),
                  _reply ?? '',
                  style: const TextStyle(height: 1.45),
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }
}
