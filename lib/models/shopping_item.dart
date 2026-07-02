class ShoppingItem {
  final String name;
  final int budgetFcfa;

  const ShoppingItem({required this.name, required this.budgetFcfa});

  factory ShoppingItem.fromMap(Map<String, dynamic> data) {
    return ShoppingItem(
      name: data['name'] as String? ?? '',
      budgetFcfa: (data['budgetFcfa'] as num? ?? 0).toInt(),
    );
  }

  Map<String, dynamic> toMap() => {
        'name': name,
        'budgetFcfa': budgetFcfa,
      };
}
