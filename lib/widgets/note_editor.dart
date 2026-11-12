import 'package:flutter/material.dart';

import '../models/color_label.dart';
import '../models/library_document.dart';
import '../models/note.dart';
import '../services/filler_cleanup.dart';
import '../services/pdf_section_resolver.dart';
import '../services/speech_capture.dart';
import '../theme/shelf_theme.dart';
import 'ask_about_note.dart';
import 'note_label_picker.dart';

class NoteEditorResult {
  const NoteEditorResult({
    required this.text,
    required this.colorLabelId,
    required this.x,
    required this.y,
    this.delete = false,
  });

  final String text;
  final String colorLabelId;
  final double x;
  final double y;
  final bool delete;
}

class NoteEditor extends StatefulWidget {
  const NoteEditor({
    super.key,
    required this.labels,
    required this.defaultLabelId,
    required this.speech,
    this.note,
    this.page,
    this.x,
    this.y,
    this.voiceHint,
    this.documentTitle,
    this.document,
    this.quotedText,
    this.pdfFileName,
    this.loadPdf,
    this.heading,
    this.subheading,
    this.sections = const [],
    this.documentActivity,
  });

  final List<ColorLabel> labels;
  final String defaultLabelId;
  final SpeechCapture speech;
  final Note? note;
  final int? page;
  final double? x;
  final double? y;
  final String? voiceHint;
  final String? documentTitle;
  final LibraryDocument? document;
  final String? quotedText;
  final String? pdfFileName;
  final Future<List<int>?> Function()? loadPdf;
  final String? heading;
  final String? subheading;
  final List<PdfSection> sections;
  final DocumentActivityGuard? documentActivity;

  static const int composerMaxLines = 4;

  static Future<NoteEditorResult?> show(
    BuildContext context, {
    required List<ColorLabel> labels,
    required String defaultLabelId,
    required SpeechCapture speech,
    Note? note,
    int? page,
    double? x,
    double? y,
    String? voiceHint,
    String? documentTitle,
    LibraryDocument? document,
    String? quotedText,
    String? pdfFileName,
    Future<List<int>?> Function()? loadPdf,
    String? heading,
    String? subheading,
    List<PdfSection> sections = const [],
    DocumentActivityGuard? documentActivity,
  }) {
    return showModalBottomSheet<NoteEditorResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: ShelfColors.white,
      builder: (context) {
        return NoteEditor(
          labels: labels,
          defaultLabelId: defaultLabelId,
          speech: speech,
          note: note,
          page: page,
          x: x,
          y: y,
          voiceHint: voiceHint,
          documentTitle: documentTitle ?? document?.title,
          document: document,
          quotedText: quotedText ?? note?.selection?.text,
          pdfFileName: pdfFileName,
          loadPdf: loadPdf,
          heading: heading,
          subheading: subheading,
          sections: sections,
          documentActivity: documentActivity,
        );
      },
    );
  }

  @override
  State<NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<NoteEditor> {
  late final TextEditingController _controller;
  late String _labelId;
  late final double _x;
  late final double _y;
  bool _listening = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.note?.text ?? '');
    _labelId = widget.note?.colorLabelId ?? widget.defaultLabelId;
    _x = Note.normalizeCoord(widget.note?.x ?? widget.x ?? 0.5);
    _y = Note.normalizeCoord(widget.note?.y ?? widget.y ?? 0.5);
    _status = widget.voiceHint;
  }

  @override
  void dispose() {
    if (_listening) {
      widget.speech.stop();
    }
    _controller.dispose();
    super.dispose();
  }

  Future<void> _toggleListen() async {
    if (_listening) {
      await widget.speech.stop();
      setState(() => _listening = false);
      _autoClean();
      return;
    }

    final ready = await widget.speech.ensureReady();
    if (!ready) {
      setState(() {
        _status =
            widget.speech.unavailableReason ??
            'Voice dictation needs a physical phone. Type the note instead.';
      });
      return;
    }

    try {
      await widget.speech.start(
        onText: (words, finalResult) {
          if (!mounted) {
            return;
          }
          setState(() {
            _controller.text = words;
            _controller.selection = TextSelection.collapsed(
              offset: _controller.text.length,
            );
            if (finalResult) {
              _listening = false;
            }
          });
          if (finalResult) {
            _autoClean();
          }
        },
      );
      setState(() {
        _listening = true;
        _status = 'Listening… tap the microphone to stop.';
      });
    } on Object catch (error) {
      setState(() {
        _listening = false;
        _status = error.toString();
      });
    }
  }

  void _autoClean() {
    final cleaned = FillerCleanup.clean(_controller.text);
    if (cleaned != _controller.text) {
      setState(() {
        _controller.text = cleaned;
        _controller.selection = TextSelection.collapsed(offset: cleaned.length);
        _status = 'Filler words removed.';
      });
    }
  }

  void _manualClean() {
    final cleaned = FillerCleanup.clean(_controller.text);
    setState(() {
      _controller.text = cleaned;
      _controller.selection = TextSelection.collapsed(offset: cleaned.length);
      _status = cleaned.isEmpty
          ? 'Nothing left after cleanup.'
          : 'Filler words removed.';
    });
  }

  void _save() {
    Navigator.of(context).pop(
      NoteEditorResult(
        text: _controller.text.trim(),
        colorLabelId: _labelId,
        x: Note.normalizeCoord(_x),
        y: Note.normalizeCoord(_y),
      ),
    );
  }

  void _delete() {
    Navigator.of(context).pop(
      NoteEditorResult(
        text: _controller.text,
        colorLabelId: _labelId,
        x: Note.normalizeCoord(_x),
        y: Note.normalizeCoord(_y),
        delete: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final page = widget.note?.page ?? widget.page;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        10,
        16,
        12 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.note == null ? 'New note' : 'Note',
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              if (page != null)
                Text(
                  'Page $page',
                  style: const TextStyle(
                    color: ShelfColors.muted,
                    fontSize: 13,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          _ChatComposer(
            controller: _controller,
            listening: _listening,
            autofocus: widget.note == null,
            labels: widget.labels,
            labelId: _labelId,
            onMic: _toggleListen,
            onLabel: (id) => setState(() => _labelId = id),
          ),
          if (_status != null) ...[
            const SizedBox(height: 6),
            Text(
              _status!,
              style: const TextStyle(color: ShelfColors.muted, fontSize: 12),
            ),
          ],
          AskAboutNoteButton(
            noteText: () => _controller.text,
            selectedText: widget.quotedText ?? widget.note?.selection?.text,
            documentTitle: widget.documentTitle ?? widget.document?.title,
            document: widget.document,
            page: widget.note?.page ?? widget.page,
            x: _x,
            y: _y,
            colorLabelId: _labelId,
            offerPdf: widget.loadPdf != null,
            loadPdf: widget.loadPdf,
            pdfFileName: widget.pdfFileName,
            heading: widget.heading,
            subheading: widget.subheading,
            sections: widget.sections,
            note: widget.note,
            labels: widget.labels,
            documentActivity: widget.documentActivity,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Flexible(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: _manualClean,
                    child: const Text(
                      'Clean up filler',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
              if (widget.note != null)
                TextButton(onPressed: _delete, child: const Text('Delete')),
              FilledButton(onPressed: _save, child: const Text('Save')),
            ],
          ),
        ],
      ),
    );
  }
}

/// Grok phone-chat pill: dark capsule, typeable field, mic circle, colour square.
class _ChatComposer extends StatelessWidget {
  const _ChatComposer({
    required this.controller,
    required this.listening,
    required this.autofocus,
    required this.labels,
    required this.labelId,
    required this.onMic,
    required this.onLabel,
  });

  final TextEditingController controller;
  final bool listening;
  final bool autofocus;
  final List<ColorLabel> labels;
  final String labelId;
  final VoidCallback onMic;
  final ValueChanged<String> onLabel;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      key: const Key('note-composer-pill'),
      decoration: BoxDecoration(
        color: ShelfColors.composerPill,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(
          color: listening ? ShelfColors.orange : const Color(0xFF2C2C2E),
          width: listening ? 1.5 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                key: const Key('note-composer-field'),
                controller: controller,
                autofocus: autofocus,
                enabled: true,
                minLines: 1,
                maxLines: NoteEditor.composerMaxLines,
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.newline,
                cursorColor: ShelfColors.composerCaret,
                style: const TextStyle(
                  color: ShelfColors.composerText,
                  fontSize: 16,
                  height: 1.25,
                ),
                decoration: const InputDecoration(
                  hintText: 'Leave a comment',
                  hintStyle: TextStyle(
                    color: ShelfColors.composerHint,
                    fontSize: 16,
                    height: 1.25,
                  ),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  filled: false,
                  fillColor: Colors.transparent,
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
            const SizedBox(width: 6),
            _MicButton(listening: listening, onPressed: onMic),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: NoteLabelPicker(
                labels: labels,
                selectedId: labelId,
                onSelected: onLabel,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MicButton extends StatelessWidget {
  const _MicButton({required this.listening, required this.onPressed});

  final bool listening;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: listening ? 'Stop listening' : 'Start a voice note',
      child: Material(
        color: listening ? ShelfColors.orange : ShelfColors.composerMicCircle,
        shape: const CircleBorder(),
        child: InkWell(
          key: const Key('note-composer-mic'),
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox(
            width: 36,
            height: 36,
            child: Icon(
              listening ? Icons.stop_rounded : Icons.mic,
              color: listening ? ShelfColors.white : const Color(0xFFD1D1D6),
              size: 20,
            ),
          ),
        ),
      ),
    );
  }
}
