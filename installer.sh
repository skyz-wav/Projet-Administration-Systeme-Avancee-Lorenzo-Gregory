#!/bin/bash

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Erreur : ce script doit être lancé en root (sudo ./installer.sh)." >&2
    exit 1
fi

cd "$(dirname "$(readlink -f "$0")")"

for f in comptes.csv creer_comptes.sh analyse_logs.sh \
         config/nftables.conf config/journald.conf; do
    if [ ! -f "$f" ]; then
        echo "Erreur : $f introuvable dans $(pwd)." >&2
        exit 1
    fi
done
[ -d config ] || { echo "Erreur : dossier config/ introuvable." >&2; exit 1; }

etape()   { echo; echo "=== $* ==="; }
avertir() { echo "[!] $*" >&2; }

lignes_csv() {
    tail -n +2 comptes.csv | tr -d '\r' | sed 's/ *; */;/g; s/ *, */,/g' | awk -F';' 'NF && $1 != ""'
}

membres_ssh() {
    lignes_csv | awk -F';' '{
        n = split($4, a, ",")
        for (i = 1; i <= n; i++) if (a[i] == "acces_ssh") print $1
    }'
}

admins_avec_mdp() {
    local login
    for login in $(lignes_csv | awk -F';' '$3 == "admins" {print $1}'); do
        if [ "$(passwd -S "$login" 2>/dev/null | awk '{print $2}')" = "P" ]; then
            echo "$login"
        fi
    done
}

etape "1. Paquets"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    sudo acl openssh-server nftables fail2ban python3-systemd

etape "2. Comptes, groupes, clés SSH et /srv (C1, C2)"
./creer_comptes.sh

etape "3. sudo et analyse_logs.sh (C3, J4)"
install -m 755 -o root -g root analyse_logs.sh /usr/local/sbin/analyse_logs.sh
if ! compgen -G "config/sudoers.d/*" >/dev/null; then
    echo "Erreur : config/sudoers.d/ est vide." >&2
    exit 1
fi
for f in config/sudoers.d/*; do
    if ! visudo -cf "$f" >/dev/null; then
        echo "Erreur : $f est invalide (visudo)." >&2
        exit 1
    fi
done
for f in config/sudoers.d/*; do
    install -m 440 -o root -g root "$f" "/etc/sudoers.d/$(basename "$f")"
done

etape "4. Durcissement SSH (S1 à S5)"
manquantes=""
for login in $(membres_ssh); do
    home="$(getent passwd "$login" | cut -d: -f6)"
    [ -n "$home" ] && [ -s "$home/.ssh/authorized_keys" ] || manquantes+=" $login"
done
if [ -n "$manquantes" ]; then
    avertir "Pas de clé SSH installée pour :$manquantes"
    avertir "Ajoutez config/ssh/cles_publiques/<login>.pub puis relancez. SSH n'a PAS été modifié."
elif ! compgen -G "config/ssh/sshd_config.d/*.conf" >/dev/null; then
    echo "Erreur : aucun .conf dans config/ssh/sshd_config.d/." >&2
    exit 1
else
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
fi

etape "5. Verrouillage de root et répertoires personnels (C4)"
for login in $(lignes_csv | cut -d';' -f1); do
    home="$(getent passwd "$login" | cut -d: -f6)"
    if [ -n "$home" ] && [ -d "$home" ]; then
        chmod 700 "$home"
    fi
done
if [ -n "$(admins_avec_mdp)" ]; then
    passwd -l root
else
    avertir "Aucun admin n'a de mot de passe : root NON verrouillé (risque de blocage)."
    avertir "Faites 'sudo passwd <login-admin>' puis relancez ce script."
fi

etape "6. Journal persistant (J3)"
install -d -m 755 -o root -g root /etc/systemd/journald.conf.d
install -m 644 -o root -g root config/journald.conf /etc/systemd/journald.conf.d/persistant.conf
install -d -m 2755 -o root -g systemd-journal /var/log/journal
systemd-tmpfiles --create --prefix /var/log/journal
systemctl restart systemd-journald
journalctl --flush

etape "7. Pare-feu nftables (J2)"
if ! nft -c -f config/nftables.conf; then
    echo "Erreur : config/nftables.conf est invalide, pare-feu NON modifié." >&2
    exit 1
fi
install -m 644 -o root -g root config/nftables.conf /etc/nftables.conf
systemctl enable nftables
systemctl restart nftables

etape "8. fail2ban (J1)"
if ! compgen -G "config/fail2ban/jail.d/*.conf" >/dev/null; then
    echo "Erreur : aucun .conf dans config/fail2ban/jail.d/." >&2
    exit 1
fi
for f in config/fail2ban/jail.d/*.conf; do
    install -m 644 -o root -g root "$f" "/etc/fail2ban/jail.d/$(basename "$f")"
done
if ! fail2ban-client -t >/dev/null; then
    echo "Erreur : configuration fail2ban invalide." >&2
    exit 1
fi
systemctl enable fail2ban
systemctl restart fail2ban

echo
echo "=== Séance 4 terminée. Lancez : sudo ./verifier.sh ==="
