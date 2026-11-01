part of 'kit_image.dart';

/// Space kept round a logo inside the avatar circle, in logical px.
const double _inset = 6;

/// Yields a vector logo's SVG text, or null when there is none.
typedef KitVectorLogoLoad = Future<String?> Function();

/// A monochrome vector logo (docs/ux-system/kit-api/KitImage.md,
/// `KitImageSource.vectorLogo`), tinted `text1` so it reads in light and
/// dark and never carries an identity colour (STATE-9). Transparent while
/// loading and when there is no logo or it cannot be drawn, so the
/// [KitAvatar] initials beneath show through; there is no error state.
class _KitVectorLogo extends StatefulWidget {
  const _KitVectorLogo({super.key, required this.id, required this.load});

  final String id;
  final KitVectorLogoLoad load;

  @override
  State<_KitVectorLogo> createState() => _KitVectorLogoViewState();
}

class _KitVectorLogoViewState extends State<_KitVectorLogo> {
  String? _svg;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(_KitVectorLogo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id) {
      _svg = null;
      _start();
    }
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  Future<void> _start() async {
    final generation = ++_generation;
    String? svg;
    try {
      svg = await widget.load();
    } catch (_) {
      svg = null;
    }
    if (!mounted || generation != _generation) return;
    if (svg != _svg) setState(() => _svg = svg);
  }

  @override
  Widget build(BuildContext context) {
    final svg = _svg;
    if (svg == null) return const SizedBox.shrink();
    final tokens = KitTokens.of(context);
    return ColoredBox(
      // Covers the initials beneath: a thin mark must not show them through.
      color: tokens.roles.surface3,
      child: Padding(
        // A monochrome mark fills a round tile badly edge to edge.
        padding: const EdgeInsets.all(_inset),
        child: SvgPicture.string(
          svg,
          fit: BoxFit.contain,
          excludeFromSemantics: true,
          colorFilter: ColorFilter.mode(tokens.roles.text1, BlendMode.srcIn),
          errorBuilder: (context, error, stack) => const SizedBox.shrink(),
          placeholderBuilder: (context) => const SizedBox.shrink(),
        ),
      ),
    );
  }
}
