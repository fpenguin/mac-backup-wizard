#!/usr/bin/env bash
#
# Run the whole test suite: Python unit tests + shell tests + syntax checks.

set -o pipefail
cd "$(dirname "$0")/.." || exit 2

status=0

echo "== syntax =="
bash -n mac-backup-wizard.sh || status=1
python3 -m py_compile mac-installed-apps.py mac-defined-app-picker.py \
  mac-settings-picker.py mac-settings-scan.py || status=1

echo
echo "== python unit tests =="
python3 -m unittest discover -s tests -p 'test_*.py' -v || status=1

echo
echo "== shell tests =="
bash tests/test_wizard.sh || status=1

echo
if [[ "$status" -eq 0 ]]; then
  echo "SUITE PASSED"
else
  echo "SUITE FAILED"
fi
exit "$status"
