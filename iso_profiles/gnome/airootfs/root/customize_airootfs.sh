#!/bin/bash
# Create a new user 'shani' with a home directory, add to wheel, and set shell to /bin/bash.
useradd -m -G wheel -s /bin/bash shani
echo "shani:shani" | chpasswd
echo "shani ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# Enable greetd service.
systemctl enable greetd

# Copy custom image to the Plymouth spinner theme directory
if [ -f /root/watermark.png ]; then
    mkdir -p /usr/share/plymouth/themes/spinner
    cp /root/watermark.png /usr/share/plymouth/themes/spinner/watermark.png
    echo "[airootfs.sh] Custom Plymouth spinner theme image installed."
else
    echo "[airootfs.sh] Warning: /root/watermark.png not found, skipping custom image copy."
fi
