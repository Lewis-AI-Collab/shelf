import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../data/shelf_store.dart';
import '../models/library_document.dart';
import '../models/note.dart';
import '../models/note_selection.dart';
import '../services/note_open_sequence.dart';
import '../services/note_page_target.dart';
import '../services/pdf_section_resolver.dart';
import '../services/select_text_handoff.dart';
import '../services/selection_anchor.dart';
import '../services/speech_capture.dart';
import '../theme/shelf_theme.dart';
import '../widgets/note_editor.dart';
import '../widgets/note_marker.dart';
import '../widgets/page_jump_sheet.dart';
import '../widgets/page_press_menu.dart';
import '../widgets/pdf_selection_chrome.dart';
import '../widgets/reader_menu.dart';
import '../widgets/selection_comment_bar.dart';

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({
    super.key,
    required this.store,
    required this.document,
    this.initialPage,
    this.focusNoteId,
  });

  final ShelfStore store;
  final LibraryDocument document;
  final int? initialPage;
  final String? focusNoteId;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  final _controller = PdfViewerController();
  final _speech = SpeechCapture();
  late final Future<String> _pdfPath = widget.store.pdfPath(widget.document);

  bool _showMarkers = true;
  int _page = 1;
  int _pageCount = 1;
  List<PdfOutlineNode> _outline = const [];
  List<PdfSection> _sections = const [];
  String? _focusedNoteId;
  bool _ready = false;
  final Completer<void> _viewerReady = Completer<void>();
  final Completer<void> _structureReady = Completer<void>();
  final SelectTextHandoff _selectHandoff = SelectTextHandoff();

  /// pdfrx `initialPageNumber` — note page when opened from the hub.
  late final int _openAtPage;

  /// pdfrx selection stays off until the user picks **Select text**.
  bool _selectionEnabled = false;
  bool _hasActiveSelection = false;

  @override
  void initState() {
    super.initState();
    _openAtPage = NotePageTarget.forNoteOpen(
      note: widget.focusNoteId == null ? null : _noteById(widget.focusNoteId!),
      fallbackPage: widget.initialPage,
    );
    _page = _openAtPage;
    _pageCount = widget.document.pageCount ?? 1;
    _focusedNoteId = widget.focusNoteId;
    widget.store.addListener(_onStoreChanged);
    unawaited(widget.store.noteDocumentOpened(widget.document.id, page: _page));
    if (widget.focusNoteId != null) {
      unawaited(_openFocusedNote(widget.focusNoteId!));
    }
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStoreChanged);
    widget.store.noteDocumentClosed(widget.document.id);
    if (!_viewerReady.isCompleted) {
      _viewerReady.complete();
    }
    if (!_structureReady.isCompleted) {
      _structureReady.complete();
    }
    super.dispose();
  }

  var _closingBecauseDeleted = false;

  void _onStoreChanged() {
    if (_closingBecauseDeleted || !mounted) {
      return;
    }
    if (widget.store.documentById(widget.document.id) != null) {
      return;
    }
    _closingBecauseDeleted = true;
    final route = ModalRoute.of(context);
    if (route != null) {
      Navigator.of(context).removeRoute(route);
    }
  }

  Note? _noteById(String noteId) {
    return widget.store.notes.cast<Note?>().firstWhere(
      (item) => item?.id == noteId,
      orElse: () => null,
    );
  }

  /// Notes hub → reader: ready, then the note's stored page, then marker,
  /// then editor. Outline / page-title work must not own this jump.
  Future<void> _openFocusedNote(String noteId) async {
    try {
      await NoteOpenSequence.run(
        waitUntilReady: () => _viewerReady.future,
        page: _targetPageForNote(noteId),
        goToPage: _goPage,
        waitUntilPageCurrent: () => _waitUntilNotePage(noteId),
        ensureMarkerVisible: () async {
          final note = _noteById(noteId);
          if (note == null || !mounted) {
            return;
          }
          setState(() => _focusedNoteId = note.id);
          await _ensureMarkerVisible(note);
        },
        openNote: () async {
          await _waitForStructure();
          final note = _noteById(noteId);
          if (note != null && mounted) {
            await _editNote(note);
          }
        },
        isActive: () => mounted,
      );
    } on Object {
      // Viewer never became ready, or the route was popped.
    }
  }

  int _targetPageForNote(String noteId) {
    return NotePageTarget.forNoteOpen(
      note: _noteById(noteId),
      fallbackPage: widget.initialPage ?? _openAtPage,
      pageCount: _livePageCount(),
    );
  }

  int? _livePageCount() {
    if (_controller.isReady) {
      try {
        final count = _controller.pageCount;
        if (count > 1) {
          return count;
        }
      } on Object {
        // Controller attached but document not readable yet.
      }
    }
    return _pageCount > 1 ? _pageCount : null;
  }

  Future<void> _waitUntilNotePage(String noteId) async {
    final target = _targetPageForNote(noteId);
    await _waitUntilPage(target);
    final current = _controller.pageNumber ?? _page;
    if (current != target) {
      await _goPage(target);
      await _waitUntilPage(target);
    }
  }

  Future<void> _waitForStructure() async {
    if (_structureReady.isCompleted) {
      return;
    }
    await _structureReady.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {},
    );
  }

  Future<void> _waitUntilPage(int page) async {
    if ((_controller.pageNumber ?? _page) == page) {
      if (mounted && _page != page) {
        setState(() => _page = page);
      }
      if (mounted) {
        await WidgetsBinding.instance.endOfFrame;
      }
      return;
    }
    final done = Completer<void>();
    void tick() {
      if ((_controller.pageNumber ?? _page) == page && !done.isCompleted) {
        done.complete();
      }
    }

    _controller.addListener(tick);
    tick();
    try {
      await done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
    } finally {
      _controller.removeListener(tick);
    }
    if (mounted && (_controller.pageNumber ?? _page) == page && _page != page) {
      setState(() => _page = page);
    }
    if (mounted) {
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  Future<void> _ensureMarkerVisible(Note note) async {
    if (!_controller.isReady) {
      return;
    }
    try {
      final viewerPage = NotePageTarget.toViewerPage(
        note.page,
        pageCount: _livePageCount(),
      );
      final page = _controller.pages.cast<PdfPage?>().firstWhere(
        (item) => item?.pageNumber == viewerPage,
        orElse: () => null,
      );
      if (page == null || page.width == 0 || page.height == 0) {
        return;
      }
      final bounds = noteFocusPdfBounds(
        note: note,
        pageWidth: page.width,
        pageHeight: page.height,
      );
      final rect = _controller.calcRectForRectInsidePage(
        pageNumber: viewerPage,
        rect: PdfRect(bounds.left, bounds.top, bounds.right, bounds.bottom),
      );
      await _controller.ensureVisible(rect, margin: 32);
    } on Object {
      // Page camera APIs can fail before layout; the editor still opens
      // once the page is current.
    }
  }

  Future<void> _onViewerReady(
    PdfDocument document,
    PdfViewerController controller,
  ) async {
    if (!mounted) {
      return;
    }
    setState(() {
      _ready = true;
      _pageCount = document.pages.length;
      _page = controller.pageNumber ?? _page;
    });
    unawaited(widget.store.noteReadingPosition(widget.document.id, _page));
    if (!_viewerReady.isCompleted) {
      _viewerReady.complete();
    }
    unawaited(_loadStructure(document));
    await widget.store.updatePageCount(
      widget.document.id,
      document.pages.length,
    );
    // Notes-hub focus owns goToPage so it cannot race the editor.
    if (widget.focusNoteId != null) {
      return;
    }
    final target = widget.initialPage;
    if (target != null && target >= 1) {
      await controller.goToPage(
        pageNumber: NotePageTarget.toViewerPage(
          target,
          pageCount: document.pages.length,
        ),
      );
    }
  }

  Future<void> _loadStructure(PdfDocument document) async {
    try {
      final outline = await document.loadOutline();
      final heights = [for (final page in document.pages) page.height];
      final sections = PdfSectionResolver.flattenOutline(
        outline,
        pageHeights: heights,
      );
      // pageTitleFallback loadText()s every page — do not run it on the
      // live viewer. Export / Ask / Send still use PdfOutlineSource.
      if (mounted) {
        setState(() {
          _outline = outline;
          _sections = sections;
        });
      }
    } on Object {
      // Jump sheet / headings degrade; note-open already has the page.
    } finally {
      if (!_structureReady.isCompleted) {
        _structureReady.complete();
      }
    }
  }

  Note? _noteAt(Offset globalPosition) {
    if (!_controller.isReady) {
      return null;
    }
    final local = _controller.globalToLocal(globalPosition);
    if (local == null) {
      return null;
    }
    final hit = _controller.getPdfPageHitTestResult(
      local,
      useDocumentLayoutCoordinates: false,
    );
    if (hit == null || hit.page.width == 0 || hit.page.height == 0) {
      return null;
    }
    Size pageSizeInView;
    try {
      final layouts = _controller.layout.pageLayouts;
      final index = hit.page.pageNumber - 1;
      if (index < 0 || index >= layouts.length) {
        return null;
      }
      pageSizeInView = layouts[index].size;
    } on Object {
      return null;
    }
    final normalised = Offset(
      hit.offset.x / hit.page.width,
      1 - (hit.offset.y / hit.page.height),
    );
    for (final note in widget.store.notesOnPage(
      widget.document.id,
      hit.page.pageNumber,
    )) {
      if (noteMarkerContains(
        note: note,
        normalisedTap: normalised,
        pageSizeInView: pageSizeInView,
      )) {
        return note;
      }
    }
    return null;
  }

  /// Long-press on a marker edits it. Otherwise show Comment | Select text.
  bool _onPageLongPress(PdfOverlayInteractionDetails details) {
    final existing = _noteAt(details.globalPosition);
    if (existing != null) {
      unawaited(_editNote(existing));
      return true;
    }
    unawaited(_showPagePressMenu(details.globalPosition));
    return true;
  }

  Future<void> _showPagePressMenu(Offset globalPosition) async {
    if (!mounted) {
      return;
    }
    // Capture the word point before the menu overlay or selection-mode
    // rebuild can invalidate global coordinates / wipe a range.
    if (_controller.isReady) {
      final documentPosition = _controller.globalToDocument(globalPosition);
      if (documentPosition != null) {
        _selectHandoff.rememberDocumentPoint(documentPosition);
      }
    }
    final action = await PagePressMenu.show(
      context,
      globalPosition: globalPosition,
    );
    if (!mounted || action == null) {
      _selectHandoff.clear();
      return;
    }
    switch (action) {
      case PagePressAction.comment:
        _selectHandoff.clear();
        await _createNoteAt(globalPosition);
      case PagePressAction.selectText:
        await _beginSelectText(globalPosition);
    }
  }

  /// Re-enable pdfrx handles only after the menu, then select the word
  /// captured at long-press (not a free-drag grey box).
  Future<void> _beginSelectText(Offset globalPosition) async {
    final pending =
        _selectHandoff.pendingDocumentPoint ??
        (_controller.isReady
            ? _controller.globalToDocument(globalPosition)
            : null);
    if (pending != null) {
      _selectHandoff.rememberDocumentPoint(pending);
    }
    setState(() {
      _selectionEnabled = true;
      _hasActiveSelection = false;
    });
    await WidgetsBinding.instance.endOfFrame;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !_controller.isReady) {
      return;
    }
    final documentPosition =
        _selectHandoff.pendingDocumentPoint ??
        _controller.globalToDocument(globalPosition);
    if (documentPosition == null) {
      return;
    }
    try {
      final delegate = _controller.textSelectionDelegate;
      await delegate.selectWord(documentPosition);
      var text = await delegate.getSelectedText();
      if (text.trim().isEmpty) {
        await WidgetsBinding.instance.endOfFrame;
        await delegate.selectWord(documentPosition);
      }
      _selectHandoff.markApplied();
    } on Object {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not grab text there. Drag a handle, or tap Done and Comment.',
          ),
        ),
      );
    }
  }

  bool _onViewerTap(
    BuildContext context,
    PdfViewerController controller,
    PdfViewerGeneralTapHandlerDetails details,
  ) {
    if (details.type == PdfViewerGeneralTapType.tap &&
        _selectHandoff.consumeWipeProtection()) {
      return true;
    }
    return false;
  }

  Future<void> _exitSelectionMode() async {
    _selectHandoff.clear();
    if (_controller.isReady) {
      try {
        await _controller.textSelectionDelegate.clearTextSelection();
      } on Object {
        // Clearing is best-effort; we still drop selection mode.
      }
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _selectionEnabled = false;
      _hasActiveSelection = false;
    });
  }

  Future<void> _onTextSelectionChange(PdfTextSelection selection) async {
    final text = await selection.getSelectedText();
    if (!mounted) {
      return;
    }
    setState(() => _hasActiveSelection = text.trim().isNotEmpty);
  }

  Future<List<int>?> _loadPdfBytes() async {
    try {
      final path = await _pdfPath;
      return await File(path).readAsBytes();
    } on Object {
      return null;
    }
  }

  Future<void> _createNoteAt(
    Offset globalPosition, {
    NoteSelection? selection,
  }) async {
    if (!_controller.isReady) {
      return;
    }
    final local = _controller.globalToLocal(globalPosition);
    if (local == null) {
      return;
    }
    final hit = _controller.getPdfPageHitTestResult(
      local,
      useDocumentLayoutCoordinates: false,
    );
    if (hit == null || hit.page.width == 0 || hit.page.height == 0) {
      return;
    }
    final x =
        selection?.anchorX ??
        Note.normalizeCoord(hit.offset.x / hit.page.width);
    final y =
        selection?.anchorY ??
        Note.normalizeCoord(1 - (hit.offset.y / hit.page.height));
    await _openComposer(
      page: hit.page.pageNumber,
      x: x,
      y: y,
      selection: selection,
    );
  }

  Future<void> _createNoteFromSelection() async {
    if (!_controller.isReady) {
      return;
    }
    final delegate = _controller.textSelectionDelegate;
    final text = await delegate.getSelectedText();
    final ranges = await delegate.getSelectedTextRanges();
    if (!mounted) {
      return;
    }
    if (ranges.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Select a word first, then add a comment.'),
        ),
      );
      return;
    }
    final first = ranges.first;
    final page = _controller.pages.cast<PdfPage?>().firstWhere(
      (item) => item?.pageNumber == first.pageNumber,
      orElse: () => null,
    );
    if (page == null || page.width == 0 || page.height == 0) {
      return;
    }
    final selection = noteSelectionFromRanges(
      ranges: ranges,
      selectedText: text,
      pageWidth: page.width,
      pageHeight: page.height,
    );
    if (selection == null) {
      return;
    }
    await _openComposer(
      page: first.pageNumber,
      x: selection.anchorX,
      y: selection.anchorY,
      selection: selection,
    );
    await _exitSelectionMode();
  }

  Future<void> _openComposer({
    required int page,
    required double x,
    required double y,
    NoteSelection? selection,
  }) async {
    final ready = await _speech.ensureReady();
    if (!mounted) {
      return;
    }
    final headings = PdfSectionResolver.headingsFor(
      sections: _sections,
      page: page,
      y: selection?.top ?? y,
    );
    final result = await NoteEditor.show(
      context,
      labels: widget.store.labels,
      defaultLabelId: widget.store.defaultLabel.id,
      speech: _speech,
      page: page,
      x: x,
      y: y,
      documentTitle: widget.document.title,
      document: widget.document,
      quotedText: selection?.text,
      pdfFileName: '${widget.document.title}.pdf',
      loadPdf: _loadPdfBytes,
      heading: headings.heading,
      subheading: headings.subheading,
      sections: _sections,
      documentActivity: widget.store.withDocumentActivity,
      voiceHint: ready ? 'Orange is selected until you pick another colour.' : 'Voice dictation is limited on simulators and emulators. Type the note, or use a physical phone.',
    );
    if (result == null || result.delete || result.text.isEmpty) {
      return;
    }
    final note = await widget.store.addNote(
      documentId: widget.document.id,
      page: page,
      x: result.x,
      y: result.y,
      text: result.text,
      colorLabelId: result.colorLabelId,
      selection: selection,
    );
    if (mounted) {
      setState(() => _focusedNoteId = note.id);
    }
  }

  Future<void> _editNote(Note note) async {
    setState(() => _focusedNoteId = note.id);
    final headings = PdfSectionResolver.forNote(note, _sections);
    final result = await NoteEditor.show(
      context,
      labels: widget.store.labels,
      defaultLabelId: widget.store.defaultLabel.id,
      speech: _speech,
      note: note,
      documentTitle: widget.document.title,
      document: widget.document,
      quotedText: note.selection?.text,
      pdfFileName: '${widget.document.title}.pdf',
      loadPdf: _loadPdfBytes,
      heading: headings.heading,
      subheading: headings.subheading,
      sections: _sections,
      documentActivity: widget.store.withDocumentActivity,
    );
    if (result == null) {
      return;
    }
    if (result.delete) {
      await widget.store.deleteNote(note.id);
      if (mounted) {
        setState(() {
          if (_focusedNoteId == note.id) {
            _focusedNoteId = null;
          }
        });
      }
      return;
    }
    await widget.store.saveNote(
      note.copyWith(
        text: result.text,
        colorLabelId: result.colorLabelId,
        x: result.x,
        y: result.y,
      ),
    );
  }

  Future<void> _goPage(int page) async {
    if (!_controller.isReady || !mounted) {
      return;
    }
    final clamped = NotePageTarget.toViewerPage(
      page,
      pageCount: _livePageCount(),
    );
    await _controller.goToPage(pageNumber: clamped);
    if (mounted) {
      setState(() => _page = clamped);
    }
  }

  void _showJump() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: ShelfColors.white,
      builder: (context) => PageJumpSheet(
        pageCount: _pageCount,
        currentPage: _page,
        outline: _outline,
        onJump: _goPage,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PdfSelectionChrome.wrap(_buildScaffold(context));
  }

  Widget _buildScaffold(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.document.title),
        actions: [
          IconButton(
            tooltip: _showMarkers ? 'Hide markers' : 'Show markers',
            onPressed: () => setState(() => _showMarkers = !_showMarkers),
            icon: Icon(
              _showMarkers
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
            ),
          ),
          ReaderOverflowMenu(
            showMarkers: _showMarkers,
            onToggleMarkers: () => setState(() => _showMarkers = !_showMarkers),
            onChapters: _showJump,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: widget.store,
        builder: (context, _) {
          return FutureBuilder<String>(
            future: _pdfPath,
            builder: (context, snapshot) {
              final path = snapshot.data;
              if (path == null) {
                return const Center(child: CircularProgressIndicator());
              }
              // Orange canvas fill + compact orange handles. The system
              // selection toolbar was the empty dark callout — keep it off.
              return PdfSelectionChrome.wrap(
                PdfViewer.file(
                  path,
                  key: ValueKey('pdf-${widget.document.id}'),
                  controller: _controller,
                  initialPageNumber: _openAtPage,
                  params: PdfViewerParams(
                    backgroundColor: ShelfColors.white,
                    onGeneralTap: _onViewerTap,
                    // Selection is off until Select text, so long-press is ours.
                    textSelectionParams: PdfTextSelectionParams(
                      enabled: _selectionEnabled,
                      enableSelectionHandles: true,
                      showContextMenuAutomatically: false,
                      onTextSelectionChange: _onTextSelectionChange,
                      buildSelectionHandle: PdfSelectionChrome.buildHandle,
                      magnifier: PdfViewerSelectionMagnifierParams(
                        enabled: false,
                        shouldShowMagnifier: () => false,
                      ),
                    ),
                    buildContextMenu: PdfSelectionChrome.hideContextMenu,
                    onViewerReady: _onViewerReady,
                    onPageChanged: (page) {
                      if (page != null && mounted) {
                        setState(() => _page = page);
                        unawaited(
                          widget.store.noteReadingPosition(
                            widget.document.id,
                            page,
                          ),
                        );
                      }
                    },
                    pageOverlaysBuilder: (context, pageRect, page) {
                      if (!_showMarkers) {
                        return const <Widget>[];
                      }
                      final pageNotes = widget.store.notesOnPage(
                        widget.document.id,
                        page.pageNumber,
                      );
                      return [
                        for (final note in pageNotes)
                          Positioned(
                            left: note.x * pageRect.width - 8,
                            top: note.y * pageRect.height - 8,
                            width: 22,
                            height: 22,
                            child: PdfOverlayInteractionRegion(
                              onTap: (_) {
                                _editNote(note);
                                return true;
                              },
                              child: NoteMarker(
                                color: widget.store
                                    .labelById(note.colorLabelId)
                                    .color,
                                focused: note.id == _focusedNoteId,
                              ),
                            ),
                          ),
                      ];
                    },
                    viewerOverlayBuilder: (context, size, handleLinkTap) {
                      return [
                        if (!_selectionEnabled)
                          PdfOverlayInteractionRegion(
                            onLongPress: _onPageLongPress,
                            child: SizedBox(
                              width: size.width,
                              height: size.height,
                            ),
                          ),
                        if (_selectionEnabled)
                          Positioned(
                            top: 12,
                            left: 0,
                            right: 0,
                            child: Center(
                              child: SelectionCommentBar(
                                hasSelection: _hasActiveSelection,
                                onAddComment: () {
                                  unawaited(_createNoteFromSelection());
                                },
                                onDone: () {
                                  unawaited(_exitSelectionMode());
                                },
                              ),
                            ),
                          ),
                      ];
                    },
                  ),
                ),
              );
            },
          );
        },
      ),
      bottomNavigationBar: Material(
        color: ShelfColors.white,
        elevation: 0,
        child: SafeArea(
          child: Container(
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: ShelfColors.hairline)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Previous page',
                  onPressed: _page <= 1 ? null : () => _goPage(_page - 1),
                  icon: const Icon(Icons.chevron_left),
                ),
                Expanded(
                  child: Text(
                    _ready ? 'Page $_page of $_pageCount' : 'Opening PDF…',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.2,
                      color: ShelfColors.ink,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Next page',
                  onPressed: _page >= _pageCount
                      ? null
                      : () => _goPage(_page + 1),
                  icon: const Icon(Icons.chevron_right),
                ),
                IconButton(
                  tooltip: 'Jump to page or chapter',
                  onPressed: _ready ? _showJump : null,
                  icon: const Icon(Icons.list_alt_outlined),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
