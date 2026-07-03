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

  ShoppingItem copyWith({String? name, int? budgetFcfa}) => ShoppingItem(
        name: name ?? this.name,
        budgetFcfa: budgetFcfa ?? this.budgetFcfa,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ShoppingItem &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          budgetFcfa == other.budgetFcfa;

  @override
  int get hashCode => Object.hash(name, budgetFcfa);
}
