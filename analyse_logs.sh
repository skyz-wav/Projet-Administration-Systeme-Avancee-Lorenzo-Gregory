#!/bin/bash

SEUIL="${1:-${SEUIL:-5}}"
FICHIER="${2:-}"
 
if ! [[ "$SEUIL" =~ ^[0-9]+$ ]] || [ "$SEUIL" -lt 1 ]; then
    echo "Erreur : le seuil doit être un entier >= 1 (reçu : '$SEUIL')" >&2
    exit 2
fi
 
LOGS=$(mktemp) || exit 2
trap 'rm -f "$LOGS"' EXIT
 
if [ -n "$FICHIER" ]; then
    if [ ! -r "$FICHIER" ]; then
        echo "Erreur : fichier illisible : $FICHIER" >&2
        exit 2
    fi
    cat "$FICHIER" > "$LOGS"
else
    journalctl -u ssh -u sshd --no-pager -o short 2>/dev/null > "$LOGS"
    
    if [ ! -s "$LOGS" ] && [ -r /var/log/auth.log ]; then
        cat /var/log/auth.log > "$LOGS"
    fi
fi
 
if [ ! -s "$LOGS" ]; then
    echo "Erreur : aucun log SSH trouvé (droits insuffisants ? essayez avec sudo)" >&2
    exit 2
fi
 
ECHECS=$(grep -E "Failed (password|publickey|keyboard-interactive/pam) for|Invalid user|not allowed because" "$LOGS" \
         | grep -v "for invalid user")
 
echecs_par_ip() {
    echo "$ECHECS" | awk 'NF { for (i = 1; i < NF; i++) if ($i == "from") { print $(i+1); break } }' \
        | sort | uniq -c | sort -rn
}
 
comptes_vises() {
    echo "$ECHECS" | awk 'NF {
        for (i = 1; i <= NF; i++) {
            if ($i == "Invalid" && $(i+1) == "user") { print $(i+2); break }
            if ($i == "for")  { print $(i+1); break }
            if ($i == "User") { print $(i+1); break }
        }
    }' | sort | uniq -c | sort -rn
}
 
echo "===== Rapport SSH - $(date '+%Y-%m-%d %H:%M:%S') ====="
echo "Seuil d'alerte : $SEUIL échecs depuis une même IP"
echo
 
echo "--- Échecs par IP ---"
PAR_IP=$(echecs_par_ip)
if [ -n "$PAR_IP" ]; then echo "$PAR_IP"; else echo "(aucun échec)"; fi
echo
 
echo "--- Comptes visés ---"
COMPTES=$(comptes_vises)
if [ -n "$COMPTES" ]; then echo "$COMPTES"; else echo "(aucun)"; fi
echo
 
echo "--- Connexions réussies ---"
REUSSIES=$(grep -E "Accepted (publickey|password|keyboard-interactive/pam) for" "$LOGS" \
           | awk '{
               u = ""; ip = ""
               for (i = 1; i < NF; i++) {
                   if ($i == "for")  u  = $(i+1)
                   if ($i == "from") ip = $(i+1)
               }
               print $1, $2, $3 " : " u " depuis " ip
           }')
if [ -n "$REUSSIES" ]; then echo "$REUSSIES"; else echo "(aucune)"; fi
echo
 
MAX=0
if [ -n "$PAR_IP" ]; then
    MAX=$(echo "$PAR_IP" | head -n 1 | awk '{print $1}')
fi
 
if [ "$MAX" -ge "$SEUIL" ]; then
    IP_MAX=$(echo "$PAR_IP" | head -n 1 | awk '{print $2}')
    echo "ALERTE : $IP_MAX a fait $MAX échecs (seuil : $SEUIL)"
    exit 1
fi
 
echo "OK : maximum $MAX échec(s) depuis une même IP (seuil : $SEUIL)"
exit 0