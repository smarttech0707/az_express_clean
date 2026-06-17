from fpdf import FPDF
from fpdf.enums import RenderStyle, Corner
import os

ALL_CORNERS = (Corner.TOP_LEFT, Corner.TOP_RIGHT, Corner.BOTTOM_LEFT, Corner.BOTTOM_RIGHT)
FONT_DIR = r"C:\Windows\Fonts"

OUTPUT = r"c:\Users\User\Desktop\AZ_Express_Bilan_Fonctionnalites.pdf"

BLUE      = (21, 101, 192)
BLUE_LIGHT= (30, 136, 229)
BLUE_BG   = (227, 242, 253)
GREEN     = (46, 125, 50)
GREEN_BG  = (232, 245, 233)
ORANGE    = (230, 81, 0)
ORANGE_BG = (255, 243, 224)
PURPLE    = (106, 27, 154)
PURPLE_BG = (243, 229, 245)
GRAY      = (100, 100, 100)
DARK      = (26, 26, 46)
WHITE     = (255, 255, 255)
YELLOW    = (255, 215, 0)

class PDF(FPDF):
    def rounded_rect(self, x, y, w, h, r, style="F"):
        self._draw_rounded_rect(x, y, w, h, RenderStyle.DF, ALL_CORNERS, r)

    def setup_fonts(self):
        self.add_font("Arial", "", os.path.join(FONT_DIR, "arial.ttf"))
        self.add_font("Arial", "B", os.path.join(FONT_DIR, "arialbd.ttf"))
        self.add_font("Arial", "I", os.path.join(FONT_DIR, "ariali.ttf"))
        self.add_font("Arial", "BI", os.path.join(FONT_DIR, "arialbi.ttf"))

    def header(self):
        pass
    def footer(self):
        if self.page_no() > 1:
            self.set_y(-12)
            self.set_font("Arial", "I", 8)
            self.set_text_color(*GRAY)
            self.cell(0, 6, f"AZ Express - Bilan des Fonctionnalites  |  Page {self.page_no()}", align="C")

    def cover_page(self):
        # Gradient background (simulated with rectangles)
        for i in range(297):
            ratio = i / 297
            r = int(21 + ratio * 9)
            g = int(101 + ratio * 35)
            b = int(192 + ratio * 37)
            self.set_fill_color(r, g, b)
            self.rect(0, i, 210, 1.1, "F")

        self.set_y(60)
        self.set_font("Arial", "B", 42)
        self.set_text_color(*WHITE)
        self.cell(0, 16, "AZ EXPRESS", align="C", new_x="LMARGIN", new_y="NEXT")

        # Gold divider
        self.set_draw_color(*YELLOW)
        self.set_line_width(1.5)
        self.line(85, self.get_y()+2, 125, self.get_y()+2)
        self.ln(8)

        self.set_font("Arial", "", 18)
        self.set_text_color(220, 235, 255)
        self.cell(0, 10, "Bilan Complet des Fonctionnalites", align="C", new_x="LMARGIN", new_y="NEXT")
        self.ln(4)

        self.set_font("Arial", "", 13)
        self.set_text_color(200, 220, 250)
        self.cell(0, 8, "Application mobile de livraison et de services a domicile", align="C", new_x="LMARGIN", new_y="NEXT")
        self.cell(0, 8, "Abengourou, Cote d'Ivoire", align="C", new_x="LMARGIN", new_y="NEXT")
        self.ln(20)

        # Stats boxes
        stats = [("8", "Roles utilisateurs"), ("30+", "Ecrans"), ("10+", "Types commande"), ("20+", "Collections Firestore")]
        box_w = 38
        start_x = (210 - 4*box_w - 3*4) / 2
        y = self.get_y()
        for i, (num, lbl) in enumerate(stats):
            x = start_x + i*(box_w+4)
            self.set_fill_color(255, 255, 255, )
            self.set_draw_color(255, 255, 255)
            # semi-transparent box
            self.set_fill_color(30, 80, 160)
            self.rounded_rect(x, y, box_w, 22, 4, "F")
            self.set_xy(x, y+3)
            self.set_font("Arial", "B", 18)
            self.set_text_color(*WHITE)
            self.cell(box_w, 8, num, align="C", new_x="LMARGIN", new_y="NEXT")
            self.set_xy(x, y+12)
            self.set_font("Arial", "", 7)
            self.set_text_color(180, 210, 255)
            self.cell(box_w, 5, lbl, align="C")
        self.ln(34)

        # Badges
        badges = ["Flutter", "Firebase", "Google Maps", "Notifications Push"]
        total_w = sum([self.get_string_width(b)+16 for b in badges]) + 3*6
        bx = (210 - total_w) / 2
        by = self.get_y() + 10
        for b in badges:
            bw = self.get_string_width(b) + 16
            self.set_fill_color(30, 60, 130)
            self.set_draw_color(150, 190, 255)
            self.set_line_width(0.4)
            self.rounded_rect(bx, by, bw, 9, 3, "FD")
            self.set_xy(bx, by+1)
            self.set_font("Arial", "", 9)
            self.set_text_color(*WHITE)
            self.cell(bw, 6, b, align="C")
            bx += bw + 6

        # Date
        self.set_xy(0, 260)
        self.set_font("Arial", "I", 9)
        self.set_text_color(170, 200, 240)
        self.cell(210, 8, "Document genere le 26 mai 2026  |  Version 1.0.0", align="C")

    def section_header(self, icon, title):
        self.ln(4)
        self.set_fill_color(*BLUE)
        self.set_text_color(*WHITE)
        self.set_font("Arial", "B", 13)
        self.set_draw_color(*BLUE)
        self.rounded_rect(self.l_margin, self.get_y(), 190, 10, 3, "F")
        self.set_xy(self.l_margin + 4, self.get_y() + 1.5)
        self.cell(186, 7, f"{icon}  {title}")
        self.ln(14)

    def sub_header(self, title):
        self.ln(2)
        self.set_fill_color(*BLUE_BG)
        self.set_draw_color(*BLUE)
        self.set_line_width(0.8)
        self.rect(self.l_margin, self.get_y(), 0.8, 8, "F")
        self.set_fill_color(*BLUE_BG)
        self.rect(self.l_margin + 0.8, self.get_y(), 189.2, 8, "F")
        self.set_xy(self.l_margin + 6, self.get_y() + 1.5)
        self.set_font("Arial", "B", 11)
        self.set_text_color(*BLUE)
        self.cell(0, 5, title)
        self.ln(10)

    def table_header(self, cols):
        self.set_fill_color(*BLUE)
        self.set_text_color(*WHITE)
        self.set_font("Arial", "B", 9)
        for label, w in cols:
            self.cell(w, 7, label, border=0, fill=True, align="L")
        self.ln()
        self.set_line_width(0)

    def table_row(self, cells, even=False):
        if even:
            self.set_fill_color(248, 249, 255)
        else:
            self.set_fill_color(*WHITE)
        self.set_text_color(*DARK)
        self.set_font("Arial", "", 9)
        y_start = self.get_y()
        x_start = self.l_margin
        max_h = 6
        # Calculate height needed
        heights = []
        for text, w in cells:
            lines = self.multi_cell(w, 5, str(text), dry_run=True, output="LINES")
            heights.append(len(lines) * 5 + 1)
        max_h = max(max(heights), 6)
        # Draw background
        self.set_fill_color(248, 249, 255) if even else self.set_fill_color(*WHITE)
        self.rect(x_start, y_start, 190, max_h, "F")
        # Draw bottom border
        self.set_draw_color(220, 220, 230)
        self.set_line_width(0.2)
        self.line(x_start, y_start + max_h, x_start + 190, y_start + max_h)
        # Draw cells
        x = x_start
        for text, w in cells:
            self.set_xy(x + 1, y_start + 1)
            self.multi_cell(w - 2, 5, str(text), border=0)
            x += w
        self.set_y(y_start + max_h)

    def info_box(self, text, color="green"):
        self.ln(2)
        bg = GREEN_BG if color=="green" else ORANGE_BG
        border_c = GREEN if color=="green" else ORANGE
        self.set_fill_color(*bg)
        self.set_draw_color(*border_c)
        self.set_line_width(0.8)
        h = 14
        self.rect(self.l_margin, self.get_y(), 0.8, h, "F")
        self.set_fill_color(*bg)
        self.rect(self.l_margin + 0.8, self.get_y(), 189.2, h, "F")
        self.set_xy(self.l_margin + 5, self.get_y() + 3)
        self.set_font("Arial", "", 9)
        self.set_text_color(*DARK)
        self.multi_cell(183, 4.5, text, border=0)
        if self.get_y() < self.l_margin + h + 5:
            self.set_y(self.get_y() + 4)
        self.ln(2)

    def bullet_list(self, items):
        self.set_font("Arial", "", 10)
        self.set_text_color(*DARK)
        for item in items:
            self.set_x(self.l_margin + 4)
            x = self.get_x()
            y = self.get_y()
            self.set_fill_color(*BLUE)
            self.ellipse(x, y+2.5, 2, 2, "F")
            self.set_x(x + 5)
            self.multi_cell(180, 5, item, border=0)
            self.ln(0.5)

    def role_box(self, title, items, color):
        w = 88
        x = self.get_x()
        y = self.get_y()
        h = 8 + len(items) * 5 + 6
        bg, fg = color
        self.set_fill_color(*bg)
        self.set_draw_color(*fg)
        self.set_line_width(0.5)
        self.rounded_rect(x, y, w, h, 3, "FD")
        self.set_xy(x+4, y+3)
        self.set_font("Arial", "B", 10)
        self.set_text_color(*fg)
        self.cell(w-8, 5, title)
        self.ln(6)
        self.set_font("Arial", "", 8.5)
        self.set_text_color(*DARK)
        for item in items:
            self.set_x(x+6)
            self.set_fill_color(*fg)
            cx, cy = self.get_x(), self.get_y()
            self.ellipse(cx, cy+2, 1.5, 1.5, "F")
            self.set_x(cx+4)
            self.cell(w-12, 4.5, item)
            self.ln(4.5)
        return h

    def badge(self, text, style="ok"):
        styles = {
            "ok":   ((232,245,233), (46,125,50)),
            "new":  ((227,242,253), (21,101,192)),
            "warn": ((255,243,224), (230,81,0)),
        }
        bg, fg = styles[style]
        w = self.get_string_width(text) + 8
        self.set_fill_color(*bg)
        self.set_draw_color(*fg)
        self.set_line_width(0.3)
        self.rounded_rect(self.get_x(), self.get_y()+0.5, w, 5, 2, "FD")
        self.set_font("Arial", "B", 7.5)
        self.set_text_color(*fg)
        self.cell(w, 5.5, text, align="C")


pdf = PDF(orientation="P", unit="mm", format="A4")
pdf.setup_fonts()
pdf.set_auto_page_break(auto=True, margin=15)
pdf.set_margins(10, 10, 10)

# ── PAGE DE GARDE ──────────────────────────────────────────
pdf.add_page()
pdf.cover_page()

# ── PAGE 2 : PRÉSENTATION GÉNÉRALE ─────────────────────────
pdf.add_page()
pdf.section_header("PRESENTATION", "Presentation Generale de AZ Express")

pdf.set_font("Arial", "", 10)
pdf.set_text_color(*DARK)
pdf.multi_cell(0, 5.5,
    "AZ Express est une application mobile multiplateforme (Android / iOS) developpee en Flutter, "
    "concue pour la ville d'Abengourou (Cote d'Ivoire). Elle connecte en temps reel les clients, les livreurs, "
    "les commercants, les restaurants, les boulangeries, les pharmacies, les artisans et les administrateurs "
    "au sein d'un ecosysteme unifie de livraison et de services a domicile.")
pdf.ln(4)

pdf.sub_header("Architecture Technique")
cols = [("Composant", 38), ("Technologie", 60), ("Usage", 92)]
pdf.table_header(cols)
rows = [
    ("Framework", "Flutter 3.x (Dart)", "Interface mobile Android / iOS"),
    ("Backend", "Firebase (Firestore, Auth, Storage)", "Base de donnees temps reel, auth, fichiers"),
    ("Cartographie", "Google Maps + Geolocator", "GPS, cartes interactives, itineraires"),
    ("Notifications", "Firebase Messaging (FCM)", "Alertes push commandes et livraisons"),
    ("Audio", "audioplayers + flutter_sound + record", "Messages vocaux, alertes sonores"),
    ("Paiement", "Portefeuille interne + Comptant", "Wallet numerique en FCFA"),
    ("Navigation", "go_router + Navigator", "Routage declaratif web + mobile"),
    ("Site web", "Flutter Web + Firebase Hosting", "Vitrine publique (9 pages)"),
]
for i, (c1, c2, c3) in enumerate(rows):
    pdf.table_row([(c1,38),(c2,60),(c3,92)], even=i%2==0)
pdf.ln(4)

pdf.sub_header("Les 8 Roles Utilisateurs")
roles = [
    ("Client", [(BLUE_BG, BLUE)], ["Passer commandes (livraison, courses, colis...)", "Suivre son livreur en temps reel sur la carte", "Payer via portefeuille ou especes", "Chatter avec son livreur", "Noter livreurs et prestataires", "Acceder aux services (artisans, locations...)"]),
    ("Livreur", [(GREEN_BG, GREEN)], ["Recevoir et accepter des courses", "Navigation GPS en temps reel", "Statut en ligne / hors ligne", "Portefeuille et suivi des gains", "Photo de preuve de livraison"]),
    ("Vendeur / Restaurant / Boulangerie", [(ORANGE_BG, ORANGE)], ["Gerer son menu ou catalogue produits", "Recevoir commandes (alerte sonore + haptique)", "Tableau de bord analytique (revenus 7 jours)", "Gestion des stocks", "Portefeuille et abonnement"]),
    ("Administrateur", [(PURPLE_BG, PURPLE)], ["Supervision complete de la plateforme", "Gestion des livreurs et partenaires", "Carte temps reel de tous les livreurs", "Rechargement des portefeuilles", "Classement des livreurs"]),
]
for title, color_info, items in roles:
    pdf.set_x(pdf.l_margin)
    h = pdf.role_box(title, items, color_info[0])
    pdf.ln(h + 4)

# ── PAGE 3 : FONCTIONNALITÉS CLIENT ────────────────────────
pdf.add_page()
pdf.section_header("COMMANDES", "Fonctionnalites Client - Services de Livraison")

pdf.sub_header("1. Creation de Commande (Courses / Shopping)")
cols = [("Fonctionnalite", 55), ("Detail", 135)]
pdf.table_header(cols)
rows = [
    ("Liste de courses", "Saisie texte libre multi-lignes + liste d'articles detaillee"),
    ("Message vocal", "Enregistrement micro style WhatsApp, lecture/pause/suppression, upload Firebase Storage"),
    ("Budget courses", "Montant estimatif des articles en FCFA"),
    ("Localisation", "Texte + selecteur Google Maps interactif (plein ecran), GPS automatique"),
    ("Calcul du prix", "Distance en km + ETA, tarif jour / nuit, carte recapitulative dynamique"),
    ("Paiement", "Especes (COD) ou Portefeuille - detection fraude (desactivation COD apres 3 fausses commandes)"),
]
for i, (c1, c2) in enumerate(rows):
    pdf.table_row([(c1,55),(c2,135)], even=i%2==0)
pdf.ln(3)

pdf.sub_header("2. Suivi de Commande en Temps Reel")
cols = [("Fonctionnalite", 55), ("Detail", 135)]
pdf.table_header(cols)
rows = [
    ("Stepper de statut", "En attente > Assigne > Accepte > Recupere > Livre - code couleur par etape"),
    ("Carte de suivi", "Position GPS du livreur mise a jour en continu"),
    ("Fiche livreur", "Photo, nom, telephone, badge verifie (identite confirmee)"),
    ("Verification identite", "Comparaison photo d'inscription vs selfie d'acceptation cote a cote"),
    ("Actions disponibles", "Appeler le livreur, chatter, annuler (si en attente)"),
    ("Photo de livraison", "Preuve photographique visible par le client"),
    ("Note livreur", "1 a 5 etoiles obligatoires avant paiement wallet"),
    ("Note prestataire", "1 a 5 etoiles + commentaire optionnel (restaurant / vendeur / boulangerie)"),
]
for i, (c1, c2) in enumerate(rows):
    pdf.table_row([(c1,55),(c2,135)], even=i%2==0)
pdf.ln(3)

pdf.sub_header("3. Boutique (Marketplace Produits)")
pdf.bullet_list([
    "Catalogue avec recherche, filtre categorie, badge VIP vendeur (couronne doree)",
    "Fiche produit : description, prix unitaire, stock, selecteur quantite +/-",
    "Remboursement automatique 48h : si non livre dans les 48h, credit wallet automatique",
    "Tri : vendeurs VIP en premier, vendeurs suspendus masques",
    "Suivi des commandes boutique : en attente > preparation > expedie > livre",
])
pdf.ln(2)

pdf.sub_header("4. Restaurant")
pdf.bullet_list([
    "Liste des restaurants : recherche, badge Ouvert/Ferme, badge VIP, note moyenne etoiles",
    "Menu par categories avec prix, selecteur quantite, total dynamique",
    "Avis clients visibles sur la carte restaurant (note + nombre d'avis)",
])
pdf.ln(2)

pdf.sub_header("5. Boulangerie")
pdf.bullet_list([
    "Menu standard : Pains, Viennoiseries, Gateaux, Boissons, Formules avec emojis",
    "Horaire de livraison : Maintenant ou creneaux 30 min (06h30 a 12h00)",
    "Gateau personnalise : description + budget + date souhaitee (calendrier)",
    "Barre recapitulative flottante : compteur articles + total + bouton confirmation",
])
pdf.ln(2)

pdf.sub_header("6. Pharmacie de Garde")
pdf.bullet_list([
    "Deux onglets : toutes les pharmacies / pharmacies de garde uniquement",
    "Carte avec statut de garde, horaires, telephone",
    "Boutons : Appeler, Carte Google Maps, Commander la livraison",
    "Livraison : frais fixes 500 FCFA, wallet ou especes, GPS automatique",
    "Verification identite livreur avant remise des medicaments (banniere d'alerte securite)",
])

# ── PAGE 4 : AUTRES SERVICES ───────────────────────────────
pdf.add_page()
pdf.section_header("SERVICES", "Autres Services Client")

pdf.sub_header("7. Livraison de Colis")
cols = [("Type de colis", 55), ("Tarif de base", 40), ("Detail", 95)]
pdf.table_header(cols)
rows = [
    ("Standard", "500 FCFA", "Envoi de paquets courants"),
    ("Cadeau emballe", "700 FCFA", "Colis avec emballage cadeau"),
    ("Document / Enveloppe", "300 FCFA", "Courriers et documents importants"),
    ("Grand colis", "1000 FCFA", "Gros volumes"),
    ("Option Fragile", "+200 FCFA", "Surcharge protection fragile"),
]
for i, r in enumerate(rows):
    pdf.table_row([(x,w) for x,w in zip(r,[55,40,95])], even=i%2==0)
pdf.ln(3)

pdf.sub_header("8. Hub de Services (Artisans & Professionnels)")
cols = [("Categorie", 45), ("Sous-categories disponibles", 145)]
pdf.table_header(cols)
rows = [
    ("Immobilier", "Location, Vente maison, Local commercial, Terrain"),
    ("Artisans (12)", "Macon, Plombier, Electricien, Forgeron, Menuisier, Carreleur, Peintre, Vitrier, Repar. TV, Camera, Decoration, Repar. telephone"),
    ("Mecaniciens", "Auto, Moto, Electricien auto, Carrossier"),
    ("Materiaux", "Packs d'eau, Ciment / briques"),
    ("Telephonie", "Telephones, Accessoires"),
    ("Boissons", "Vins, Bieres, Boissons sans alcool"),
]
for i, (c1, c2) in enumerate(rows):
    pdf.table_row([(c1,45),(c2,145)], even=i%2==0)
pdf.ln(3)

pdf.sub_header("9. Locations & Residences")
pdf.bullet_list([
    "Locations immobilieres : recherche texte, photos, nb pieces, prix mensuel, bouton appel proprietaire",
    "Residences meublees : filtre par type (Studio / 1 piece / 2 pieces / Villa), prix nuit et mois",
    "Commodites avec icones : WiFi, Clim, TV, Cuisine, Parking, Eau, Electricite, Securite, Piscine",
])
pdf.ln(2)

pdf.sub_header("10. Autres Services")
pdf.bullet_list([
    "Courses libres : formulaire simple (description + budget) pour toute demande non standard",
    "Blanchisserie : types de service (laver+repasser, pressing), quantite en kg, 1000 FCFA/kg",
    "Eau & Boissons : catalogue (eaux, sodas, jus, lait, energisants), panier flottant, 500 FCFA livraison",
    "E-Kbine : recharge credit, forfaits internet, transfert Mobile Money, inscription agent",
    "Marketplace occasion : produits d'occasion, recherche, favoris, profil vendeur, chat",
])
pdf.ln(2)

pdf.sub_header("Communication & Alertes")
pdf.bullet_list([
    "Chat temps reel client <-> livreur (par commande), messages vocaux, chat marketplace",
    "Notifications push FCM : acceptation course, livraison, nouvelles commandes prestataires",
    "SOS : bouton urgence avec capture GPS, envoi alerte Firestore, cooldown 30 secondes",
])

# ── PAGE 5 : DASHBOARDS PROFESSIONNELS ──────────────────────
pdf.add_page()
pdf.section_header("DASHBOARDS", "Tableaux de Bord Professionnels")

pdf.sub_header("Restaurant - Dashboard Proprietaire (4 onglets)")
cols = [("Onglet", 40), ("Fonctionnalites", 150)]
pdf.table_header(cols)
rows = [
    ("Menu", "Ajout / modification / suppression d'articles (nom, prix, categorie, disponibilite, stock). Badge orange si stock <= 5."),
    ("Commandes", "Liste temps reel des commandes, acceptation, mise a jour du statut de progression"),
    ("Portefeuille", "Solde en temps reel, historique complet des transactions"),
    ("Analytique", "Revenus 7 jours : total, nb commandes, panier moyen + graphique barres anime par jour"),
]
for i, (c1, c2) in enumerate(rows):
    pdf.table_row([(c1,40),(c2,150)], even=i%2==0)
pdf.info_box("Alerte nouvelle commande : vibration haptique immediate + son audio + dialog 'Nouvelle commande !' avec bouton 'Voir maintenant'")

pdf.sub_header("Vendeur Boutique - Dashboard (4 onglets)")
cols = [("Onglet", 40), ("Fonctionnalites", 150)]
pdf.table_header(cols)
rows = [
    ("Commandes", "Commandes en attente et en cours, acceptation, suivi des statuts"),
    ("Produits", "Catalogue avec stock. Badges : vert (>5), orange (1-5), rouge Epuise (0). Ajout/modif/suppression."),
    ("Portefeuille", "Solde, transactions, rechargement"),
    ("Analytique", "Revenus 7 jours : total, ventes, panier moyen + graphique barres anime"),
]
for i, (c1, c2) in enumerate(rows):
    pdf.table_row([(c1,40),(c2,150)], even=i%2==0)
pdf.ln(3)

pdf.sub_header("Livreur - Dashboard")
cols = [("Fonctionnalite", 55), ("Detail", 135)]
pdf.table_header(cols)
rows = [
    ("Statut en ligne", "Toggle visible / invisible pour les nouvelles courses"),
    ("Carte en direct", "Position GPS transmise en continu (DriverLocationService)"),
    ("Acceptation course", "Dialog acceptation/refus avec details commande et informations client"),
    ("Selfie d'acceptation", "Photo prise au moment de l'acceptation (verification identite)"),
    ("Photo de livraison", "Preuve photographique envoyee a Firebase Storage"),
    ("Message vocal", "Lecture du message vocal enregistre par le client"),
    ("Portefeuille", "Solde, commissions, recharges, historique de toutes les transactions"),
    ("Note & classement", "Note moyenne sur 5 etoiles, compteur de livraisons effectuees"),
]
for i, (c1, c2) in enumerate(rows):
    pdf.table_row([(c1,55),(c2,135)], even=i%2==0)
pdf.ln(3)

pdf.sub_header("Administrateur - Fonctions Disponibles")
admin_features = [
    "Carte temps reel de tous les livreurs actifs",
    "Gestion des demandes d'inscription livreurs (validation / refus)",
    "Liste complete des livreurs avec profils et statuts",
    "Classement des livreurs par performance",
    "Gestion flotte de vehicules",
    "Gestion des restaurants (demandes + liste + statut VIP)",
    "Gestion des pharmacies et statuts de garde",
    "Gestion des boutiques et vendeurs (abonnements, suspension)",
    "Gestion des boulangeries",
    "Suivi de toutes les commandes en cours",
    "Rechargement des portefeuilles clients et livreurs",
    "Gestion des paiements comptant (COD)",
    "Gestion des locations et residences",
    "Gestion des services et artisans",
    "Consultation et traitement des alertes SOS",
    "Tableau des gains de la plateforme",
    "Purge et maintenance des donnees",
    "Dashboard Admin Web (accessible depuis navigateur)",
]
pdf.bullet_list(admin_features)

# ── PAGE 6 : PAIEMENTS & AVIS ──────────────────────────────
pdf.add_page()
pdf.section_header("PAIEMENTS", "Systeme de Portefeuille, Paiements & Avis")

pdf.sub_header("Portefeuille Numerique (Wallet)")
cols = [("Operation", 45), ("Detail", 145)]
pdf.table_header(cols)
rows = [
    ("Solde", "Affiche en temps reel (FCFA), mis a jour via Firestore stream"),
    ("Rechargement", "Par l'administrateur (interface dedicee) ou agent E-Kbine"),
    ("Paiement commande", "Deduction automatique au moment de la validation de commande"),
    ("Remboursement auto", "Credit wallet si livraison boutique non effectuee en 48 heures"),
    ("Retrait", "Demande de retrait via WalletActionSheet"),
    ("Historique", "50 dernieres transactions : type, montant, description, date et heure"),
]
for i, (c1, c2) in enumerate(rows):
    pdf.table_row([(c1,45),(c2,145)], even=i%2==0)
pdf.ln(2)
pdf.info_box("Securite COD : Si un client genere 3 fausses commandes en paiement comptant, le paiement especes est automatiquement desactive pour son compte (flag cashOnDeliveryEnabled = false).", color="warn")

pdf.sub_header("Systeme d'Avis & Notations")
cols = [("Qui est note", 40), ("Qui note", 30), ("Quand", 55), ("Stockage", 65)]
pdf.table_header(cols)
rows = [
    ("Livreur", "Client", "Apres livraison (obligatoire avant paiement wallet)", "Champ rating dans commande + calcul avgRating livreur"),
    ("Restaurant", "Client", "Apres livraison restaurant (si pas encore note)", "Transaction Firestore : avgRating + ratingCount sur le restaurant"),
    ("Vendeur boutique", "Client", "Apres livraison boutique", "Idem sur la collection sellers"),
    ("Boulangerie", "Client", "Apres livraison boulangerie", "Idem sur la collection boulangeries"),
]
for i, r in enumerate(rows):
    pdf.table_row([(x,w) for x,w in zip(r,[40,30,55,65])], even=i%2==0)
pdf.info_box("Les notes s'affichent en etoiles sur les cartes restaurants et vendeurs avec la note moyenne et le nombre d'avis. Chaque avis est aussi stocke dans la collection 'reviews'.")

pdf.sub_header("Gestion des Stocks")
cols = [("Module", 40), ("Comportement", 150)]
pdf.table_header(cols)
rows = [
    ("Restaurant (menu)", "Champ stock modifiable par le proprietaire. Badge orange si stock <= 5. Decremente a chaque commande."),
    ("Boutique (produits)", "Onglet Produits dedie. Badges : vert (>5), orange (1-5 / 'Stock: X'), rouge (0 / 'Epuise'). Produit epuise = automatiquement indisponible."),
]
for i, (c1, c2) in enumerate(rows):
    pdf.table_row([(c1,40),(c2,150)], even=i%2==0)

pdf.sub_header("Abonnements Vendeurs")
pdf.bullet_list([
    "Statut d'abonnement : actif / suspendu / expire",
    "Vendeurs suspendus automatiquement masques de la liste boutique pour les clients",
    "Statut VIP (couronne doree) : vendeurs VIP affiches en priorite avec badge visible",
    "Gestion complete des abonnements depuis le dashboard Administrateur",
])

# ── PAGE 7 : ARCHITECTURE FIRESTORE ────────────────────────
pdf.add_page()
pdf.section_header("FIREBASE", "Architecture Firestore - Collections Principales")

cols = [("Collection", 50), ("Contenu", 140)]
pdf.table_header(cols)
collections = [
    ("orders", "Toutes les commandes (shopping, restaurant, pharmacie, colis, boulangerie, blanchisserie...)"),
    ("clients", "Profils clients, wallet, transactions, preferences, flag COD"),
    ("livreurs", "Profils livreurs, position GPS temps reel, wallet, statut en ligne, note moyenne"),
    ("restaurants", "Infos restaurant, menu items, avgRating, ratingCount, statut VIP"),
    ("boulangeries", "Profil boulangerie, menu, statut ouvert/ferme, avgRating"),
    ("pharmacies", "Pharmacies, statut de garde (isOnDuty), coordonnees, horaires"),
    ("sellers", "Vendeurs boutique, statut abonnement, avgRating, statut VIP"),
    ("boutique_products", "Produits avec stock, prix unitaire, categorie, images, sellerId"),
    ("boutique_orders", "Commandes boutique avec suivi remboursement automatique 48h"),
    ("reviews", "Avis clients : note, commentaire, type prestataire, orderId"),
    ("locations", "Annonces immobilieres : titre, adresse, prix mensuel, photos, nb pieces"),
    ("residences", "Residences meublees : type, prix nuit/mois, commodites, photos"),
    ("service_providers", "Artisans et prestataires : categorie, photos portfolio, contact"),
    ("sos_alerts", "Alertes SOS : coordonnees GPS, clientId, statut, timestamp"),
    ("fleet_owners", "Proprietaires de flotte et association avec leurs livreurs"),
    ("mp_products", "Produits marketplace occasion : etat, prix, photos, vendeurId"),
    ("ek_orders", "Commandes E-Kbine : credit, internet, mobile money, operateur"),
    ("artisans", "Profils artisans inscrits avec specialites"),
    ("conversations", "Messages temps reel client <-> livreur par commande"),
    ("notifications", "Historique des notifications push FCM envoyees"),
]
for i, (c1, c2) in enumerate(collections):
    pdf.table_row([(c1,50),(c2,140)], even=i%2==0)
pdf.ln(3)

pdf.sub_header("Modele OrderModel - Champs Cles")
cols = [("Champ", 45), ("Type", 30), ("Description", 115)]
pdf.table_header(cols)
fields = [
    ("id", "String", "Identifiant unique UUID genere a la creation"),
    ("type", "String", "shopping / pharmacie / boutique / restaurant / boulangerie / colis / blanchisserie / eau_boissons"),
    ("status", "String", "pending > assigned > accepted > picked_up > delivered / cancelled"),
    ("paymentMethod", "String", "cash (especes) ou wallet (portefeuille)"),
    ("budget", "int", "Frais de livraison en FCFA"),
    ("shoppingBudget", "int", "Montant estimatif des articles achetes"),
    ("voiceMessage", "String?", "URL Firebase Storage du message vocal enregistre"),
    ("deliveryPhoto", "String?", "URL photo de preuve de livraison"),
    ("driverAcceptanceSelfie", "String?", "URL selfie pris par le livreur a l'acceptation"),
    ("rating", "int?", "Note donnee au livreur (1 a 5 etoiles)"),
    ("sellerRating", "int?", "Note donnee au prestataire (1 a 5 etoiles)"),
    ("isPaid", "bool", "Paiement wallet effectue apres livraison"),
    ("sellerId / sellerType", "String?", "Reference prestataire + type (restaurant, seller, boulangerie)"),
]
for i, r in enumerate(fields):
    pdf.table_row([(x,w) for x,w in zip(r,[45,30,115])], even=i%2==0)

# ── PAGE 8 : RÉCAPITULATIF COMPLET ─────────────────────────
pdf.add_page()
pdf.section_header("RECAPITULATIF", "Tableau Recapitulatif de Toutes les Fonctionnalites")

cols = [("Fonctionnalite", 105), ("Statut", 25), ("Module", 60)]
pdf.table_header(cols)

all_features = [
    ("Commande de courses / livraison standard", "ok", "Client"),
    ("Suivi GPS temps reel du livreur", "ok", "Client / Livreur"),
    ("Message vocal dans la commande", "ok", "Client / Livreur"),
    ("Messagerie chat temps reel", "ok", "Client / Livreur"),
    ("Commande restaurant avec menu complet", "ok", "Client / Restaurant"),
    ("Commande boulangerie + gateau personnalise", "ok", "Client / Boulangerie"),
    ("Pharmacie de garde + livraison medicaments", "ok", "Client / Pharmacie"),
    ("Marketplace boutique produits", "ok", "Client / Vendeur"),
    ("Livraison de colis (4 types + fragile)", "ok", "Client"),
    ("Blanchisserie", "ok", "Client"),
    ("Eau & Boissons", "ok", "Client"),
    ("Locations immobilieres", "ok", "Client"),
    ("Residences meublees avec commodites", "ok", "Client"),
    ("Hub artisans & prestataires de services", "ok", "Client"),
    ("E-Kbine (credit / internet / mobile money)", "ok", "Client"),
    ("Marketplace occasion (petites annonces)", "ok", "Client"),
    ("Portefeuille numerique (wallet FCFA)", "ok", "Client / Livreur"),
    ("Paiement comptant avec anti-fraude COD", "ok", "Client"),
    ("Remboursement automatique 48h boutique", "ok", "Client / Vendeur"),
    ("Notation livreur (1-5 etoiles)", "ok", "Client"),
    ("Notation prestataire / restaurant / boulangerie", "new", "Client"),
    ("Verification identite livreur (comparaison photos)", "ok", "Client"),
    ("Preuve de livraison (photo)", "ok", "Livreur"),
    ("Alerte sonore + haptique nouvelles commandes", "new", "Vendeur / Restaurant"),
    ("Gestion des stocks (menu + boutique)", "new", "Vendeur / Restaurant"),
    ("Tableau de bord analytique 7 jours", "new", "Vendeur / Restaurant"),
    ("Abonnements vendeurs avec statut VIP", "ok", "Admin / Vendeur"),
    ("Notifications push Firebase (FCM)", "ok", "Tous"),
    ("Alerte SOS avec localisation GPS", "ok", "Client / Admin"),
    ("Dashboard administrateur complet (18 sections)", "ok", "Admin"),
    ("Gestion flotte de livreurs", "ok", "Fleet owner"),
    ("Site web public (9 pages)", "ok", "Web"),
    ("Dashboard admin web (navigateur)", "ok", "Web / Admin"),
    ("Multi-langue Francais / Anglais", "ok", "Tous"),
    ("Crash reporting (Firebase Crashlytics)", "ok", "Systeme"),
]

for i, (feat, status, module) in enumerate(all_features):
    y = pdf.get_y()
    if status == "ok":
        badge_bg, badge_fg = GREEN_BG, GREEN
        badge_txt = "Actif"
    else:
        badge_bg, badge_fg = BLUE_BG, BLUE
        badge_txt = "Nouveau"

    if i % 2 == 0:
        pdf.set_fill_color(248, 249, 255)
    else:
        pdf.set_fill_color(*WHITE)
    pdf.rect(pdf.l_margin, y, 190, 6.5, "F")
    pdf.set_draw_color(220, 220, 230)
    pdf.set_line_width(0.2)
    pdf.line(pdf.l_margin, y+6.5, pdf.l_margin+190, y+6.5)

    # Feature name
    pdf.set_xy(pdf.l_margin+1, y+1)
    pdf.set_font("Arial", "", 9)
    pdf.set_text_color(*DARK)
    pdf.cell(103, 5, feat)

    # Badge
    bw = 22
    pdf.set_fill_color(*badge_bg)
    pdf.set_draw_color(*badge_fg)
    pdf.set_line_width(0.3)
    pdf.rounded_rect(pdf.l_margin+107, y+1, bw, 4.5, 2, "FD")
    pdf.set_xy(pdf.l_margin+107, y+1)
    pdf.set_font("Arial", "B", 7.5)
    pdf.set_text_color(*badge_fg)
    pdf.cell(bw, 4.5, badge_txt, align="C")

    # Module
    pdf.set_xy(pdf.l_margin+131, y+1)
    pdf.set_font("Arial", "", 8.5)
    pdf.set_text_color(*GRAY)
    pdf.cell(59, 4.5, module)
    pdf.ln(6.5)

pdf.ln(4)
pdf.info_box("Legende :  'Actif' = fonctionnalite existante et deployee  |  'Nouveau' = fonctionnalite ajoutee lors de la derniere session de developpement")

# ── PAGE 9 : SITE WEB ──────────────────────────────────────
pdf.add_page()
pdf.section_header("SITE WEB", "Site Web Vitrine (Flutter Web + Firebase Hosting)")

pdf.set_font("Arial", "", 10)
pdf.set_text_color(*DARK)
pdf.multi_cell(0, 5.5, "En complement de l'application mobile, AZ Express dispose d'un site web public heberge sur Firebase Hosting, developpe egalement en Flutter Web.")
pdf.ln(3)

cols = [("Page", 45), ("Contenu", 145)]
pdf.table_header(cols)
web_pages = [
    ("Accueil", "Hero section avec presentation, appel a l'action telechargement de l'application"),
    ("Services", "Description de tous les services disponibles (livraison, restaurants, pharmacie...)"),
    ("Comment ca marche", "Explication du processus en etapes illustrees"),
    ("Marchands", "Information pour les commercants souhaitant rejoindre la plateforme"),
    ("Livreurs", "Recrutement de livreurs : conditions, avantages, inscription"),
    ("A propos", "Histoire et mission d'AZ Express"),
    ("Contact", "Formulaire de contact et coordonnees"),
    ("CGU", "Conditions Generales d'Utilisation"),
    ("Confidentialite", "Politique de traitement des donnees personnelles"),
]
for i, (c1, c2) in enumerate(web_pages):
    pdf.table_row([(c1,45),(c2,145)], even=i%2==0)
pdf.info_box("Le site web inclut aussi un Dashboard Admin Web : interface d'administration accessible depuis un navigateur, protege par authentification.")
pdf.ln(4)

pdf.section_header("CONCLUSION", "Bilan General")
pdf.set_font("Arial", "", 10.5)
pdf.set_text_color(*DARK)
pdf.multi_cell(0, 6,
    "AZ Express est une application complete et mature couvrant l'ensemble du cycle de livraison "
    "et de services de proximite. Elle integre des fonctionnalites avancees comme le suivi GPS temps reel, "
    "la verification d'identite des livreurs, un systeme de paiement par portefeuille numerique avec "
    "remboursement automatique, des alertes sonores et haptiques pour les prestataires, un tableau de bord "
    "analytique, et un systeme d'avis clients complet.\n\n"
    "L'architecture Firebase assure la scalabilite et la fiabilite en temps reel, tandis que la "
    "structure multi-roles permet a chaque acteur (client, livreur, vendeur, admin) de disposer "
    "d'une interface taillee pour ses besoins specifiques.")
pdf.ln(4)

# Final stats
pdf.set_font("Arial", "B", 11)
pdf.set_text_color(*BLUE)
pdf.cell(0, 7, "Chiffres cles de l'application :")
pdf.ln(8)

final_stats = [
    ("35", "Fonctionnalites\ntotales"),
    ("8", "Roles\nutilisateurs"),
    ("30+", "Ecrans\nFlutter"),
    ("20+", "Collections\nFirestore"),
]
box_w = 40
start_x = (210 - 4*box_w - 3*6) / 2
y = pdf.get_y()
for i, (num, lbl) in enumerate(final_stats):
    x = start_x + i*(box_w+6)
    pdf.set_fill_color(*BLUE)
    pdf.rounded_rect(x, y, box_w, 24, 4, "F")
    pdf.set_xy(x, y+3)
    pdf.set_font("Arial", "B", 20)
    pdf.set_text_color(*WHITE)
    pdf.cell(box_w, 10, num, align="C", new_x="LMARGIN", new_y="NEXT")
    pdf.set_xy(x, y+14)
    pdf.set_font("Arial", "", 7)
    pdf.set_text_color(200, 225, 255)
    pdf.cell(box_w, 4, lbl.split('\n')[0], align="C", new_x="LMARGIN", new_y="NEXT")
    pdf.set_xy(x, y+18)
    pdf.cell(box_w, 4, lbl.split('\n')[1], align="C")

pdf.output(OUTPUT)
print(f"PDF genere : {OUTPUT}")
