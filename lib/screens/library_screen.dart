import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/shelf_store.dart';
import '../models/color_label.dart';
import '../models/library_document.dart';
import '../models/note.dart';
import '../services/export_share.dart';
import '../services/notes_export.dart';
import '../services/pdf_outline_source.dart';
import '../services/pdf_section_resolver.dart';
import '../theme/shelf_theme.dart';
import '../widgets/ask_about_note.dart';
import '../widgets/markdown_preview_sheet.dart';
import '../widgets/shelf_menu_label.dart';
import 'reader_screen.dart';

class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key, required this.store, this.onViewAllComments});

  final ShelfStore store;
  final ValueChanged<String>? onViewAllComments;

  Future<void> _import(BuildContext context) async {
    final document = await store.importPdf();
    if (!context.mounted) {
      return;
    }
    if (store.lastError != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(store.lastError!)));
    }
    if (document != null) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ReaderScreen(store: store, document: document),
        ),
      );
    }
  }

  static Future<void> exportDocumentComments({
    required LibraryDocument document,
    required List<Note> notes,
    required ColorLabel Function(String id) labelById,
    Directory? directory,
    List<PdfSection> outline = const [],
    BuildContext? shareContext,
    GlobalKey? shareKey,
    Rect? sharePositionOrigin,
  }) async {
    final origin = ShareOrigin.resolve(
      preferred: sharePositionOrigin,
      context: shareContext,
      key: shareKey,
    );
    final files = await NotesExport.writeFiles(
      document: document,
      notes: notes,
      labelById: labelById,
      directory: directory,
      outline: outline,
    );
    await ExportShare.files(
      files,
      subject: 'Shelf notes — ${document.title}',
      sharePositionOrigin: origin,
    );
  }

  Future<void> _exportComments(BuildContext context, LibraryDocument document) {
    return store.withDocumentActivity(document.id, () async {
      // Snapshot the ⋮ button before the async outline/file work. iOS share
      // rejects a zero origin; Android omits origin. This is the menu anchor
      // (or a safe fallback) when the platform needs one.
      final origin = ShareOrigin.resolve(context: context);
      try {
        final outline = await PdfOutlineSource.loadForDocument(
          document,
          store.pdfPath,
        );
        if (!context.mounted) {
          return;
        }
        final notes = store.notesForDocument(document.id);
        final share = await MarkdownPreviewSheet.show(
          context,
          fileName: document.title,
          markdown: NotesExport.previewMarkdown(
            documentTitle: document.title,
            notes: notes,
            labelById: store.labelById,
            outline: outline,
          ),
        );
        if (!share || !context.mounted) {
          return;
        }
        await exportDocumentComments(
          document: document,
          notes: store.notesForDocument(document.id),
          labelById: store.labelById,
          outline: outline,
          sharePositionOrigin: origin,
        );
      } on Object catch (error) {
        if (!context.mounted) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not export comments: $error')),
        );
      }
    });
  }

  Future<void> _sendToAi(BuildContext context, LibraryDocument document) {
    return store.withDocumentActivity(document.id, () async {
      final notes = store.notesForDocument(document.id);
      if (notes.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('This book has no comments yet.')),
        );
        return;
      }
      await AskAboutNoteButton.open(
        context,
        noteText: 'Notes from ${document.title}',
        documentTitle: document.title,
        notesToResolve: notes,
        labelById: store.labelById,
        loadSections: () =>
            PdfOutlineSource.loadForDocument(document, store.pdfPath),
        offerPdf: true,
        pdfFileName: '${document.title}.pdf',
        loadPdf: () async {
          try {
            final path = await store.pdfPath(document);
            return await File(path).readAsBytes();
          } on Object {
            return null;
          }
        },
      );
    });
  }

  Future<bool> _confirmDelete(
    BuildContext context,
    LibraryDocument document,
  ) async {
    if (store.isDocumentBusy(document.id)) {
      _showDeleteBusy(context);
      return false;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.delete_outline, color: _deleteColor),
        title: const Text('Delete?'),
        actions: [
          TextButton(
            key: const Key('library-delete-cancel'),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('library-delete-confirm'),
            style: TextButton.styleFrom(foregroundColor: _deleteColor),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) {
      return false;
    }
    if (store.isDocumentBusy(document.id)) {
      _showDeleteBusy(context);
      return false;
    }
    return true;
  }

  void _showDeleteBusy(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        key: Key('library-delete-busy'),
        content: Text('Export in progress'),
      ),
    );
  }

  Future<void> _deleteDocument(
    BuildContext context,
    LibraryDocument document,
  ) async {
    final confirmed = await _confirmDelete(context, document);
    if (!confirmed) {
      return;
    }
    final removed = await store.removeDocument(document);
    if (!removed && context.mounted) {
      _showDeleteBusy(context);
    }
  }

  void _onMenu(BuildContext context, LibraryDocument document, String value) {
    switch (value) {
      case 'export':
        unawaited(_exportComments(context, document));
      case 'send':
        unawaited(_sendToAi(context, document));
      case 'view':
        onViewAllComments?.call(document.title);
      case 'delete':
        unawaited(_deleteDocument(context, document));
    }
  }

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('d MMM y');
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: store,
          builder: (context, _) {
            if (store.documents.isEmpty) {
              return const _EmptyLibrary();
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: Text(
                    'Library',
                    style: TextStyle(
                      color: ShelfColors.ink,
                      fontSize: 34,
                      height: 1.05,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.8,
                    ),
                  ),
                ),
                Expanded(
                  child: GridView.builder(
                    key: const Key('library-grid'),
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 112),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          childAspectRatio: 0.72,
                        ),
                    itemCount: store.documents.length,
                    itemBuilder: (context, index) {
                      final document = store.documents[index];
                      final noteCount = store
                          .notesForDocument(document.id)
                          .length;
                      return Dismissible(
                        key: ValueKey(document.id),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 16),
                          decoration: BoxDecoration(
                            color: const Color(0xFFB91C1C),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: const Icon(
                            Icons.delete_outline,
                            color: Colors.white,
                          ),
                        ),
                        confirmDismiss: (_) async {
                          final confirmed = await _confirmDelete(
                            context,
                            document,
                          );
                          if (!confirmed || !context.mounted) {
                            return false;
                          }
                          final removed = await store.removeDocument(document);
                          if (!removed && context.mounted) {
                            _showDeleteBusy(context);
                          }
                          return removed;
                        },
                        child: _LibraryCoverCard(
                          document: document,
                          noteCount: noteCount,
                          imported: dateFormat.format(document.importedAt),
                          cover: _covers[index % _covers.length],
                          onOpen: () {
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => ReaderScreen(
                                  store: store,
                                  document: document,
                                ),
                              ),
                            );
                          },
                          onMenu: (menuContext, value) =>
                              _onMenu(menuContext, document, value),
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Import PDF',
        onPressed: () => _import(context),
        child: const Icon(Icons.add),
      ),
    );
  }
}

class _CoverStyle {
  const _CoverStyle({
    required this.background,
    required this.foreground,
    required this.accent,
  });

  final Color background;
  final Color foreground;
  final Color accent;
}

const _deleteColor = Color(0xFFB91C1C);

const _covers = <_CoverStyle>[
  _CoverStyle(
    background: ShelfColors.ink,
    foreground: ShelfColors.white,
    accent: ShelfColors.orange,
  ),
  _CoverStyle(
    background: ShelfColors.orange,
    foreground: ShelfColors.white,
    accent: ShelfColors.orangeSoft,
  ),
  _CoverStyle(
    background: ShelfColors.orangePressed,
    foreground: ShelfColors.white,
    accent: ShelfColors.white,
  ),
  _CoverStyle(
    background: ShelfColors.orangeSoft,
    foreground: ShelfColors.ink,
    accent: ShelfColors.orange,
  ),
];

class _LibraryCoverCard extends StatelessWidget {
  const _LibraryCoverCard({
    required this.document,
    required this.noteCount,
    required this.imported,
    required this.cover,
    required this.onOpen,
    required this.onMenu,
  });

  final LibraryDocument document;
  final int noteCount;
  final String imported;
  final _CoverStyle cover;
  final VoidCallback onOpen;
  final void Function(BuildContext menuContext, String value) onMenu;

  String get _initials {
    final words = document.title
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .take(2)
        .map((word) => word[0].toUpperCase())
        .join();
    if (words.isNotEmpty) {
      return words;
    }
    return 'PDF';
  }

  @override
  Widget build(BuildContext context) {
    final meta = [
      imported,
      if (document.pageCount != null) '${document.pageCount} pages',
      '$noteCount ${noteCount == 1 ? 'note' : 'notes'}',
    ].join(' · ');
    return Material(
      color: cover.background,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned.fill(
            child: InkWell(
              onTap: onOpen,
              splashColor: cover.foreground.withValues(alpha: 0.12),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 52, 14, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _initials,
                      style: TextStyle(
                        fontSize: 40,
                        height: 1,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -1.4,
                        color: cover.foreground.withValues(alpha: 0.22),
                      ),
                    ),
                    const Spacer(),
                    Container(
                      width: 28,
                      height: 3,
                      decoration: BoxDecoration(
                        color: cover.accent,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      document.title,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: cover.foreground,
                        fontSize: 16,
                        height: 1.2,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      meta,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: cover.foreground.withValues(alpha: 0.78),
                        fontSize: 12,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            right: 0,
            top: 0,
            child: Builder(
              builder: (menuContext) {
                return PopupMenuButton<String>(
                  key: Key('library-card-menu-${document.id}'),
                  tooltip: 'Book actions',
                  icon: Icon(Icons.more_horiz, color: cover.foreground),
                  onSelected: (value) => onMenu(menuContext, value),
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      key: Key('library-card-export-comments'),
                      value: 'export',
                      child: ShelfMenuLabel(
                        icon: Icons.ios_share_outlined,
                        label: 'Export comments',
                      ),
                    ),
                    PopupMenuItem(
                      key: Key('library-card-send-to-ai'),
                      value: 'send',
                      child: ShelfMenuLabel(
                        icon: Icons.auto_awesome_outlined,
                        label: 'Send to connected AI',
                      ),
                    ),
                    PopupMenuItem(
                      key: Key('library-card-view-comments'),
                      value: 'view',
                      child: ShelfMenuLabel(
                        icon: Icons.sticky_note_2_outlined,
                        label: 'View all comments',
                      ),
                    ),
                    PopupMenuItem(
                      key: Key('library-card-delete'),
                      value: 'delete',
                      child: ShelfMenuLabel(
                        icon: Icons.delete_outline,
                        label: 'Delete',
                        destructive: true,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Text(
            'Library',
            style: TextStyle(
              color: ShelfColors.ink,
              fontSize: 34,
              height: 1.05,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.8,
            ),
          ),
        ),
        const Expanded(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.menu_book_outlined,
                  size: 48,
                  color: ShelfColors.orange,
                ),
                SizedBox(height: 12),
                Text(
                  'Nothing here yet',
                  style: TextStyle(color: ShelfColors.muted, fontSize: 15),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
