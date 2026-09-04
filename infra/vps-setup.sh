#!/usr/bin/env bash
# One-time provisioning for a fresh Ubuntu 24.04 (Docker template) VPS.
# Run as: curl -fsSL <raw-url-to-this-file> | bash
# or: scp this file up, then `bash vps-setup.sh`.
#
# Brings up: Docker infra (Postgres+PostGIS, Redis), Node 20, the backend
# and admin console dependencies, and a Flutter/Android toolchain for
# device passes. Does NOT fill in secrets (PayPal, Firebase, Twilio,
# Postmark, AWS) — those are gitignored and have to come from you; see the
# "Manual follow-ups" section printed at the end.

set -euo pipefail

REPO_URL="https://github.com/rupanaalbert/app-cleaner.git"
REPO_DIR="$HOME/sparkle-platform"

log() { echo -e "\n\033[1;36m==> $1\033[0m"; }

log "System update"
sudo apt-get update -y
sudo apt-get upgrade -y

log "Base packages"
sudo apt-get install -y git curl unzip xz-utils zip build-essential \
  ca-certificates gnupg lib32stdc++6 libpulse0

log "Checking Docker (template should already have it)"
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sudo sh
fi
sudo usermod -aG docker "$USER"
docker compose version

log "Node.js 20 (NodeSource)"
if ! command -v node &>/dev/null || [[ "$(node -v)" != v20* ]]; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get install -y nodejs
fi
node -v
npm -v

log "Cloning the repo"
if [ ! -d "$REPO_DIR" ]; then
  git clone "$REPO_URL" "$REPO_DIR"
else
  echo "Already cloned at $REPO_DIR, pulling latest"
  git -C "$REPO_DIR" pull
fi
cd "$REPO_DIR"

log "Starting Postgres+PostGIS and Redis"
sudo docker compose -f infra/docker-compose.yml up -d
echo "Waiting for Postgres to report healthy..."
until [ "$(sudo docker inspect -f '{{.State.Health.Status}}' "$(sudo docker compose -f infra/docker-compose.yml ps -q db)" 2>/dev/null)" = "healthy" ]; do
  sleep 2
done

log "Backend: npm install + .env scaffold"
cd "$REPO_DIR/backend"
npm install
if [ ! -f .env ]; then
  cp .env.example .env
  # Generate real JWT secrets in place of the shipped placeholders — the
  # app refuses to boot on anything shorter than 16 chars anyway.
  ACCESS_SECRET="$(openssl rand -hex 32)"
  REFRESH_SECRET="$(openssl rand -hex 32)"
  sed -i "s#^JWT_ACCESS_SECRET=.*#JWT_ACCESS_SECRET=${ACCESS_SECRET}#" .env
  sed -i "s#^JWT_REFRESH_SECRET=.*#JWT_REFRESH_SECRET=${REFRESH_SECRET}#" .env
  echo "Wrote backend/.env with fresh JWT secrets. PayPal/Firebase/Twilio/Postmark/AWS keys still need filling in — see below."
fi

log "Migrations + seed data"
npm run migrate:up
npm run seed -- --reset

log "Admin console: npm install"
cd "$REPO_DIR/admin"
npm install

log "JDK 21 (for the Android toolchain)"
sudo apt-get install -y openjdk-21-jdk-headless
java -version

log "Android command-line tools"
ANDROID_HOME="$HOME/android-sdk"
mkdir -p "$ANDROID_HOME/cmdline-tools"
if [ ! -d "$ANDROID_HOME/cmdline-tools/latest" ]; then
  curl -fsSL -o /tmp/cmdline-tools.zip \
    https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
  unzip -q /tmp/cmdline-tools.zip -d "$ANDROID_HOME/cmdline-tools"
  mv "$ANDROID_HOME/cmdline-tools/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest"
fi

{
  echo "export ANDROID_HOME=\"$ANDROID_HOME\""
  echo "export PATH=\"\$PATH:\$ANDROID_HOME/cmdline-tools/latest/bin:\$ANDROID_HOME/platform-tools:\$ANDROID_HOME/emulator\""
} >> "$HOME/.bashrc"
export ANDROID_HOME
export PATH="$PATH:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator"

yes | sdkmanager --licenses >/dev/null || true
sdkmanager --install "platform-tools" "platforms;android-34" "emulator" \
  "system-images;android-34;aosp_atd;x86_64"

log "Checking for hardware-accelerated virtualization (KVM)"
if [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
  echo "/dev/kvm present and accessible — the emulator can run accelerated."
else
  echo "WARNING: /dev/kvm not accessible. Hostinger's KVM VPS product name refers"
  echo "to the HOST's hypervisor, not nested virtualization for guests — the"
  echo "emulator likely has to run unaccelerated (-no-accel), which is much"
  echo "slower than local. Confirm with Hostinger support if this matters."
  sudo apt-get install -y cpu-checker
  kvm-ok || true
fi

log "Creating the AVD (software-rendering, matches the local dev config)"
echo "no" | avdmanager create avd -n sparkle_vps -k "system-images;android-34;aosp_atd;x86_64" --force

log "Flutter SDK (stable channel)"
if [ ! -d "$HOME/flutter" ]; then
  git clone https://github.com/flutter/flutter.git -b stable "$HOME/flutter"
fi
echo "export PATH=\"\$PATH:\$HOME/flutter/bin\"" >> "$HOME/.bashrc"
export PATH="$PATH:$HOME/flutter/bin"
flutter precache
flutter doctor -v || true

cd "$REPO_DIR/mobile/customer_app" && flutter pub get
cd "$REPO_DIR/mobile/cleaner_app" && flutter pub get

log "Done. Log out and back in (or run 'newgrp docker') for the docker group to take effect."

cat <<'EOF'

=========================== Manual follow-ups ===========================

1. Secrets that can't be scripted (all gitignored locally, copy from your
   machine with scp):
     scp backend/secrets/firebase.json          <vps>:~/sparkle-platform/backend/secrets/
     scp mobile/customer_app/android/app/google-services.json <vps>:~/sparkle-platform/mobile/customer_app/android/app/
     scp mobile/cleaner_app/android/app/google-services.json  <vps>:~/sparkle-platform/mobile/cleaner_app/android/app/

   Then fill in backend/.env by hand: PAYPAL_CLIENT_ID/SECRET/WEBHOOK_ID,
   FIREBASE_DATABASE_URL, TWILIO_*, POSTMARK_TOKEN, AWS_*, GOOGLE_MAPS_KEY,
   CHECKR_API_KEY. Copy the real values from your local backend/.env —
   don't regenerate them, they're tied to real sandbox/live accounts.

2. Start the backend and worker (each in its own screen/tmux pane so they
   survive disconnecting):
     cd ~/sparkle-platform/backend && npm run dev
     cd ~/sparkle-platform/backend && npm run worker

3. Start the admin console:
     cd ~/sparkle-platform/admin && npm run dev -- --host

4. Reach services from your laptop over SSH tunnels rather than opening
   firewall ports:
     ssh -L 8080:localhost:8080 -L 5173:localhost:5173 <user>@<vps-ip>
   Then browse http://localhost:5173 locally, same as before.

5. Run the emulator headless and pull screenshots to review visually
   instead of needing a GUI/VNC session:
     emulator -avd sparkle_vps -no-window -gpu swiftshader_indirect &
     # once booted:
     adb wait-for-device
     cd ~/sparkle-platform/mobile/cleaner_app && flutter run -d emulator-5554
     # to grab a screenshot for review:
     adb shell screencap -p /sdcard/screen.png
     adb pull /sdcard/screen.png .
     scp <vps-ip>:~/sparkle-platform/mobile/cleaner_app/screen.png .

===========================================================================
EOF
