# Dossier — Durcissement d'un serveur Debian 13

Projet XTI302-CYB — Lorenzo Rivallin et Grégory Rendu
Contexte B : cabinet comptable Chiffres & Co

Les numéros « R » renvoient au guide ANSSI-BP-028 v2.0 *Recommandations de configuration d'un système GNU/Linux*. Les exigences SSH renvoient au guide ANSSI *Usage sécurisé d'(Open)SSH*.

## 1. Tableau de conformité

| ID | Ce que nous avons fait | Test dans `verifier.sh` | ANSSI |
|---|---|---|---|
| C1 | `creer_comptes.sh` lit `comptes.csv`, crée les groupes manquants, crée les comptes absents et met à jour les autres (`usermod`), installe les clés publiques. Relançable sans erreur ni doublon. | `test_C1` : chaque compte du CSV existe avec ses groupes ; clés installées pour `acces_ssh` | R30, R33 |
| C2 | `/srv/dossiers_clients`, `/srv/rh`, `/srv/commun`, `/srv/commun/depot` : droits `770 root:root`, aucun droit pour les autres, ACL nommées par groupe métier, mêmes ACL par défaut. `depot` : `-wx` pour stagiaire + sticky bit. | `test_C2` : 12 tests d'accès réels avec `sudo -u` (autorisés et refusés), ACL par défaut | R37, R54 |
| C3 | `config/sudoers.d/admins` : `%admins ALL=(ALL:ALL) ALL`. `config/sudoers.d/support` : uniquement `/usr/local/sbin/analyse_logs.sh`, sans argument ou avec un seuil numérique. `installer.sh` vide le groupe `sudo` de Debian. | `test_C3` : admins ont sudo ; support limité à `analyse_logs.sh` ; aucun autre compte (UID ≥ 1000) n'a sudo | R38, R39, R43 |
| C4 | `passwd -l root` (seulement si un admin a un mot de passe, pour ne pas se bloquer) ; `chmod 700` sur les répertoires personnels. | `test_C4` : root verrouillé ; aucun répertoire personnel accessible au groupe ou aux autres | R33, R50 |
| S1 | `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PubkeyAuthentication yes` | `test_S1` (valeurs effectives lues avec `sshd -T`) | guide SSH |
| S2 | `PermitRootLogin no` | `test_S2` | guide SSH |
| S3 | `AllowGroups acces_ssh` | `test_S3` | guide SSH |
| S4 | `MaxAuthTries 3`, `ClientAliveInterval 300`, `ClientAliveCountMax 3` | `test_S4` : ≤ 4 essais ; intervalle × nombre ≤ 900 s | guide SSH |
| S5 | `config/ssh/sshd_config.d/10-durcissement.conf` copié dans `/etc/ssh/sshd_config.d/`, validé par `sshd -t` avant `reload` ; retiré si invalide. Pas appliqué tant qu'un compte `acces_ssh` n'a pas de clé. | `test_S5` | guide SSH |
| J1 | fail2ban, prison `sshd`, backend `systemd`, action `nftables` | `test_J1` : service actif et prison chargée | R79 |
| J2 | `config/nftables.conf` : politique `drop` en entrée et en transit, sauf connexions établies, boucle locale et TCP 22 ; service `nftables` activé au démarrage | `test_J2` : politique, règles, service activé | R78, R80 |
| J3 | `Storage=persistent` dans `/etc/systemd/journald.conf.d/persistant.conf` | `test_J3` | R71 |
| J4 | `analyse_logs.sh` lit le journal de `ssh.service` ; rapport échecs par IP, comptes visés, connexions réussies ; code `1` si une IP dépasse le seuil, `2` en cas d'erreur | `test_J4` : appartient à root, non modifiable ; codes de sortie vérifiés sur un faux journal | R72 |
| D1 | `unattended-upgrades` + `config/apt/20auto-upgrades` ; timers `apt-daily` activés | `test_D1` | R61 |
| D2 | Seul SSH écoute sur le réseau. `installer.sh` désactive `avahi-daemon` et `cups-browsed` s'ils sont présents (voir §2.6). | `test_D2` : analyse de `ss -tuln` | R62, R80 |
| D3 | `installer.sh` retire le droit d'écriture « autres » des fichiers modifiables par tous et le bit SUID hors de `/usr` (voir §2.7). | `test_D3` : aucun fichier modifiable par tous ; SUID uniquement dans `/usr` et non modifiables | R54, R56, R57 |
| B1 | `sauvegarde.sh` : `rsync -aAXH --link-dest` de `/srv` et `/etc` vers `/sauvegardes/AAAA-MM-JJ_HHMMSS` sur le second disque ; garde 7 versions | `test_B1` : disque séparé ; ACL conservées ; fichier inchangé = même inode entre deux versions ; ≤ 7 versions | — |
| B2 | `sauvegarde.timer` (tous les jours à 2 h, `Persistent=true`) ; chaque exécution écrit dans le journal (`logger -t sauvegarde`) | `test_B2` : timer activé ; exécutions journalisées | R71 |
| B3 | `/sauvegardes` : `750 root:admins` | `test_B3` : propriétaire et droits ; un admin y accède ; un stagiaire non | R50 |
| B4 | Procédure en §4 | `test_B4` : restauration d'un fichier dans un répertoire temporaire et comparaison | — |

`verifier.sh` compte 45 tests. Le 5 novembre 2026, sur notre VM restaurée depuis son snapshot vierge, `installer.sh` puis une seconde exécution de `sauvegarde.sh` ont donné **45 / 45 tests réussis**. Cette VM avait été installée avec un environnement de bureau : les premiers essais ont fait apparaître des écarts sur D2 (avahi) et D3 (Additions invité VirtualBox), que `installer.sh` corrige maintenant (§2.6 et §2.7).

## 2. Choix techniques

### 2.1 Comptes et mots de passe

Aucun mot de passe n'est dans le dépôt. `creer_comptes.sh` génère un mot de passe aléatoire de 16 caractères pour chaque **nouveau** compte et le range dans `/root/mots_de_passe_initiaux.txt` (mode 600). `installer.sh` affiche à la fin ceux des admins, car root est verrouillé juste avant : sans cet affichage, la personne qui installe pourrait perdre tout accès administrateur.

Les admins utilisent sudo **avec** mot de passe : une clé SSH volée ne suffit pas pour devenir root. Le compte `support` utilise `NOPASSWD`, mais sur une seule commande dont les arguments sont contrôlés par une expression régulière (`^[0-9]+$`). Sans cette restriction, `support` pourrait passer à `analyse_logs.sh` un fichier en second argument et lire n'importe quel fichier en root.

`analyse_logs.sh` est copié dans `/usr/local/sbin`, propriétaire root, mode 755. Si `support` pouvait modifier le script qu'il lance en root, il lui suffirait d'y écrire une commande pour obtenir un shell root.

### 2.2 Répertoires `/srv` (contexte B)

Les droits classiques sont fermés (`770 root:root`) et tout passe par les ACL, ce qui permet de donner des droits différents à quatre groupes. Les ACL par défaut s'appliquent aux fichiers créés plus tard.

Pour `depot`, « dépôt seul » est obtenu par trois mécanismes :

- `group:stagiaire:-wx` : créer un fichier demande `w` et `x` sur le répertoire, lister demande `r` ;
- ACL par défaut sans entrée pour `stagiaire` et `group::---` : un fichier déposé par un stagiaire n'est pas lisible par les autres stagiaires, même s'ils partagent son groupe principal ;
- sticky bit : un stagiaire qui devinerait un nom de fichier ne peut pas le supprimer. Contrepartie : un comptable ne peut pas non plus supprimer le fichier d'un autre, mais peut le lire et le modifier.

### 2.3 SSH

- **3 essais par connexion** (`MaxAuthTries 3`) : avec une authentification par clé, un utilisateur légitime réussit au premier essai ; 3 laisse de la marge si plusieurs clés sont chargées dans l'agent.
- **Session inactive fermée après 15 minutes** : le serveur envoie un message toutes les 300 s ; après 3 messages sans réponse, il coupe la session. 300 × 3 = 900 s, la limite du sujet.

### 2.4 fail2ban et analyse des journaux

- **fail2ban** : bannissement après **3 échecs en 10 minutes**, pour **10 minutes**. Une durée courte limite l'impact si nous nous bannissons nous-mêmes depuis l'hôte (débannissement : `fail2ban-client set sshd unbanip <ip>`), tout en rendant une attaque par force brute inutilisable : au mieux 3 essais toutes les 10 minutes.
- **Seuil d'alerte d'`analyse_logs.sh` : 5 échecs** depuis une même IP. fail2ban bannit à 3 : dépasser 5 signifie que l'attaque continue malgré les bannissements successifs ou que fail2ban ne fonctionne plus. Le seuil se change en argument (`analyse_logs.sh 10`).
- **Journal** : persistant, limité à **200 Mo** et à **3 mois**. Trois mois permettent de remonter une attaque découverte tardivement ; 200 Mo évitent de remplir le disque système.

### 2.5 Pare-feu

`config/nftables.conf` ne contient qu'une table, `inet filtre`, qui couvre IPv4 et IPv6. Le fichier commence par `destroy table inet filtre` plutôt que `flush ruleset` : recharger le pare-feu ne doit pas effacer la table créée par fail2ban. `installer.sh` utilise `reload-or-restart` pour la même raison. La boucle locale est autorisée car certains services locaux (cupsd sur une installation complète) en dépendent. La sortie reste ouverte : filtrer la sortie empêcherait les mises à jour automatiques.

### 2.6 Écoutes réseau (D2)

Résultat de `ss -tulpn` sur notre VM, une Debian 13 installée avec un environnement de bureau :

| Écoute | Processus | Décision |
|---|---|---|
| TCP 22 | `sshd` | service attendu |
| UDP 68 (IPv4), UDP 546 (IPv6) | `dhcpcd` | client DHCP : la VM obtient son adresse ainsi. Il répond seulement au serveur DHCP ; on le garde. |
| TCP 631 sur 127.0.0.1 et ::1 | `cupsd` | service d'impression, joignable uniquement depuis la machine elle-même ; on le garde. |
| UDP 5353, ports UDP aléatoires | `avahi-daemon` | annonce de la machine sur le réseau local (mDNS) : inutile sur un serveur ; désactivé et masqué par `installer.sh`. |

Sur une installation minimale, seuls `sshd` et `dhcpcd` sont présents. Le pare-feu bloque de toute façon les autres ports ; désactiver les services réduit la surface d'attaque si le pare-feu est un jour désactivé par erreur.

### 2.7 Fichiers modifiables par tous et SUID (D3)

La recherche porte uniquement sur les vrais systèmes de fichiers (`findmnt -t ext4,ext3,xfs,btrfs,vfat`, `find -xdev`) : `/proc`, `/sys` et les systèmes en mémoire ne sont pas parcourus, et `-type f` exclut les liens symboliques (toujours en `777`). `/tmp`, `/var/tmp` et `/sauvegardes` sont exclus.

Fichiers SUID trouvés sur notre VM :

| Fichier | Rôle | Pourquoi SUID |
|---|---|---|
| `/usr/bin/passwd`, `chfn`, `chsh` | changer son mot de passe ou ses informations | écrit dans `/etc/shadow` et `/etc/passwd` |
| `/usr/bin/su`, `/usr/bin/sudo` | changer d'identité | doit pouvoir devenir root |
| `/usr/bin/newgrp`, `/usr/bin/gpasswd` | gestion des groupes | modifie `/etc/group`, `/etc/gshadow` |
| `/usr/bin/mount`, `umount` | montages autorisés aux utilisateurs dans `/etc/fstab` | appel système réservé à root |
| `/usr/lib/openssh/ssh-keysign` | authentification par hôte de SSH | lit la clé privée de l'hôte (inutilisé chez nous) |
| `/usr/lib/dbus-1.0/dbus-daemon-launch-helper` | démarre les services D-Bus système | exécutable seulement par le groupe `messagebus` |
| `/usr/bin/pkexec`, `/usr/lib/polkit-1/polkit-agent-helper-1` | polkit (environnement de bureau) | élévation de privilèges graphique |
| `/usr/bin/fusermount3`, `/usr/bin/ntfs-3g` | systèmes de fichiers en espace utilisateur | montage par un utilisateur |
| `/usr/lib/xorg/Xorg.wrap` | serveur graphique | accès au matériel graphique |
| `/usr/sbin/pppd` | connexions PPP | configuration réseau ; exécutable seulement par le groupe `dip` |
| `/opt/VBoxGuestAdditions-7.2.4/bin/VBoxDRMClient` | Additions invité VirtualBox | **SUID retiré** par `installer.sh` : hors de `/usr`, ne vient pas d'un paquet Debian |

Les six derniers fichiers de `/usr` viennent de l'environnement de bureau et n'existent pas sur une installation minimale. Nous ne les supprimons pas car ils appartiennent à des paquets Debian maintenus et mis à jour (R58 recommanderait plutôt de ne pas les installer).

### 2.8 Sauvegardes

- **Préparation du disque** : formaté en ext4 avec l'étiquette `sauvegardes`, **seulement s'il ne contient rien** (pas de partition, pas de système de fichiers). Relancer `installer.sh` ne détruit donc jamais les sauvegardes. Montage par étiquette dans `/etc/fstab`, avec `nofail` pour que la VM démarre même sans le disque.
- **Incrémental par liens durs** (`--link-dest`) : chaque version est un dossier complet, directement lisible, mais un fichier inchangé n'occupe pas de place en plus (il partage son inode avec la version précédente). `-A` et `-X` conservent ACL et attributs étendus.
- **Atomicité** : la copie se fait dans `<date>.en_cours`, renommé à la fin. Une sauvegarde interrompue ne peut pas servir de base à la suivante.
- **7 versions**, une par jour : une semaine d'historique, suffisante pour revenir avant une suppression ou un chiffrement découvert quelques jours plus tard.
- **2 h du matin** : hors des heures de travail du cabinet. `Persistent=true` rattrape la sauvegarde si la VM était éteinte.
- **Accès** : `750 root:admins`. Les admins ont déjà sudo ; les autres utilisateurs ne doivent pas lire une copie de `/etc/shadow` ni les dossiers RH.

### 2.9 `verifier.sh`

Il utilise `set -uo pipefail` **sans `-e`** : un test qui échoue ne doit pas arrêter le script. `pipefail` est désactivé à l'intérieur de chaque test : avec `commande | grep -q`, `grep` s'arrête dès qu'il trouve, ce qui peut faire échouer la commande de gauche et donner un faux négatif. Les tests de droits s'exécutent réellement sous l'identité de l'utilisateur (`sudo -u`), ses fichiers temporaires sont supprimés à la sortie.

## 3. Défense

| Attaque | Ce qui la rend plus difficile |
|---|---|
| **Force brute SSH** depuis Internet | Mots de passe refusés en SSH : il faudrait deviner une clé ed25519. `MaxAuthTries 3` et fail2ban (bannissement après 3 échecs) ralentissent fortement les tentatives ; `analyse_logs.sh` signale une IP insistante. |
| **Vol du mot de passe** d'un employé (hameçonnage) | Inutile à distance : SSH n'accepte que les clés et seulement pour `acces_ssh`. Les comptes métier n'ont pas d'accès SSH. |
| **Vol de la clé SSH** d'un admin | L'attaquant entre, mais sudo demande encore le mot de passe de l'admin ; root est verrouillé et sa connexion SSH interdite. |
| **Utilisateur curieux** (un comptable qui veut lire les dossiers RH) | `/srv/rh` sans droit pour les comptables, aucun droit « autres » sur `/srv`, répertoires personnels en `700`, sauvegardes réservées aux admins. |
| **Compte stagiaire compromis** | Pas de SSH, pas de sudo ; dans `depot`, il peut déposer mais ni lister, ni lire, ni supprimer les fichiers des autres ; lecture seule sur `/srv/commun`. |
| **Suppression accidentelle ou rançongiciel** sur `/srv` | Versions quotidiennes sur un autre disque : on revient à la veille ou à l'avant-veille (§4). |

Ce que notre configuration **ne couvre pas** :

- **Sauvegarde sur la même machine** : une panne, un vol ou un rançongiciel avec les droits root détruit le serveur et ses sauvegardes. Il faudrait une copie sur une autre machine, idéalement hors site (règle 3-2-1).
- **Accès physique ou à l'hyperviseur** : la console ne passe pas par SSH ; GRUB n'a pas de mot de passe (R5) et le disque n'est pas chiffré.
- **Failles logicielles** : une vulnérabilité de `sshd` ou du noyau non encore corrigée. Les mises à jour automatiques réduisent la fenêtre d'exposition, sans l'annuler.
- **Admin malveillant ou compromis avec son mot de passe** : il a tous les droits, et les journaux sont sur la machine qu'il contrôle (pas d'envoi vers un serveur de journaux distant, pas d'`auditd`).
- **Trafic sortant** non filtré : un programme malveillant installé pourrait contacter l'extérieur.
- **Pas d'authentification à deux facteurs** pour les admins.

## 4. Procédure de restauration

Toutes les commandes se lancent avec un compte admin.

**1. Trouver la version à restaurer.** Les versions sont nommées par date et heure :

```bash
ls /sauvegardes
sudo journalctl -t sauvegarde
```

**2. Vérifier que le fichier est dans cette version** (exemple : un fichier supprimé dans `/srv/rh`) :

```bash
sudo ls -l /sauvegardes/2026-11-05_021500/srv/rh/
```

**3. Restaurer un fichier**, avec ses droits et ses ACL :

```bash
sudo rsync -aAX /sauvegardes/2026-11-05_021500/srv/rh/contrat.pdf /srv/rh/
```

**4. Restaurer tout un répertoire** dans l'état de cette version (les fichiers créés depuis sont supprimés, d'où l'option `--delete` à n'utiliser qu'en connaissance de cause) :

```bash
sudo rsync -aAX --delete /sauvegardes/2026-11-05_021500/srv/rh/ /srv/rh/
```

**5. Contrôler** le contenu et les droits :

```bash
sudo getfacl /srv/rh/contrat.pdf
```

Pour **examiner** une ancienne version sans écraser l'existant, on restaure d'abord dans un répertoire temporaire, puis on compare (`diff -r`).

**Test** : `verifier.sh` (`test_B4`) restaure à chaque exécution `/etc/hostname` depuis la dernière version dans un répertoire temporaire et le compare au fichier en place. Ce test passait sur notre VM le 5 novembre 2026.
