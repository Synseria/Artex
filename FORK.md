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
  - `nonroot-vX.Y.Z` : version officielle de l'amont + modifs du fork (voir section 4) ;
  - `nonroot-stable` : dernière version officielle construite.
- Image **multi-arch** (`linux/amd64` + `linux/arm64`) : le même tag fonctionne sur un PC x86
  et sur un Mac mini Apple Silicon. Chaque architecture est construite nativement (runner
  `ubuntu-24.04-arm`, gratuit pour un repo public) puis testée (`uname -m`, UID ≠ 0, binaire OK).
- Lancement manuel possible (Actions → fork-image → Run workflow).
- Le paquet GHCR est privé par défaut : il faut le rendre public, ou utiliser un `imagePullSecret`.

### Compromis de sécurité du mode non-root

L'image amont démarre en root, puis abaisse les privilèges des processus agents
(Bash/outils lancés par le LLM) vers l'UID 10001. Ainsi, un agent ne peut pas lire les secrets du serveur.

Un processus non-root ne peut pas changer d'UID. Dans cette image, les agents tournent donc
avec la même identité que le serveur : ils peuvent lire `/app/keys` et les variables
d'environnement (mot de passe Postgres, clés LLM). ARTEX signale ce mode « degraded » au démarrage et dans l'UI.
La compensation passe par le cluster : NetworkPolicy, namespace dédié, secrets limités au strict nécessaire.

Sans `NET_RAW`, nmap bascule sur le scan TCP connect (`-sT`). Les scans SYN et arp-scan ne sont pas disponibles.

### k3s sur Mac mini

k3s ne tourne pas nativement sous macOS : il tourne dans une VM Linux arm64
(OrbStack, Lima/Colima, UTM, Multipass…) ou sous Asahi Linux. Le nœud est donc
`linux/arm64`, et l'image arm64 est choisie automatiquement.
Prévoir ~4 Go de RAM pour la VM et une dizaine de Go de disque (image volumineuse :
Chromium, templates nuclei, bbot). PostgreSQL (`postgres:16-alpine`) existe aussi en arm64.

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

## 3. Synchronisation semi-automatique avec l'amont

`.github/workflows/upstream-sync.yml` tourne chaque nuit, ou à la demande via Actions → upstream-sync → Run workflow :

1. Si `BaaRai/ARTEX@main` a avancé, il fusionne l'amont dans la branche `sync/upstream`.
   C'est un merge classique : vos commits (traduction, image non-root) sont conservés.
2. Il ouvre une PR `sync/upstream → main`, ou la met à jour si elle existe déjà.
   La PR liste les nouveaux commits amont et les clés françaises à traduire.
3. Vous relisez et vous mergez. `fork-image.yml` reconstruit ensuite l'image.
4. En cas de conflit, aucune PR n'est ouverte : une issue liste les fichiers à résoudre à la main.

Prérequis : un secret `UPSTREAM_SYNC_TOKEN`, à créer dans Settings → Secrets and variables → Actions.

Il s'agit d'un PAT *fine-grained*, limité à ce dépôt, avec ces permissions :

- Contents : read/write ;
- Pull requests : read/write ;
- Issues : read/write ;
- Workflows : read/write.

Sans ce PAT, le workflow utilise `GITHUB_TOKEN`, avec trois limites :

1. Il ne peut pas pousser un merge qui modifie `.github/workflows/`.
2. La PR qu'il ouvre ne déclenche pas la CI.
3. Il faut activer « Allow GitHub Actions to create and approve pull requests » dans Settings → Actions → General.

## 4. Images basées sur les tags officiels

Le workflow `.github/workflows/upstream-tags.yml` tourne chaque nuit, après la synchro, ou à la demande :

1. Il repère le dernier tag officiel `vX.Y.Z` de `BaaRai/ARTEX`. S'il n'a pas encore été construit, il part du commit exact de ce tag.
2. Il y applique les modifs du fork : traduction FR, image non-root et workflows.
3. Il pousse le tag `fork-vX.Y.Z`. Ce push déclenche `fork-image.yml`, qui construit l'image `nonroot-vX.Y.Z` et met à jour `nonroot-stable`.
4. En cas de conflit, rien n'est construit et une issue liste les fichiers concernés.

Les tags du fork sont préfixés `fork-` : un tag `v*` déclencherait aussi le `release.yml` de l'amont.

**Tag personnalisé.** Lancez Actions → upstream-tags → Run workflow avec :

- `tag` : la version officielle, par exemple `v0.7.0` ;
- `suffix` : le suffixe voulu, par exemple `fr2`.

Le workflow crée alors `fork-v0.7.0-fr2`, ce qui donne l'image `nonroot-v0.7.0-fr2`. C'est utile pour reconstruire une version avec une traduction mise à jour.

Tout tag `fork-<x>` poussé à la main produit de la même façon l'image `nonroot-<x>`.

Sur le cluster, deux façons de choisir l'image :

- un tag figé, comme `nonroot-v0.7.0`, pour ne changer de version que quand vous le décidez ;
- `nonroot-stable`, pour suivre automatiquement la dernière version officielle.

Ce workflow utilise le même secret `UPSTREAM_SYNC_TOKEN` : un tag poussé avec `GITHUB_TOKEN` ne déclencherait pas le build.
