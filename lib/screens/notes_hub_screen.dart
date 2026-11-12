import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/shelf_store.dart';
import '../models/note.dart';
import '../services/note_page_target.dart';
import '../services/notes_export.dart';
import '../services/pdf_outline_source.dart';
import '../theme/shelf_theme.dart';
import '../widgets/ask_about_note.dart';
import '../widgets/colour_label_chip.dart';
import '../widgets/icon_menu_card.dart';
import 'reader_screen.dart';

enum _NoteAction { open, copyHighlight, copyNote, edit, delete }

class NotesHubScreen extends StatefulWidget {
  const NotesHubScreen({super.key, required this.store, this.searchController});

  final ShelfStore store;
  final TextEditingController? searchController;

  @override
  State<NotesHubScreen> createState() => _NotesHubScreenState();
}

class _NotesHubScreenState extends State<NotesHubScreen> {
  late final TextEditingController _query;
  var _ownsQuery = false;
  String? _labelId;

  @override
  void initState() {
    super.initState();
    final incoming = widget.searchController;
    if (incoming != null) {
      _query = incoming;
    } else {
      _query = TextEditingController();
      _ownsQuery = true;
    }
    _query.addListener(_onQueryChanged);
  }

  void _onQueryChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _query.removeListener(_onQueryChanged);
    if (_ownsQuery) {
      _query.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: widget.store,
          builder: (context, _) {
            final notes = widget.store.searchNotes(
              query: _query.text,
              colorLabelId: _labelId,
            );
            final groups = <String, List<Note>>{};
            final order = <String>[];
            for (final note in notes) {
              groups
                  .putIfAbsent(note.documentId, () {
                    order.add(note.documentId);
                    return <Note>[];
                  })
                  .add(note);
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: Text(
                    'Notes',
                    style: TextStyle(
                      color: ShelfColors.ink,
                      fontSize: 34,
                      height: 1.05,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.8,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                  child: Text(
                    '${notes.length} ${notes.length == 1 ? 'note' : 'notes'}',
                    style: const TextStyle(
                      color: ShelfColors.muted,
                      fontSize: 13,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 8, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const Key('notes-hub-search'),
                          controller: _query,
                          decoration: InputDecoration(
                            hintText: 'Search notes, titles, labels…',
                            prefixIcon: const Icon(
                              Icons.search,
                              color: ShelfColors.muted,
                            ),
                            filled: true,
                            fillColor: const Color(0xFFF5F5F4),
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 12,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(24),
                              borderSide: BorderSide.none,
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(24),
                              borderSide: BorderSide.none,
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(24),
                              borderSide: const BorderSide(
                                color: ShelfColors.orange,
                                width: 1.5,
                              ),
                            ),
                          ),
                        ),
                      ),
                      PopupMenuButton<String>(
                        key: const Key('notes-label-filter'),
                        tooltip: 'Filter by colour',
                        icon: Icon(
                          Icons.palette_outlined,
                          color: _labelId == null
                              ? ShelfColors.ink
                              : ShelfColors.orange,
                        ),
                        onSelected: (value) {
                          setState(() {
                            _labelId = value == 'all' ? null : value;
                          });
                        },
                        itemBuilder: (context) => [
                          const PopupMenuItem(value: 'all', child: Text('All')),
                          for (final label in widget.store.labels)
                            PopupMenuItem(
                              value: label.id,
                              child: Row(
                                children: [
                                  ColourDot(color: label.color, size: 14),
                                  const SizedBox(width: 12),
                                  Flexible(child: Text(label.name)),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: notes.isEmpty
                      ? Center(
                          child: Text(
                            _query.text.trim().isEmpty && _labelId == null
                                ? 'No notes'
                                : 'No notes match',
                            style: const TextStyle(
                              color: ShelfColors.muted,
                              fontSize: 15,
                            ),
                          ),
                        )
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                          children: [
                            for (final documentId in order) ...[
                              Padding(
                                padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
                                child: Text(
                                  widget.store
                                          .documentById(documentId)
                                          ?.title ??
                                      'Missing PDF',
                                  style: const TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: -0.2,
                                    color: ShelfColors.ink,
                                  ),
                                ),
                              ),
                              for (final note in groups[documentId]!)
                                _NoteBlock(store: widget.store, note: note),
                            ],
                          ],
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _NoteBlock extends StatelessWidget {
  const _NoteBlock({required this.store, required this.note});

  final ShelfStore store;
  final Note note;

  Future<void> _open(BuildContext context, {required bool focus}) async {
    final document = store.documentById(note.documentId);
    if (document == null) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ReaderScreen(
          store: store,
          document: document,
          initialPage: NotePageTarget.forNoteOpen(note: note),
          focusNoteId: focus ? note.id : null,
        ),
      ),
    );
  }

  Future<void> _menu(BuildContext context, Offset globalPosition) async {
    final quote = note.selection?.text.trim() ?? '';
    final action = await IconMenuCard.show<_NoteAction>(
      context,
      globalPosition: globalPosition,
      menuKey: Key('note-menu-${note.id}'),
      entries: [
        IconMenuEntry(
          value: _NoteAction.open,
          entryKey: Key('note-menu-open-${note.id}'),
          icon: Icons.near_me_outlined,
          label: 'Go to highlight',
        ),
        if (quote.isNotEmpty)
          IconMenuEntry(
            value: _NoteAction.copyHighlight,
            entryKey: Key('note-menu-copy-highlight-${note.id}'),
            icon: Icons.content_copy_outlined,
            label: 'Copy highlight',
          ),
        IconMenuEntry(
          value: _NoteAction.copyNote,
          entryKey: Key('note-menu-copy-note-${note.id}'),
          icon: Icons.notes_outlined,
          label: 'Copy note',
          dividerBefore: true,
        ),
        IconMenuEntry(
          value: _NoteAction.edit,
          entryKey: Key('note-menu-edit-${note.id}'),
          icon: Icons.edit_outlined,
          label: 'Edit note',
        ),
        IconMenuEntry(
          value: _NoteAction.delete,
          entryKey: Key('note-menu-delete-${note.id}'),
          icon: Icons.delete_outline,
          label: 'Delete note',
          destructive: true,
        ),
      ],
    );
    if (!context.mounted || action == null) {
      return;
    }
    switch (action) {
      case _NoteAction.open:
        await _open(context, focus: false);
      case _NoteAction.edit:
        await _open(context, focus: true);
      case _NoteAction.copyHighlight:
        await Clipboard.setData(ClipboardData(text: quote));
      case _NoteAction.copyNote:
        final text = note.text.trim();
        if (text.isNotEmpty) {
          await Clipboard.setData(ClipboardData(text: text));
        }
      case _NoteAction.delete:
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Delete note?'),
            content: const Text(
              'This comment will be removed from this phone.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Keep'),
              ),
              FilledButton(
                key: Key('note-delete-confirm-${note.id}'),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if (confirmed == true) {
          await store.deleteNote(note.id);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final document = store.documentById(note.documentId);
    final label = store.labelById(note.colorLabelId);
    final quote = note.selection?.text.trim() ?? '';
    final hasQuote = quote.isNotEmpty;
    final comment = note.text.trim().isEmpty ? 'Empty note' : note.text.trim();
    return GestureDetector(
      key: Key('note-card-${note.id}'),
      onTap: document == null ? null : () => _open(context, focus: true),
      onLongPressStart: (details) => _menu(context, details.globalPosition),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              key: Key('note-accent-${note.id}'),
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: label.color, width: 3)),
              ),
              padding: const EdgeInsets.only(left: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (hasQuote)
                    Text(
                      quote,
                      key: Key('note-quote-${note.id}'),
                      style: const TextStyle(
                        fontSize: 15.5,
                        height: 1.4,
                        color: ShelfColors.ink,
                      ),
                    ),
                  if (hasQuote) const SizedBox(height: 8),
                  Text(
                    comment,
                    key: Key('note-comment-${note.id}'),
                    style: TextStyle(
                      fontSize: 15.5,
                      height: 1.4,
                      color: ShelfColors.ink,
                      fontWeight: hasQuote ? FontWeight.w500 : FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  'p. ${note.page}',
                  key: Key('note-page-${note.id}'),
                  style: const TextStyle(
                    color: ShelfColors.muted,
                    fontSize: 12,
                    height: 1.2,
                  ),
                ),
                const Spacer(),
                IconButton(
                  key: Key('ask-about-note-${note.id}'),
                  tooltip: 'Ask AI',
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    unawaited(
                      store.withDocumentActivity(
                        note.documentId,
                        () => AskAboutNoteButton.choose(
                          context,
                          noteText: note.text,
                          selectedText: note.selection?.text,
                          documentTitle: document?.title,
                          document: document,
                          page: note.page,
                          x: note.x,
                          y: note.y,
                          colorLabelId: note.colorLabelId,
                          note: note,
                          loadSections: document == null
                              ? null
                              : () => PdfOutlineSource.loadForDocument(
                                  document,
                                  store.pdfPath,
                                ),
                          offerPdf: document != null,
                          pdfFileName: document == null
                              ? null
                              : NotesExport.fileNameOf(document),
                          loadPdf: document == null
                              ? null
                              : () async {
                                  try {
                                    final path = await store.pdfPath(document);
                                    return await File(path).readAsBytes();
                                  } on Object {
                                    return null;
                                  }
                                },
                          labels: store.labels,
                          labelById: store.labelById,
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.auto_awesome_outlined, size: 20),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
