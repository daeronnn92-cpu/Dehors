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
