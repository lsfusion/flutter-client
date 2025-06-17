import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AddressBar extends StatefulWidget {
  final String initialUrl;
  final void Function(String url) onNavigate;

  const AddressBar({
    super.key,
    required this.initialUrl,
    required this.onNavigate,
  });

  @override
  State<AddressBar> createState() => _AddressBarState();
}

class _AddressBarState extends State<AddressBar> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  List<String> _history = [];

  @override
  void initState() {
    super.initState();
    _controller.text = widget.initialUrl;
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList('history') ?? [];
    setState(() {
      _history = stored;
    });
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
    if (!url.startsWith('http')) {
      url = 'http://$url';
    }

    _controller.text = url;
    widget.onNavigate(url);
    _saveUrl(url);
    _focusNode.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    return RawAutocomplete<String>(
      textEditingController: _controller,
      focusNode: _focusNode,
      optionsBuilder: (TextEditingValue value) {
        final input = value.text.toLowerCase();
        return _history.reversed
            .where((url) => url.toLowerCase().contains(input));
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
            border: OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: Icon(Icons.arrow_forward),
              onPressed: () => _handleSubmit(controller.text),
            ),
          ),
          onSubmitted: _handleSubmit,
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
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
                return ListTile(
                  title: Text(option),
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