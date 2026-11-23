#!/usr/bin/env bash
# Repository leak scan: credentials, private IPs, local paths, e-mails, agent/bid identifiers.
# Exit 0 only when there are zero findings.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2
fail=0

scan() {
  local label="$1" pattern="$2" out
  out="$(grep -RInE --exclude-dir=.git --exclude=MANIFEST.sha256 --exclude=secret-scan.sh \
    -- "$pattern" . 2>/dev/null || true)"
  if [ -n "$out" ]; then
    printf '[HIT] %s\n%s\n' "$label" "$out"
    fail=1
  else
    printf '[OK]  %s\n' "$label"
  fi
}

scan "private key"            'BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY'
scan "github token"           '(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})'
scan "cloud/api key"          '(AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9]{24,}|CLAWHUNT_API_KEY=[^ ]+)'
scan "db password value"      'POSTGRES_PASSWORD=[0-9a-fA-F]{16,}'
scan "private network IP"     '(^|[^0-9])(10\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])|192\.168)\.[0-9]{1,3}\.[0-9]{1,3}'
scan "local absolute path"    '([A-Za-z]:\\\\|/home/|/Users/)'
scan "e-mail address"         '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
scan "bid identifier"         '(36427|36428)'
scan "agent identifier"       '(agent[ _-]?[0-9]{3,}|[Aa]gentId[^0-9]{0,4}[0-9]{3,})'
scan "host name leak"         'iZ[0-9a-z]{10,}'

if find . -path ./.git -prune -o -type f \( -name '*.env' -o -name '.env*' \) -print | grep -q .; then
  printf '[HIT] forbidden env file present\n'
  fail=1
else
  printf '[OK]  no .env files\n'
fi

if [ "$fail" -eq 0 ]; then
  echo "scan_result=PASS"
else
  echo "scan_result=FAIL"
fi
exit "$fail"
