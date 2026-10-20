# shellcheck shell=bash
# Task file format: frontmatter, body, ## Result, ## Log.

fm_get() {
  local raw out="" i c n
  raw="$(FM_KEY="$2" awk '
    NR == 1 { if ($0 != "---") exit; next }
    $0 == "---" { exit }
    { k = ENVIRON["FM_KEY"] ": "; if (index($0, k) == 1) { print substr($0, length(k) + 1); exit } }
  ' "$1")"
  case "$raw" in
    \"*\")
      raw="${raw#\"}"; raw="${raw%\"}"
      n="${#raw}"; i=0
      while [ "$i" -lt "$n" ]; do
        c="${raw:$i:1}"
        if [ "$c" = "\\" ] && [ $((i + 1)) -lt "$n" ]; then
          i=$((i + 1)); c="${raw:$i:1}"
        fi
        out="$out$c"
        i=$((i + 1))
      done
      raw="$out"
      ;;
  esac
  printf '%s\n' "$raw"
}

fm_quote_always() {
  local esc
  esc="$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  printf '"%s"\n' "$esc"
}

# Plain scalar when YAML-safe, double-quoted otherwise.
fm_quote() {
  local v="$1" re='^[A-Za-z0-9_~./][^"\\]*$' num='^[-+]?[0-9][0-9._:-]*$' lower
  # Lowercase via tr: Bash 3.2 has no ${v,,}.
  lower="$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')"
  if [[ "$v" =~ $re ]]; then
    case "$lower" in
      null|true|false|yes|no|on|off|"~") ;;
      *)
        if [[ "$v" =~ $num ]]; then :
        else
          case "$v" in
            *": "*|*" #"*|*:) ;;
            *) printf '%s\n' "$v"; return 0 ;;
          esac
        fi
        ;;
    esac
  fi
  fm_quote_always "$v"
}

# Free text must not contain lines that the Result/Log layout relies on.
reject_sections() {   # reject_sections <what> <text>
  local line
  while IFS= read -r line; do
    case "$line" in
      "## Log"|"## Result") die "$1 must not contain a '$line' line" ;;
    esac
  done <<< "$2"
}

# Dies unless line 1 is `---` and a closing `---` follows. Every mutating
# command calls this first, so the awk rewriters below never see a file whose
# frontmatter they could mistake for body text (or the reverse).
fm_require() {
  local ok=0
  awk '
    NR == 1 { if ($0 != "---") { bad = 1; exit } next }
    $0 == "---" { closed = 1; exit }
    END { exit (closed && !bad) ? 0 : 1 }
  ' "$1" || ok=1
  if [ "$ok" -ne 0 ]; then
    die "malformed frontmatter in ${1#"$STORE"/} (run 'task doctor')"
  fi
}

# Both rewriters exit non-zero (and leave the file alone) when the frontmatter
# has no closing `---`.
fm_set() {
  local file="$1" tmp="${1%.md}.$$.tmp"
  FM_KEY="$2" FM_VAL="$3" awk '
    BEGIN { k = ENVIRON["FM_KEY"]; v = ENVIRON["FM_VAL"]; infm = 0; done = 0; closed = 0 }
    NR == 1 && $0 == "---" { infm = 1; print; next }
    infm && $0 == "---" { if (!done) { print k ": " v; done = 1 } infm = 0; closed = 1; print; next }
    infm && index($0, k ": ") == 1 { if (!done) { print k ": " v; done = 1 } next }
    { print }
    END { if (!closed) exit 1 }
  ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$file"
}

fm_unset() {
  local file="$1" tmp="${1%.md}.$$.tmp"
  FM_KEY="$2" awk '
    BEGIN { k = ENVIRON["FM_KEY"]; infm = 0; closed = 0 }
    NR == 1 && $0 == "---" { infm = 1; print; next }
    infm && $0 == "---" { infm = 0; closed = 1; print; next }
    infm && index($0, k ": ") == 1 { next }
    { print }
    END { if (!closed) exit 1 }
  ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$file"
}

# Append-only, so it cannot damage existing content. `## Log` is looked up with
# grep: bodies and summaries may not contain that line (see reject_sections).
log_append() {
  local file="$1" author="$2" msg="$3" first=1 line
  [ -f "$file" ] || die "no such task file: $file"
  if [ -s "$file" ] && [ -n "$(tail -c 1 "$file")" ]; then printf '\n' >> "$file"; fi
  if ! grep -qx '## Log' "$file"; then
    if [ -n "$(tail -n 1 "$file")" ]; then printf '\n' >> "$file"; fi
    printf '## Log\n' >> "$file"
  fi
  while IFS= read -r line; do
    if [ "$first" -eq 1 ]; then
      printf -- '- %s %s: %s\n' "$(date '+%Y-%m-%d %H:%M')" "$author" "$line" >> "$file"
      first=0
    else
      printf '  %s\n' "$line" >> "$file"
    fi
  done <<< "$msg"
}

# Puts text into ## Result (created when missing), right before ## Log.
# Sections are only searched after the closing `---`; --body and --summary
# reject `## Log` / `## Result` lines, so the first ones found are the real ones.
# Fails (file untouched) when the frontmatter is not closed.
result_append() {
  local file="$1" tmp="${1%.md}.$$.tmp"
  RES_TEXT="$2" awk '
    { line[NR] = $0
      if (NR == 1) { if ($0 == "---") infm = 1; next }
      if (infm) { if ($0 == "---") { infm = 0; closed = 1 } next }
      if (closed && logat == 0 && $0 == "## Log") logat = NR }
    END {
      if (!closed) exit 1
      if (logat == 0) logat = NR + 1
      last = logat - 1
      while (last > 0 && line[last] == "") last--
      has = 0
      for (i = 1; i <= last; i++) { if (i > 1 && line[i] == "## Result") has = 1; print line[i] }
      if (!has) { print ""; print "## Result" }
      print ""
      print ENVIRON["RES_TEXT"]
      print ""
      for (i = logat; i <= NR; i++) print line[i]
    }
  ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$file"
}

# One line per file: path, id, title, project, created, session (tab-separated).
task_rows() {
  [ $# -gt 0 ] || return 0
  awk '
    function unq(v,   out, i, c, n) {
      if (length(v) >= 2 && substr(v, 1, 1) == "\"" && substr(v, length(v), 1) == "\"") {
        v = substr(v, 2, length(v) - 2); out = ""; n = length(v)
        for (i = 1; i <= n; i++) {
          c = substr(v, i, 1)
          if (c == "\\" && i < n) { i++; c = substr(v, i, 1) }
          out = out c
        }
        return out
      }
      return v
    }
    function flush() { if (cur != "") print cur "\t" id "\t" title "\t" project "\t" created "\t" session }
    FNR == 1 {
      flush(); cur = FILENAME; id = title = project = created = session = ""
      state = ($0 == "---") ? 1 : 0
      next
    }
    state == 1 {
      if ($0 == "---") { state = 2; next }
      p = index($0, ": ")
      if (p > 0) {
        k = substr($0, 1, p - 1); v = unq(substr($0, p + 2))
        if (k == "id") id = v
        else if (k == "title") title = v
        else if (k == "project") project = v
        else if (k == "created") created = v
        else if (k == "session") session = v
      }
    }
    END { flush() }
  ' "$@"
}

# Fills R_PATH R_ID R_TITLE R_PROJECT R_CREATED R_SESSION from a task_rows line.
# `read` with a tab IFS would merge empty fields, so split by hand.
# shellcheck disable=SC2034 # R_* are read by the callers
split_row() {
  local r="$1" t=$'\t'
  R_PATH="${r%%"$t"*}"; r="${r#*"$t"}"
  R_ID="${r%%"$t"*}"; r="${r#*"$t"}"
  R_TITLE="${r%%"$t"*}"; r="${r#*"$t"}"
  R_PROJECT="${r%%"$t"*}"; r="${r#*"$t"}"
  R_CREATED="${r%%"$t"*}"; r="${r#*"$t"}"
  R_SESSION="$r"
}
