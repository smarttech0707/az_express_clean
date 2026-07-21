import 'package:flutter/material.dart';

import '../../services/az_ia_service.dart';
import 'az_ia_message_parser.dart';
import 'az_ia_rich_message.dart';

// ═══════════════════════════════════════════════════════════════════════════
// Widgets spécialisés par type de réponse AZ IA (Master Prompt 117) —
// dispatch UNIQUEMENT sur `response.type` (jamais un mot-clé deviné dans le
// texte). `icon`/`color` sont des chaînes déclarées par le serveur
// (responseBuilder.js) résolues ici via des tables de correspondance
// statiques et exhaustives — un nom d'icône/couleur inconnu retombe sur une
// valeur neutre, jamais un crash.
// ═══════════════════════════════════════════════════════════════════════════

const Map<String, IconData> _icons = {
  'account_balance_wallet': Icons.account_balance_wallet_outlined,
  'history':                Icons.history,
  'add_card':               Icons.add_card_outlined,
  'money_off':               Icons.money_off_outlined,
  'local_shipping':          Icons.local_shipping_outlined,
  'cancel':                  Icons.cancel_outlined,
  'sports_motorsports':      Icons.sports_motorsports_outlined,
  'restaurant':              Icons.restaurant_outlined,
  'restaurant_menu':         Icons.restaurant_menu_outlined,
  'storefront':              Icons.storefront_outlined,
  'shopping_bag':            Icons.shopping_bag_outlined,
  'chat':                    Icons.chat_outlined,
  'swap_horiz':              Icons.swap_horiz,
  'medication':              Icons.medication_outlined,
  'bakery_dining':           Icons.bakery_dining_outlined,
  'home_work':               Icons.home_work_outlined,
  'event_available':         Icons.event_available_outlined,
  'support_agent':           Icons.support_agent_outlined,
  'help_outline':            Icons.help_outline,
  'quiz':                    Icons.quiz_outlined,
  'error_outline':           Icons.error_outline,
  'warning_amber':           Icons.warning_amber_outlined,
  'check_circle':            Icons.check_circle_outline,
  'shield':                  Icons.shield_outlined,
  'notifications':           Icons.notifications_outlined,
  'payments':                Icons.payments_outlined,
  'location_on':             Icons.location_on_outlined,
  'wb_sunny':                Icons.wb_sunny_outlined,
  'auto_awesome':            Icons.auto_awesome,
};

IconData iconForName(String name) => _icons[name] ?? Icons.auto_awesome;

Color colorForHex(String hex) {
  final cleaned = hex.replaceAll('#', '');
  final value = int.tryParse(cleaned, radix: 16);
  if (value == null) return const Color(0xFF6D4C41);
  return Color(0xFF000000 | value);
}

String fcfa(num? amount) => amount == null ? '' : '${amount.toStringAsFixed(0)} FCFA';

/// Coquille commune à toutes les cartes — icône/couleur en en-tête,
/// contenu libre en dessous. Évite de dupliquer 9 fois la même décoration.
class _CardShell extends StatelessWidget {
  final AzIaStructuredResponse response;
  final Widget child;
  const _CardShell({required this.response, required this.child});

  @override
  Widget build(BuildContext context) {
    final color = colorForHex(response.color);
    return Container(
      constraints: const BoxConstraints(maxWidth: 340),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.18)),
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.10), blurRadius: 16, offset: const Offset(0, 6)),
          const BoxShadow(color: Colors.black12, blurRadius: 3, offset: Offset(0, 1)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 30, height: 30,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [color, color.withValues(alpha: 0.7)],
                    begin: Alignment.topLeft, end: Alignment.bottomRight,
                  ),
                  shape: BoxShape.circle,
                ),
                child: Icon(iconForName(response.icon), color: Colors.white, size: 16),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(response.title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

/// Texte de `response.message` mis en forme (titres/puces/paragraphes) —
/// réutilisé à l'identique par toutes les cartes ci-dessous.
Widget _messageBlocks(AzIaStructuredResponse response) {
  return AzIaRichBlocks(blocks: AzIaMessageParser.parseBlocks(response.message));
}

Widget _kv(String label, String value, {Color? valueColor}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 90, child: Text(label, style: TextStyle(color: Colors.grey.shade600, fontSize: 12.5))),
        Expanded(child: Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: valueColor))),
      ],
    ),
  );
}

// ── WalletCard — wallet, wallet_history ─────────────────────────────────
class WalletCard extends StatelessWidget {
  final AzIaStructuredResponse response;
  const WalletCard({super.key, required this.response});

  @override
  Widget build(BuildContext context) {
    final payload = response.payload;
    final balance = payload['balance'];
    final transactions = payload['transactions'] as List?;
    return _CardShell(
      response: response,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (balance is num) _kv('Solde', fcfa(balance), valueColor: colorForHex(response.color)),
          if (transactions != null && transactions.isNotEmpty) ...[
            const SizedBox(height: 4),
            for (final t in transactions.take(5))
              if (t is Map)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(
                    '${t['description'] ?? t['type'] ?? 'Mouvement'} · ${fcfa((t['amount'] as num?)?.abs())}',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
          ],
          const SizedBox(height: 6),
          _messageBlocks(response),
        ],
      ),
    );
  }
}

// ── PaymentCard — wallet_recharge, wallet_withdrawal, payment ──────────
class PaymentCard extends StatelessWidget {
  final AzIaStructuredResponse response;
  const PaymentCard({super.key, required this.response});

  @override
  Widget build(BuildContext context) {
    final payload = response.payload;
    return _CardShell(
      response: response,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (payload['orderId'] != null) _kv('Commande', '#${payload['orderId']}'),
          if (payload['txId'] != null) _kv('Référence', '${payload['txId']}'),
          if (payload['dispatched'] == true) _kv('Livreur', 'Notifié'),
          const SizedBox(height: 6),
          _messageBlocks(response),
        ],
      ),
    );
  }
}

// ── DeliveryCard — delivery, delivery_cancel, ekbine_order ──────────────
class DeliveryCard extends StatelessWidget {
  final AzIaStructuredResponse response;
  const DeliveryCard({super.key, required this.response});

  @override
  Widget build(BuildContext context) {
    final payload = response.payload;
    return _CardShell(
      response: response,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (payload['orderId'] != null) _kv('Commande', '#${payload['orderId']}'),
          if (payload['refundAmount'] != null) _kv('Remboursé', fcfa(payload['refundAmount'] as num?)),
          const SizedBox(height: 6),
          _messageBlocks(response),
        ],
      ),
    );
  }
}

// ── TrackingCard — delivery_tracking, ekbine_tracking, driver ───────────
class TrackingCard extends StatelessWidget {
  final AzIaStructuredResponse response;
  const TrackingCard({super.key, required this.response});

  @override
  Widget build(BuildContext context) {
    final payload = response.payload;
    final agent = payload['agent'];
    return _CardShell(
      response: response,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (payload['orderId'] != null) _kv('Commande', '#${payload['orderId']}'),
          if (payload['status'] != null) _kv('Statut', '${payload['status']}'),
          if (payload['driver'] != null) _kv('Livreur', '${payload['driver']}'),
          if (agent is Map && agent['name'] != null) _kv('Agent', '${agent['name']}'),
          if (payload['amount'] != null) _kv('Montant', fcfa(payload['amount'] as num?)),
          const SizedBox(height: 6),
          _messageBlocks(response),
        ],
      ),
    );
  }
}

Widget _resultsList(List results) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final r in results.take(5))
        if (r is Map)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              [
                r['title'] ?? r['name'] ?? '',
                if (r['price'] != null) fcfa(r['price'] as num?),
                if (r['address'] != null) r['address'],
                if (r['city'] != null) r['city'],
              ].where((s) => s.toString().isNotEmpty).join(' · '),
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
    ],
  );
}

// ── RestaurantCard — restaurant, restaurant_order, restaurant_status,
// bakery, pharmacy (tous "commerçant" — même forme réelle de payload) ────
class RestaurantCard extends StatelessWidget {
  final AzIaStructuredResponse response;
  const RestaurantCard({super.key, required this.response});

  @override
  Widget build(BuildContext context) {
    final payload = response.payload;
    final results = payload['results'] as List?;
    return _CardShell(
      response: response,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (payload['orderId'] != null) _kv('Commande', '#${payload['orderId']}'),
          if (results != null && results.isNotEmpty) _resultsList(results),
          const SizedBox(height: 6),
          _messageBlocks(response),
        ],
      ),
    );
  }
}

// ── MarketplaceCard — marketplace, marketplace_product, marketplace_chat ─
class MarketplaceCard extends StatelessWidget {
  final AzIaStructuredResponse response;
  const MarketplaceCard({super.key, required this.response});

  @override
  Widget build(BuildContext context) {
    final results = response.payload['results'] as List?;
    return _CardShell(
      response: response,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (results != null && results.isNotEmpty) _resultsList(results),
          const SizedBox(height: 6),
          _messageBlocks(response),
        ],
      ),
    );
  }
}

// ── PropertyCard — real_estate, visit_request ───────────────────────────
class PropertyCard extends StatelessWidget {
  final AzIaStructuredResponse response;
  const PropertyCard({super.key, required this.response});

  @override
  Widget build(BuildContext context) {
    final payload = response.payload;
    final results = payload['results'] as List?;
    return _CardShell(
      response: response,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (payload['requestId'] != null) _kv('Demande', '#${payload['requestId']}'),
          if (results != null && results.isNotEmpty) _resultsList(results),
          const SizedBox(height: 6),
          _messageBlocks(response),
        ],
      ),
    );
  }
}

// ── ConfirmationCard — confirmation (représentation en ligne dans le fil ;
// les boutons Confirmer/Annuler restent exclusivement portés par la carte
// persistante _PendingActionCard, pilotée par le flux Firestore en direct
// — voir az_ia_chat_screen.dart, Master Prompt 115. Deux widgets distincts
// pour deux rôles distincts : celui-ci est un rappel dans l'historique, pas
// un second jeu de boutons qui doublonnerait/contredirait le premier.
class ConfirmationCard extends StatelessWidget {
  final AzIaStructuredResponse response;
  const ConfirmationCard({super.key, required this.response});

  @override
  Widget build(BuildContext context) {
    final payload = response.payload;
    return _CardShell(
      response: response,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (payload['summary'] != null)
            Text('${payload['summary']}', style: const TextStyle(fontSize: 13.5, height: 1.35)),
          if (payload['amount'] != null) ...[
            const SizedBox(height: 4),
            _kv('Montant', fcfa(payload['amount'] as num?)),
          ],
        ],
      ),
    );
  }
}

// ── SupportCard — support, help, faq ────────────────────────────────────
class SupportCard extends StatelessWidget {
  final AzIaStructuredResponse response;
  const SupportCard({super.key, required this.response});

  @override
  Widget build(BuildContext context) {
    final ticketId = response.payload['ticketId'];
    return _CardShell(
      response: response,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (ticketId != null) _kv('Ticket', '#$ticketId'),
          const SizedBox(height: 6),
          _messageBlocks(response),
        ],
      ),
    );
  }
}

// ── NotificationCard — notification, success, warning, error ───────────
class NotificationCard extends StatelessWidget {
  final AzIaStructuredResponse response;
  const NotificationCard({super.key, required this.response});

  @override
  Widget build(BuildContext context) {
    final color = colorForHex(response.color);
    return Container(
      constraints: const BoxConstraints(maxWidth: 320),
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(iconForName(response.icon), color: color, size: 18),
          const SizedBox(width: 8),
          Flexible(child: _messageBlocks(response)),
        ],
      ),
    );
  }
}

/// Carte générique (fallback) — `generic`, `location`, `weather`, ou tout
/// type non reconnu (compatibilité descendante, Prompt 117). Simple bulle
/// blanche avec le texte mis en forme, sans en-tête coloré superflu.
class GenericBubble extends StatelessWidget {
  final AzIaStructuredResponse response;
  const GenericBubble({super.key, required this.response});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(20), topRight: Radius.circular(20),
          bottomLeft: Radius.circular(6), bottomRight: Radius.circular(20),
        ),
        boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 8, offset: Offset(0, 3))],
      ),
      child: _messageBlocks(response),
    );
  }
}

/// Dispatcher unique — Flutter ne devine plus rien : uniquement
/// `response.type` détermine le widget affiché (Master Prompt 117).
Widget buildResponseCard(AzIaStructuredResponse response) {
  switch (response.type) {
    case 'wallet':
    case 'wallet_history':
      return WalletCard(response: response);
    case 'wallet_recharge':
    case 'wallet_withdrawal':
    case 'payment':
      return PaymentCard(response: response);
    case 'delivery':
    case 'delivery_cancel':
    case 'ekbine_order':
      return DeliveryCard(response: response);
    case 'delivery_tracking':
    case 'ekbine_tracking':
    case 'driver':
    case 'ekbine':
      return TrackingCard(response: response);
    case 'restaurant':
    case 'restaurant_order':
    case 'restaurant_status':
    case 'bakery':
    case 'pharmacy':
      return RestaurantCard(response: response);
    case 'marketplace':
    case 'marketplace_product':
    case 'marketplace_chat':
      return MarketplaceCard(response: response);
    case 'real_estate':
    case 'visit_request':
      return PropertyCard(response: response);
    case 'confirmation':
      return ConfirmationCard(response: response);
    case 'support':
    case 'help':
    case 'faq':
      return SupportCard(response: response);
    case 'notification':
    case 'success':
    case 'warning':
    case 'error':
      return NotificationCard(response: response);
    case 'generic':
    case 'location':
    case 'weather':
    default:
      return GenericBubble(response: response);
  }
}
