import 'package:flutter/material.dart';

// ── Brand colors ───────────────────────────────────────────────────────────────
const kEkGreen     = Color(0xFF00C853);
const kEkTeal      = Color(0xFF00BFA5);
const kEkDark      = Color(0xFF0A2E1A);
const kEkBg        = Color(0xFFF0FFF4);
const kEkCard      = Colors.white;
const kEkText      = Color(0xFF1A1A2E);
const kEkMuted     = Color(0xFF9E9E9E);
const kEkDivider   = Color(0xFFEEEEEE);
const kEkOrange    = Color(0xFFFF6D00);

// ── Operators ──────────────────────────────────────────────────────────────────
const ekOperators = [
  {
    'id':    'orange',
    'label': 'Orange',
    'color':  0xFFFF6600,
    'bg':     0xFFFFF3E0,
    'emoji':  '🟠',
    'logo':   'assets/payment/orange.png',
  },
  {
    'id':    'mtn',
    'label': 'MTN',
    'color':  0xFFFFBB00,
    'bg':     0xFFFFFDE7,
    'emoji':  '🟡',
    'logo':   'assets/payment/mtn.png',
  },
  {
    'id':    'moov',
    'label': 'Moov',
    'color':  0xFF005EB8,
    'bg':     0xFFE3F2FD,
    'emoji':  '🔵',
    'logo':   'assets/payment/moov.png',
  },
  {
    'id':    'wave',
    'label': 'Wave',
    'color':  0xFF00B9F1,
    'bg':     0xFFE0F7FA,
    'emoji':  '🌊',
    'logo':   'assets/payment/wave.png',
  },
];

// ── Services par opérateur ─────────────────────────────────────────────────────
const ekServices = {
  'orange': [
    {'id': 'credit',           'label': 'Crédit Orange',      'icon': '📞', 'minAmount': 100},
    {'id': 'mix',              'label': 'Mix Orange',          'icon': '📦', 'minAmount': 200},
    {'id': 'internet',         'label': 'Pass Internet',       'icon': '🌐', 'minAmount': 500},
    {'id': 'transfer',         'label': 'Transfert Orange',    'icon': '↗️', 'minAmount': 500},
    {'id': 'momo_deposit',     'label': 'Dépôt Orange Money',  'icon': '💰', 'minAmount': 500},
    {'id': 'momo_withdrawal',  'label': 'Retrait Orange Money','icon': '💵', 'minAmount': 1000},
  ],
  'mtn': [
    {'id': 'credit',           'label': 'Crédit MTN',          'icon': '📞', 'minAmount': 100},
    {'id': 'internet',         'label': 'Pass Internet MTN',   'icon': '🌐', 'minAmount': 500},
    {'id': 'transfer',         'label': 'Transfert MTN',       'icon': '↗️', 'minAmount': 500},
    {'id': 'momo_deposit',     'label': 'Dépôt MTN MoMo',      'icon': '💰', 'minAmount': 500},
    {'id': 'momo_withdrawal',  'label': 'Retrait MTN MoMo',    'icon': '💵', 'minAmount': 1000},
  ],
  'moov': [
    {'id': 'credit',           'label': 'Crédit Moov',         'icon': '📞', 'minAmount': 100},
    {'id': 'internet',         'label': 'Pass Internet Moov',  'icon': '🌐', 'minAmount': 500},
    {'id': 'momo_deposit',     'label': 'Dépôt Moov Money',    'icon': '💰', 'minAmount': 500},
    {'id': 'momo_withdrawal',  'label': 'Retrait Moov Money',  'icon': '💵', 'minAmount': 1000},
  ],
  'wave': [
    {'id': 'transfer',         'label': 'Transfert Wave',      'icon': '↗️', 'minAmount': 500},
    {'id': 'momo_deposit',     'label': 'Dépôt Wave',          'icon': '💰', 'minAmount': 500},
    {'id': 'momo_withdrawal',  'label': 'Retrait Wave',        'icon': '💵', 'minAmount': 1000},
  ],
};

// ── Frais de service ───────────────────────────────────────────────────────────
// Retourne les frais pour un service donné + montant
int ekCalculateFee(String serviceId, int amount) {
  switch (serviceId) {
    case 'credit':
    case 'mix':
    case 'internet':
      // 5% min 50 max 500
      return (amount * 0.05).round().clamp(50, 500);
    case 'transfer':
      // 3% min 100 max 1000
      return (amount * 0.03).round().clamp(100, 1000);
    case 'momo_deposit':
      // 2% min 100 max 2000
      return (amount * 0.02).round().clamp(100, 2000);
    case 'momo_withdrawal':
      // 3% min 150 max 3000
      return (amount * 0.03).round().clamp(150, 3000);
    default:
      return (amount * 0.05).round().clamp(50, 500);
  }
}

// Commission AZ Express = 25% des frais
// Agent earning = 75% des frais
int ekAzCommission(int fee) => (fee * 0.25).round();
int ekAgentEarning(int fee) => fee - ekAzCommission(fee);

// ── Order statuses ─────────────────────────────────────────────────────────────
const ekStatusLabels = {
  'pending':           'En attente d\'agent',
  'assigned':          'Agent trouvé',
  'awaiting_deposit':  'Envoyez votre preuve de paiement',
  'in_progress':       'En cours',
  'proof_sent':        'Preuve envoyée',
  'completed':         'Terminé',
  'cancelled':         'Annulé',
  'disputed':          'Litige',
};

Color ekStatusColor(String status) {
  switch (status) {
    case 'pending':          return const Color(0xFFFF8F00);
    case 'assigned':         return const Color(0xFF2196F3);
    case 'awaiting_deposit': return const Color(0xFFE65100);
    case 'in_progress':      return const Color(0xFF9C27B0);
    case 'proof_sent':  return const Color(0xFF00BCD4);
    case 'completed':   return kEkGreen;
    case 'cancelled':   return Colors.red;
    case 'disputed':    return Colors.deepOrange;
    default:            return kEkMuted;
  }
}

// ── Payment methods ────────────────────────────────────────────────────────────
const ekPaymentMethods = [
  {'id': 'wallet',      'label': 'Wallet AZ Express', 'icon': Icons.account_balance_wallet_rounded},
  {'id': 'orange_money','label': 'Orange Money',      'icon': Icons.phone_android_rounded},
  {'id': 'mtn_momo',   'label': 'MTN MoMo',          'icon': Icons.phone_android_rounded},
  {'id': 'wave',        'label': 'Wave',               'icon': Icons.waves_rounded},
];

// ── Quick amount presets ───────────────────────────────────────────────────────
const ekAmountPresets = [200, 500, 1000, 2000, 5000, 10000];
