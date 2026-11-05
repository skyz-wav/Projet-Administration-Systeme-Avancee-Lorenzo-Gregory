#!/bin/bash

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Erreur : ce script doit être lancé en root (sudo ./installer_seance3.sh)." >&2
    exit 1
fi

cd "$(dirname "$(readlink -f "$0")")"

for f in comptes.csv creer_comptes.sh; do
    if [ ! -f "$f" ]; then
        echo "Erreur : $f introuvable dans $(pwd)." >&2
        exit 1
    fi
done
[ -d config ] || { echo "Erreur : dossier config/ introuvable." >&2; exit 1; }

etape()   { echo; echo "=== $* ==="; }
avertir() { echo "[!] $*" >&2; }

membres_ssh() {
    tr -d '\r' < comptes.csv | awk -F';' 'NR>1 {
        n = split($4, a, ",")
        for (i = 1; i <= n; i++) if (a[i] == "acces_ssh") print $1
    }'
}

admins_avec_mdp() {
    local login
    for login in $(tr -d '\r' < comptes.csv | awk -F';' 'NR>1 && $3=="admins" {print $1}'); do
        if [ "$(passwd -S "$login" | awk '{print $2}')" = "P" ]; then
            echo "$login"
        fi
    done
}

etape "1. Paquets"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y sudo acl openssh-server

etape "2. Comptes, groupes, clés SSH et /srv (C1, C2)"
./creer_comptes.sh

etape "3. sudo (C3)"
if ! compgen -G "config/sudoers.d/*" >/dev/null; then
    echo "Erreur : config/sudoers.d/ est vide." >&2
    exit 1
fi
for f in config/sudoers.d/*; do
    visudo -cf "$f" >/dev/null
    install -m 440 -o root -g root "$f" "/etc/sudoers.d/$(basename "$f")"
done

etape "4. Durcissement SSH (S1 à S5)"
manquantes=""
for login in $(membres_ssh); do
    home="$(getent passwd "$login" | cut -d: -f6)"
    [ -s "$home/.ssh/authorized_keys" ] || manquantes+=" $login"
done
if [ -n "$manquantes" ]; then
    echo "Erreur : pas de clé SSH installée pour :$manquantes" >&2
    echo "Ajoutez config/ssh/cles_publiques/<login>.pub puis relancez. SSH n'a PAS été modifié." >&2
    exit 1
fi
if ! compgen -G "config/ssh/sshd_config.d/*.conf" >/dev/null; then
    echo "Erreur : aucun .conf dans config/ssh/sshd_config.d/." >&2
    exit 1
fi
for f in config/ssh/sshd_config.d/*.conf; do
    install -m 644 -o root -g root "$f" "/etc/ssh/sshd_config.d/$(basename "$f")"
done
if ! sshd -t; then
    echo "Erreur : configuration SSH invalide, retrait de nos fichiers." >&2
    for f in config/ssh/sshd_config.d/*.conf; do
        rm -f "/etc/ssh/sshd_config.d/$(basename "$f")"
    done
    exit 1
fi
systemctl reload ssh

etape "5. Verrouillage de root (C4)"
if [ -n "$(admins_avec_mdp)" ]; then
    passwd -l root
else
    avertir "Aucun admin n'a de mot de passe : root NON verrouillé (risque de blocage)."
    avertir "Faites 'sudo passwd <login-admin>' puis relancez ce script."
fi

echo
echo "=== Séance 3 terminée. Lancez : sudo ./verifier.sh ==="