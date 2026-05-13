import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AddressBar extends StatefulWidget {
  final String initialUrl;
  final void Function(String url) onNavigate;
  final bool isLoading;

  const AddressBar({
    super.key,
    required this.initialUrl,
    required this.onNavigate,
    required this.isLoading,
  });

  @override
  State<AddressBar> createState() => _AddressBarState();
}

class _AddressBarState extends State<AddressBar> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  List<String> _history = [];
  int _highlightedIndex = -1;
  List<String> _currentOptions = [];

  @override
  void initState() {
    super.initState();
    _controller.text = widget.initialUrl;

    _focusNode.onKeyEvent = (node, event) {
      if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
        return KeyEventResult.ignored;
      }

      if (_currentOptions.isEmpty) return KeyEventResult.ignored;

      final key = event.logicalKey;

      if (key == LogicalKeyboardKey.arrowDown) {
        setState(() {
          _highlightedIndex =
              (_highlightedIndex + 1).clamp(0, _currentOptions.length - 1);
        });
        return KeyEventResult.handled;
      }

      if (key == LogicalKeyboardKey.arrowUp) {
        setState(() {
          _highlightedIndex =
              (_highlightedIndex - 1).clamp(-1, _currentOptions.length - 1);
        });
        return KeyEventResult.handled;
      }

      if (key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter) {
        if (_highlightedIndex >= 0 &&
            _highlightedIndex < _currentOptions.length) {
          _handleSubmit(_currentOptions[_highlightedIndex]);
          return KeyEventResult.handled;
        }
      }

      if (key == LogicalKeyboardKey.escape) {
        setState(() => _highlightedIndex = -1);
        _focusNode.unfocus();
        return KeyEventResult.handled;
      }

      // any type key - reset highlighting 
      setState(() => _highlightedIndex = -1);
      return KeyEventResult.ignored;
    };

    _focusNode.addListener(() {
      if (!_focusNode.hasFocus) {
        setState(() => _highlightedIndex = -1);
      }
    });

    _loadHistory();
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList('history') ?? [];
    setState(() => _history = stored);
  }

  Future<void> _saveUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    _history.remove(url);
    _history.add(url);
    if (_history.length > 10) {
      _history = _history.sublist(_history.length - 10);
    }
    await prefs.setStringList('history', _history);
  }

  void _handleSubmit(String input) {
    var url = input.trim();
    if (url.isEmpty) return;
    if (!url.startsWith('http')) {
      url = 'http://$url';
    }

    _controller.text = url;
    widget.onNavigate(url);
    _saveUrl(url);
    _focusNode.unfocus();
    setState(() => _highlightedIndex = -1);
  }

  @override
  Widget build(BuildContext context) {
    return RawAutocomplete<String>(
      textEditingController: _controller,
      focusNode: _focusNode,
      optionsBuilder: (TextEditingValue value) {
        final input = value.text.toLowerCase();
        final opts = _history.reversed
            .where((url) => url.toLowerCase().contains(input))
            .toList();

        _currentOptions = opts;
        _highlightedIndex = -1;

        return opts;
      },
      onSelected: (String selection) {
        _handleSubmit(selection);
      },
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        return TextField(
          controller: controller,
          focusNode: focusNode,
          decoration: InputDecoration(
            labelText: 'Address',
            border: const OutlineInputBorder(),
            suffixIcon: widget.isLoading
                ? const Padding(
              padding: EdgeInsets.all(12.0),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
                : IconButton(
              icon: const Icon(Icons.arrow_forward),
              onPressed: () => _handleSubmit(controller.text),
            ),
          ),
          onSubmitted: (value) {
            if (_highlightedIndex >= 0 &&
                _highlightedIndex < _currentOptions.length) {
              // Enter is handled in onKeyEvent
              return;
            }
            _handleSubmit(value);
          },
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        _currentOptions = options.toList();

        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4.0,
            child: ListView.builder(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              itemCount: options.length,
              itemBuilder: (context, index) {
                final option = options.elementAt(index);
                final isHighlighted = index == _highlightedIndex;
                return ListTile(
                  title: Text(option),
                  selected: isHighlighted,
                  selectedTileColor: Theme.of(context).focusColor,
                  onTap: () => onSelected(option),
                );
              },
            ),
          ),
        );
      },
    );
  }
}
