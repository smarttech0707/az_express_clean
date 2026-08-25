import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

enum AdminReviewPartnerFilter { all, restaurant, boulangerie, seller }

enum AdminReviewRatingFilter { all, low }

class AdminReviewRecord {
  const AdminReviewRecord({
    required this.id,
    required this.sellerId,
    required this.sellerType,
    required this.rating,
    required this.comment,
    required this.createdAt,
  });

  final String id;
  final String sellerId;
  final String sellerType;
  final int rating;
  final String comment;
  final DateTime? createdAt;
}

class AdminReviewPageRequest {
  const AdminReviewPageRequest({
    required this.partnerFilter,
    required this.ratingFilter,
    required this.limit,
    this.cursor,
  });

  final AdminReviewPartnerFilter partnerFilter;
  final AdminReviewRatingFilter ratingFilter;
  final int limit;
  final Object? cursor;
}

class AdminReviewPageResult {
  const AdminReviewPageResult({required this.records, this.cursor});

  final List<AdminReviewRecord> records;
  final Object? cursor;
}

typedef AdminReviewsPageLoader = Future<AdminReviewPageResult> Function(
    AdminReviewPageRequest request);

class AdminReviewsPage extends StatefulWidget {
  const AdminReviewsPage({super.key, this.pageLoader});

  final AdminReviewsPageLoader? pageLoader;

  @override
  State<AdminReviewsPage> createState() => _AdminReviewsPageState();
}

class _AdminReviewsPageState extends State<AdminReviewsPage> {
  static const pageSize = 25;

  final List<AdminReviewRecord> _reviews = [];
  final Map<String, Future<String>> _partnerNames = {};
  AdminReviewPartnerFilter _partnerFilter = AdminReviewPartnerFilter.all;
  AdminReviewRatingFilter _ratingFilter = AdminReviewRatingFilter.all;
  Object? _cursor;
  bool _loading = false;
  bool _hasMore = true;

  @override
  void initState() {
    super.initState();
    _loadMore();
  }

  Future<AdminReviewPageResult> _firestoreLoader(
      AdminReviewPageRequest request) async {
    Query<Map<String, dynamic>> query = FirebaseFirestore.instance
        .collection('reviews')
        .orderBy('createdAt', descending: true);
    if (request.partnerFilter != AdminReviewPartnerFilter.all) {
      query = query.where('sellerType', isEqualTo: request.partnerFilter.name);
    }
    if (request.ratingFilter == AdminReviewRatingFilter.low) {
      query = query.where('rating', whereIn: const [1, 2]);
    }
    final cursor = request.cursor;
    if (cursor is DocumentSnapshot<Map<String, dynamic>>) {
      query = query.startAfterDocument(cursor);
    }
    final snapshot = await query.limit(request.limit).get();
    return AdminReviewPageResult(
      records: snapshot.docs.map((doc) {
        final data = doc.data();
        return AdminReviewRecord(
          id: doc.id,
          sellerId: data['sellerId'] as String? ?? '',
          sellerType: data['sellerType'] as String? ?? 'non renseigné',
          rating: (data['rating'] as num?)?.toInt() ?? 0,
          comment: data['comment'] as String? ?? '',
          createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
        );
      }).toList(),
      cursor: snapshot.docs.isEmpty ? cursor : snapshot.docs.last,
    );
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() => _loading = true);
    try {
      final result = await (widget.pageLoader ?? _firestoreLoader)(
        AdminReviewPageRequest(
          partnerFilter: _partnerFilter,
          ratingFilter: _ratingFilter,
          limit: pageSize,
          cursor: _cursor,
        ),
      );
      if (!mounted) return;
      setState(() {
        _reviews.addAll(result.records);
        _cursor = result.cursor;
        _hasMore = result.records.length == pageSize;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Impossible de charger les avis : $error')),
      );
    }
  }

  void _reload() {
    setState(() {
      _reviews.clear();
      _partnerNames.clear();
      _cursor = null;
      _hasMore = true;
    });
    _loadMore();
  }

  Future<String> _loadPartnerName(AdminReviewRecord review) async {
    final collection = switch (review.sellerType) {
      'restaurant' => 'restaurants',
      'boulangerie' => 'boulangeries',
      'seller' => 'sellers',
      _ => null,
    };
    if (collection == null || review.sellerId.isEmpty) {
      return review.sellerId.isEmpty
          ? 'Partenaire non renseigné'
          : review.sellerId;
    }
    final doc = await FirebaseFirestore.instance
        .collection(collection)
        .doc(review.sellerId)
        .get();
    final data = doc.data();
    return (data?['name'] ?? data?['shopName'] ?? review.sellerId).toString();
  }

  String _date(DateTime? value) {
    if (value == null) return 'Date non renseignée';
    final d = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('Avis partenaires'),
        backgroundColor: const Color(0xFF00695C),
        foregroundColor: Colors.white,
      ),
      body: Column(children: [
        Material(
          color: Colors.white,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(spacing: 12, runSpacing: 8, children: [
              DropdownButton<AdminReviewPartnerFilter>(
                key: const Key('reviews-partner-filter'),
                value: _partnerFilter,
                items: const [
                  DropdownMenuItem(
                      value: AdminReviewPartnerFilter.all,
                      child: Text('Tous les partenaires')),
                  DropdownMenuItem(
                      value: AdminReviewPartnerFilter.restaurant,
                      child: Text('Restaurants')),
                  DropdownMenuItem(
                      value: AdminReviewPartnerFilter.boulangerie,
                      child: Text('Boulangeries')),
                  DropdownMenuItem(
                      value: AdminReviewPartnerFilter.seller,
                      child: Text('Boutiques')),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  _partnerFilter = value;
                  _reload();
                },
              ),
              FilterChip(
                key: const Key('reviews-low-rating-filter'),
                label: const Text('Notes 1–2 étoiles'),
                selected: _ratingFilter == AdminReviewRatingFilter.low,
                onSelected: (selected) {
                  _ratingFilter = selected
                      ? AdminReviewRatingFilter.low
                      : AdminReviewRatingFilter.all;
                  _reload();
                },
              ),
            ]),
          ),
        ),
        Expanded(
          child: _reviews.isEmpty && _loading
              ? const Center(child: CircularProgressIndicator())
              : _reviews.isEmpty
                  ? const Center(child: Text('Aucun avis pour ce filtre.'))
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _reviews.length + 1,
                      itemBuilder: (context, index) {
                        if (index == _reviews.length) {
                          if (!_hasMore) return const SizedBox.shrink();
                          return Center(
                            child: OutlinedButton.icon(
                              key: const Key('reviews-load-more'),
                              onPressed: _loading ? null : _loadMore,
                              icon: _loading
                                  ? const SizedBox.square(
                                      dimension: 16,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2))
                                  : const Icon(Icons.expand_more),
                              label: const Text('Charger 25 avis suivants'),
                            ),
                          );
                        }
                        final review = _reviews[index];
                        final cacheKey =
                            '${review.sellerType}:${review.sellerId}';
                        final partnerName = _partnerNames.putIfAbsent(
                            cacheKey, () => _loadPartnerName(review));
                        return Card(
                          margin: const EdgeInsets.only(bottom: 12),
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  Text('${review.rating}/5',
                                      style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          color: review.rating <= 2
                                              ? Colors.red
                                              : Colors.amber.shade800)),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: FutureBuilder<String>(
                                      future: partnerName,
                                      initialData: review.sellerId,
                                      builder: (_, snap) => Text(
                                        snap.data ?? review.sellerId,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                  ),
                                  Text(review.sellerType),
                                ]),
                                const SizedBox(height: 8),
                                Text(review.comment.isEmpty
                                    ? 'Aucun commentaire.'
                                    : review.comment),
                                const SizedBox(height: 8),
                                Text(_date(review.createdAt),
                                    style: TextStyle(
                                        color: Colors.grey.shade600,
                                        fontSize: 12)),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
        ),
      ]),
    );
  }
}
