import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../theme/app_theme.dart';

/// Master Prompt "Immobilier V6" — Mission 6 : galerie photos avec ordre,
/// vignettes, plein écran, zoom et swipe. Les vidéos (`videos`) sont
/// affichées comme vignettes distinctes qui s'ouvrent en externe — ce
/// projet n'a aucune dépendance de lecture vidéo (`video_player`/`chewie`),
/// en ajouter une serait hors du périmètre de cette passe ; ouvrir en
/// externe (navigateur/lecteur natif) reste honnête et fonctionnel.
class ListingGalleryHeader extends StatefulWidget {
  final List<String> images;
  final List<String> videos;
  final double height;

  const ListingGalleryHeader({
    super.key,
    required this.images,
    this.videos = const [],
    this.height = 240,
  });

  @override
  State<ListingGalleryHeader> createState() => _ListingGalleryHeaderState();
}

class _ListingGalleryHeaderState extends State<ListingGalleryHeader> {
  final _pageController = PageController();
  int _index = 0;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _openFullscreen(int startIndex) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            _FullscreenGallery(images: widget.images, initialIndex: startIndex),
        fullscreenDialog: true,
      ),
    );
  }

  Future<void> _openVideo(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (widget.images.isEmpty && widget.videos.isEmpty) {
      return Container(
        height: widget.height,
        color: AppColors.primaryBg,
        child:
            const Icon(Icons.home_outlined, size: 56, color: AppColors.primary),
      );
    }
    return SizedBox(
      height: widget.height,
      child: Stack(
        children: [
          if (widget.images.isNotEmpty)
            PageView.builder(
              controller: _pageController,
              itemCount: widget.images.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (context, i) => GestureDetector(
                onTap: () => _openFullscreen(i),
                child: CachedNetworkImage(
                  imageUrl: widget.images[i],
                  fit: BoxFit.cover,
                  width: double.infinity,
                  placeholder: (_, __) => Container(color: AppColors.primaryBg),
                  errorWidget: (_, __, ___) => Container(
                      color: AppColors.primaryBg,
                      child: const Icon(Icons.broken_image_outlined,
                          color: AppColors.primary)),
                ),
              ),
            )
          else
            Container(color: AppColors.primaryBg),
          if (widget.images.length > 1)
            Positioned(
              bottom: 12,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                  widget.images.length,
                  (i) => AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: i == _index ? 18 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: i == _index ? Colors.white : Colors.white54,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ),
            ),
          if (widget.videos.isNotEmpty)
            Positioned(
              top: 12,
              right: 12,
              child: Wrap(
                spacing: 6,
                children: widget.videos
                    .map((v) => GestureDetector(
                          onTap: () => _openVideo(v),
                          child: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: const BoxDecoration(
                                color: Colors.black54, shape: BoxShape.circle),
                            child: const Icon(Icons.play_arrow_rounded,
                                color: Colors.white, size: 20),
                          ),
                        ))
                    .toList(),
              ),
            ),
        ],
      ),
    );
  }
}

class _FullscreenGallery extends StatefulWidget {
  final List<String> images;
  final int initialIndex;
  const _FullscreenGallery({required this.images, required this.initialIndex});

  @override
  State<_FullscreenGallery> createState() => _FullscreenGalleryState();
}

class _FullscreenGalleryState extends State<_FullscreenGallery> {
  late final _controller = PageController(initialPage: widget.initialIndex);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: widget.images.length,
        itemBuilder: (context, i) => InteractiveViewer(
          minScale: 1,
          maxScale: 4,
          child: Center(
            child: CachedNetworkImage(
              imageUrl: widget.images[i],
              fit: BoxFit.contain,
            ),
          ),
        ),
      ),
    );
  }
}
