import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/driver_model.dart';

class DriverService {

  final FirebaseFirestore db = FirebaseFirestore.instance;

  Future<void> registerDriver(DriverModel driver) async {
    await db.collection("livreurs").doc(driver.id).set(driver.toMap());
  }

  Future<String> getDriverStatus(String driverId) async {
    final doc = await db.collection("livreurs").doc(driverId).get();
    if (!doc.exists) return "not_found";
    return doc.data()?["status"] as String? ?? "unknown";
  }
}