# Dehors

Les hauts faits de la vraie vie : villes, lieux mythiques, sport, food, culture. Sors, explore, collectionne.

- Site en ligne : https://dehors-sandy.vercel.app
- Le site est dans le dossier `dehors-site` : chaque envoi sur la branche `main` le met à jour automatiquement sur Vercel.

## Base de données (Supabase)

- Le schéma est dans `supabase/schema.sql` (comptes, classement public, progression privée, lieux partenaires), complété par `supabase/02_comptes_relies.sql` (une clé par appareil, comptes reliés à Google ou à une adresse e-mail).
- Pas d'e-mail ni de mot de passe : chaque joueur a un **code de récupération** (16 caractères) créé par son téléphone. La base n'en garde qu'une empreinte. Ce code permet de retrouver sa progression sur un autre appareil (onglet Profil → Ton compte).
- L'app n'écrit jamais directement dans les tables : elle passe par des fonctions qui vérifient le code du joueur. Seuls le classement et les lieux (sans leur code secret) sont lisibles publiquement.
- Les positions envoyées en ligne sont arrondies à environ 1 km.
- L'adresse du projet et sa clé publiable se règlent en haut du script de `dehors-site/index.html` (`SUPA_URL`, `SUPA_KEY`). Tant qu'elles sont vides, l'app garde tout sur le téléphone.
- Donner l'accès à l'espace établissements : `insert into public.admins (id) select id from public.players where lower(pseudo) = lower('TonPseudo');`
- Connexion Google / e-mail (Supabase Auth) : elle sert seulement à relier un compte ou à le retrouver sur un autre appareil, puis la session est refermée. Elle s'active avec `AUTH_EMAIL` et `AUTH_GOOGLE` en haut du script, une fois l'envoi d'e-mails et le client Google configurés dans Supabase.
- La demande « Sécurise ta progression » arrive après le 5e haut fait (une fois les notifications terminées), puis seulement à un nouveau rang ou 10 hauts faits plus tard, jamais deux fois en 3 jours, 4 fois au plus. Sécuriser son compte débloque le haut fait « Coffre-fort ».

## Dehors+ (offre payante)

- Ce que Dehors+ ajoute : le parcours premium de chaque saison (défis en plus et une couronne), un indice pour chaque secret, le cadre de rang et le badge « + » au classement, des couleurs, avatars et titres exclusifs, une vitrine de 6 hauts faits.
- Sans Dehors+, un défi premium réussi est « gagné » : il attend jusqu'à la fin de sa saison et se récupère en passant à Dehors+. Après la saison, il disparaît pour de bon.
- Formules : annuel 29,99 € (essai de 14 jours), mensuel 3,99 € (essai de 14 jours), Fondateur 59 € à vie (300 places, compteur réel), Pass Saison 6,99 € (parcours premium de la saison en cours).
- Propositions dans l'app : jamais plus d'une par jour, aucune pendant 3 jours après « Plus tard », jamais le jour de la demande de sécurisation, et seulement après un vrai événement (nouveau rang, récompense premium gagnée).
- Base : `supabase/03_dehors_plus.sql` (statut par compte, badge public, passes de saison, liste d'attente, compteurs anonymes du parcours). L'app ne peut pas se donner Dehors+ : seules les fonctions serveur (rôle `service_role`) l'appliquent.
- Paiement : Stripe Checkout et portail client Stripe, via deux fonctions Supabase (`supabase/functions`) :
  - `plus` : ouvre le paiement, le portail (gérer, résilier) et la rétractation sous 14 jours ;
  - `stripe-webhook` : reçoit les confirmations signées de Stripe (paiements, essais, renouvellements, résiliations).
- Secrets à définir dans Supabase (Edge Functions → Secrets) : `STRIPE_SECRET_KEY` et `STRIPE_WEBHOOK_SECRET`. Ne jamais les mettre dans le site.
- Notifications Stripe à envoyer vers `https://xyyffpfrzfeimddieoti.supabase.co/functions/v1/stripe-webhook` : `checkout.session.completed`, `checkout.session.async_payment_succeeded`, `customer.subscription.created`, `customer.subscription.updated`, `customer.subscription.deleted`, `invoice.paid`.
- Prix Stripe retrouvés par leur clé de recherche : `dehors_plus_annual`, `dehors_plus_monthly`, `dehors_founder`, `dehors_pass_season`.
- `PAY_LIVE` (en haut du script) ouvre le paiement à tous. Tant qu'il vaut `false`, seuls les administrateurs voient le vrai paiement (Stripe en mode test) et les autres joueurs s'inscrivent pour être prévenus à l'ouverture.
- Offrir Dehors+ (test, partenaire, concours) : Classement → espace administrateur → « Dehors+ ». Le même encadré montre la liste d'attente et le parcours des 7 derniers jours.
