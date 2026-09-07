import 'package:flutter/material.dart';

class VehicleReportSheet extends StatefulWidget {
  const VehicleReportSheet({super.key, required this.seller});
  final bool seller;

  @override
  State<VehicleReportSheet> createState() => _VehicleReportSheetState();
}

class _VehicleReportSheetState extends State<VehicleReportSheet> {
  String? _reason;
  final _details = TextEditingController();

  List<String> get _reasons => widget.seller
      ? const [
          'Arnaque suspectée',
          'Fausse identité',
          'Comportement abusif',
          'Faux professionnel/magasin',
          'Spam',
          'Autre',
        ]
      : const [
          'Arnaque suspectée',
          'Faux véhicule / fausse annonce',
          'Prix trompeur',
          'Contenu inapproprié',
          'Véhicule déjà vendu/loué',
          'Usurpation',
          'Autre',
        ];

  @override
  void dispose() {
    _details.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            16,
            16,
            16,
            16 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.seller
                    ? 'Signaler ce vendeur'
                    : 'Signaler cette annonce',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              RadioGroup<String>(
                groupValue: _reason,
                onChanged: (value) => setState(() => _reason = value),
                child: Column(
                  children: _reasons
                      .map(
                        (reason) => RadioListTile<String>(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(reason),
                          value: reason,
                        ),
                      )
                      .toList(),
                ),
              ),
              if (_reason == 'Autre')
                TextField(
                  controller: _details,
                  maxLength: 300,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Description courte',
                  ),
                ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _reason == null ||
                        (_reason == 'Autre' && _details.text.trim().isEmpty)
                    ? null
                    : () => Navigator.pop(
                          context,
                          (_reason!, _details.text.trim()),
                        ),
                child: const Text('Envoyer le signalement'),
              ),
            ],
          ),
        ),
      );
}
