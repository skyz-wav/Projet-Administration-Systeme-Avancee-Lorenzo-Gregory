#!/bin/bash

set -uo pipefail
export LC_ALL=C

if [ "$EUID" -ne 0 ]; then
    echo "Erreur : ce script doit être lancé en root (sudo ./verifier.sh)." >&2
    exit 2
fi

cd "$(dirname "$(readlink -f "$0")")"
[ -f comptes.csv ] || { echo "Erreur : comptes.csv introuvable dans $(pwd)." >&2; exit 2; }

REUSSIS=0
TOTAL=0
MARQUE=".verifier_$$"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; find /srv -name "$MARQUE*" -delete 2>/dev/null' EXIT

ok() { REUSSIS=$((REUSSIS + 1)); TOTAL=$((TOTAL + 1)); echo "[OK] $1 $2"; }
ko() { TOTAL=$((TOTAL + 1)); echo "[KO] $1 $2"; }

controle() {
    local attendu="$1" id="$2" msg="$3" obtenu=non
    ( set +o pipefail; eval "$4" ) >/dev/null 2>&1 && obtenu=oui
    if [ "$obtenu" = "$attendu" ]; then ok "$id" "$msg"; else ko "$id" "$msg"; fi
}

csv() {
    tail -n +2 comptes.csv | tr -d '\r' | sed 's/ *; */;/g; s/ *, */,/g' | awk -F';' 'NF && $1 != ""'
}
membre() { csv | awk -F';' -v g="$1" '$3 == g {print $1; exit}'; }
home_de() { getent passwd "$1" | cut -d: -f6; }
lire()    { sudo -u "$1" ls "$2"; }
ecrire()  { sudo -u "$1" touch "$2/$MARQUE.$1"; }
sshd_val() { sshd -T 2>/dev/null | awk -v k="$1" '$1 == k {print $2; exit}'; }

test_C1() {
    local login nom principal sec g erreurs="" sans_cle=""
    while IFS=';' read -r login nom principal sec; do
        if ! id "$login" >/dev/null 2>&1; then erreurs+=" $login"; continue; fi
        [ "$(id -gn "$login")" = "$principal" ] || erreurs+=" $login"
        for g in ${sec//,/ }; do
            id -nG "$login" | tr ' ' '\n' | grep -qx "$g" || erreurs+=" $login"
        done
        if [[ ",$sec," == *",acces_ssh,"* ]] && [ ! -s "$(home_de "$login")/.ssh/authorized_keys" ]; then
            sans_cle+=" $login"
        fi
    done < <(csv)
    if [ -z "$erreurs" ]; then ok C1 "comptes et groupes conformes à comptes.csv"; else ko C1 "comptes ou groupes incorrects :$erreurs"; fi
    if [ -z "$sans_cle" ]; then ok C1 "clés SSH installées pour acces_ssh"; else ko C1 "clé SSH absente :$sans_cle"; fi
}

test_C2() {
    local c r d s
    c="$(membre comptables)"; r="$(membre rh)"; d="$(membre direction)"; s="$(membre stagiaire)"
    if [ -z "$c" ] || [ -z "$r" ] || [ -z "$d" ] || [ -z "$s" ]; then
        ko C2 "il manque un utilisateur par groupe métier dans comptes.csv"
        return
    fi
    controle oui C2 "un comptable écrit dans /srv/dossiers_clients" "ecrire $c /srv/dossiers_clients"
    controle oui C2 "la direction lit /srv/dossiers_clients" "lire $d /srv/dossiers_clients"
    controle non C2 "la direction n'écrit pas dans /srv/dossiers_clients" "ecrire $d /srv/dossiers_clients"
    controle non C2 "un rh ne lit pas /srv/dossiers_clients" "lire $r /srv/dossiers_clients"
    controle oui C2 "un rh écrit dans /srv/rh" "ecrire $r /srv/rh"
    controle non C2 "un comptable ne lit pas /srv/rh" "lire $c /srv/rh"
    controle oui C2 "un stagiaire lit /srv/commun" "lire $s /srv/commun"
    controle non C2 "un stagiaire n'écrit pas dans /srv/commun" "ecrire $s /srv/commun"
    controle oui C2 "un stagiaire dépose dans /srv/commun/depot" "ecrire $s /srv/commun/depot"
    controle non C2 "un stagiaire ne liste pas /srv/commun/depot" "lire $s /srv/commun/depot"
    ecrire "$c" /srv/commun/depot >/dev/null 2>&1
    controle non C2 "un stagiaire ne lit pas les fichiers des autres dans depot" \
        "sudo -u $s test -r /srv/commun/depot/$MARQUE.$c"
    controle oui C2 "ACL par défaut présentes sur /srv" \
        "for r in /srv/dossiers_clients /srv/rh /srv/commun /srv/commun/depot; do
             getfacl -p \$r | grep -q '^default:group:[^:]' || exit 1
         done"
}

test_C3() {
    local admin autres="" login
    admin="$(membre admins)"
    controle oui C3 "les admins ont sudo" "sudo -l -U '$admin' | grep -q '(ALL : ALL) ALL'"
    controle oui C3 "le compte support ne peut lancer que analyse_logs.sh" \
        "sudo -l -U support | sed -n '/may run/,\$p' | tail -n +2 | grep -q analyse_logs.sh &&
         ! sudo -l -U support | sed -n '/may run/,\$p' | tail -n +2 | grep -v analyse_logs.sh | grep -q '[^[:space:]]'"
    for login in $(csv | awk -F';' '$3 != "admins" && $1 != "support" {print $1}'); do
        sudo -l -U "$login" 2>/dev/null | grep -q "not allowed" || autres+=" $login"
    done
    if [ -z "$autres" ]; then ok C3 "aucun autre compte n'a sudo"; else ko C3 "sudo autorisé pour :$autres"; fi
}

test_C4() {
    local login mode lisibles=""
    controle oui C4 "le compte root est verrouillé" "[ \"\$(passwd -S root | awk '{print \$2}')\" = L ]"
    for login in $(csv | cut -d';' -f1); do
        mode="$(stat -c %a "$(home_de "$login")" 2>/dev/null)" || { lisibles+=" $login"; continue; }
        (( 8#$mode & 8#077 )) && lisibles+=" $login"
    done
    if [ -z "$lisibles" ]; then ok C4 "répertoires personnels privés"; else ko C4 "répertoires personnels accessibles :$lisibles"; fi
}

test_S1() {
    controle oui S1 "connexion par clé uniquement" \
        "[ \"\$(sshd_val passwordauthentication)\" = no ] && [ \"\$(sshd_val pubkeyauthentication)\" = yes ] &&
         [ \"\$(sshd_val kbdinteractiveauthentication)\" = no ]"
}

test_S2() { controle oui S2 "connexion root refusée" "[ \"\$(sshd_val permitrootlogin)\" = no ]"; }

test_S3() { controle oui S3 "seul acces_ssh peut se connecter" "[ \"\$(sshd_val allowgroups)\" = acces_ssh ]"; }

test_S4() {
    local essais intervalle nombre
    essais="$(sshd_val maxauthtries)"; intervalle="$(sshd_val clientaliveinterval)"; nombre="$(sshd_val clientalivecountmax)"
    controle oui S4 "au plus 4 essais par connexion ($essais)" "[ '${essais:-99}' -le 4 ]"
    controle oui S4 "session inactive fermée en 15 min au plus" \
        "[ '${intervalle:-0}' -gt 0 ] && [ \$(( ${intervalle:-0} * ${nombre:-0} )) -le 900 ]"
}

test_S5() {
    controle oui S5 "configuration dans sshd_config.d et validée par sshd -t" \
        "compgen -G '/etc/ssh/sshd_config.d/*.conf' && sshd -t"
}

test_J1() {
    controle oui J1 "fail2ban actif et prison sshd en place" \
        "systemctl is-active fail2ban && fail2ban-client status sshd"
}

test_J2() {
    controle oui J2 "pare-feu : entrée refusée par défaut, SSH et établi autorisés" \
        "nft list chain inet filtre entree | grep -q 'policy drop' &&
         nft list chain inet filtre entree | grep -q 'established,related accept' &&
         nft list chain inet filtre entree | grep -q 'tcp dport 22 .*accept'"
    controle oui J2 "pare-feu chargé au démarrage" "systemctl is-enabled nftables"
}

test_J3() {
    controle oui J3 "journal persistant" \
        "systemd-analyze cat-config systemd/journald.conf | grep -qx 'Storage=persistent' && [ -d /var/log/journal ]"
}

test_J4() {
    local script=/usr/local/sbin/analyse_logs.sh i
    controle oui J4 "analyse_logs.sh appartient à root et n'est modifiable que par lui" \
        "[ \"\$(stat -c %U $script)\" = root ] && [ -z \"\$(find $script -perm /022)\" ]"
    for i in 1 2 3 4 5 6; do
        echo "Nov  5 12:00:0$i vm sshd[1]: Failed password for grendu from 192.0.2.10 port 22 ssh2"
    done > "$TMP/auth.log"
    controle oui J4 "code de sortie 1 au-dessus du seuil, 0 en dessous" \
        "! $script 5 $TMP/auth.log && $script 10 $TMP/auth.log"
}

for t in C1 C2 C3 C4 S1 S2 S3 S4 S5 J1 J2 J3 J4; do
    "test_$t"
done

echo "--- $REUSSIS / $TOTAL tests réussis"
[ "$REUSSIS" -eq "$TOTAL" ]
