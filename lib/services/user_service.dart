import 'package:cloud_firestore/cloud_firestore.dart';

class UserService {

  final FirebaseFirestore db = FirebaseFirestore.instance;

  Future<String?> getUserRole(String uid) async {

    try {

      final doc = await db.collection("users").doc(uid).get();

      if (!doc.exists) {
        return null;
      }

      return doc.data()?["role"] as String?;

    } catch (e) {

      return null;

    }
  }
}