#!/bin/bash
useradd -m -G wheel -s /bin/bash shani
echo "shani:shani" | chpasswd
echo "shani ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

systemctl enable greetd
