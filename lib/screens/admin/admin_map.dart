import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../widgets/stream_error_state.dart';

class AdminMap extends StatefulWidget {
  const AdminMap({super.key});

  @override
  State<AdminMap> createState() => _AdminMapState();
}

class _AdminMapState extends State<AdminMap> {
  GoogleMapController? mapController;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Carte Admin"),
        backgroundColor: Colors.green,
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance.collection("livreurs").snapshots(),
        builder: (context, driverSnapshot) {
          if (driverSnapshot.hasError) {
            return const StreamErrorState(
                message: "Impossible de charger les livreurs.");
          }
          if (!driverSnapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          return StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection("orders")
                .where("status", whereIn: [
              "pending",
              "assigned",
              "accepted",
              "picked_up"
            ]).snapshots(),
            builder: (context, orderSnapshot) {
              if (orderSnapshot.hasError) {
                return const StreamErrorState(
                    message: "Impossible de charger les commandes en cours.");
              }
              if (!orderSnapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              Set<Marker> markers = {};
              Set<Polyline> polylines = {};

              /// =========================
              /// LIVREURS
              /// =========================
              for (var doc in driverSnapshot.data!.docs) {
                var data = doc.data() as Map<String, dynamic>;

                double lat = (data["lat"] ?? 0).toDouble();
                double lng = (data["lng"] ?? 0).toDouble();

                if (lat == 0 || lng == 0) continue;

                String name = data["name"] ?? "Livreur";
                String phone = data["phone"] ?? "";

                markers.add(
                  Marker(
                    markerId: MarkerId("driver_${doc.id}"),
                    position: LatLng(lat, lng),
                    infoWindow: InfoWindow(
                      title: name,
                      snippet: phone,
                    ),
                    icon: BitmapDescriptor.defaultMarkerWithHue(
                      BitmapDescriptor.hueBlue,
                    ),
                  ),
                );
              }

              /// =========================
              /// COMMANDES
              /// =========================
              for (var order in orderSnapshot.data!.docs) {
                var data = order.data() as Map<String, dynamic>;

                double lat = (data["latitude"] ?? 0).toDouble();
                double lng = (data["longitude"] ?? 0).toDouble();

                if (lat == 0 || lng == 0) continue;

                LatLng orderPosition = LatLng(lat, lng);

                markers.add(
                  Marker(
                    markerId: MarkerId("order_${order.id}"),
                    position: orderPosition,
                    infoWindow: InfoWindow(
                      title: "Commande",
                      snippet: data["description"] ?? "Course",
                    ),
                    icon: BitmapDescriptor.defaultMarkerWithHue(
                      BitmapDescriptor.hueRed,
                    ),
                  ),
                );

                /// =========================
                /// LIGNE LIVREUR → SA COMMANDE
                /// =========================

                final assignedDriverId = data["driverId"] as String?;
                if (assignedDriverId != null && assignedDriverId.isNotEmpty) {
                  final driverDoc = driverSnapshot.data!.docs
                      .where((d) => d.id == assignedDriverId)
                      .firstOrNull;
                  if (driverDoc != null) {
                    final driverData = driverDoc.data() as Map<String, dynamic>;
                    final driverLat = (driverData["lat"] ?? 0).toDouble();
                    final driverLng = (driverData["lng"] ?? 0).toDouble();
                    if (driverLat != 0 && driverLng != 0) {
                      polylines.add(Polyline(
                        polylineId: PolylineId("route_${order.id}"),
                        points: [LatLng(driverLat, driverLng), orderPosition],
                        width: 4,
                        color: Colors.green,
                      ));
                    }
                  }
                }
              }

              return GoogleMap(
                initialCameraPosition: const CameraPosition(
                  target: LatLng(6.7273, -3.4961), // Abengourou
                  zoom: 13,
                ),
                markers: markers,
                polylines: polylines,
                zoomControlsEnabled: true,
                myLocationEnabled: false,
                myLocationButtonEnabled: true,
                onMapCreated: (controller) {
                  mapController = controller;
                },
              );
            },
          );
        },
      ),
    );
  }
}
