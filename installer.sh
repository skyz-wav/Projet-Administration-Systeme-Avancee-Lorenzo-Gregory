#!/bin/bash

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Erreur : ce script doit être lancé en root (sudo ./installer.sh)." >&2
    exit 1
fi

cd "$(dirname "$(readlink -f "$0")")"

DISQUE="${DISQUE_SAUVEGARDE:-/dev/sdb}"

for f in comptes.csv creer_comptes.sh analyse_logs.sh sauvegarde.sh \
         config/nftables.conf config/journald.conf config/apt/20auto-upgrades \
         config/systemd/sauvegarde.service config/systemd/sauvegarde.timer; do
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
    sudo acl openssh-server nftables fail2ban python3-systemd unattended-upgrades rsync

etape "2. Comptes, groupes, clés SSH et /srv (C1, C2)"
FICHIER_MDP=/root/mots_de_passe_initiaux.txt
lignes_avant=0
[ -f "$FICHIER_MDP" ] && lignes_avant="$(wc -l < "$FICHIER_MDP")"
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
for membre in $(getent group sudo | cut -d: -f4 | tr ',' ' '); do
    gpasswd -d "$membre" sudo
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
systemctl reload-or-restart nftables

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

etape "9. Mises à jour de sécurité automatiques (D1)"
install -m 644 -o root -g root config/apt/20auto-upgrades /etc/apt/apt.conf.d/20auto-upgrades
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer

etape "10. Disque de sauvegarde (B1, B3)"
if ! blkid -L sauvegardes >/dev/null; then
    if [ ! -b "$DISQUE" ]; then
        echo "Erreur : disque $DISQUE introuvable (précisez DISQUE_SAUVEGARDE=/dev/...)." >&2
        exit 1
    fi
    if [ "$(lsblk -nro NAME "$DISQUE" | wc -l)" -gt 1 ] || blkid "$DISQUE" >/dev/null; then
        echo "Erreur : $DISQUE contient déjà des données, il n'est PAS formaté." >&2
        exit 1
    fi
    mkfs.ext4 -q -L sauvegardes "$DISQUE"
fi
install -d -m 750 -o root -g admins /sauvegardes
if ! grep -q '^LABEL=sauvegardes ' /etc/fstab; then
    echo "LABEL=sauvegardes /sauvegardes ext4 defaults,nofail 0 2" >> /etc/fstab
    systemctl daemon-reload
fi
mountpoint -q /sauvegardes || mount /sauvegardes
chown root:admins /sauvegardes
chmod 750 /sauvegardes

etape "11. Sauvegarde planifiée (B1, B2)"
install -m 755 -o root -g root sauvegarde.sh /usr/local/sbin/sauvegarde.sh
for f in config/systemd/sauvegarde.service config/systemd/sauvegarde.timer; do
    install -m 644 -o root -g root "$f" "/etc/systemd/system/$(basename "$f")"
done
systemctl daemon-reload
systemctl enable --now sauvegarde.timer
systemctl start sauvegarde.service

etape "12. Fichiers modifiables par tous et SUID hors /usr (D3)"
find $(findmnt -rn -o TARGET -t ext4,ext3,xfs,btrfs,vfat) -xdev \
    \( -path /sauvegardes -o -path /tmp -o -path /var/tmp \) -prune \
    -o -type f -perm -0002 -print -exec chmod o-w {} +
find $(findmnt -rn -o TARGET -t ext4,ext3,xfs,btrfs,vfat) -xdev \
    \( -path /sauvegardes -o -path /usr \) -prune \
    -o -type f -perm -4000 -print -exec chmod u-s {} +

etape "13. Services réseau inutiles (D2)"
for unite in avahi-daemon.socket avahi-daemon.service cups-browsed.service; do
    if systemctl cat "$unite" >/dev/null 2>&1; then
        systemctl disable --now "$unite"
        systemctl mask "$unite"
    fi
done

admins="$(lignes_csv | awk -F';' '$3 == "admins" {print $1}' | paste -sd '|')"
nouveaux="$(tail -n +"$((lignes_avant + 1))" "$FICHIER_MDP" 2>/dev/null | grep -E "^($admins):" || true)"
if [ -n "$nouveaux" ]; then
    echo
    echo "=== Identifiants des administrateurs créés (login:mot de passe) ==="
    echo "$nouveaux"
    echo "Notez-les maintenant : root est verrouillé, ce sont les seuls comptes avec sudo."
fi

echo
echo "=== Installation terminée. Lancez : sudo ./verifier.sh ==="
