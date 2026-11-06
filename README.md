# Durcir un serveur Linux et le prouver

Projet XTI302-CYB — Administration Systèmes avancées et Scripting.
Binôme : **Lorenzo Rivallin** et **Grégory Rendu**.

## Contexte choisi : B — Cabinet comptable Chiffres & Co

| Répertoire | comptables | rh | direction | stagiaire |
|---|---|---|---|---|
| `/srv/dossiers_clients` | lecture/écriture | - | lecture | - |
| `/srv/rh` | - | lecture/écriture | lecture | - |
| `/srv/commun` | lecture/écriture | lecture/écriture | lecture/écriture | lecture |
| `/srv/commun/depot` | lecture/écriture | lecture/écriture | lecture/écriture | dépôt seul |

Les stagiaires peuvent déposer des fichiers dans `depot` mais ne peuvent ni lister le répertoire ni lire les fichiers des autres.

Comptes (fichier `comptes.csv`) :

| Groupe | Comptes |
|---|---|
| admins (sudo) | `lrivallin`, `grendu` |
| support | `support` (sudo uniquement pour `analyse_logs.sh`) |
| comptables | `cdubois`, `mlefevre` |
| rh | `sleroy`, `proussel` |
| direction | `jlmartin`, `emoreau` |
| stagiaire | `tpetit`, `lgarcia` |

Seuls `lrivallin`, `grendu` et `support` (groupe `acces_ssh`) peuvent se connecter en SSH, par clé uniquement.

## Prérequis

- Une VM **Debian 13** en installation minimale, sans interface graphique, avec le serveur SSH. Une installation plus complète fonctionne aussi : `installer.sh` désactive les services réseau inutiles qu'elle ajoute (voir plus bas).
- Un **second disque virtuel vide** (1 à 2 Go) pour les sauvegardes. Il est attendu en `/dev/sdb` ; sinon, voir plus bas.
- Un accès root (mot de passe root ou compte avec sudo) et un accès Internet pour `apt`.
- `git` pour récupérer le dépôt : `apt-get install -y git`.

## Installation

```bash
git clone https://github.com/skyz-wav/Projet-Administration-Systeme-Avancee-Lorenzo-Gregory.git projet
cd projet
sudo ./installer.sh
```

Si le second disque n'est pas `/dev/sdb` (vérifier avec `lsblk`) :

```bash
sudo DISQUE_SAUVEGARDE=/dev/vdb ./installer.sh
```

`installer.sh` reconstruit toute la configuration : paquets, comptes et ACL, sudo, SSH, journal persistant, pare-feu, fail2ban, mises à jour automatiques, disque et planification des sauvegardes. Il peut être relancé sans danger : il ne recrée pas les comptes existants et ne reformate jamais un disque qui contient déjà des données.

Sur une installation qui n'est pas strictement minimale, il fait aussi le ménage :

- il désactive `avahi-daemon` et `cups-browsed` s'ils sont présents, pour que seul SSH soit joignable depuis le réseau (D2) ;
- il retire le bit SUID des fichiers situés hors de `/usr`, qui ne viennent pas des paquets Debian (D3). Sur VirtualBox, cela concerne `VBoxDRMClient` des Additions invité : le redimensionnement automatique de la fenêtre de la VM peut ne plus fonctionner, ce qui n'a pas d'importance pour un serveur administré en SSH.

### Noter les identifiants affichés à la fin

L'installation **verrouille root** et retire sudo à tous les comptes sauf ceux du groupe `admins`. À la fin, `installer.sh` affiche les mots de passe générés pour `lrivallin` et `grendu` : **notez-les avant de fermer la session**, ce sont les seuls comptes qui pourront ensuite utiliser `sudo`.

Les mots de passe initiaux de tous les comptes créés sont aussi dans `/root/mots_de_passe_initiaux.txt` (lisible par root uniquement). Aucun mot de passe n'est stocké dans le dépôt.

### Connexion SSH

Après l'installation, SSH n'accepte plus les mots de passe : il faut une clé dont la partie publique est dans `config/ssh/cles_publiques/<login>.pub`.

Pour tester avec votre propre clé, ajoutez-la au compte `support` ou à un compte admin avant de lancer `installer.sh` :

```bash
cp ~/.ssh/id_ed25519.pub config/ssh/cles_publiques/grendu.pub
```

Tant qu'un compte de `acces_ssh` n'a pas de clé, `installer.sh` **n'applique pas** le durcissement SSH, pour éviter de bloquer l'accès à la VM.

## Vérification

```bash
sudo sauvegarde.sh
sudo ./verifier.sh
```

La seconde sauvegarde est nécessaire au test « incrémental » de B1, qui compare deux versions (`installer.sh` en fait déjà une).

`verifier.sh` teste chaque exigence et affiche une ligne par test :

```
[OK] C3 le compte support ne peut lancer que analyse_logs.sh
[OK] S2 connexion root refusée
...
--- 45 / 45 tests réussis
```

Il renvoie `0` si tout est conforme, `1` sinon. Il ne modifie pas le système (ses fichiers de test sont supprimés à la fin).

## Contenu du dépôt

| Fichier | Rôle |
|---|---|
| `installer.sh` | reconstruit toute la configuration sur une VM vierge |
| `creer_comptes.sh` | comptes, groupes, clés SSH, répertoires `/srv` et ACL à partir de `comptes.csv` |
| `comptes.csv` | liste des comptes (`login;nom;groupe_principal;groupes_secondaires`) |
| `analyse_logs.sh` | rapport des connexions SSH, code de sortie `1` au-delà du seuil |
| `sauvegarde.sh` | sauvegarde incrémentale datée de `/srv` et `/etc` vers `/sauvegardes` |
| `verifier.sh` | vérifie automatiquement toutes les exigences |
| `config/` | configurations copiées par `installer.sh` (SSH, sudoers, nftables, fail2ban, journald, apt, systemd) et clés publiques |
| `DOSSIER.md` | conformité, choix techniques, défense, procédure de restauration |

## Utilisation courante

```bash
sudo /usr/local/sbin/analyse_logs.sh
sudo /usr/local/sbin/analyse_logs.sh 10
```

Rapport SSH avec le seuil par défaut (5 échecs depuis une même IP) ou un seuil choisi. Le compte `support` peut lancer cette commande, et rien d'autre en sudo.

```bash
sudo sauvegarde.sh
ls /sauvegardes
journalctl -t sauvegarde
```

Sauvegarde manuelle, liste des versions, historique des exécutions. La sauvegarde automatique a lieu tous les jours à 2 h (`systemctl list-timers sauvegarde.timer`).

```bash
sudo fail2ban-client status sshd
sudo fail2ban-client set sshd unbanip <adresse-ip>
```

Adresses bannies par fail2ban, et débannissement.

La procédure de restauration d'une sauvegarde est décrite dans `DOSSIER.md`.
