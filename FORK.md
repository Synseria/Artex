# Notes du fork (Synseria/Artex)

Ce fork ajoute deux choses à ARTEX, en touchant le moins possible aux fichiers amont
pour que les merges depuis `BaaRai/ARTEX` restent triviaux.

## 1. Traduction française

- Fichier ajouté : `web/src/i18n/locales/fr.json`. Il n'y a aucun conflit possible sur ce fichier.
- Petites modifications amont :
  - `web/src/i18n/index.ts` : 5 lignes d'enregistrement de la locale ;
  - `web/scripts/i18n.test.mjs` : `fr-FR` servait d'exemple de langue non supportée, il est remplacé par `de-DE`, et un test FR est ajouté ;
  - `web/src/i18n/README.md`.
- Langue choisie automatiquement selon le navigateur, ou via Préférences → Langue.

### Après un merge de l'amont

Une clé ajoutée par l'amont, mais absente de `fr.json`, s'affiche en anglais. L'app ne casse pas.
En revanche, `npm run test:i18n` (CI `ci.yml`) échoue et liste les clés manquantes :

```bash
cd web && npm run test:i18n
```

Il suffit de les ajouter à `fr.json`. Le build de l'image (`fork-image.yml`) ne dépend pas de ce test et n'est donc jamais bloqué.

## 2. Image container non-root

- Fichiers ajoutés, sans aucune modification de `Dockerfile` : `Dockerfile.nonroot`, `docker-bake.hcl` et `.github/workflows/fork-image.yml`.
- Publication sur `ghcr.io/synseria/artex` :
  - `nonroot` : dernier build de `main` ;
  - `nonroot-<sha>` : un tag par commit ;
  - `nonroot-vX.Y.Z` : à chaque tag `v*`.
- Lancement manuel possible (Actions → fork-image → Run workflow), avec option arm64.
- Le paquet GHCR est privé par défaut : il faut le rendre public, ou utiliser un `imagePullSecret`.

### Compromis de sécurité du mode non-root

L'image amont démarre en root, puis abaisse les privilèges des processus agents
(Bash/outils lancés par le LLM) vers l'UID 10001. Ainsi, un agent ne peut pas lire les secrets du serveur.

Un processus non-root ne peut pas changer d'UID. Dans cette image, les agents tournent donc
avec la même identité que le serveur : ils peuvent lire `/app/keys` et les variables
d'environnement (mot de passe Postgres, clés LLM). ARTEX signale ce mode « degraded » au démarrage et dans l'UI.
La compensation passe par le cluster : NetworkPolicy, namespace dédié, secrets limités au strict nécessaire.

Sans `NET_RAW`, nmap bascule sur le scan TCP connect (`-sT`). Les scans SYN et arp-scan ne sont pas disponibles.

### Exemple Kubernetes (extrait)

```yaml
securityContext:            # pod
  runAsNonRoot: true
  runAsUser: 10001
  runAsGroup: 0
  fsGroup: 0
  seccompProfile: { type: RuntimeDefault }
containers:
  - name: artex
    image: ghcr.io/synseria/artex:nonroot
    ports: [{ containerPort: 8787 }, { containerPort: 8788 }]
    securityContext:
      allowPrivilegeEscalation: false
      capabilities: { drop: ["ALL"] }
      readOnlyRootFilesystem: false   # voir note ci-dessous
    env:
      - { name: ARTEX_PG_HOST, value: postgres }
      - name: ARTEX_PG_PASSWORD
        valueFrom: { secretKeyRef: { name: artex-pg, key: password } }
      # ARTEX_PG_PORT / ARTEX_PG_USER / ARTEX_PG_DBNAME / ARTEX_JWT_KEY_DIR=/app/keys ...
    volumeMounts:
      - { name: data, mountPath: /app/data }
      - { name: keys, mountPath: /app/keys }
```

`readOnlyRootFilesystem: true` est possible avec un `emptyDir` sur `/tmp`, mais `/home/artex`
doit rester inscriptible. Ce dossier contient la config et les dépendances bbot préinstallées :
y monter un `emptyDir` les masquerait. Mieux vaut laisser `false`, car le système de fichiers
racine est déjà en lecture seule pour l'UID 10001, sauf `/home/artex`, `/app/{data,keys,skills}` et `/tmp`.
Le jeton de setup s'affiche dans les logs au premier démarrage : `kubectl logs ... | grep "Setup token"`.
