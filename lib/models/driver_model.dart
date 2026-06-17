class DriverModel {

  final String id;
  final String name;
  final String phone;
  final String vehicle;
  final String status;

  DriverModel({
    required this.id,
    required this.name,
    required this.phone,
    required this.vehicle,
    required this.status,
  });

  Map<String, dynamic> toMap() {
    return {
      "name": name,
      "phone": phone,
      "vehicle": vehicle,
      "status": status,
    };
  }

  factory DriverModel.fromMap(String id, Map data) {
    return DriverModel(
      id: id,
      name: data["name"],
      phone: data["phone"],
      vehicle: data["vehicle"],
      status: data["status"],
    );
  }
}