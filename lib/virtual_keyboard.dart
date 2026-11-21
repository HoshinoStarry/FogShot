import 'package:material_ui/material_ui.dart';

/// Reports a Windows virtual-key transition to the remote input layer.
typedef VirtualKeyCallback = void Function(int vk, bool down);

/// A compact QWERTY keyboard for desktop-streaming input.
///
/// Sticky modifiers wrap each tapped key in down/up transitions, and all
/// transient keyboard state is cleared when this widget loses focus.
class VirtualKeyboard extends StatefulWidget {
  const VirtualKeyboard({super.key, required this.onKey});

  final VirtualKeyCallback onKey;

  @override
  State<VirtualKeyboard> createState() => _VirtualKeyboardState();
}

const int _vkBackspace = 0x08;
const int _vkTab = 0x09;
const int _vkEnter = 0x0d;
const int _vkShift = 0x10;
const int _vkCtrl = 0x11;
const int _vkAlt = 0x12;
const int _vkEsc = 0x1b;
const int _vkSpace = 0x20;
const int _vkLeft = 0x25;
const int _vkUp = 0x26;
const int _vkRight = 0x27;
const int _vkDown = 0x28;
const int _vkWin = 0x5b;

typedef _CharacterPair = ({String plain, String shifted, int vk});
typedef _ShiftedKey = ({String label, int vk});

const List<_CharacterPair> _digitPairs = [
  (plain: '1', shifted: '!', vk: 0x31),
  (plain: '2', shifted: '@', vk: 0x32),
  (plain: '3', shifted: '#', vk: 0x33),
  (plain: '4', shifted: r'$', vk: 0x34),
  (plain: '5', shifted: '%', vk: 0x35),
  (plain: '6', shifted: '^', vk: 0x36),
  (plain: '7', shifted: '&', vk: 0x37),
  (plain: '8', shifted: '*', vk: 0x38),
  (plain: '9', shifted: '(', vk: 0x39),
  (plain: '0', shifted: ')', vk: 0x30),
];

const List<_CharacterPair> _punctuationPairs = [
  (plain: '-', shifted: '_', vk: 0xbd),
  (plain: '=', shifted: '+', vk: 0xbb),
  (plain: '[', shifted: '{', vk: 0xdb),
  (plain: ']', shifted: '}', vk: 0xdd),
  (plain: ';', shifted: ':', vk: 0xba),
  (plain: "'", shifted: '"', vk: 0xde),
  (plain: ',', shifted: '<', vk: 0xbc),
  (plain: '.', shifted: '>', vk: 0xbe),
  (plain: '/', shifted: '?', vk: 0xbf),
  (plain: r'\', shifted: '|', vk: 0xdc),
];

const List<_ShiftedKey> _shiftedKeys = [
  (label: '@', vk: 0x32),
  (label: '#', vk: 0x33),
  (label: r'$', vk: 0x34),
  (label: '%', vk: 0x35),
  (label: '&', vk: 0x37),
  (label: '*', vk: 0x38),
  (label: '(', vk: 0x39),
  (label: ')', vk: 0x30),
];

int _letterVk(String letter) => 0x41 + letter.codeUnitAt(0) - 0x61;

class _VirtualKeyboardState extends State<VirtualKeyboard>
    with WidgetsBindingObserver {
  final List<int> _activeModifiers = [];
  bool _symbols = false;
  bool _shift = false;
  String? _lastAction;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _clearKeyboardState();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clearKeyboardState(rebuild: false);
    super.dispose();
  }

  void _clearKeyboardState({bool rebuild = true}) {
    final changed =
        _activeModifiers.isNotEmpty || _shift || _lastAction != null;
    _activeModifiers.clear();
    _shift = false;
    _lastAction = null;
    if (rebuild && changed && mounted) setState(() {});
  }

  void _toggleModifier(int vk, String label) {
    setState(() {
      if (_activeModifiers.contains(vk)) {
        _activeModifiers.remove(vk);
      } else {
        _activeModifiers.add(vk);
      }
      _lastAction = label;
    });
  }

  void _toggleShift() {
    setState(() {
      _shift = !_shift;
      _lastAction = 'Shift';
    });
  }

  void _toggleSymbols() {
    setState(() {
      _symbols = !_symbols;
      _shift = false;
      _lastAction = _symbols ? '符号' : '字母';
    });
  }

  void _emitKey(int vk, {bool withShift = false}) {
    final modifiers = [
      if (_activeModifiers.contains(_vkCtrl)) _vkCtrl,
      if (_activeModifiers.contains(_vkAlt)) _vkAlt,
      if (_activeModifiers.contains(_vkWin)) _vkWin,
      if (withShift) _vkShift,
    ];
    for (final modifier in modifiers) {
      widget.onKey(modifier, true);
    }
    widget.onKey(vk, true);
    widget.onKey(vk, false);
    for (final modifier in modifiers.reversed) {
      widget.onKey(modifier, false);
    }
  }

  void _pressCharacter(int vk, String label, {bool forceShift = false}) {
    final withShift = forceShift || _shift;
    setState(() {
      _shift = false;
      _lastAction = label;
    });
    _emitKey(vk, withShift: withShift);
  }

  void _pressSpecial(int vk, String label, {bool withShift = true}) {
    final useShift = withShift && _shift;
    setState(() {
      if (useShift) _shift = false;
      _lastAction = label;
    });
    _emitKey(vk, withShift: useShift);
  }

  Widget _key({
    required Widget child,
    required VoidCallback onPressed,
    int flex = 1,
    bool selected = false,
    String? tooltip,
    Key? key,
    double gap = 4,
    double height = 38,
  }) {
    final style = FilledButton.styleFrom(
      padding: EdgeInsets.zero,
      minimumSize: Size(0, height),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
    );
    Widget button = SizedBox(
      height: height,
      child: selected
          ? FilledButton(
              key: key,
              style: style,
              onPressed: onPressed,
              child: child,
            )
          : FilledButton.tonal(
              key: key,
              style: style,
              onPressed: onPressed,
              child: child,
            ),
    );
    if (tooltip != null) {
      button = Tooltip(message: tooltip, child: button);
    }
    return Expanded(
      flex: flex,
      child: Padding(padding: EdgeInsets.all(gap / 2), child: button),
    );
  }

  Widget _textKey(
    String label, {
    required VoidCallback onPressed,
    int flex = 1,
    bool selected = false,
    String? tooltip,
    Key? key,
    double gap = 4,
    double height = 38,
  }) => _key(
    key: key,
    onPressed: onPressed,
    flex: flex,
    selected: selected,
    tooltip: tooltip,
    gap: gap,
    height: height,
    child: FittedBox(fit: BoxFit.scaleDown, child: Text(label)),
  );

  Widget _iconKey(
    IconData icon, {
    required String tooltip,
    required VoidCallback onPressed,
    int flex = 1,
    bool selected = false,
    Key? key,
    double gap = 4,
    double height = 38,
  }) => _key(
    key: key,
    onPressed: onPressed,
    flex: flex,
    selected: selected,
    tooltip: tooltip,
    gap: gap,
    height: height,
    child: Icon(icon, size: 18),
  );

  Widget _letterLayer(double gap, double height) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            for (final letter in 'qwertyuiop'.split(''))
              _textKey(
                _shift ? letter.toUpperCase() : letter,
                key: ValueKey('vk-${_letterVk(letter)}'),
                onPressed: () => _pressCharacter(
                  _letterVk(letter),
                  _shift ? letter.toUpperCase() : letter,
                ),
                gap: gap,
                height: height,
              ),
          ],
        ),
        Row(
          children: [
            _iconKey(
              Icons.arrow_upward,
              tooltip: 'Shift',
              selected: _shift,
              flex: 2,
              onPressed: _toggleShift,
              gap: gap,
              height: height,
            ),
            for (final letter in 'asdfghjkl'.split(''))
              _textKey(
                _shift ? letter.toUpperCase() : letter,
                key: ValueKey('vk-${_letterVk(letter)}'),
                onPressed: () => _pressCharacter(
                  _letterVk(letter),
                  _shift ? letter.toUpperCase() : letter,
                ),
                gap: gap,
                height: height,
              ),
          ],
        ),
        Row(
          children: [
            for (final letter in 'zxcvbnm'.split(''))
              _textKey(
                _shift ? letter.toUpperCase() : letter,
                key: ValueKey('vk-${_letterVk(letter)}'),
                onPressed: () => _pressCharacter(
                  _letterVk(letter),
                  _shift ? letter.toUpperCase() : letter,
                ),
                gap: gap,
                height: height,
              ),
            _iconKey(
              Icons.backspace_outlined,
              tooltip: 'Backspace',
              flex: 2,
              onPressed: () => _pressSpecial(_vkBackspace, 'Backspace'),
              gap: gap,
              height: height,
            ),
          ],
        ),
        _bottomRow(gap, height),
      ],
    );
  }

  Widget _symbolLayer(double gap, double height) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            for (final pair in _digitPairs)
              _textKey(
                _shift ? pair.shifted : pair.plain,
                key: ValueKey('vk-${pair.vk}'),
                onPressed: () => _pressCharacter(
                  pair.vk,
                  _shift ? pair.shifted : pair.plain,
                ),
                gap: gap,
                height: height,
              ),
          ],
        ),
        Row(
          children: [
            for (final pair in _punctuationPairs)
              _textKey(
                _shift ? pair.shifted : pair.plain,
                key: ValueKey('vk-${pair.vk}'),
                onPressed: () => _pressCharacter(
                  pair.vk,
                  _shift ? pair.shifted : pair.plain,
                ),
                gap: gap,
                height: height,
              ),
          ],
        ),
        Row(
          children: [
            _iconKey(
              Icons.arrow_upward,
              tooltip: 'Shift',
              selected: _shift,
              flex: 2,
              onPressed: _toggleShift,
              gap: gap,
              height: height,
            ),
            for (final shifted in _shiftedKeys)
              _textKey(
                shifted.label,
                key: ValueKey('vk-shift-${shifted.vk}'),
                onPressed: () => _pressCharacter(
                  shifted.vk,
                  shifted.label,
                  forceShift: true,
                ),
                gap: gap,
                height: height,
              ),
            _iconKey(
              Icons.backspace_outlined,
              tooltip: 'Backspace',
              flex: 2,
              onPressed: () => _pressSpecial(_vkBackspace, 'Backspace'),
              gap: gap,
              height: height,
            ),
          ],
        ),
        _bottomRow(gap, height),
      ],
    );
  }

  Widget _bottomRow(double gap, double height) {
    return Row(
      children: [
        _textKey(
          _symbols ? 'ABC' : '?123',
          tooltip: _symbols ? '字母' : '符号',
          selected: _symbols,
          flex: 2,
          onPressed: _toggleSymbols,
          gap: gap,
          height: height,
        ),
        _textKey(
          'Ctrl',
          tooltip: 'Ctrl',
          selected: _activeModifiers.contains(_vkCtrl),
          flex: 2,
          onPressed: () => _toggleModifier(_vkCtrl, 'Ctrl'),
          gap: gap,
          height: height,
        ),
        _textKey(
          'Alt',
          tooltip: 'Alt',
          selected: _activeModifiers.contains(_vkAlt),
          flex: 2,
          onPressed: () => _toggleModifier(_vkAlt, 'Alt'),
          gap: gap,
          height: height,
        ),
        _textKey(
          'Win',
          tooltip: 'Win',
          selected: _activeModifiers.contains(_vkWin),
          flex: 2,
          onPressed: () => _toggleModifier(_vkWin, 'Win'),
          gap: gap,
          height: height,
        ),
        _textKey(
          ',',
          key: const ValueKey('vk-188'),
          onPressed: () => _pressCharacter(0xbc, ','),
          gap: gap,
          height: height,
        ),
        _iconKey(
          Icons.space_bar,
          tooltip: '空格',
          flex: 5,
          onPressed: () => _pressSpecial(_vkSpace, '空格', withShift: false),
          gap: gap,
          height: height,
        ),
        _textKey(
          '.',
          key: const ValueKey('vk-190'),
          onPressed: () => _pressCharacter(0xbe, '.'),
          gap: gap,
          height: height,
        ),
        _iconKey(
          Icons.keyboard_return,
          tooltip: 'Enter',
          flex: 2,
          onPressed: () => _pressSpecial(_vkEnter, 'Enter'),
          gap: gap,
          height: height,
        ),
      ],
    );
  }

  Widget _utilityRow(double gap, double height) {
    return Row(
      children: [
        _textKey(
          'Esc',
          tooltip: 'Esc',
          flex: 2,
          onPressed: () => _pressSpecial(_vkEsc, 'Esc'),
          gap: gap,
          height: height,
        ),
        _iconKey(
          Icons.keyboard_tab,
          tooltip: 'Tab',
          flex: 2,
          onPressed: () => _pressSpecial(_vkTab, 'Tab'),
          gap: gap,
          height: height,
        ),
        _iconKey(
          Icons.keyboard_arrow_left,
          tooltip: '左方向键',
          flex: 2,
          onPressed: () => _pressSpecial(_vkLeft, '←'),
          gap: gap,
          height: height,
        ),
        _iconKey(
          Icons.keyboard_arrow_up,
          tooltip: '上方向键',
          flex: 2,
          onPressed: () => _pressSpecial(_vkUp, '↑'),
          gap: gap,
          height: height,
        ),
        _iconKey(
          Icons.keyboard_arrow_down,
          tooltip: '下方向键',
          flex: 2,
          onPressed: () => _pressSpecial(_vkDown, '↓'),
          gap: gap,
          height: height,
        ),
        _iconKey(
          Icons.keyboard_arrow_right,
          tooltip: '右方向键',
          flex: 2,
          onPressed: () => _pressSpecial(_vkRight, '→'),
          gap: gap,
          height: height,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : 720.0;
        final width = availableWidth < 720 ? availableWidth : 720.0;
        final compact = width < 480;
        final gap = compact ? 3.0 : 5.0;
        final height = compact ? 36.0 : 42.0;
        return TapRegion(
          onTapOutside: (_) => _clearKeyboardState(),
          child: Focus(
            canRequestFocus: false,
            onFocusChange: (hasFocus) {
              if (!hasFocus) _clearKeyboardState();
            },
            child: SizedBox(
              width: width,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Padding(
                  padding: EdgeInsets.all(gap / 2),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: gap),
                        child: Row(
                          children: [
                            Icon(
                              Icons.keyboard_alt_outlined,
                              size: compact ? 15 : 17,
                            ),
                            SizedBox(width: gap),
                            Expanded(
                              child: Text(
                                _lastAction == null
                                    ? '屏幕键盘'
                                    : '已发送 $_lastAction',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelSmall,
                              ),
                            ),
                          ],
                        ),
                      ),
                      _utilityRow(gap, height),
                      if (_symbols)
                        _symbolLayer(gap, height)
                      else
                        _letterLayer(gap, height),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
