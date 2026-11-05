#!/bin/bash

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Erreur : ce script doit être lancé en root (sudo ./creer_comptes.sh)." >&2
    exit 1
fi

cd "$(dirname "$(readlink -f "$0")")"

CSV="comptes.csv"
FICHIER_MDP="/root/mots_de_passe_initiaux.txt"

if [ ! -f "$CSV" ]; then
    echo "Erreur : $CSV introuvable dans $(pwd)." >&2
    exit 1
fi
if [ "$(head -n 1 "$CSV" | tr -d '\r')" != "login;nom;groupe_principal;groupes_secondaires" ]; then
    echo "Erreur : en-tête de $CSV invalide." >&2
    exit 1
fi

mdp_aleatoire() {
    head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-16
}

creer_groupe() {
    getent group "$1" >/dev/null || groupadd "$1"
}

creer_compte() {
    local login="$1" nom="$2" principal="$3" secondaires="$4" g mdp

    creer_groupe "$principal"
    if [ -n "$secondaires" ]; then
        IFS=',' read -ra liste <<< "$secondaires"
        for g in "${liste[@]}"; do
            creer_groupe "$g"
        done
    fi

    if id "$login" >/dev/null 2>&1; then
        usermod -c "$nom" -g "$principal" -G "$secondaires" "$login"
        echo "  $login : existe déjà, groupes mis à jour"
    else
        useradd -m -s /bin/bash -c "$nom" -g "$principal" \
            ${secondaires:+-G "$secondaires"} "$login"
        mdp="$(mdp_aleatoire)"
        echo "$login:$mdp" | chpasswd
        echo "$login:$mdp" >> "$FICHIER_MDP"
        echo "  $login : créé"
    fi
}

droits_repertoire() {
    local rep="$1" acl="$2"
    install -d -m 0770 -o root -g root "$rep"
    setfacl --set "u::rwx,g::---,o::---,m::rwx,$acl" "$rep"
    setfacl -d --set "u::rwx,g::---,o::---,m::rwx,$acl" "$rep"
}

echo "=== Comptes et groupes (C1) ==="
[ -f "$FICHIER_MDP" ] || install -m 600 -o root -g root /dev/null "$FICHIER_MDP"

while IFS=';' read -r login nom principal secondaires || [ -n "$login" ]; do
    [ -z "$login" ] && continue
    creer_compte "$login" "$nom" "$principal" "$secondaires"
done < <(tail -n +2 "$CSV" | tr -d '\r' | sed 's/ *; */;/g; s/ *, */,/g')

echo "=== Répertoires de /srv (C2) ==="
install -d -m 0755 -o root -g root /srv

droits_repertoire /srv/dossiers_clients "g:comptables:rwx,g:direction:r-x"
droits_repertoire /srv/rh               "g:rh:rwx,g:direction:r-x"
droits_repertoire /srv/commun           "g:comptables:rwx,g:rh:rwx,g:direction:rwx,g:stagiaire:r-x"
droits_repertoire /srv/commun/depot     "g:comptables:rwx,g:rh:rwx,g:direction:rwx"
setfacl -m g:stagiaire:-wx /srv/commun/depot
chmod +t /srv/commun/depot

if [ -s "$FICHIER_MDP" ]; then
    echo "Mots de passe initiaux des nouveaux comptes : $FICHIER_MDP"
fi
