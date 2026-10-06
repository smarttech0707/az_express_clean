import 'package:flutter/material.dart';

/// Keeps dish text independent of the space needed by price and actions.
class AdminRestaurantDishCard extends StatelessWidget {
  const AdminRestaurantDishCard({
    super.key,
    required this.name,
    required this.description,
    required this.price,
    required this.imageUrl,
    required this.onEdit,
    required this.onDelete,
  });

  final String name;
  final String description;
  final String price;
  final String imageUrl;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: 54,
      height: 54,
      color: const Color(0xFF1565C0).withValues(alpha: 0.1),
      child: const Icon(Icons.fastfood_rounded,
          color: Color(0xFF1565C0), size: 26),
    );
    final image = ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: imageUrl.isEmpty
          ? fallback
          : Image.network(
              imageUrl,
              width: 54,
              height: 54,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => fallback,
            ),
    );
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Tooltip(
          message: name,
          child: Text(
            name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ),
        if (description.isNotEmpty) ...[
          const SizedBox(height: 4),
          Tooltip(
            message: description,
            child: Text(
              description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ],
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: LayoutBuilder(builder: (context, constraints) {
        // Stack the thumbnail when a phone or large text needs the full width.
        final stacked = constraints.maxWidth <
            360 * MediaQuery.textScalerOf(context).scale(16) / 16;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (stacked) ...[
              Align(alignment: Alignment.centerLeft, child: image),
              const SizedBox(height: 12),
              text,
            ] else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  image,
                  const SizedBox(width: 12),
                  Expanded(child: text),
                ],
              ),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 4,
              children: [
                Text(
                  price,
                  style: const TextStyle(
                    color: Color(0xFF1565C0),
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Modifier',
                      icon: const Icon(Icons.edit_outlined,
                          color: Colors.grey, size: 20),
                      onPressed: onEdit,
                    ),
                    IconButton(
                      tooltip: 'Supprimer',
                      icon: const Icon(Icons.delete_outline,
                          color: Colors.red, size: 20),
                      onPressed: onDelete,
                    ),
                  ],
                ),
              ],
            ),
          ],
        );
      }),
    );
  }
}

class AdminRestaurantActions extends StatelessWidget {
  const AdminRestaurantActions({
    super.key,
    required this.onMenu,
    required this.onSubscription,
    required this.onDelete,
  });

  final VoidCallback onMenu;
  final VoidCallback onSubscription;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Wrap(
          alignment: WrapAlignment.spaceEvenly,
          spacing: 8,
          runSpacing: 4,
          children: [
            TextButton.icon(
              onPressed: onMenu,
              icon: const Icon(Icons.menu_book,
                  size: 18, color: Color(0xFF1565C0)),
              label: const Text('Menu',
                  style: TextStyle(color: Color(0xFF1565C0))),
            ),
            TextButton.icon(
              onPressed: onSubscription,
              icon: const Icon(Icons.workspace_premium_rounded,
                  size: 18, color: Colors.amber),
              label: const Text('Abo', style: TextStyle(color: Colors.amber)),
            ),
            TextButton(
              onPressed: onDelete,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              ),
              child: const Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: [
                  Icon(Icons.delete_outline, size: 18, color: Colors.red),
                  Text('Supprimer', style: TextStyle(color: Colors.red)),
                ],
              ),
            ),
          ],
        ),
      );
}
