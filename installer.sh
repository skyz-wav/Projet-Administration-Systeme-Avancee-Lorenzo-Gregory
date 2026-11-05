#!/bin/bash

# 1. Vérification des droits administrateur (root)
if [ "$EUID" -ne 0 ]; then
  echo "Erreur : Veuillez exécuter ce script en tant que root (avec sudo)."
  exit 1
fi

# Vérification de la présence du dossier config
if [ ! -d "config" ]; then
  echo "Erreur : Le dossier 'config/' est introuvable. Exécutez le script depuis la racine de votre projet."
  exit 1
fi

echo "=== 1. Mise à jour et installation des paquets ==="
apt-get update
# On installe sudo, le pare-feu et fail2ban
apt-get install -y sudo nftables fail2ban

echo "=== 2. Persistance des journaux (Exigence J3) ==="
mkdir -p /etc/systemd/journald.conf.d/
cp config/journald-persistent.conf /etc/systemd/journald.conf.d/
systemctl restart systemd-journald

echo "=== 3. Durcissement de SSH (Exigence J1) ==="
# On copie notre configuration SSH personnalisée
cp config/ssh/sshd_config.d/sshd_chiffres.conf /etc/ssh/sshd_config.d/
sshd -t
systemctl restart ssh

echo "=== 4. Configuration du Pare-feu nftables (Exigence J2) ==="
# On remplace la configuration par défaut par la nôtre
cp config/nftables.conf /etc/nftables.conf
systemctl enable --now nftables
systemctl restart nftables

echo "=== 5. Configuration de Fail2ban (Exigence J4) ==="
# On déploie la prison SSH (jail)
cp config/sshd.local /etc/fail2ban/jail.d/
systemctl enable --now fail2ban
systemctl restart fail2ban

echo "=== Installation et sécurisation terminées avec succès ! ==="