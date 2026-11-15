#!/usr/bin/env bash
# Bash: heredocs (indented with tabs), case, arrays, expansions. Ünïcode ✓
set -euo pipefail

declare -A colors=([red]=1 [green]=2)
files=(*.txt "with space" $'tab\there')
name="${1:-world}"
upper="${name^^}"
count=$(( ${#files[@]} * 2 + 1 ))

greet() {
  local who="$1"
  printf 'hello %s\n' "$who"
}

cat <<EOF
Plain heredoc for $name
with $(date +%Y) and ${upper}
EOF

if [[ -n "$name" && $count -gt 1 ]]; then
	cat <<-INDENTED
		tab-indented heredoc
		ends at an indented marker
	INDENTED
fi

cat <<'RAW'
no $expansion here
RAW

case "$name" in
  world|earth) greet "$name" ;;
  *[0-9]*) echo "digits" ;&
  *) echo "other: ${name//o/0}" ;;
esac

for (( i = 0; i < 3; i++ )); do
  while read -r line; do
    [[ $line =~ ^#.*$ ]] && continue
    echo "${line%%:*}" | tr a-z A-Z > /dev/null 2>&1
  done < <(printf '%s\n' "${!colors[@]}")
done

result=$(greet "$(basename "$PWD")")
echo "$result" >> log.txt
