#!/bin/bash
MDP="Projet_2026"
while IFS=';' read -r login nom groupe_principal groupes_secondaires password || [ -n "$login" ]
do
    [ -z "$login" ] && continue

    groupadd -f "$groupe_principal"

    if [ -n "$groupes_secondaires" ]; then
        IFS=',' read -ra groupes <<< "$groupes_secondaires"
        for g in "${groupes[@]}"; do
            groupadd -f "$g"
        done
    fi

    useradd -m -s /bin/bash -c "$nom" -g "$groupe_principal" \
        ${groupes_secondaires:+-G "$groupes_secondaires"} "$login"

    echo "$login:$MDP" | chpasswd
done < <(tail -n +2 comptes.csv | tr -d '\r' | sed 's/ *; */;/g')