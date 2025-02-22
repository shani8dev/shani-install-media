#!/bin/bash
# Create a new user 'shani' with a home directory, add to wheel, and set shell to /bin/bash.
useradd -m -G wheel -s /bin/bash shani
echo "shani:shani" | chpasswd
echo "shani ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# Enable greetd service.
systemctl enable greetd

# This ensures that the custom hook is applied after pacstrap has finished.
if [ -f /root/archiso ]; then
    echo "[INFO] Moving custom archiso hook from /root to /usr/lib/initcpio/hooks/archiso..."
    mv /root/archiso /usr/lib/initcpio/hooks/archiso || {
        echo "[ERROR] Failed to move custom archiso hook" >&2
        exit 1
    }
else
    echo "[WARNING] Custom archiso hook not found in /root; skipping move."
fi
