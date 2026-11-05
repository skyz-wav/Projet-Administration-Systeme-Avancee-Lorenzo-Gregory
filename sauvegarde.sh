#!/bin/bash

set -euo pipefail

DEST="/sauvegardes"
SOURCES=(/srv /etc)
GARDER="${1:-7}"

journal() { echo "$*"; logger -t sauvegarde -- "$*"; }

if [ "$EUID" -ne 0 ]; then
    echo "Erreur : ce script doit être lancé en root (sudo $0)." >&2
    exit 1
fi
if ! [[ "$GARDER" =~ ^[0-9]+$ ]] || [ "$GARDER" -lt 7 ]; then
    echo "Erreur : le nombre de versions à garder doit être un entier >= 7 (reçu : '$GARDER')." >&2
    exit 2
fi
if ! mountpoint -q "$DEST"; then
    journal "Erreur : $DEST n'est pas monté, sauvegarde annulée."
    exit 1
fi

versions() {
    find "$DEST" -mindepth 1 -maxdepth 1 -type d -name '20??-??-??_??????' | sort
}

trap 'journal "Échec de la sauvegarde ${date:-}"' ERR

date="$(date +%Y-%m-%d_%H%M%S)"
precedente="$(versions | tail -n 1)"
rm -rf "$DEST"/*.en_cours

journal "Début de la sauvegarde $date${precedente:+ (base : $(basename "$precedente"))}"
rsync -aAXH --numeric-ids --delete ${precedente:+--link-dest="$precedente"} \
    "${SOURCES[@]}" "$DEST/$date.en_cours/"
mv "$DEST/$date.en_cours" "$DEST/$date"

versions | head -n -"$GARDER" | while read -r ancienne; do
    rm -rf "$ancienne"
    journal "Suppression de l'ancienne version $(basename "$ancienne")"
done

journal "Fin de la sauvegarde $date ($(versions | wc -l) versions conservées)"
