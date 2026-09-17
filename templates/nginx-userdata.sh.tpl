#!/bin/bash
set -euo pipefail

dnf install -y nginx
cat >/usr/share/nginx/html/healthz <<'EOF'
ok
EOF
systemctl enable --now nginx