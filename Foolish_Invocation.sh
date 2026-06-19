systemctl disable getty@tty2.service
EOF

print_header "Step 7: Finalizing & Unmounting"
rm -f packages.json
umount -R /mnt

log_info "Installation Complete!"
echo -e "${GREEN}You can now reboot. rEFInd will load with your theme, BTRFS will mount, and your Python script will execute cleanly in Kitty on first login.${NC}"
