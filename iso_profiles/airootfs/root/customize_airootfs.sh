#!/bin/bash
# Create a new user 'shani' with a home directory, add to wheel, and set shell to /bin/bash.
useradd -m -G wheel -s /bin/bash shani
echo "shani:shani" | chpasswd
echo "shani ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# Enable greetd service.
systemctl enable greetd
